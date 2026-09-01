//
//  GenerationTransport.swift
//  teemoon
//
//  The seam between *how a turn is produced* and *what teemoon does with it*.
//
//  A transport does exactly one thing: take the conversation so far, get one
//  model turn back, and stream its visible text as it arrives. It knows about
//  sockets, or Metal, or nothing at all (tests). It does NOT know about tool
//  execution, argument coercion, tool-call recovery, or how many rounds are
//  allowed — that is `GenerationEngine`, and it is shared by every transport
//  so local and remote inference cannot drift apart.
//
//  Conformers:
//    - `HTTPTransport`  — OpenAI-compatible chat/completions over URLSession,
//                          incl. E2EE sealing and TEE signature verification.
//    - `LiteRTTransport` — on-device generation via LiteRT-LM.
//
//  Related: GenerationEngine.swift (the shared loop), SSEParser.swift (wire
//  parsing + tool-call recovery), ToolCallFormat.swift (per-family formats).
//

import Foundation

/// One completed model turn, however the transport produced it.
///
/// This is deliberately *post-parse*: the transport has already turned bytes
/// (or tokens) into text and tool calls. What it must NOT do is execute those
/// tool calls or decide whether to loop — that belongs to the engine.
struct TurnOutput: Sendable {
    /// Visible answer text for this turn, with any tool-call markup already
    /// removed by the transport's parser.
    var content: String = ""

    /// Thinking tokens, when the model streams them in a separate field
    /// (`reasoning_content` / `reasoning`). Kept apart from `content` so the
    /// engine can apply the reasoning-only fallback without guessing.
    var reasoning: String = ""

    /// Tool calls the model requested, keyed by call index (the key ordering is
    /// the order the calls are sent back to the model).
    var toolCalls: [Int: ToolCallState] = [:]

    /// True when the calls were *recovered from text* (Gemma ```tool_code,
    /// Qwen/GLM `<tool_call>`) rather than read from a structured `tool_calls`
    /// field. The follow-up messages have to be shaped differently — a model
    /// that emitted text cannot always ingest an OpenAI `tool` role reply.
    var isTextBasedToolCall: Bool = false

    var completionTokens: Int?

    /// True when generation stopped because it ran out of budget, not because
    /// the model finished.
    ///
    /// Only the transport knows its own cap, so only the transport can tell the
    /// difference — and the difference matters for the reasoning-only fallback
    /// below. A model whose entire answer arrives as reasoning must still be
    /// shown; a model that spiralled and was cut off mid-thought must not,
    /// because its "reasoning" is a truncated scratchpad, not an answer.
    ///
    /// Measured: Qwen3-0.6B on MLX occasionally loops on the date teemoon
    /// injects, burns all 1024 tokens, and produced 3,616 characters ending
    /// mid-word — which teemoon then displayed as the assistant's reply.
    var wasTruncated: Bool = false

    /// Transport-specific reporting and verification for this turn.
    var report: TurnReport = .init()
}

/// What the server said it evaluated, against what teemoon sent it.
///
/// Exists to catch a server **silently discarding the front of the prompt**.
/// Ollama's context window defaults by VRAM and a 16 GB machine gets 4096 no
/// matter what the model supports; past that its runner is launched
/// `--context-shift --keep 4`, so the prompt slides — four tokens survive from
/// the head and the rest of the front goes, system prompt and user question
/// first. There is no error and no flag: HTTP 200, and a fluent answer to a
/// question the model can no longer see. One `web_search` result is 4-6k tokens
/// on its own, so a single grounded turn overflows 4096 by itself.
///
/// Measured on gemma4:latest at the default: a 4,500-token turn came back
/// `prompt_tokens = 392`, and the model invented an unrelated search query out
/// of the void rather than answering what was asked.
///
/// `usage.prompt_tokens` is the only number in the response that gives this
/// away, because it reports what the server actually evaluated rather than what
/// it was handed.
struct PromptBudget: Sendable, Equatable {
    /// Rough token count for what teemoon sent. Deliberately an UNDER-estimate:
    /// it counts message content only, ignoring the tool schemas and chat
    /// template that also consume input tokens, so the comparison below errs
    /// toward silence rather than toward crying wolf.
    let sentEstimate: Int
    /// `usage.prompt_tokens` — what the server says it evaluated.
    let evaluated: Int

