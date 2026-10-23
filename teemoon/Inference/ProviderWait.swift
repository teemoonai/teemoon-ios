//
//  ProviderWait.swift
//  teemoon
//
//  A request that has gone out and has no response headers yet. Says only
//  that: no "queue" or "busy" unless the provider tells us so.
//

import Foundation

struct ProviderWait: Equatable, Sendable {
    let turn: Int
    let sentAt: Date
    let providerName: String

    /// Below this a missing response is ordinary latency.
    static let threshold: TimeInterval = 5

    /// Seconds this request has waited, once past the threshold; nil before.
    /// Decides WHEN the chip says so; the number on it is the whole turn's.
    func shownSeconds(at now: Date) -> Int? {
        let waited = now.timeIntervalSince(sentAt)
        return waited >= Self.threshold ? Int(waited) : nil
    }

    static func label(providerName: String, seconds: Int) -> String {
        "waiting for \(providerName)... \(seconds)s"
    }
}
