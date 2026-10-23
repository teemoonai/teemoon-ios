//
//  TurnPhases.swift
//  teemoon
//
//  Where one send's time went, from the tap: the attestation gate, each
//  request's send / response / first token / first answer token, each tool
//  round, the last token, and the reply-signature check after it. The kinds
//  match Android's so the two cards read the same.
//

import Foundation

/// A wall-clock event inside one send. The engine and transport record these;
/// `TurnPhases` turns them into offsets from the tap.
struct PhaseEvent: Sendable, Equatable {
    enum Kind: String, Sendable { case gate, sent, response, firstToken, firstAnswer, tool, done, verified }
    let kind: Kind
    let at: Date
    /// tool only: how long it ran, how big the result was, and its rough token cost.
    var durationMs: Int? = nil
    var bytes: Int? = nil
    var tokens: Int? = nil
}

struct TurnPhases: Sendable, Equatable {
    struct Mark: Sendable, Equatable {
        let kind: PhaseEvent.Kind
        /// Seconds from the tap.
        let offset: TimeInterval
        var durationMs: Int? = nil
        var bytes: Int? = nil
        var tokens: Int? = nil
    }
    var marks: [Mark] = []
    /// Summed over every request in the send.
    var promptTokens: Int? = nil
    var cachedTokens: Int? = nil
    /// The chat's first message: nothing earlier could be in the provider's cache.
    var firstMessage = false
    /// What a missing cached figure means for the host that served the turn.
    var cacheReporting: CacheReporting = .figureOnly

    enum CacheReporting: Sendable, Equatable {
        /// Show a figure when there is one, nothing otherwise (on-device).
        case figureOnly
        /// Sends a figure on a hit and none on a miss: missing reads as 0.
        case missingIsZero
        /// Never seen to send one: missing reads as "not reported".
        case missingIsUnreported
    }

    /// near.ai plaintext sends `prompt_tokens_details: null` on a miss; the other three
    /// send their figure only when there is one. near.ai E2EE sent null on a repeat of the
    /// same 5.8k-token prompt (2026-10-21), so it is "not reported" until the maintainer decides.
    static func cacheReporting(host: String?, onDevice: Bool, isE2EE: Bool = false) -> CacheReporting {
        guard !onDevice, let host = host?.lowercased() else { return .figureOnly }
        let nearAI = host == "near.ai" || host.hasSuffix(".near.ai")
        if nearAI && isE2EE { return .missingIsUnreported }
        if nearAI || ["api.fireworks.ai", "api.x.ai", "openrouter.ai"].contains(host) { return .missingIsZero }
        return .missingIsUnreported
    }

    init(origin: Date, events: [PhaseEvent], promptTokens: Int? = nil, cachedTokens: Int? = nil) {
        marks = events.sorted { $0.at < $1.at }.map {
            Mark(kind: $0.kind, offset: max(0, $0.at.timeIntervalSince(origin)),
                 durationMs: $0.durationMs, bytes: $0.bytes, tokens: $0.tokens)
        }
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
    }

    /// The share of prompt tokens the provider served from its prompt cache.
    var cachePercent: Int? {
        guard let p = promptTokens, p > 0, let c = cachedTokens else { return nil }
        return Int((Double(min(c, p)) / Double(p) * 100).rounded())
    }

    /// The card's only figure from this turn: `cache 92%`, or the reason a first message has none.
    var cacheLine: String? {
        let cached = cachedTokens ?? (cacheReporting == .missingIsZero ? 0 : nil)
        guard let p = promptTokens, p > 0, let c = cached else {
            return cacheReporting == .figureOnly ? nil : "cache — not reported"
        }
        let pct = Int((Double(min(c, p)) / Double(p) * 100).rounded())
        return pct == 0 && firstMessage ? "cache — first message" : "cache \(pct)%"
    }

    func first(_ kind: PhaseEvent.Kind) -> TimeInterval? { marks.first { $0.kind == kind }?.offset }

    /// A mark that lands after the turn closed (the signature check).
    mutating func append(_ kind: PhaseEvent.Kind, at: Date, origin: Date) {
        marks.append(Mark(kind: kind, offset: max(0, at.timeIntervalSince(origin))))
    }

    /// `gate 0.80 · sent 0.81 · resp 1.20 · first 1.31 · answer 5.90 · tool 1.2s 14KB ~3.5k tok · … · done 7.30 · cache 92%`
    var line: String? {
        guard !marks.isEmpty else { return nil }
        var parts: [String] = marks.map { m in
            let t = String(format: "%.2f", m.offset)
            switch m.kind {
            case .gate: return "gate \(t)"
            case .sent: return "sent \(t)"
            case .response: return "resp \(t)"
            case .firstToken: return "first \(t)"
            case .firstAnswer: return "answer \(t)"
            case .done: return "done \(t)"
            case .verified: return "signed \(t)"
            case .tool:
                var s = "tool \(String(format: "%.1fs", Double(m.durationMs ?? 0) / 1000))"
                if let b = m.bytes { s += " \(b >= 1024 ? "\(b / 1024)KB" : "\(b)B")" }
                if let k = m.tokens { s += k >= 1000 ? String(format: " ~%.1fk tok", Double(k) / 1000) : " ~\(k) tok" }
                return s
            }
        }
        if let pct = cachePercent { parts.append("cache \(pct)%") }
        return parts.joined(separator: " · ")
    }
}
