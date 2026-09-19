//
//  ModelOffer.swift
//  teemoon
//
//  One place a model can be served from, as a catalogue reports it. Only
//  OpenRouter publishes such a list today; the shape is the app's, so no view
//  names a vendor to render it.
//

import Foundation

struct ModelOffer: Identifiable, Equatable, Hashable {
    let providerName: String
    /// OpenRouter's own id for this offer ("openai/flex"). The variant half
    /// is what distinguishes two offers from one provider.
    let tag: String
    var price: String = ""
    var isFree: Bool = false
    var contextTokens: Int? = nil
    var maxOutputTokens: Int? = nil
    var quantization: String? = nil
    /// Percent uptime over the last day, as OpenRouter reports it.
    var uptimePercent: Double? = nil
    /// Median time to first token, in milliseconds. Only with a key: the
    /// public list answers null.
    var latencyMilliseconds: Double? = nil
    /// Median tokens per second, same condition.
    var throughputTokensPerSecond: Double? = nil
    /// The provider is on OpenRouter's zero-data-retention list.
    var isZeroDataRetention: Bool = false
    var supportsImplicitCaching: Bool = false

    var id: String { providerName + "\u{0}" + tag }

    /// "OpenAI" when the tag is just the provider, "OpenAI · flex" when it
    /// names a variant. Never invents one the tag did not carry.
    var title: String {
        let parts = tag.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return providerName }
        return "\(providerName) · \(parts[1])"
    }

    var uptimeLabel: String? {
        guard let uptimePercent else { return nil }
        return uptimePercent >= 99.95 ? "100%" : String(format: "%.1f%%", uptimePercent)
    }

    /// Milliseconds under a second, seconds above it — 2085 ms reads as
    /// "2.1 s", which is how long it actually feels.
    var latencyLabel: String? {
        guard let latencyMilliseconds, latencyMilliseconds > 0 else { return nil }
        if latencyMilliseconds >= 1000 { return String(format: "%.1f s", latencyMilliseconds / 1000) }
        return String(format: "%.0f ms", latencyMilliseconds)
    }

    var throughputLabel: String? {
        guard let throughputTokensPerSecond, throughputTokensPerSecond > 0 else { return nil }
        return String(format: "%.0f tok/s", throughputTokensPerSecond)
    }
}
