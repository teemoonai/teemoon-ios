//
//  ModelDefaultRule.swift
//  teemoon
//
//  How a provider chooses its default / highlighted model from the LIVE catalogue.
//  Per-provider, resolved against live data, so each provider expresses its own
//  notion of "the right default" and nothing is version-pinned (glm 5.2 → 5.3 just
//  works). Cloud users reach for the biggest model they can't run locally, so a
//  capability-forward pick (most expensive) is the sensible cloud default; local
//  providers favour what fits instead.
//
//  Kept as a preset → rule map in Provider+Presets — never a stored field, so there
//  is no persisted-schema change.
//

import Foundation

enum ModelDefaultRule: Equatable {
    /// No /models endpoint — pin this id and skip the fetch entirely (Brave).
    case fixed(String)
    /// Most expensive by input+output rate (ties → most recent). `e2eeOnly` restricts
    /// to the attestable tier so a proxied Claude/GPT can never win (near.ai).
    case mostExpensive(e2eeOnly: Bool)
    /// Newest model (the catalogue is recency-sorted, so the first in the pool).
    case newest(e2eeOnly: Bool)
    /// First match from an ordered curated id list — for huge catalogues (Fireworks,
    /// OpenRouter) where a hand-picked shortlist beats a heuristic.
    case curated([String])
    /// Whatever the catalogue returns first — generic fallback (Grok / unknown).
    case first

    /// Whether this rule needs the live catalogue at all. `.fixed` doesn't.
    var needsCatalogue: Bool {
        if case .fixed = self { return false }
        return true
    }

    /// Resolve to a model id against a catalogue that is already recency-sorted
    /// (newest first within each family). Returns nil only for an empty catalogue.
    func resolve(from models: [KnownModel]) -> String? {
        func pool(_ e2eeOnly: Bool) -> [KnownModel] {
            e2eeOnly ? models.filter { NearAIModelCatalog.confidentiality(forID: $0.id).isAttestable }
                     : models
        }
        switch self {
        case .fixed(let id):
            return id
        case .first:
            return models.first?.id
        case .newest(let e2eeOnly):
            return (pool(e2eeOnly).first ?? models.first)?.id
        case .curated(let ids):
            let have = Set(models.map { $0.id.lowercased() })
            return ids.first { have.contains($0.lowercased()) } ?? models.first?.id
        case .mostExpensive(let e2eeOnly):
            let p = pool(e2eeOnly)
            guard !p.isEmpty else { return models.first?.id }
            // Highest price wins; on a tie prefer the larger context window (the newer
            // flagship — e.g. GLM 5.2 at 1M beats GLM 5.1 at 203K, both $1.40/$4.40),
            // which is order-independent so a namespace-drift sort can't flip the pick.
            return p.reduce(nil as KnownModel?) { best, m in
                guard let best else { return m }
                let sm = Self.priceScore(m), sb = Self.priceScore(best)
                if sm != sb { return sm > sb ? m : best }
                return Self.contextValue(m.contextWindow) > Self.contextValue(best.contextWindow) ? m : best
            }?.id
        }
    }

    /// input + output per-1M rates from "$1.40/$4.40".
    static func priceScore(_ m: KnownModel) -> Double {
        m.price.split(separator: "/").reduce(0.0) { acc, part in
            let d = part.drop(while: { !$0.isNumber && $0 != "." })
            return acc + (Double(d.prefix(while: { $0.isNumber || $0 == "." })) ?? 0)
        }
    }

    /// "1M" → 1_000_000, "203k" → 203_000, "128000" → 128_000.
    static func contextValue(_ s: String) -> Double {
        let t = s.lowercased()
        let num = Double(t.prefix(while: { $0.isNumber || $0 == "." })) ?? 0
        if t.contains("m") { return num * 1_000_000 }
        if t.contains("k") { return num * 1_000 }
        return num
    }
}
