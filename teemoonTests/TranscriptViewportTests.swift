#if os(iOS)

import Foundation
import Testing
@testable import teemoon

@Suite("TranscriptViewport")
struct TranscriptViewportTests {

    private let t: CFTimeInterval = 1_000

    @Test func aLiveFollowIsThrottled() {
        #expect(TranscriptViewport.resolve(
            generating: true, interrupted: false,
            now: t, settleUntil: t + 1, holdY: nil, holdUntil: 0)
            == .pinToEnd(.throttled))
    }

    @Test func walkingAwayStopsTheFollow() {
        #expect(TranscriptViewport.resolve(
            generating: true, interrupted: true,
            now: t, settleUntil: 0, holdY: nil, holdUntil: 0)
            == .free)
    }

    @Test func aFollowingHandoffSettlesImmediately() {
        #expect(TranscriptViewport.resolve(
            generating: false, interrupted: false,
            now: t, settleUntil: t + 1, holdY: nil, holdUntil: 0)
            == .pinToEnd(.immediate))
    }

    @Test func aHoldOutranksSettleAndFollow() {
        #expect(TranscriptViewport.resolve(
            generating: false, interrupted: true,
            now: t, settleUntil: t + 1, holdY: 800, holdUntil: t + 1)
            == .hold(y: 800))
        #expect(TranscriptViewport.resolve(
            generating: true, interrupted: true,
            now: t, settleUntil: t + 1, holdY: 800, holdUntil: t + 1)
            == .hold(y: 800))
    }

    @Test func anExpiredHoldIsFree() {
        #expect(TranscriptViewport.resolve(
            generating: false, interrupted: true,
            now: t, settleUntil: 0, holdY: 800, holdUntil: t - 0.01)
            == .free)
    }

    @Test func aLiveFollowOutranksALeftoverSettle() {
        #expect(TranscriptViewport.resolve(
            generating: true, interrupted: false,
            now: t, settleUntil: t + 1, holdY: 800, holdUntil: t - 1)
            == .pinToEnd(.throttled))
    }

    @Test func idleIsFree() {
        #expect(TranscriptViewport.resolve(
            generating: false, interrupted: false,
            now: t, settleUntil: 0, holdY: nil, holdUntil: 0)
            == .free)
    }

    // MARK: The reserve — how the prompt comes to ride near the top

    /// A 900pt viewport, 60pt of title fade, 190pt of composer chrome:
    /// 650pt of usable band. The prompt is a 120pt bubble.
    private func geometry(ink: CGFloat) -> TranscriptAnchorGeometry {
        TranscriptAnchorGeometry(
            userHeight: 120, visibleHeight: 900,
            topFade: 60, chrome: 190, inkBelow: ink)
    }

    /// THE RESERVE IS THE WHOLE MECHANISM, AND IT IS NOT A SCROLL TARGET.
    ///
    /// Nothing scrolls to the prompt. `placeholder` goes into
    /// `contentInset.bottom`, which moves the end of the scrollable content
    /// to exactly where the prompt-at-the-top would put it — so the ordinary
    /// pin-to-end lands there. This is the identity that makes that true:
    ///
    ///     maxContentOffsetY - (prompt at top) == U.height + ink + reserve - V
    ///
    /// and it is 0 for as long as there is reserve left. Measured on device:
    /// `contentH 2697 + (350 reserve + 96 ink + 132 chrome + 34 home) - 874`
    /// = 2436, which is exactly where the follow sat while the reply grew.
    ///
    /// An `.anchor` intent that wrote that position directly existed briefly.
    /// It was the only absolute target derived from a cell's frame, and after
    /// a submit that frame belonged to the PREVIOUS message for a pass or two
    /// — the offset went to two places 5ms apart (-1427 then +1894 on
    /// device). Deleted. A stale read now only mis-sizes this reserve.
    private func gap(_ ink: CGFloat) -> CGFloat {
        let g = geometry(ink: ink)
        return g.userHeight + ink + g.placeholder - g.usableHeight
    }

    @Test func theReserveMakesTheEndLandWhereThePromptAtTopWouldBe() {
        for ink in stride(from: CGFloat(0), through: 530, by: 10) {
            #expect(gap(ink) == 0)
        }
        // And crossing out of the reserve is continuous — no step at the seam.
        #expect(gap(529) == 0)
        #expect(gap(530) == 0)
        #expect(gap(531) == 1)
        #expect(gap(560) == 30)
    }

    /// One point of jitter must not move the viewport, anywhere near the
    /// boundary. This is the stutter as a property rather than an anecdote.
    @Test func aPointOfJitterAtTheBoundaryDoesNotMoveTheViewport() {
        for ink in stride(from: CGFloat(500), through: 560, by: 1) {
            #expect(abs(gap(ink) - gap(ink - 1)) <= 1)
        }
    }

    @Test func aShortReplyReservesTheRestOfTheBand() {
        // 120 + 200 against 650 usable: 330 of reserve, so the end of the
        // content sits 330pt below the reply and the prompt rides the top.
        #expect(geometry(ink: 200).placeholder == 330)
    }

    @Test func theReserveGivesBackExactlyWhatTheReplyTakes() {
        // The point of the whole design: growth costs no offset movement,
        // because the reserve shrinks by precisely what the reply grew.
        let small = geometry(ink: 100), bigger = geometry(ink: 400)
        #expect(small.placeholder - bigger.placeholder == 300)
        #expect(small.placeholder + 100 == bigger.placeholder + 400)
    }

    @Test func aReplyTallerThanTheBandReservesNothing() {
        #expect(geometry(ink: 600).placeholder == 0)
        #expect(geometry(ink: 530).placeholder == 0)
        #expect(geometry(ink: 529).placeholder == 1)
    }

    @Test func turnStartReservesSoTheEndIsNotTheComposer() {
        // ink = 0: the streaming view is mounted but has not measured. This
        // is the jump-to-bottom-of-a-blank-answer the design removes.
        #expect(geometry(ink: 0).placeholder == 530)
    }

    @Test func theReserveSurvivesTheHandoffBecauseTheCellBacksIt() {
        // `inkBelow` is the streaming view before `[DONE]` and the persisted
        // cell of the same height after, so the reserve does not move. If it
        // collapsed here the scrollable end would fall by exactly this much
        // and the clamp would shove the prompt back down the screen.
        #expect(geometry(ink: 300).placeholder == geometry(ink: 300).placeholder)
        #expect(geometry(ink: 300).placeholder == 230)
    }

    @Test func slackIsBoundedByOneViewportAndNeverTheGapBetweenTwoEnds() {
        // THE 2,040pt BLANK was the difference between two content ends —
        // unbounded, more than two screens, nothing ever drawn in it. This
        // reserve cannot exceed the band minus the prompt however little ink
        // there is, and shrinks monotonically as the reply grows.
        let empty = geometry(ink: 0)
        #expect(empty.placeholder == empty.usableHeight - 120)
        #expect(empty.placeholder <= empty.visibleHeight)
        var previous = empty.placeholder
        for ink in stride(from: CGFloat(50), through: 700, by: 50) {
            let p = geometry(ink: ink).placeholder
            #expect(p <= previous)
            previous = p
        }
        #expect(previous == 0)
    }

    @Test func aTallPromptLeavesNoReserveOfItsOwn() {
        var tall = geometry(ink: 0)
        tall.userHeight = 800
        #expect(tall.placeholder == 0)
    }

    @Test func handoffFloorKeepsTheSeedWhenFittedIsUnfitted() {
        #expect(TranscriptHandoffSizing.floor(seed: 6480, fitted: 400) == 6480)
        #expect(TranscriptHandoffSizing.floor(seed: 6480, fitted: 83) == 6480)
        #expect(TranscriptHandoffSizing.floor(seed: 6480, fitted: 6447) == 6447)
        #expect(TranscriptHandoffSizing.floor(seed: 0, fitted: 500) == 500)
        #expect(TranscriptHandoffSizing.floor(seed: 876, fitted: 276) == 276)
    }

    @Test func aFirstPaintMustNotShrinkAHandoffSeed() {
        let item = TranscriptItem.message(UUID())
        TranscriptRowHeightCache.store(3000, for: item)
        TranscriptRowHeightCache.store(83, for: item)
        #expect(TranscriptRowHeightCache.height(for: item) == 3000)
        TranscriptRowHeightCache.forget(item)
        TranscriptRowHeightCache.store(83, for: item)
        #expect(TranscriptRowHeightCache.height(for: item) == 83)
        TranscriptRowHeightCache.forget(item)
    }
}

#endif
