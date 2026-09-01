//
//  GenerationEvents.swift
//  teemoon
//
//  The contract between the generation engine and ChatGeneration: the result
//  payload, the progress callbacks, and the one lock-guarded box used to hand
//  values out of @Sendable callbacks.
//

import Foundation

/// Result delivered on successful stream completion.
struct RequestResult: Sendable {
    let url: URL?
    let requestHeaders: [String: String]?
    let requestBodyJSON: String?
    /// The sealed body, when E2EE was active. See `TurnReport.sealedBodyJSON`.
    var sealedBodyJSON: String? = nil
    let responseBody: String?
    let toolCalls: [ToolCallRecord]
    let outputTokens: Int?
    /// Input-token accounting, when the server reported it — the signal for a
    /// server silently truncating the prompt. See `PromptBudget`.
    var promptBudget: PromptBudget? = nil
    /// When the first token of ANY kind arrived, and when the first VISIBLE one did.
    /// The gap between them is the model thinking — see `SSEStreamParser.firstDeltaAt`.
    var firstTokenAt: Date? = nil
    var firstVisibleTokenAt: Date? = nil
    /// TEE signature verification result. nil when provider doesn't support attestation.
    let teeVerification: ResponseVerification?
    /// Whether this request/response was encrypted with application-layer E2EE.
    let isE2EEActive: Bool
}

/// All callbacks the generation engine uses to communicate with ChatGeneration.
/// Errors are NOT a callback — the engine throws, and the stream's owner
/// publishes; one channel, no dedup.
struct StreamCallbacks: Sendable {
    let onSourcesFound: @Sendable ([GroundingSource]) -> Void
    let onQueriesFound: @Sendable ([String]) -> Void
    let onToolExecutionEnded: @Sendable () -> Void
    let onSuccess: @Sendable (RequestResult) -> Void

    /// Whether a model turn is IN FLIGHT AND HAS PRODUCED NO VISIBLE TEXT YET.
    ///
    /// The activity chip needs to know "is teemoon working on this right now",
    /// and until this existed the UI had to guess with a 3-second stall timer.
    /// That guess has a hole in it exactly the width of a follow-up round trip
    /// plus prefill — see `StreamingMessageView.showTrailingChip`.
    ///
    /// `turn` is a monotonic index, and it is what makes this safe to deliver
    /// across actor hops: each edge names the turn it describes, so a late
    /// "finished" for turn 2 can never clear the "started" for turn 3.
    ///
    /// Defaulted, so every existing call site and test keeps compiling — a UI
    /// progress signal is not something a stub transport should have to care
    /// about.
    var onAwaitingModel: @Sendable (_ turn: Int, _ awaiting: Bool) -> Void = { _, _ in }
}

/// Minimal lock-guarded box for handing a value out of a @Sendable callback.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { self._value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