    /// Below this the ratio is noise: a short prompt's estimate is dominated by
    /// the template overhead the estimate deliberately ignores.
    static let minimumEstimateToJudge = 1_000
    /// Truncation is not subtle when it happens — the observed cases came back
    /// at 9% and 33% of what was sent — so the bar sits far from anything a
    /// tokenizer disagreement could reach.
    static let suspiciousRatio = 0.6

    var looksTruncated: Bool {
        sentEstimate >= Self.minimumEstimateToJudge
            && Double(evaluated) < Double(sentEstimate) * Self.suspiciousRatio
    }

    /// Token counts for message content only. ~4 characters per token is the
    /// standard English approximation and is all this needs — the decision it
    /// feeds is an order-of-magnitude one.
    static func estimateSentTokens(messages: [[String: Any]]) -> Int {
        var characters = 0
        for message in messages {
            characters += (message["content"] as? String)?.count ?? 0
            for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                let function = call["function"] as? [String: Any]
                characters += (function?["name"] as? String)?.count ?? 0
                characters += (function?["arguments"] as? String)?.count ?? 0
            }
        }
        return characters / 4
    }
}

/// What a transport can say about the exchange it just performed.
///
/// Every field is optional because on-device generation has no request to
/// report and no signature to verify — the developer panel simply shows less,
/// rather than the engine growing a "was this local?" branch.
struct TurnReport: Sendable {
    var url: URL?
    var requestHeaders: [String: String]?
    var requestBodyJSON: String?

    /// The body as it actually left the device, when E2EE sealed it.
    ///
    /// `requestBodyJSON` is the PLAINTEXT the request was built from, which is
    /// what a developer wants to read. Under E2EE that is not what went out,
    /// and the debug panel was showing only the former under a green
    /// "encrypted" label — the one surface whose whole job is to show the wire.
    var sealedBodyJSON: String?

    /// Whether this exchange used application-layer E2EE.
    var isE2EEActive: Bool = false

    /// When the first token of ANY kind arrived, and when the first VISIBLE one did.
    /// The gap is thinking — see `SSEStreamParser.firstDeltaAt`.
    var firstTokenAt: Date?
    var firstVisibleTokenAt: Date?

    /// Input-token accounting for this turn, when the server reported it.
    ///
    /// nil under E2EE — the wire carries hex ciphertext, roughly twice the
    /// character count of the plaintext it encodes, so any estimate built from
    /// it is wrong by a factor that would manufacture false alarms.
    var promptBudget: PromptBudget?

    /// Tool calls the TRANSPORT ran itself, rather than handing back for the
    /// engine to run.
    ///
    /// Only LiteRT populates this: it owns the tool loop, so `toolCalls` comes
    /// back empty and the engine has nothing to record. Without this the
    /// developer panel showed no tools at all for on-device chats that had
    /// plainly just searched — the sources rail said "5 sources" while the
    /// debug card listed none.
    var executedToolCalls: [ToolCallRecord] = []

    /// Verifies this turn's response signature, if the transport has an
    /// attestation story at all. nil for local inference and for plain
    /// OpenAI-compatible endpoints — absence means "not applicable", which is
    /// distinct from a verification that ran and failed.
    var verify: (@Sendable () async -> ResponseVerification?)?
}

/// Produces one model turn from a conversation.
///
/// `messages` is OpenAI wire shape (`role`/`content`, plus `tool_calls` and
/// `tool_call_id` on follow-up turns). That shape is the lingua franca every
/// provider teemoon talks to already speaks, so it is also what the on-device
/// transport translates *from* rather than inventing a third representation.
protocol GenerationTransport: Sendable {
    /// Runs one round-trip.
    ///
    /// - Parameters:
    ///   - messages: the conversation so far, in OpenAI wire shape.
    ///   - includeTools: whether to offer tools this round. The engine turns
    ///     this off once a text-based tool round has happened, and when the
    ///     round budget is spent.
    ///   - onPartialContent: called with *this turn's* visible text as it
    ///     accumulates (not the whole conversation). The engine owns everything
    ///     that came before. Not called while a tool call is being buffered.
    /// - Returns: the completed turn.
    func runTurn(
        messages: [[String: Any]],
        includeTools: Bool,
        onPartialContent: @escaping @Sendable (String) -> Void
    ) async throws -> TurnOutput
}
