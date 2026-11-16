//
//  StallIndicatorTests.swift
//  teemoonTests
//
//  The trailing chip for a reply that has started and gone quiet (the maintainer, 2026-10-25: "with near … the thinking
//  chip shows up every few second and looks horrible"). near.ai streams 24-character deltas with silences that
//  reach 1.1-1.6 s on a phone; the old 1 s rule mounted a "thinking…" row on each one, five times in 12 s on the
//  stream rig (pm/evidence/1.1-ui/ios/stream/7b-*). The rule: nothing until 3 s of silence, then shown at least
//  1 s, and hidden only after 0.5 s of text flowing again.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Stall indicator")
struct StallIndicatorTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func on(_ s: inout StallIndicator, _ t: TimeInterval) -> Bool { s.settle(at: at(t)) }

    /// Replays a stream: one text arrival after each gap, sampling the chip every 50 ms in between.
    func timesShown(gaps: [TimeInterval]) -> Int {
        var s = StallIndicator(at: t0)
        var t: TimeInterval = 0, shows = 0, was = false
        for gap in gaps {
            var u = t
            while u < t + gap {
                let now = s.settle(at: at(u))
                if now && !was { shows += 1 }
                was = now; u += 0.05
            }
            t += gap
            s.textArrived(at: at(t))
            was = s.isShown
        }
        return shows
    }

    @Test func nearBurstsWithPausesUnderThreeSecondsNeverShowIt() {
        // The 7b profile: ~0.6 s between 24-char chunks and every seventh pause 1.1-1.6 s.
        let gaps = (0..<40).map { i -> TimeInterval in i % 7 == 6 ? 1.1 + Double(i % 5) * 0.12 : 0.6 }
        #expect(timesShown(gaps: gaps) == 0)
        #expect(timesShown(gaps: Array(repeating: 2.9, count: 10)) == 0)
    }

    @Test func aRealStallShowsAfterThreeSeconds() {
        var s = StallIndicator(at: t0)
        s.textArrived(at: at(0.5))
        #expect(!on(&s, 3.4))
        #expect(on(&s, 3.5))
        #expect(s.nextDeadline == nil, "shown: only new text can start the way out")
    }

    @Test func onceShownItStaysAtLeastASecondAndHidesOnlyAfterTextFlows() {
        var s = StallIndicator(at: t0)
        #expect(on(&s, 3.0))                 // shown at 3.0
        s.textArrived(at: at(3.2))                      // text resumes at once
        #expect(on(&s, 3.6), "hidden after 0.4 s of text: it would blink")
        #expect(on(&s, 3.9), "hidden before it has been up a second")
        #expect(s.nextDeadline == at(4.0))
        #expect(!on(&s, 4.0))
    }

    @Test func aSingleChunkAfterALongStallDoesNotHideItAtOnce() {
        var s = StallIndicator(at: t0)
        #expect(on(&s, 5))                    // up since 3.0
        s.textArrived(at: at(5))
        #expect(on(&s, 5.3))
        #expect(!on(&s, 5.5))
    }

    @Test func aResetStartsTheThreeSecondsAgain() {
        var s = StallIndicator(at: t0)
        #expect(on(&s, 4))
        s.reset(at: at(10))                             // a tool round ended
        #expect(!s.isShown)
        #expect(s.nextDeadline == at(13))
    }
}
