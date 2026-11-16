//
//  MotionTests.swift
//  teemoonTests
//
//  The motion tokens (pm/features/motion-audit.md §3): one value per job, and Reduce Motion takes every movement out.
//

import SwiftUI
import Testing
@testable import teemoon

@Suite("Motion tokens")
struct MotionTests {

    @Test func reduceMotionTakesOutEveryMovement() {
        #expect(Motion.spatial(reduceMotion: true) == nil)
        #expect(Motion.playful(reduceMotion: true) == nil)
        #expect(Motion.attention(reduceMotion: true) == nil)
    }

    @Test func eachJobHasOneValue() {
        #expect(Motion.spatial(reduceMotion: false) == .smooth)
        #expect(Motion.playful(reduceMotion: false) == .spring(duration: 0.35, bounce: 0.3))
        #expect(Motion.fade == .easeOut(duration: 0.2))
        #expect(Motion.swap == .smooth(duration: 0.2))
    }

    /// Motion audit #5: chips that grow or shrink hold their size under Reduce Motion.
    @Test func reduceMotionHoldsEverySizeCue() {
        #expect(Motion.scale(1.12, reduceMotion: true) == 1)
        #expect(Motion.scale(0.94, reduceMotion: true) == 1)
        #expect(Motion.scale(1.12, reduceMotion: false) == 1.12)
    }
}
