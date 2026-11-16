//
//  WebSearchOfferModelTests.swift
//  teemoonTests
//
//  The offer card: pasting twice re-asked the question twice, and dismissing the
//  card while brave was still checking let the check finish, save the key and
//  turn search on anyway.
//

import Foundation
import Testing
@testable import teemoon

@MainActor
@Suite("Web search offer — stale runs")
struct WebSearchOfferModelTests {

    final class Recorder { var accepted: [String] = []; var dismissed = 0 }

    /// One gate per beat, in call order.
    actor Beats {
        let gates = [AsyncGate(), AsyncGate()]
        private var next = 0
        func beat() async { let gate = gates[next]; next += 1; await gate.pass() }
    }

    @Test func pastingTwiceAsksAgainOnceWithTheLastKey() async {
        let beats = Beats()
        let rec = Recorder()
        let model = WebSearchOfferModel(checker: { _ in .valid }, beat: { await beats.beat() })
        let first = Task { await model.paste("key-one", onAccepted: { rec.accepted.append($0) }) }
        await beats.gates[0].reached()
        let second = Task { await model.paste("key-two", onAccepted: { rec.accepted.append($0) }) }
        await beats.gates[1].reached()
        await beats.gates[0].open()
        await beats.gates[1].open()
        await first.value
        await second.value
        #expect(rec.accepted == ["key-two"], "each acceptance saves the key and re-sends the question")
    }

    @Test func dismissingWhileBraveChecksSavesNothing() async {
        let gate = AsyncGate()
        let rec = Recorder()
        let model = WebSearchOfferModel(checker: { _ in await gate.pass(); return .valid }, beat: {})
        let paste = Task { await model.paste("key-one", onAccepted: { rec.accepted.append($0) }) }
        await gate.reached()
        model.dismiss { rec.dismissed += 1 }
        await gate.open()
        await paste.value
        #expect(rec.dismissed == 1)
        #expect(rec.accepted.isEmpty, "a dismissed offer must not save the key or turn search on")
    }

    @Test func dismissingDuringTheBeatSavesNothing() async {
        let gate = AsyncGate()
        let rec = Recorder()
        let model = WebSearchOfferModel(checker: { _ in .valid }, beat: { await gate.pass() })
        let paste = Task { await model.paste("key-one", onAccepted: { rec.accepted.append($0) }) }
        await gate.reached()
        model.dismiss { rec.dismissed += 1 }
        await gate.open()
        await paste.value
        #expect(rec.accepted.isEmpty)
    }
}
