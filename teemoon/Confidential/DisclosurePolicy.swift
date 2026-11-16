//
//  DisclosurePolicy.swift
//  teemoon
//
//  What a request says about the person, per destination tier (docs/DISCLOSURE.md, conformance/disclosure.json,
//  which Android runs too). Callers ask the policy how an item renders; they never branch on the tier themselves.
//

import Foundation

struct DisclosurePolicy: Equatable {
    enum Tier: String { case `private`, minimised }

    let tier: Tier
    /// The phone's zone; read only by the private tier.
    let zone: TimeZone

    /// Private: this phone, a home place, or a request sealed end to end. Minimised: everything else.
    static func destinationTier(place: WhereLocality, sealed: Bool) -> Tier {
        place == .phone || place == .home || sealed ? .private : .minimised
    }

    init(tier: Tier, zone: TimeZone = .current) {
        self.tier = tier
        self.zone = zone
    }

    init(place: WhereLocality, sealed: Bool, zone: TimeZone = .current) {
        self.init(tier: Self.destinationTier(place: place, sealed: sealed), zone: zone)
    }

    /// The system prompt's `{{date}}`: a day, never the minute, so the prefix stays cacheable all day.
    func dateLine(_ now: Date) -> String {
        switch tier {
        case .private: return "\(toolDay(now)) (\(zone.identifier), \(offset(at: now)))"
        case .minimised: return "\(toolDay(now)) (UTC)"
        }
    }

    /// The web-search tool's "Today is …".
    func toolDay(_ now: Date) -> String { formatter("EEEE, MMMM d, yyyy").string(from: now) }

    /// Appended to a user turn on the wire, never stored; the turn's own timestamp, so the bytes repeat.
    func sentAt(_ date: Date) -> String {
        switch tier {
        case .private: return "\n\n[Sent at \(formatter("h:mm a").string(from: date))]"
        case .minimised: return "\n\n[Sent at \(formatter("HH:mm").string(from: date)) UTC]"
        }
    }

    private var renderZone: TimeZone { tier == .private ? zone : TimeZone(identifier: "UTC")! }

    private func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = renderZone
        f.dateFormat = format
        return f
    }

    private func offset(at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let minutes = abs(seconds) / 60
        return String(format: "UTC%@%02d:%02d", seconds < 0 ? "\u{2212}" : "+", minutes / 60, minutes % 60)
    }
}
