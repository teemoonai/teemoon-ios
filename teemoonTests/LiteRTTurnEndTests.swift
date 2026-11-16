//
//  LiteRTTurnEndTests.swift
//  teemoonTests
//
//  reply-machine.json G7 on device: the answer cap followed by a drain timeout is a cut-short reply, never the
//  background interruption that triggers an automatic re-ask; only the app leaving the foreground is.
//

import Foundation
import Testing
@testable import teemoon

@Suite("How an on-device turn ended")
struct LiteRTTurnEndTests {

    @Test func aDrainTimeoutAfterTheCapIsNotAnInterruption() {
        guard case .success(let text) = LiteRTTransport.abandonOutcome(backgrounded: false, shown: "") else {
            Issue.record("a cap + drain timeout with nothing shown read as an interruption (auto re-ask)")
            return
        }
        #expect(text == "")
        if case .success(let partial) = LiteRTTransport.abandonOutcome(backgrounded: false, shown: "Looping") {
            #expect(partial == "Looping")
        } else { Issue.record("the shown partial was lost") }
    }

    @Test func leavingTheForegroundIsAnInterruption() {
        guard case .failure(let error) = LiteRTTransport.abandonOutcome(backgrounded: true, shown: "Title line") else {
            Issue.record("a backgrounded turn handed back an answer")
            return
        }
        #expect(error is CancellationError)
    }

    @Test func theCapIsALengthFinish() {
        #expect(LiteRTTransport.turnEnd(hitCap: true) == .length)
        #expect(LiteRTTransport.turnEnd(hitCap: false) == .stop)
    }
}
