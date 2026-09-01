//
//  ToolCallDisplayTruncationTests.swift
//  teemoonTests
//
//  Pins the debug card's display bound for tool results. The incident, from
//  the device trace (2026-08-26): a tool result tens of thousands of
//  characters long, mounted whole into the expanded debug-card row, swung
//  the transcript tail's height by thousands of points on expand/collapse
//  and stranded the viewport past the deflating content end — 70
//  overscrolled samples, worst 1230 pt past the end, seen on screen as a
//  full blank transcript with a live scroll indicator. The COPY path
//  deliberately stays complete; only the mounted row is bounded.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Tool-call display truncation")
struct ToolCallDisplayTruncationTests {

    @Test func shortResultsPassThroughUntouched() {
        let record = ToolCallRecord(name: "web_search", arguments: "{}",
                                    result: "three sources")
        #expect(record.displayResult == "three sources")
    }

    @Test func longResultsAreBoundedWithAnHonestTrailer() {
        let huge = String(repeating: "x", count: 40_000)
        let record = ToolCallRecord(name: "web_search", arguments: "{}", result: huge)

        let shown = record.displayResult
        #expect(shown.count < ToolCallRecord.displayCap + 200,
                "the mounted row must stay bounded — an unbounded row is the blank screen")
        #expect(shown.contains("display truncated"))
        #expect(shown.contains("40000"), "the trailer must say how much exists")
    }

    @Test func theBoundaryItselfIsNotTruncated() {
        let exact = String(repeating: "y", count: ToolCallRecord.displayCap)
        let record = ToolCallRecord(name: "web_search", arguments: "{}", result: exact)
        #expect(record.displayResult == exact, "at the cap is short enough — no trailer noise")
    }
}
