//
//  LastRequestDebugInfo.swift
//  teemoon
//
//  What the developer debug card reports about one completed request.
//  Lives here — not on ChatGeneration — so ConfidentialSession and the
//  view can take the value without opening the orchestrator.
//

import Foundation

/// A single tool call made during generation, captured for the developer debug panel.
struct ToolCallRecord {
    let name: String
    let arguments: String
    let result: String

    /// Cap for the EXPANDED debug-card row. Whole-message history excerpts
    /// made tool results tens of thousands of characters; mounting one into
    /// the card swung the transcript tail's height by thousands of points and
    /// stranded the viewport past the deflating content end — the measured
    /// blank screen (70 overscrolled samples, worst 1230 pt, 2026-08-26).
    /// The COPY path stays complete; only the mounted row is bounded.
    static let displayCap = 1500

    /// The result as the card ROW shows it: complete when short, honestly
    /// truncated when not.
    var displayResult: String {
        guard result.count > Self.displayCap else { return result }
        return result.prefix(Self.displayCap)
            + "\n… [display truncated — \(Self.displayCap) of \(result.count) chars; copy has the full payload]"
    }
}

/// Debug context captured from a successful generation request.
struct LastRequestDebugInfo {
    /// The PLACE this request went to, canonically — `fireworks`, `near.ai`,
    /// `ringzero` — never the provider record's label.
    ///
    /// It used to be `provider.name`, and that label is auto-generated as
    /// "<provider> <model>" when a key is saved and then never refreshed, because
    /// the user may have typed it. So a record labelled "fireworks Qwen3.7 Plus"
    /// on the day the key went in still says so after the user equips
    /// deepseek-v4-flash from the Where sheet — and this card, the one surface
    /// whose entire job is to say what was sent, printed it as the header.
    /// Observed on device 2026-07-30: chip said `deepseek-v4-flash`, card said
    /// `fireworks Qwen3.7 Plus`, and the request had used deepseek all along.
    let providerName: String
    /// The model id ACTUALLY SENT — `HTTPTransport` writes exactly this into the
    /// body's `model` field, so the header can no longer disagree with the wire.
    var modelID: String = ""
    let url: URL?
    let requestHeaders: [String: String]?
    let requestBodyJSON: String?
    /// The sealed body, when E2EE was active. See `TurnReport.sealedBodyJSON`.
    var sealedBodyJSON: String? = nil
    let responseBody: String?
    let toolCalls: [ToolCallRecord]
    let threadID: UUID
    let totalDuration: TimeInterval?
    /// Time to the first VISIBLE token — what the user waited to see anything.
    let timeToFirstToken: TimeInterval?
    /// How long the model spent THINKING before that, when it did.
    ///
    /// Reasoning never reaches the UI while it streams, so a thinking model looked
    /// like a slow one: a user on a warm `gemma4:e4b` asked "why is it 6s for ttft if it's
    /// warm?". Measured on the wire that same minute — first delta 0.64s, first
    /// visible character 5.10s, 824 characters of reasoning in between. The model was
    /// working the whole time and the card had no way to say so.
    var thinkingTime: TimeInterval? = nil
    let outputTokens: Int?
    /// The runtime's own prefill/decode timing, when it reported one.
    var engineTimings: EngineTimings? = nil
    /// What ran this turn on the device. nil for every turn that left the phone.
    var onDeviceRun: OnDeviceRun? = nil
    /// Input-token accounting, when the server reported it. Surfaced so a server
    /// that silently discarded most of the prompt says so instead of leaving a
    /// confident wrong answer as the only evidence. See `PromptBudget`.
    var promptBudget: PromptBudget? = nil
    /// Whether application-layer E2EE was active for this request.
    let isE2EEActive: Bool
    /// TEE signature verification result for this response (nil if not applicable).
    let teeVerification: ResponseVerification?

    /// Time spent producing VISIBLE text.
    var generationTime: TimeInterval? {
        guard let total = totalDuration, let ttft = timeToFirstToken else { return nil }
        return max(0, total - ttft)
    }

