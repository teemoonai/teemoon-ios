//
//  LiteRTTurnWaitTests.swift
//  teemoonTests
//
//  The on-device turn's wait loop, without a model. Build 39's audit (2026-10-15)
//  found the loop checked "backgrounded" before "finished": an answer that had
//  completed, caught in the loop's 100 ms sleep when the user swiped home, was
//  thrown away as an interruption and re-asked on return — a fresh generation
//  replacing a complete reply, and a healthy engine discarded. A finished answer
//  now wins; a stream that FAILED while backgrounded is still an interruption,
//  because GPU revocation can surface as an error instead of a hang.
//

import Testing
@testable import teemoon

@Suite("LiteRT turn wait")
struct LiteRTTurnWaitTests {

    @Test func aFinishedAnswerIsKeptWhenTheAppHasJustGoneToTheBackground() {
        #expect(LiteRTTransport.waitStep(finishedCleanly: true, backgrounded: true, dead: false) == .collect)
        // A drain that timed out after the answer completed keeps the answer too.
        #expect(LiteRTTransport.waitStep(finishedCleanly: true, backgrounded: false, dead: true) == .collect)
    }

    @Test func aStreamStillRunningIsAbandonedOnBackground() {
        #expect(LiteRTTransport.waitStep(finishedCleanly: nil, backgrounded: true, dead: false) == .abandon)
        #expect(LiteRTTransport.waitStep(finishedCleanly: nil, backgrounded: false, dead: true) == .abandon)
    }

    @Test func aStreamThatFailedInTheBackgroundIsAnInterruptionNotAnError() {
        #expect(LiteRTTransport.waitStep(finishedCleanly: false, backgrounded: true, dead: false) == .abandon)
    }

    @Test func inTheForegroundTheLoopWaitsThenCollects() {
        #expect(LiteRTTransport.waitStep(finishedCleanly: nil, backgrounded: false, dead: false) == .wait)
        #expect(LiteRTTransport.waitStep(finishedCleanly: true, backgrounded: false, dead: false) == .collect)
        // A real error in the foreground reaches the caller as one.
        #expect(LiteRTTransport.waitStep(finishedCleanly: false, backgrounded: false, dead: false) == .collect)
    }
}
