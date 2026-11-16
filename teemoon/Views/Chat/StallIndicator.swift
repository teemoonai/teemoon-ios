//
//  StallIndicator.swift
//  teemoon
//
//  Whether a reply that has started but gone quiet shows the trailing chip. Pure: the view feeds it
//  text arrivals and asks when to look again. StallIndicatorTests pins the timings.
//

import Foundation

struct StallIndicator: Equatable {
    /// Silence after text before the chip shows. Do not lower it to "catch" pauses sooner: a
    /// bursty provider then blinks the chip on every gap.
    static let showAfter: TimeInterval = 3
    /// Once shown, the chip stays at least this long.
    static let minShown: TimeInterval = 1
    /// Text must have resumed for this long before a shown chip hides.
    static let hideAfterFlow: TimeInterval = 0.5

    private(set) var lastText: Date
    private var shownAt: Date?
    private var resumedAt: Date?

    init(at start: Date) { lastText = start }

    var isShown: Bool { shownAt != nil }

    /// Starts over, as at the start of a stream or the end of a tool round.
    mutating func reset(at t: Date) { self = StallIndicator(at: t) }

    mutating func textArrived(at t: Date) {
        settle(at: t)
        if shownAt != nil, resumedAt == nil { resumedAt = t }
        lastText = t
        settle(at: t)
    }

    /// Brings the state up to `t`; returns whether the chip is shown.
    @discardableResult
    mutating func settle(at t: Date) -> Bool {
        if let shown = shownAt, let resumed = resumedAt,
           t >= max(shown.addingTimeInterval(Self.minShown), resumed.addingTimeInterval(Self.hideAfterFlow)) {
            shownAt = nil
            resumedAt = nil
        }
        if shownAt == nil, t.timeIntervalSince(lastText) >= Self.showAfter {
            shownAt = lastText.addingTimeInterval(Self.showAfter)
        }
        return shownAt != nil
    }

    /// When the answer can next change with no new text, or nil if only new text can change it.
    var nextDeadline: Date? {
        guard let shown = shownAt else { return lastText.addingTimeInterval(Self.showAfter) }
        guard let resumed = resumedAt else { return nil }
        return max(shown.addingTimeInterval(Self.minShown), resumed.addingTimeInterval(Self.hideAfterFlow))
    }
}
