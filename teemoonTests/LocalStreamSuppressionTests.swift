//
//  LocalStreamSuppressionTests.swift
//  teemoonTests
//
//  The on-device sibling of StreamSuppressionTests. LiteRTTransport had the
//  same defect the SSE path was cured of in b364fad, in cruder form:
//
//      if !ToolCallFormat.containsAnyMarker(answer) { onPartialContent(answer) }
//
//  `answer` is the CUMULATIVE reply, so the first tool-call marker never left
//  it and partial updates froze for the rest of the turn — the on-device
//  answer then landed in one batch at the end. On-device models are part of
//  onboarding, and small local models are the likeliest to emit text tool
//  syntax (no server-side template decides when it is legal), so the latch
//  fired exactly where streaming matters most.
//
//  The fix drives the SAME machine as the network path — ToolMarkupElider,
//  factored out of SSEStreamParser — fed the per-chunk pieces the engine
//  yields, streaming its cumulative `visibleContent`. These tests exercise the
//  elider exactly as LiteRTTransport does (append a piece; if anything new
//  became visible, snapshot `visibleContent` as the partial the UI would get;
//  `finish()` at end of stream) and pin the same contract:
//
//    1. prose before a marker streams;
//    2. prose after a CLOSED tool call streams too, rather than batching;
//    3. raw markup never appears in ANY partial — including a marker split
//       across pieces, which must not be shown-then-retracted;
//    4. an UNTERMINATED region stays suppressed to end of turn;
//    5. the raw accumulation is untouched — elision is display-only, so the
//       end-of-turn consumers (thinking parse, sanitize, call recovery) still
//       see everything the model wrote.
//

import XCTest
@testable import teemoon

final class LocalStreamSuppressionTests: XCTestCase {

    /// Drives the elider the way LiteRTTransport's stream loop does and
    /// returns every snapshot `onPartialContent` would have received, plus the
    /// raw accumulation the transport keeps for the final TurnOutput.
    private func stream(_ pieces: [String]) -> (partials: [String], raw: String) {
        let elider = ToolMarkupElider()
        var partials: [String] = []
        var raw = ""
        for piece in pieces {
            raw += piece
            if !elider.append(piece).isEmpty {
                partials.append(elider.visibleContent)
            }
        }
        if !elider.finish().isEmpty {
            partials.append(elider.visibleContent)
        }
        return (partials, raw)
    }

    /// The control: no marker, every piece streams as it arrives.
    func testAllContentStreamsWhenNoMarkerAppears() {
        let pieces = (0..<10).map { "part \($0). " }
        let (partials, _) = stream(pieces)
        XCTAssertEqual(partials.count, pieces.count,
                       "every marker-free piece must produce a partial — that is the streaming")
        XCTAssertTrue(partials.last?.contains("part 9.") == true)
    }

