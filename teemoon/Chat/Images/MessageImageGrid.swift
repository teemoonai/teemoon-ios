//
//  MessageImageGrid.swift
//  teemoon
//

import CoreGraphics

/// A sent message's photo tiles, the same as Android's: at most four, two to a row; from the fifth photo on the
/// fourth tile carries "+N" and stands for every photo from the fourth on.
enum MessageImageGrid {
    static let shown = 4
    static let perRow = 2

    static func tileSize(count: Int) -> CGSize {
        switch count {
        case 1: CGSize(width: 240, height: 180)
        case 2: CGSize(width: 136, height: 136)
        default: CGSize(width: 100, height: 100)
        }
    }

    /// Indices of the tiles drawn, row by row.
    static func rows(count: Int) -> [[Int]] {
        let tiles = min(max(count, 0), shown)
        return stride(from: 0, to: tiles, by: perRow).map { Array($0..<min($0 + perRow, tiles)) }
    }

    /// The "+N" on the last tile, nil when every photo has its own tile.
    static func more(count: Int) -> Int? {
        count > shown ? count - shown + 1 : nil
    }

    /// The tile the viewer closes into from `page`: past the shown tiles, the "+N" tile.
    static func zoomTile(page: Int) -> Int { min(page, shown - 1) }

    static func label(tile n: Int, count: Int) -> String {
        more(count: count) != nil && n == shown - 1 ? "images \(shown) to \(count) of \(count)" : "image \(n + 1) of \(count)"
    }
}
