//
//  ConformanceRevealVectors.swift
//  teemoonTests
//
//  "Whole if quick" (the maintainer, 2026-10-25, picked in the canvas lab; pm settled (a)-(d) with Android). The first
//  paragraph's hold dropped to 250 ms on 2026-10-26 (the maintainer via pm): on-device first tokens are 0.5-0.8 s, and
//  a short reply held a further 600 ms read as late; (e) and (f) pin the split. On 2026-10-31 the maintainer dropped the
//  first hold on the phone after Android's Pixel clip ("drop it on device"); (g)-(i) pin onDevice. Each
//  expected value is worked by hand from the rule, not computed by StreamReveal, so a change to the model that
//  moves a probe fails here, and Android's StreamReveal runs the same rows.
//

import Foundation
import Testing
@testable import teemoon

struct RevealVectors: Encodable {
    struct Event: Encodable {
        let atMs: Double
        /// The cumulative answer text that has arrived; nil for the end of the stream.
        let arrive: String?
        let finish: Bool
    }
    struct Probe: Encodable {
        let atMs: Double
        let shown: String
        /// Where the paragraph fading in starts, as a character offset; nil when nothing fades.
        let fadeFrom: Int?
    }
    struct Case: Encodable {
        let name: String
        let note: String
        let events: [Event]
        let probes: [Probe]
        var source: StreamReveal.Origin = .cloud
    }
    struct Constants: Encodable {
        let firstHoldMs: Double, onDeviceFirstHoldMs: Double, holdMs: Double, fadeMs: Double, stepMs: String
        let divisor: Int, partialWaitMs: Double
    }
    let rule: String
    let harness: String
    let constants: Constants
    let cases: [Case]
}

enum ConformanceRevealVectors {
    static let rule = """
        A paragraph is the text between blank lines; a fenced block counts as one, and a paragraph's end includes \
        the blank line that closes it. A paragraph is held for holdMs from its first arrived character; the \
        answer's first paragraph (the one starting at offset 0) for firstHoldMs instead, or onDeviceFirstHoldMs \
        when the case's source is onDevice. If it \
        completes in that time it is shown whole and fades in over fadeMs (fadeFrom = its start). Otherwise the \
        reveal starts: the first frame after the hold takes exactly one step, and later frames take \
        floor(elapsed / stepMs) steps from the last step. A step moves the shown end ceil(deficit / divisor) \
        characters, then forward to the end of the word it lands in (before the following whitespace), when \
        that end has arrived. A trailing word still arriving holds the shown end at the last whitespace until \
        partialWaitMs after the reveal first ran into it, then shows to the arrived end. A paragraph that \
        completes after some of it was shown snaps whole without a fade; a new paragraph's arrival completes \
        the one before it. The end of the stream shows everything.
        """
    static let harness = """
        Start a StreamReveal for the case's source (cloud or onDevice). Replay events and probes in time order, \
        an event before a probe at the same time. An event calls \
        arrive(text, atMs) or finish(); a probe calls frame(atMs) and compares the shown prefix and fadeFrom. \
        frame() is called only at probe times. Texts are ASCII, so offsets are characters on both platforms.
        """

    static func arrive(_ t: Double, _ s: String) -> RevealVectors.Event { .init(atMs: t, arrive: s, finish: false) }
    static func finish(_ t: Double) -> RevealVectors.Event { .init(atMs: t, arrive: nil, finish: true) }
    static func probe(_ t: Double, _ s: String, fade: Int? = nil) -> RevealVectors.Probe {
        .init(atMs: t, shown: s, fadeFrom: fade)
    }

