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
}

#endif
