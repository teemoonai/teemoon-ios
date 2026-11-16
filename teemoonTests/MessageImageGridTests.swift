//
//  MessageImageGridTests.swift
//  teemoonTests
//
//  the maintainer 2026-11-14 (via pm), both apps: a sent message shows at most 4 tiles, a 2×2 grid; from the 5th photo on the
//  4th tile is "+N", N = count − 3. Before, up to 6 tiles three to a row, so 5 shared photos drew 3 + 2 with no "+N".
//

import CoreGraphics
import Testing
@testable import teemoon

struct MessageImageGridTests {
    @Test func atMostFourTiles_twoToARow() {
        #expect(MessageImageGrid.rows(count: 1) == [[0]])
        #expect(MessageImageGrid.rows(count: 2) == [[0, 1]])
        #expect(MessageImageGrid.rows(count: 3) == [[0, 1], [2]])
        #expect(MessageImageGrid.rows(count: 4) == [[0, 1], [2, 3]])
        #expect(MessageImageGrid.rows(count: 5) == [[0, 1], [2, 3]])
        #expect(MessageImageGrid.rows(count: 10) == [[0, 1], [2, 3]])
    }

    @Test func theFourthTileCarriesEveryPhotoFromTheFourthOn() {
        #expect(MessageImageGrid.more(count: 4) == nil)
        #expect(MessageImageGrid.more(count: 5) == 2)
        #expect(MessageImageGrid.more(count: 10) == 7)
    }

    @Test func theViewerClosesIntoThePlusNTileFromTheFourthPageOn() {
        #expect(MessageImageGrid.zoomTile(page: 2) == 2)
        #expect(MessageImageGrid.zoomTile(page: 3) == 3)
        #expect(MessageImageGrid.zoomTile(page: 9) == 3)
    }

    @Test func voiceOverReadsThePlusNTileAsTheRange() {
        #expect(MessageImageGrid.label(tile: 0, count: 10) == "image 1 of 10")
        #expect(MessageImageGrid.label(tile: 3, count: 4) == "image 4 of 4")
        #expect(MessageImageGrid.label(tile: 3, count: 10) == "images 4 to 10 of 10")
    }

    @Test func sizesAreUnchanged() {
        #expect(MessageImageGrid.tileSize(count: 1) == CGSize(width: 240, height: 180))
        #expect(MessageImageGrid.tileSize(count: 2) == CGSize(width: 136, height: 136))
        #expect(MessageImageGrid.tileSize(count: 5) == CGSize(width: 100, height: 100))
    }
}
