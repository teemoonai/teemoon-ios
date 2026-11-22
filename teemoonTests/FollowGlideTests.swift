#if os(iOS)

import Foundation
import Testing
@testable import teemoon

@Suite("Follow glide")
struct FollowGlideTests {

    private let wrap: CGFloat = 23

    @Test func aWrapSizedDeltaStartsAGlide_settleDoesNot() {
        #expect(FollowGlide.shouldStart(delta: wrap, mode: .throttled))
        #expect(!FollowGlide.shouldStart(delta: wrap, mode: .immediate))
        #expect(!FollowGlide.shouldStart(delta: wrap, mode: .off))
        #expect(!FollowGlide.shouldStart(delta: 4, mode: .throttled))
    }

    @Test func aReserveSizedDeltaIsAJump_aWrapBurstIsNot() {
        #expect(FollowGlide.isJump(delta: 475))
        #expect(!FollowGlide.isJump(delta: 46))
        #expect(!FollowGlide.isJump(delta: wrap))
    }

    @Test func midGlideNoiseDoesNotRetarget_aBurstDoes() {
        #expect(!FollowGlide.shouldRetarget(delta: wrap))
        #expect(FollowGlide.shouldRetarget(delta: 46))
    }

    @Test func aWrapIsMidTravelAtHalfwayAndLandedAtTheDuration() {
        let t0: CFTimeInterval = 1_000
        let glide = FollowGlide(from: 100, to: 100 + wrap,
                                start: t0,
                                duration: PinningCollectionView.followGlideDuration)
        #expect(abs(glide.offset(at: t0) - 100) < 0.01)
        let mid = glide.offset(at: t0 + 0.06)
        #expect(mid > 108 && mid < 115)
        #expect(!glide.isFinished(at: t0 + 0.06))
        #expect(abs(glide.offset(at: t0 + 0.12) - 123) < 0.01)
        #expect(glide.isFinished(at: t0 + 0.12))
    }

    /// The send's jump strobed: 0.25 s smoothstep over a typical ~670 pt send moved up to 67 pt per frame at 60 Hz
    /// (sim measure, 2026-11-20). the maintainer picked 0.40 s ("A", 2026-11-19).
    @Test func theSendJumpStepsAtMost21PointsAFrameAt120Hz() {
        let travel: CGFloat = 670
        let glide = FollowGlide(from: 0, to: travel, start: 0, duration: PinningCollectionView.jumpGlideDuration, eased: true)
        func peak(hz: Double) -> CGFloat {
            (0..<Int(glide.duration * hz) + 2).map { i in
                glide.offset(at: Double(i + 1) / hz) - glide.offset(at: Double(i) / hz)
            }.max() ?? 0
        }
        #expect(peak(hz: 120) <= 21, "\(peak(hz: 120)) pt per frame at 120 Hz")
        #expect(peak(hz: 60) <= 42, "\(peak(hz: 60)) pt per frame at 60 Hz")
        #expect(abs(glide.offset(at: glide.duration) - travel) < 0.01)
    }
}

#endif