    /// The fix. A complete tool call halfway through the answer: prose after
    /// it must KEEP producing partials instead of freezing to end of turn.
    func testProseAfterAClosedToolCallResumesStreaming() {
        var pieces = (0..<5).map { "first half \($0). " }
        pieces.append(#"<tool_call>{"name": "web_search", "arguments": {"query": "windfinder"}}</tool_call>"#)
        pieces += (0..<5).map { "second half \($0). " }
        let (partials, raw) = stream(pieces)

        // The defect this replaces, for the record: gate each cumulative
        // snapshot on "no marker anywhere yet", as LiteRTTransport used to.
        var oldAnswer = ""
        var oldPartials: [String] = []
        for piece in pieces {
            oldAnswer += piece
            if !ToolCallFormat.allMarkers.contains(where: { oldAnswer.contains($0) }) {
                oldPartials.append(oldAnswer)
            }
        }
        let beforeCall = partials.filter { !$0.contains("second half") }
        print("[local-suppression] old latch: \(oldPartials.count) partials, "
              + "froze at \(oldPartials.last?.count ?? 0) chars — "
              + "fixed: \(partials.count) partials, \(partials.last?.count ?? 0) chars live")
        XCTAssertEqual(oldPartials.last?.contains("second half") ?? false, false,
                       "control: the old gate really did freeze before the second half")

        XCTAssertTrue(beforeCall.contains { $0.contains("first half 4.") },
                      "text before the marker should already have streamed")
        XCTAssertTrue(partials.last?.contains("second half 4.") == true,
            "content after a CLOSED tool call must keep streaming — the old "
            + "containsAnyMarker(answer) gate latched here and batched the whole "
            + "second half to end of turn")
        XCTAssertGreaterThan(partials.filter { $0.contains("second half") }.count, 1,
            "the second half must arrive across multiple partials, not one batch")
        for p in partials {
            XCTAssertFalse(p.contains("<tool_call>"), "opening markup leaked")
            XCTAssertFalse(p.contains("</tool_call>"), "closing markup leaked")
            XCTAssertFalse(p.contains("web_search"), "tool-call payload leaked")
        }
        // Elision is display-only: the raw accumulation the transport hands to
        // end-of-turn consumers still contains everything the model wrote.
        XCTAssertTrue(raw.contains("<tool_call>"))
        XCTAssertEqual(ToolCallFormat.parseAny(raw, tools: [])[0]?.name, "web_search",
                       "the call must remain machine-readable from the raw answer")
    }

    /// Non-negotiable: raw markup never appears in any partial, even when the
    /// markers themselves are split mid-token across engine chunks.
    func testMarkupSplitAcrossPiecesNeverReachesAPartial() {
        let pieces = [
            "Checking. ",
            "<tool_",                    // opening marker, half…
            "call>",                     // …and half
            #"{"name": "web_search", "arguments": {"query": "Da Nang"}}"#,
            "</tool_",                   // closing marker, half…
            "call>Found it.",            // …and half, prose resuming in the same chunk
        ]
        let (partials, _) = stream(pieces)
        for p in partials {
            XCTAssertFalse(p.contains("<tool_"), "a partial marker was shown — it can't be retracted")
            XCTAssertFalse(p.contains("call>"), "markup fragment leaked")
            XCTAssertFalse(p.contains("web_search"), "payload leaked")
            XCTAssertFalse(p.contains("Da Nang"), "payload leaked")
        }
        XCTAssertTrue(partials.first?.contains("Checking.") == true)
        XCTAssertTrue(partials.last?.contains("Found it.") == true,
                      "prose resuming right after a split closing marker must stream")
    }

    /// LiteRT-specific contract: each partial REPLACES the displayed text, so
    /// a snapshot must never be rolled back — every partial is a prefix of the
    /// next, or the visible reply would flicker and retract.
    func testPartialsAreMonotonicPrefixes() {
        let pieces = [
            "a < b, and ",               // bare '<' — an ambiguous maybe-marker tail
            "then <tool",                // prefix of <tool_call>, held back…
            "_call>",                    // …completed: it WAS a marker
            #"{"name": "web_search", "arguments": {}}"#,
            "</tool_call>",
            " done <tool",               // held back again…
            " is prose this time.",      // …disambiguated as prose
        ]
        let (partials, _) = stream(pieces)
        for (a, b) in zip(partials, partials.dropFirst()) {
            XCTAssertTrue(b.hasPrefix(a),
                          "partial retracted: \(a.suffix(20)) → \(b.suffix(20))")
        }
        XCTAssertTrue(partials.last?.contains("a < b, and then") == true)
        XCTAssertTrue(partials.last?.contains("done <tool is prose this time.") == true,
                      "prose that merely LOOKS like a marker prefix must not be lost")
        XCTAssertFalse(partials.last?.contains("_call>") == true)
    }

    /// A region that opens and never closes — the turn ends mid-markup. The
    /// unterminated tail must stay suppressed: neither partial markup nor the
    /// payload the model wrote after the marker may reach a partial.
    func testUnterminatedMarkupStaysSuppressed() {
        var pieces = (0..<5).map { "first half \($0). " }
        pieces.append("<tool_call>")
        pieces.append(#"{"name": "web_search""#)
        pieces += (0..<5).map { "tail \($0). " }
        let (partials, _) = stream(pieces)

        XCTAssertTrue(partials.last?.contains("first half 4.") == true,
                      "prose before the marker still streams")
        for p in partials {
            XCTAssertFalse(p.contains("<tool_call>"), "unterminated markup leaked")
            XCTAssertFalse(p.contains("web_search"), "payload of an unterminated call leaked")
            XCTAssertFalse(p.contains("tail 4."),
                "everything inside an unterminated region stays suppressed — "
                + "the engine's end-of-turn sanitize, not the stream, decides what survives")
        }
    }

    /// A second marker family — Gemma's fenced ```tool_code — gets the same
    /// region elision. Gemma-class models are exactly what runs on-device, so
    /// for this path the non-<tool_call> family is the COMMON case.
    func testGemmaToolCodeFenceIsElidedAndProseResumes() {
        let pieces = [
            "Let me look that up. ",
            "```tool_code\nweb_search(query=\"weather in SF\")\n```",
            " Here is what I found.",
        ]
        let (partials, raw) = stream(pieces)
        XCTAssertTrue(partials.first?.contains("Let me look that up.") == true)
        XCTAssertTrue(partials.last?.contains("Here is what I found.") == true,
                      "prose after the closed fence must stream")
        for p in partials {
            XCTAssertFalse(p.contains("tool_code"), "fence markup leaked")
            XCTAssertFalse(p.contains("web_search"), "fenced call payload leaked")
        }
        XCTAssertEqual(ToolCallFormat.parseAny(raw, tools: [])[0]?.name, "web_search",
                       "the Gemma call must remain machine-readable from the raw answer")
    }

    /// A holdback tail that turns out to be plain prose at end of stream (the
    /// reply ENDS with something that could begin a marker) is released by
    /// `finish()` — held only until disambiguated, never dropped.
    func testAmbiguousMarkerPrefixAtEndOfStreamIsReleased() {
        let (partials, _) = stream(["The winner is x ", "<tool"])
        XCTAssertEqual(partials.last, "The winner is x <tool",
                       "prose that merely LOOKS like a marker prefix must be released at end of stream")
    }
}