    static let cases: [RevealVectors.Case] = [
        .init(name: "quick-paragraph-whole-with-fade",
              note: "complete 200 ms after its first character: held, then whole, fading for 300 ms",
              events: [arrive(0, "Hello there."), arrive(200, "Hello there.\n\n")],
              probes: [probe(100, ""), probe(200, "Hello there.\n\n", fade: 0),
                       probe(499, "Hello there.\n\n", fade: 0), probe(500, "Hello there.\n\n")]),
        .init(name: "a-time-based-steps",
              note: """
                  48 characters still arriving: one step at 250 (ceil(48/9)=6, into "two", to 7); at 360, \
                  floor(110/16.67)=6 steps: 13, 18, 23, 27, 33, 39
                  """,
              events: [arrive(0, "one two three four five six seven eight nine ten")],
              probes: [probe(249, ""), probe(250, "one two"),
                       probe(360, "one two three four five six seven eight")]),
        .init(name: "b-partial-word-waits-300ms-from-the-run-in",
              note: """
                  "gamm" has no end yet: the reveal runs into it at 360 and holds at "beta" until 660; at \
                  670 it shows to the arrived end
                  """,
              events: [arrive(0, "alpha beta gamm")],
              probes: [probe(250, "alpha"), probe(360, "alpha beta"), probe(650, "alpha beta"),
                       probe(670, "alpha beta gamm")]),
        .init(name: "c-completes-mid-reveal-snaps-without-fade",
              note: "part of it was showing when it completed, so it snaps whole and nothing fades",
              events: [arrive(0, "alpha beta gamma delta"), arrive(300, "alpha beta gamma delta epsilon.\n\n")],
              probes: [probe(250, "alpha"), probe(300, "alpha beta gamma delta epsilon.\n\n")]),
        .init(name: "d-new-paragraph-snaps-the-previous-and-starts-its-own-hold",
              note: """
                  the second paragraph's first character arrives at 300: the first snaps whole (no fade) and the \
                  second is held for holdMs, until 900, when one step shows "next"
                  """,
              events: [arrive(0, "alpha beta gamma delta"), arrive(300, "alpha beta gamma delta\n\nnext para words")],
              probes: [probe(250, "alpha"), probe(300, "alpha beta gamma delta\n\n"),
                       probe(899, "alpha beta gamma delta\n\n"), probe(900, "alpha beta gamma delta\n\nnext")]),
        .init(name: "e-a-first-paragraph-completing-after-250ms-flows-in",
              note: """
                  completes at 400, inside 600 but past firstHoldMs: it started flowing at 250 ("Short"; at 310, \
                  floor(60/16.67)=3 steps reach "answer" and stop at the arriving "here."), then snaps whole \
                  with no fade
                  """,
              events: [arrive(0, "Short answer here."), arrive(400, "Short answer here.\n\n")],
              probes: [probe(249, ""), probe(250, "Short"), probe(310, "Short answer"),
                       probe(400, "Short answer here.\n\n")]),
        .init(name: "f-a-later-paragraph-still-waits-600ms",
              note: """
                  the first paragraph is complete at 0 and fades in; the second's first character also arrives at \
                  0 but it is held for holdMs, not firstHoldMs: nothing of it at 599, one step ("Second") at 600
                  """,
              events: [arrive(0, "First.\n\nSecond paragraph")],
              probes: [probe(0, "First.\n\n", fade: 0), probe(300, "First.\n\n"), probe(599, "First.\n\n"),
                       probe(600, "First.\n\nSecond")]),
        .init(name: "a-fence-is-one-paragraph",
              note: "the blank line inside the fence does not split it",
              events: [arrive(0, "```\nline one\n\nline two\n```\n\n")],
              probes: [probe(0, "```\nline one\n\nline two\n```\n\n", fade: 0)]),
        .init(name: "finished-paragraphs-show-at-once-and-finish-shows-all",
              note: "the first paragraph is complete on arrival; the second is held until the stream ends",
              events: [arrive(0, "First para.\n\nSecond"), finish(100)],
              probes: [probe(0, "First para.\n\n", fade: 0), probe(100, "First para.\n\nSecond")]),
        .init(name: "g-on-device-the-first-paragraph-flows-at-once",
              note: """
                  case (a) from the phone: no first hold, so the first step is at 0 (ceil(48/9)=6, into "two", to \
                  7) and at 110 floor(110/16.67)=6 steps reach "eight", as (a) does at 250 and 360
                  """,
              events: [arrive(0, "one two three four five six seven eight nine ten")],
              probes: [probe(0, "one two"), probe(110, "one two three four five six seven eight")],
              source: .onDevice),
        .init(name: "h-on-device-a-quick-first-paragraph-is-not-held-back",
              note: """
                  the quick paragraph from the phone: "Hello" shows at 0 (ceil(12/9)=2, to the end of the word); \
                  it completes at 200 with part of it showing, so it snaps whole without a fade
                  """,
              events: [arrive(0, "Hello there."), arrive(200, "Hello there.\n\n")],
              probes: [probe(0, "Hello"), probe(200, "Hello there.\n\n")],
              source: .onDevice),
        .init(name: "i-on-device-a-later-paragraph-still-waits-600ms",
              note: """
                  case (f) from the phone: only the first paragraph loses its hold; the second is held for \
                  holdMs, nothing of it at 599, one step ("Second") at 600
                  """,
              events: [arrive(0, "First.\n\nSecond paragraph")],
              probes: [probe(0, "First.\n\n", fade: 0), probe(599, "First.\n\n"),
                       probe(600, "First.\n\nSecond")],
              source: .onDevice),
    ]