    /// Tokens per second over the whole time the model was GENERATING — thinking
    /// included, because those tokens are in `outputTokens` too.
    ///
    /// Dividing every token by the visible-only window is how the card came to claim
    /// 1874 tok/s from a home Ollama box: 124 tokens, almost all of them reasoning,
    /// over the 0.1s it took to emit "Ho." The same numbers over the real window are
    /// about 27 tok/s, which is what that machine actually does.
    ///
    /// The window opens on a token that is already decoded, so it spans n − 1 of
    /// them; dividing all n by it overstates short replies (5 tokens: +25%).
    /// Decode only — prefill is ttft's figure, not this one's.
    var tokensPerSecond: Double? {
        if let rate = engineTimings?.decodeRate, rate > 0 { return rate }
        guard let tokens = outputTokens, tokens > 1 else { return nil }
        let window = (thinkingTime ?? 0) + (generationTime ?? 0)
        guard window > 0 else { return nil }
        return Double(tokens - 1) / window
    }

    /// `prefill 2140tok · 1412tok/s` — only from a runtime that timed it, and not
    /// on-device, where `speedLine` already carries the rate.
    var prefillSummary: String? {
        guard onDeviceRun == nil, let t = engineTimings, t.prefillTokens > 0, t.prefillRate > 0 else { return nil }
        var parts = ["prefill \(t.prefillTokens)tok", String(format: "%.0ftok/s", t.prefillRate)]
        if t.cachedTokens > 0 { parts.append("\(t.cachedTokens) cached") }
        return parts.joined(separator: " · ")
    }

    /// The card's timing chain, in the order it happened:
    /// `4.4s · ttft 3.4s · think 2.0s · gen 1.0s · 24tok · 52tok/s`.
    ///
    /// On-device the rate is not here: `speedLine` leads with it, and a figure
    /// printed twice reads as two measurements. A cloud turn keeps this chain exactly.
    var timingLine: String? {
        let parts: [String] = [
            totalDuration.map    { $0.debugFormatted },
            timeToFirstToken.map { "ttft \($0.debugFormatted)" },
            thinkingTime.map     { "think \($0.debugFormatted)" },
            generationTime.map   { "gen \($0.debugFormatted)" },
            outputTokens.map     { "\($0)tok" },
            onDeviceRun == nil ? tokensPerSecond.map { String(format: "%.0ftok/s", $0) } : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// On-device only, and the card's FIRST row:
    /// `decode 52tok/s · prefill 610tok/s · gpu + speculative`. A screenshot of
    /// this card is how a phone's speed gets reported, so the two rates lead and
    /// the backend says what produced them — `+ speculative` only when the drafter
    /// was actually on. Prefill is the runtime's own figure or nothing; the decode
    /// rate is the chain's. Android prints the same row from the same facts.
    var speedLine: String? {
        guard let run = onDeviceRun else { return nil }
        var parts: [String] = []
        if let rate = tokensPerSecond { parts.append(String(format: "decode %.0ftok/s", rate)) }
        if let t = engineTimings, t.prefillRate > 0 { parts.append(String(format: "prefill %.0ftok/s", t.prefillRate)) }
        parts.append(run.speculative ? "\(run.backend) + speculative" : run.backend)
        return parts.joined(separator: " · ")
    }
}

/// What ran an on-device turn — the facts the debug card prints beside the
/// runtime's own rates. Android prints the same row from the same two facts;
/// keep the shape if you change it.
struct OnDeviceRun: Sendable, Equatable {
    /// The accelerator the engine was built on: `gpu`, `cpu` (`npu` on Android).
    var backend: String
    /// Whether the engine was built WITH speculative decoding — the bundle's
    /// drafter present and nothing disabled it — not merely whether the file
    /// could have supported it.
    var speculative: Bool
}

/// Timing a runtime measured itself: LiteRT's benchmark info, llama.cpp's `timings`.
struct EngineTimings: Sendable, Equatable {
    /// Prompt tokens actually evaluated this turn — cache hits excluded.
    var prefillTokens: Int
    var prefillRate: Double
    var decodeRate: Double
    /// Prompt tokens reused from the server's cache (llama.cpp `cache_n`).
    var cachedTokens: Int = 0
}

extension EngineTimings {
    /// llama-server's `timings` (tools/server/server-task.cpp, `result_timings::to_json`).
    init?(llamaCpp json: [String: Any]) {
        func int(_ key: String) -> Int? { (json[key] as? NSNumber)?.intValue }
        func double(_ key: String) -> Double? { (json[key] as? NSNumber)?.doubleValue }
        guard let prefillTokens = int("prompt_n"),
              let prefillRate = double("prompt_per_second"),
              let decodeRate = double("predicted_per_second") else { return nil }
        self.init(prefillTokens: prefillTokens, prefillRate: prefillRate,
                  decodeRate: decodeRate, cachedTokens: int("cache_n") ?? 0)
    }
}
