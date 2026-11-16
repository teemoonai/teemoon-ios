//
//  ComposerImagesTests.swift
//  teemoonTests
//
//  When the composer may send: never while a photo is still loading, or the text went alone and the photo landed in
//  the emptied composer. Same rule and table as Android's ComposerImages.canSend.
//

import Testing
@testable import teemoon

@Suite("Images — when the composer may send")
struct ComposerImagesTests {

    @Test func canSendTable() {
        let table: [(prompt: String, picked: Int, pending: Int, limit: Int, canSend: Bool)] = [
            ("hi", 0, 0, 10, true),
            ("", 1, 0, 10, true),
            ("hi", 2, 0, 10, true),
            ("hi", 10, 0, 10, true),
            ("", 0, 0, 10, false),
            (" \n ", 0, 0, 10, false),
            ("hi", 0, 1, 10, false),
            ("hi", 1, 1, 10, false),
            ("", 0, 1, 10, false),
            ("", 1, 3, 10, false),
            ("hi", 11, 0, 10, false),
            ("", 5, 0, 4, false),
        ]
        for row in table {
            #expect(ComposerImages.canSend(prompt: row.prompt, picked: row.picked, pending: row.pending, limit: row.limit)
                    == row.canSend, "\(row)")
        }
    }

    /// A paste of 5 images with 1 slot left showed 5 spinners, then 4 vanished (design review 2026-11-14).
    @Test func loadingTilesNeverExceedTheFreeSlots() {
        #expect(ComposerImages.loadingTiles(requested: 5, limit: 10, ready: 9, loading: 0) == 1)
        #expect(ComposerImages.loadingTiles(requested: 5, limit: 10, ready: 2, loading: 3) == 5)
        #expect(ComposerImages.loadingTiles(requested: 5, limit: 10, ready: 6, loading: 3) == 1)
        #expect(ComposerImages.loadingTiles(requested: 2, limit: 10, ready: 10, loading: 0) == 0)
        #expect(ComposerImages.loadingTiles(requested: 0, limit: 10, ready: 0, loading: 0) == 0)
    }

    @Test func loadingTilesTable_aShareOnASmallModel() {
        let table: [(requested: Int, limit: Int, ready: Int, loading: Int, tiles: Int)] = [
            (10, 4, 0, 0, 4),
            (10, 10, 0, 0, 10),
            (2, 10, 0, 0, 2),
            (3, 4, 2, 0, 2),
            (3, 4, 1, 2, 1),
            (3, 4, 4, 0, 0),
            (3, 4, 5, 0, 0),
            (0, 4, 0, 0, 0),
        ]
        for row in table {
            #expect(ComposerImages.loadingTiles(requested: row.requested, limit: row.limit, ready: row.ready,
                                                loading: row.loading) == row.tiles, "\(row)")
        }
    }
}
