//
//  BraveKeyCheckRunTests.swift
//  teemoonTests
//
//  Search settings: "brave accepted this key" stayed on screen after the key was
//  edited or cleared, and a slow check for an earlier key could finish last and
//  turn search on for a key brave had just rejected.
//

import Foundation
import Testing
@testable import teemoon

@MainActor
@Suite("Brave key check — stale results")
struct BraveKeyCheckRunTests {

    /// Each key answers its own verdict, after its gate (if any) opens.
    private func checker(_ verdicts: [String: BraveWebSearchTool.KeyCheck],
                         gates: [String: AsyncGate] = [:]) -> BraveKeyCheckRun.Checker {
        { key in
            if let gate = gates[key] { await gate.pass() }
            return verdicts[key] ?? .rejected
        }
    }

    @Test func editingTheKeyClearsWhatBraveSaidAboutTheOldOne() async {
        let run = BraveKeyCheckRun(checker: checker(["good": .valid]))
        _ = await run.check("good")
        #expect(run.result == .valid)
        run.keyEdited()
        #expect(run.result == nil, "the field changed; brave's answer was about the old text")
    }

    @Test func aCheckOvertakenByALaterOneCannotTurnSearchOn() async {
        let gate = AsyncGate()
        let run = BraveKeyCheckRun(checker: checker(["good": .valid, "bad": .rejected], gates: ["good": gate]))
        let first = Task { await run.check("good") }
        await gate.reached()
        let second = await run.check("bad")
        await gate.open()
        let late = await first.value
        #expect(second == .rejected)
        #expect(late == nil, "a superseded check must not report .valid — the view enables search on it")
        #expect(run.result == .rejected)
        #expect(!run.checking)
    }

    @Test func aCheckOvertakenByAnEditWritesNothing() async {
        let gate = AsyncGate()
        let run = BraveKeyCheckRun(checker: checker(["good": .valid], gates: ["good": gate]))
        let pending = Task { await run.check("good") }
        await gate.reached()
        run.keyEdited()
        #expect(!run.checking, "the spinner is for a key no longer in the field")
        await gate.open()
        #expect(await pending.value == nil)
        #expect(run.result == nil)
    }
}
