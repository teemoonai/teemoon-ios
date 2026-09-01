//
//  AuditIndexStamp.swift
//  teemoon
//
//  Freshness line under known-code. Stale after a day must be visible.
//  See AuditIndexStampTests.
//

import Foundation

enum AuditIndexStamp {
    static let staleAfter: TimeInterval = 86_400

    /// nil when there is no index to stamp.
    static func make(hasIndex: Bool, updated: String?, loadedAt: Date?, now: Date) -> (text: String, stale: Bool)? {
        guard hasIndex else { return nil }
        let updatedText = (updated?.isEmpty == false) ? updated! : "unknown"
        guard let fetched = loadedAt else {
            return (
                "audit index · updated \(updatedText) · fetch age unknown — verdicts may lag the fleet",
                true
            )
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let ago = formatter.localizedString(for: fetched, relativeTo: now)
        if now.timeIntervalSince(fetched) > staleAfter {
            return ("audit index · cached \(ago) — verdicts may lag the fleet", true)
        }
        return ("audit index · updated \(updatedText) · refreshed \(ago)", false)
    }
}
