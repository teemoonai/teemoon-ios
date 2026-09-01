//
//  StreamSuppressionTests.swift
//  teemoonTests
//
//  "It still returns the bottom half of a fast generation in one batch."
//
//  The renderer was ruled out on the device: `StreamTrace` showed the paced
//  text never once behind `llm.output` over 82,613 characters. The batching was
//  in delivery: `SSEStreamParser`'s text tool-call suppression was STICKY —
//  once a marker was seen with tools configured, content stopped being
//  forwarded for the rest of the turn (measured here: 70 of 156 chars, the
//  rest withheld to [DONE]). Grounding attaches a tool to every chat when a
//  Brave key is configured, so that was a default-configuration defect.
//
//  The fix elides only the markup REGION — from an opening marker to its
//  format's closing marker (ToolCallFormat.markerPairs) — and resumes
//  forwarding after it. These tests drive the real parser through its
//  test-visible entry point and pin the contract:
//
//    1. prose before a marker streams;
//    2. prose after a CLOSED tool call streams too, rather than batching;
//    3. raw markup never reaches the forwarded stream — including a marker
//       split across SSE deltas, which must not be forwarded-then-retracted;
//    4. an UNTERMINATED region stays suppressed to end of turn (leaking half a
//       call would be worse than batching its tail).
//

import XCTest
@testable import teemoon

final class StreamSuppressionTests: XCTestCase {

