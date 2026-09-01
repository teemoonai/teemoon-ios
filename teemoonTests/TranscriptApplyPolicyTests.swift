//
//  TranscriptApplyPolicyTests.swift
//  teemoonTests
//
//  The debug card must be a tail-only insert after the hand-off — that is
//  what lets the collection view slide it in instead of snapping the
//  answer up under the settle pin. A combined hand-off+debug apply is
//  split: first snapshot strips the card, second is this reveal.
//

#if os(iOS)

import Foundation
import Testing
@testable import teemoon

@Suite("Debug card reveal")
struct DebugCardRevealTests {

    @Test func aTailOnlyDebugInsertIsAReveal() {
        let msg = TranscriptItem.message(UUID())
        #expect(TranscriptApplyPolicy.isDebugCardReveal(
            previousTranscript: [msg], previousTail: [],
            transcript: [msg], tail: [.debugInfo(turn: 1)]))
    }

    @Test func aHandoffThatAlsoAddsDebugIsNotAReveal() {
        let a = TranscriptItem.message(UUID())
        let b = TranscriptItem.message(UUID())
        #expect(!TranscriptApplyPolicy.isDebugCardReveal(
            previousTranscript: [a], previousTail: [],
            transcript: [a, b], tail: [.debugInfo(turn: 1)]))
    }

    @Test func removingDebugIsNotAReveal() {
        let msg = TranscriptItem.message(UUID())
        #expect(!TranscriptApplyPolicy.isDebugCardReveal(
            previousTranscript: [msg], previousTail: [.debugInfo(turn: 1)],
            transcript: [msg], tail: []))
    }

    @Test func anUnchangedTailIsNotAReveal() {
        let msg = TranscriptItem.message(UUID())
        let tail: [TranscriptItem] = [.debugInfo(turn: 1)]
        #expect(!TranscriptApplyPolicy.isDebugCardReveal(
            previousTranscript: [msg], previousTail: tail,
            transcript: [msg], tail: tail))
    }

    @Test func handoffTailStripsTheDebugCard() {
        let debug = TranscriptItem.debugInfo(turn: 1)
        let pending = TranscriptItem.pending
        #expect(TranscriptApplyPolicy.handoffTail([debug]) == [])
        #expect(TranscriptApplyPolicy.handoffTail([pending, debug]) == [pending])
        #expect(TranscriptApplyPolicy.handoffTail([pending]) == [pending])
        #expect(TranscriptApplyPolicy.hasDebugCard([debug]))
        #expect(!TranscriptApplyPolicy.hasDebugCard([pending]))
    }

    @Test func aHandoffThenDebugInsertIsAReveal() {
        // The two-apply sequence: first snapshot is the persisted row
        // without the card (settle still armed); the second is a tail-only
        // insert. Combining them parks the viewport on the top of the reply.
        let user = TranscriptItem.message(UUID())
        let reply = TranscriptItem.message(UUID())
        let afterHandoff = [user, reply]
        #expect(TranscriptApplyPolicy.isDebugCardReveal(
            previousTranscript: afterHandoff, previousTail: [],
            transcript: afterHandoff, tail: [.debugInfo(turn: 1)]))
    }

    @Test func aHandoffSnapshotMustNotCarryTheDebugCard() {
        let debug = TranscriptItem.debugInfo(turn: 1)
        #expect(TranscriptApplyPolicy.handoffTail([debug]).allSatisfy { !$0.isDebugInfo })
    }

    @Test func aNewDebugCardIsFlooredAboveTheLayoutEstimate() {
        // 120pt is the compositional-layout estimate and only fits the
        // header. A first insert at that height is the "part then rest"
        // paint. The floor is the collapsed card, not a guess at tools.
        // NOTHING FLOORS A DEBUG CARD. Both floors it used to carry — a 220pt
        // constant, then the previous turn's measured card — were guesses
        // about a row whose height is set by what the turn did, and a `minSize`
        // guessed too high is an empty band under the card (three screenshots,
        // 2026-08-22). Only a row's OWN earlier measurement may floor it.
        #expect(TranscriptRowHeightCache.height(for: .debugInfo(turn: 7)) == nil)
        TranscriptRowHeightCache.store(900, for: .debugInfo(turn: 7))
        #expect(TranscriptRowHeightCache.height(for: .debugInfo(turn: 7)) == 900)
        #expect(TranscriptRowHeightCache.height(for: .debugInfo(turn: 8)) == nil)
        TranscriptRowHeightCache.forget(.debugInfo(turn: 7))
        #expect(TranscriptRowHeightCache.height(for: .debugInfo(turn: 7)) == nil)
    }
}

#endif
