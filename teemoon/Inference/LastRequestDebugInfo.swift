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
    var tokensPerSecond: Double? {
        guard let tokens = outputTokens else { return nil }
        let window = (thinkingTime ?? 0) + (generationTime ?? 0)
        guard window > 0 else { return nil }
        return Double(tokens) / window
    }
}