    /// One SSE content-delta event. JSON-serialized (not string-templated) so
    /// markers containing quotes or newlines arrive exactly as a server would
    /// send them.
    private func chunk(_ text: String) -> String {
        let payload: [String: Any] = [
            "choices": [[
                "index": 0,
                "delta": ["content": text],
                "finish_reason": NSNull(),
            ] as [String: Any]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    /// Forwarded visible text, as the transport downstream would reassemble it.
    private func forwardedText(_ sse: String, hasTools: Bool) -> String {
        let result = SSEStreamParser.processSSEChunks(Data(sse.utf8), hasTools: hasTools)
        var out = ""
        for line in String(decoding: result.forwarded, as: UTF8.self).split(separator: "\n") {
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst("data: ".count)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else { continue }
            out += content
        }
        return out
    }

    /// Regression (2026-08-06): the parser must record that the wire said
    /// [DONE], because the transport breaks its read loop on this flag rather
    /// than waiting for connection close. A keep-alive server whose response
    /// has neither Content-Length nor chunking never closes, and without the
    /// flag a finished reply sat under a live stop control until the request's
    /// idle timeout.
    func testDoneIsRecordedSoTheTransportCanStopReading() {
        let parser = SSEStreamParser(hasTools: false)
        _ = parser.consume(Data(chunk("hello ").utf8))
        XCTAssertFalse(parser.sawDone, "no [DONE] has arrived yet")
        _ = parser.consume(Data("data: [DONE]\n\n".utf8))
        XCTAssertTrue(parser.sawDone, "the wire said [DONE]; the flag must say so")
    }

    /// The control: no marker, everything streams.
    func testAllContentIsForwardedWhenNoToolMarkerAppears() {
        let sse = (0..<10).map { chunk("part \($0). ") }.joined()
        XCTAssertEqual(forwardedText(sse, hasTools: true).isEmpty, false)
        XCTAssertTrue(forwardedText(sse, hasTools: true).contains("part 9."),
                      "ordinary content must stream through untouched")
    }

    /// The fix. A complete tool call halfway through an answer: the prose after
    /// it must stream too, not arrive in one batch at end of turn — and the
    /// markup between the halves must not exist in the forwarded stream.
    func testProseAfterAClosedToolCallResumesStreaming() {
        var sse = (0..<5).map { chunk("first half \($0). ") }.joined()
        sse += chunk(#"<tool_call>{"name": "web_search", "arguments": {"query": "windfinder"}}</tool_call>"#)
        sse += (0..<5).map { chunk("second half \($0). ") }.joined()
        sse += "data: [DONE]\n\n"

        let withTools = forwardedText(sse, hasTools: true)
        let withoutTools = forwardedText(sse, hasTools: false)

        print("[suppression] forwarded WITH tools:    \(withTools.count) chars")
        print("[suppression] forwarded WITHOUT tools: \(withoutTools.count) chars")

        XCTAssertTrue(withTools.contains("first half 4."),
                      "text before the marker should already have streamed")
        XCTAssertTrue(withTools.contains("second half 4."),
            "content after a CLOSED tool call must keep streaming "
            + "(\(withTools.count) chars forwarded vs \(withoutTools.count) without tools) — "
            + "withholding it to [DONE] is the reported 'bottom half of a fast "
            + "generation in one batch'")
        XCTAssertFalse(withTools.contains("<tool_call>"), "opening markup leaked")
        XCTAssertFalse(withTools.contains("</tool_call>"), "closing markup leaked")
        XCTAssertFalse(withTools.contains("web_search"), "tool-call payload leaked")
        // The call itself must still be detected and executed — resuming the
        // prose must not cost the tool round.
        let result = SSEStreamParser.processSSEChunks(Data(sse.utf8), hasTools: true)
        XCTAssertTrue(result.toolCallDetected, "the closed call must still be recovered at [DONE]")
        XCTAssertEqual(result.toolCalls[0]?.name, "web_search")
    }

    /// Non-negotiable: raw markup never appears in the forwarded stream, even
    /// when payload and tags are spread across many deltas.
    func testToolCallMarkupIsNeverForwarded() {
        var sse = chunk("Checking. ")
        sse += chunk("<tool_call>")
        sse += chunk(#"{"name": "web_search", "arguments": {"query": "Da Nang"}}"#)
        sse += chunk("</tool_call>")
        sse += chunk("Found it.")
        sse += "data: [DONE]\n\n"

        let forwarded = forwardedText(sse, hasTools: true)
        XCTAssertFalse(forwarded.contains("<tool_call>"))
        XCTAssertFalse(forwarded.contains("</tool_call>"))
        XCTAssertFalse(forwarded.contains("web_search"))
        XCTAssertFalse(forwarded.contains("Da Nang"))
        XCTAssertTrue(forwarded.contains("Checking."))
        XCTAssertTrue(forwarded.contains("Found it."))
    }

    /// A region that opens and never closes — the turn ends mid-markup. The
    /// unterminated tail must stay suppressed: partial markup must not leak,
    /// and neither must payload the model wrote after the marker.
    func testUnterminatedMarkupStaysSuppressed() {
        var sse = (0..<5).map { chunk("first half \($0). ") }.joined()
        sse += chunk("<tool_call>")
        sse += chunk(#"{"name": "web_search""#)
        sse += (0..<5).map { chunk("tail \($0). ") }.joined()
        sse += "data: [DONE]\n\n"

        let forwarded = forwardedText(sse, hasTools: true)
        XCTAssertTrue(forwarded.contains("first half 4."),
                      "prose before the marker still streams")
        XCTAssertFalse(forwarded.contains("<tool_call>"), "unterminated markup leaked")
        XCTAssertFalse(forwarded.contains("web_search"), "payload of an unterminated call leaked")
        XCTAssertFalse(forwarded.contains("tail 4."),
            "everything inside an unterminated region stays suppressed — "
            + "the end-of-turn sanitize pass, not the stream, decides what of it survives")
    }

    /// Markers split across SSE deltas: the half-marker at a chunk boundary
    /// must be neither missed (leaking markup) nor forwarded-then-retracted.
    func testMarkerSplitAcrossChunkBoundariesIsStillElided() {
        var sse = chunk("Before. ")
        sse += chunk("<tool_")           // opening marker, half…
        sse += chunk("call>")            // …and half
        sse += chunk(#"{"name": "web_search", "arguments": {"query": "split"}}"#)
        sse += chunk("</tool_")          // closing marker, half…
        sse += chunk("call>After.")      // …and half, prose resuming in the same delta
        sse += "data: [DONE]\n\n"

        let forwarded = forwardedText(sse, hasTools: true)
        XCTAssertTrue(forwarded.contains("Before."))
        XCTAssertTrue(forwarded.contains("After."),
                      "prose resuming right after a split closing marker must stream")
        XCTAssertFalse(forwarded.contains("<tool_"),
                       "a partial marker was forwarded — it can't be retracted once shown")
        XCTAssertFalse(forwarded.contains("call>"), "markup fragment leaked")
        XCTAssertFalse(forwarded.contains("web_search"), "payload leaked")
    }

    /// A second marker family — Gemma's fenced ```tool_code — must get the same
    /// region elision, not just `<tool_call>`.
    func testGemmaToolCodeFenceIsElidedAndProseResumes() {
        var sse = chunk("Let me look that up. ")
        sse += chunk("```tool_code\nweb_search(query=\"weather in SF\")\n```")
        sse += chunk(" Here is what I found.")
        sse += "data: [DONE]\n\n"

        let forwarded = forwardedText(sse, hasTools: true)
        XCTAssertTrue(forwarded.contains("Let me look that up."))
        XCTAssertTrue(forwarded.contains("Here is what I found."),
                      "prose after the closed fence must stream")
        XCTAssertFalse(forwarded.contains("tool_code"), "fence markup leaked")
        XCTAssertFalse(forwarded.contains("web_search"), "fenced call payload leaked")

        let result = SSEStreamParser.processSSEChunks(Data(sse.utf8), hasTools: true)
        XCTAssertTrue(result.toolCallDetected, "the Gemma call must still be recovered")
        XCTAssertEqual(result.toolCalls[0]?.name, "web_search")
    }

    /// A holdback tail that turns out to be plain prose (here: a `<` comparison
    /// at a chunk boundary) must still reach `visibleContent` — held only until
    /// disambiguated, released at latest when the turn finishes.
    func testAmbiguousMarkerPrefixAtChunkBoundaryIsReleased() {
        var sse = chunk("a <tool")   // prefix of <tool_call>, held back…
        sse += chunk(" is what it is. ")  // …then disambiguated as prose
        sse += "data: [DONE]\n\n"

        let forwarded = forwardedText(sse, hasTools: true)
        XCTAssertTrue(forwarded.contains("a <tool is what it is."),
                      "prose that merely LOOKS like a marker prefix must not be lost")
    }
}
