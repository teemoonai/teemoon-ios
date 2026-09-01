//
//  TranscriptRowHeightCache.swift
//  teemoon
//

#if os(iOS) || os(visionOS)

import Foundation

/// THE DEBUG CARD IS NOT FLOORED AT ALL, and this type is the tombstone.
///
/// It held a first-paint floor: each turn is a new `.debugInfo(turn:)`
/// identity, so the per-item cache cannot help the first insert, and the
/// layout's 120pt estimate shows only the card's header until the cell grows a
/// frame later. 220pt was "header + url + timing + two collapsed rows"; later
/// Last self-sized height for a transcript item. Used only as
/// `UIHostingConfiguration.minSize` on the next dequeue so a recycled
/// row is not first shown at the layout's 120pt estimate.
///
/// Not the row-size *correction* cache that livelocked (1e7438b..7d577f8):
/// nothing compares, nothing invalidates. Persisted messages do not change
/// height, so the last measurement is a valid floor. Without it, a fast
/// flick after a turn paints a 2,000pt reply into a 120pt cell and the
/// overflow lands on the next row — double-printed text.
/// Internal rather than private so `HandoffCellHeightTests` can put a seeded
/// floor and a real `MessageView` in the same cell and measure what comes out
/// — the screenshot's empty band was invisible to every fixture built on
/// `Color.clear` rows.
enum TranscriptRowHeightCache {
    private static let lock = NSLock()
    private static var heights: [TranscriptItem: CGFloat] = [:]

    static func height(for item: TranscriptItem) -> CGFloat? {
        lock.lock(); defer { lock.unlock() }
        // Only a height this very row reported earlier. See
        // `TranscriptDebugCardSizing` for why the debug card has no floor.
        return heights[item]
    }

    static func store(_ height: CGFloat, for item: TranscriptItem) {
        lock.lock(); defer { lock.unlock() }
        // NEVER SHRINK VIA STORE. The hand-off seeds the persisted row with
        // the streaming view's height so the first layout is not the 120pt
        // estimate. The hosting view then reports its unfitted first measure
        // (~83pt) through `onGeometryChange` and would overwrite that seed,
        // so the next configure floors at 83pt and the hold clamps the
        // reader to the top of the reply. Shrinking is `forget` — a
        // reconfigure whose inputs changed — not a first-paint report.
        if let existing = heights[item], existing > height { return }
        heights[item] = height
    }

    /// A REMEMBERED HEIGHT IS ONLY GOOD WHILE THE ROW STILL SAYS THAT.
    ///
    /// The floor is applied on EVERY dequeue, not only the first, which is
    /// what keeps a recycled row off the 120pt estimate. The cost is that a
    /// row whose content GOES AWAY keeps the height it had when it was full:
    /// the web-search offer card, once its search is accepted and the sources
    /// chip takes over, renders nothing into a cell still 300pt tall. That is
    /// a band of empty space between the answer and the next message, and it
    /// was reported as one (2026-08-22, screenshot).
    ///
    /// `reconfigure` is exactly the signal that a row's INPUTS changed while
    /// its identity did not, so the height taken under the old inputs is
    /// dropped there. Not a correction loop — nothing compares heights and
    /// nothing re-invalidates on measurement (1e7438b..7d577f8); the entry is
    /// simply forgotten and taken again from whatever the row now reports.
    static func forget(_ item: TranscriptItem) {
        lock.lock(); defer { lock.unlock() }
        heights[item] = nil
    }
}

#endif
