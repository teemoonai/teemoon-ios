//
//  FlowLayoutTests.swift
//  teemoonTests
//
//  2026-11-01, the maintainer's Pixel at default size: a row of image links laid out side by side gave "audit · private"
//  a column one letter wide. A link is laid out at its own width, or the whole line when it is wider; never
//  narrower, so no link can become a sliver.
//

import CoreGraphics
import Testing
@testable import teemoon

@Suite("Flow layout")
struct FlowLayoutTests {

    @Test func noItemIsNarrowerThanItsOwnWidthOrTheLine() {
        let ideal: [CGFloat] = [80, 60, 240, 70, 900]
        let widths = FlowLayout.widths(ideal: ideal, available: 300)
        for (w, i) in zip(widths, ideal) { #expect(w >= min(i, 300)) }
        #expect(widths.last == 300, "an item wider than the line gets the whole line")
    }

    @Test func itemsThatDoNotFitMoveToTheNextLine() {
        let lines = FlowLayout.lines(widths: [80, 60, 240, 70], available: 300, spacing: 14)
        #expect(lines == [[0, 1], [2], [3]])
        #expect(FlowLayout.lines(widths: [300, 10], available: 300, spacing: 14) == [[0], [1]])
        #expect(FlowLayout.lines(widths: [], available: 300, spacing: 14) == [])
    }
}