    static func reveal() -> RevealVectors {
        RevealVectors(rule: rule, harness: harness,
                      constants: .init(firstHoldMs: StreamReveal.firstHoldMs, onDeviceFirstHoldMs: StreamReveal.onDeviceFirstHoldMs, holdMs: StreamReveal.holdMs, fadeMs: StreamReveal.fadeMs, stepMs: "1000/60",
                                       divisor: StreamReveal.divisor, partialWaitMs: StreamReveal.partialWaitMs),
                      cases: cases)
    }

    /// Replays one case and returns each probe's (shown, fadeFrom).
    static func replay(_ c: RevealVectors.Case) -> [(String, Int?)] {
        enum Step { case event(RevealVectors.Event), probe(RevealVectors.Probe) }
        let steps = (c.events.map { (t: $0.atMs, o: 0, s: Step.event($0)) }
                     + c.probes.map { (t: $0.atMs, o: 1, s: Step.probe($0)) })
            .sorted { ($0.t, $0.o) < ($1.t, $1.o) }
        var reveal = StreamReveal(origin: c.source)
        var arrived = ""
        var out: [(String, Int?)] = []
        for step in steps {
            switch step.s {
            case .event(let e):
                if e.finish { reveal.finish() } else if let text = e.arrive { arrived = text; reveal.arrive(text, at: e.atMs) }
            case .probe(let p):
                let shown = reveal.frame(at: p.atMs)
                out.append((String(arrived.prefix(shown.length)), shown.fadeFrom))
            }
        }
        return out
    }
}

@Suite("Conformance vectors — streaming reveal")
struct ConformanceRevealTests {

    @Test(arguments: ConformanceRevealVectors.cases.indices)
    func everyProbeShowsWhatTheRuleSays(_ index: Int) {
        let c = ConformanceRevealVectors.cases[index]
        for (probe, got) in zip(c.probes, ConformanceRevealVectors.replay(c)) {
            #expect(got.0 == probe.shown, "\(c.name) at \(probe.atMs) ms")
            #expect(got.1 == probe.fadeFrom, "\(c.name) at \(probe.atMs) ms: fade")
        }
    }

    /// Steps are counted in elapsed time: a 120 Hz caller lands where the vector's probe-only caller does.
    @Test func theRefreshRateDoesNotChangeTheReveal() {
        let text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen"
        func shown(frameEvery: Double) -> Int {
            var r = StreamReveal()
            r.arrive(text, at: 0)
            _ = r.frame(at: 600)
            var t = 600.0
            while t + frameEvery < 900 { t += frameEvery; _ = r.frame(at: t) }
            return r.frame(at: 900).length
        }
        #expect(shown(frameEvery: 1000.0 / 120) == shown(frameEvery: 1000.0 / 60))
        #expect(shown(frameEvery: 1000.0 / 120) == shown(frameEvery: 290))
    }

    @Test func theCommittedFixtureMatchesTheTable() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let url = ConformanceEmitTests.outputDirectory().appendingPathComponent("reveal.json")
        let committed = try Data(contentsOf: url)
        let fresh = try ConformanceEncoder.encode(ConformanceDocument(
            kitVersion: ConformanceVectors.kitVersion, fixtureClass: "reveal",
            sourceOfTruth: "teemoon-ios", vectors: ConformanceRevealVectors.reveal()))
        #expect(committed == fresh, "conformance/reveal.json is stale: run make conformance")
    }
}
