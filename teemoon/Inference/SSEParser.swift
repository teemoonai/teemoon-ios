//
//  SSEParser.swift
//  teemoon
//
//  Single SSE event-stream parser shared by the production streaming path
//  (ConfidentialLanguageModel's GenerationEngine) and the testable entry
//  point (SSEStreamParser.processSSEChunks).
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "stream")

/// Incremental parser for OpenAI-style SSE chat-completion streams.
///
/// Splits buffered bytes into `\n\n`-separated events, forwards plain content
/// events, accumulates structured tool-call deltas, elides text-based
/// tool-call markup REGIONS when tools are configured (prose on either side of
/// a call keeps streaming), and (optionally) decrypts E2EE-encrypted fields
/// via the `decrypt` hook.
///
/// One instance holds all cross-chunk state. The caller is responsible for
/// serialization — production feeds it from the URLSession delegate queue.
/// Accumulator for one tool call assembled from streaming deltas.
struct ToolCallState {
    var id = ""
    var name = ""
    var arguments = ""
}

/// The minimal tool schema the client-side RECOVERY parser needs to disambiguate
/// a malformed tool call the server parser couldn't normalize (e.g. GLM's
/// kwarg-collapse): the function name and its parameter names. teemoon knows
/// these because it registered the tools — which is exactly the knowledge the
/// strict server-side parser lacks.
struct RecoveryToolSpec {
    let name: String
    let paramNames: [String]
    let requiredParams: [String]
}

final class SSEStreamParser {

    /// Registered tool schemas, used ONLY by the text-tool-call recovery path to
    /// disambiguate malformed emissions. Empty when no tools are configured.
    private let recoveryTools: [RecoveryToolSpec]

    // Cross-chunk parsing state.
    var buffer = Data()
    var accumulatedContent = ""
    /// Thinking/CoT tokens (`reasoning_content`). Reasoning models (e.g.
    /// DeepSeek V4 Flash) can stream their entire visible answer here and leave
    /// `content` empty — the engine falls back to this so the reply isn't lost.
    var accumulatedReasoning = ""

    /// When the first delta of ANY kind arrived — reasoning included — and when the
    /// first VISIBLE character did.
    ///
    /// They are different questions and the card was answering the second while
    /// labelling it the first. Measured against a warm gemma4:e4b on 2026-07-30: the
    /// stream's first delta at 0.64s, the first visible character at 5.10s, with 824
    /// characters of `reasoning` in between. Reasoning never reaches `onText` while it
    /// streams, so nothing downstream can tell the model was working rather than idle.
    var firstDeltaAt: Date?
    var firstVisibleAt: Date?
    var toolCallStates: [Int: ToolCallState] = [:]

    // MARK: Streaming markup elision
    //
    // Text-based tool calls arrive as raw markup in the content stream
    // (`<tool_call>{…}</tool_call>`, ```` ```tool_code … ``` ````). The markup must
    // never reach the user, but the suppression used to be STICKY: once a marker
    // was seen, ALL later content was withheld for the rest of the turn, so a
    // prose→call→prose reply had its whole second half batched to the end
    // (measured: 70 of 156 chars forwarded, StreamSuppressionTests). Now only the
    // markup REGION is elided — suppress from an opening marker to its format's
    // closing marker (ToolCallFormat.markerPairs), then resume forwarding. An
    // unterminated region stays suppressed to end of turn: leaking half a call
    // is worse than batching, and sanitizeToolMarkup still nets any residue.
    //
    // The scan stays O(chunk), never O(accumulated): each state keeps only a
    // bounded tail across the chunk boundary. Rescanning the full reply per
    // delta was O(n²) over a stream — 368 ms vs 5.5 ms for an 800-event reply
    // with tools configured (measured), and grounding makes tools the
    // default configuration.
    //
    // The machine itself lives in ToolMarkupElider (ToolCallFormat.swift), not
    // here: LiteRTTransport's on-device stream had the identical latch defect,
    // and two hand-rolled copies would drift the next time a format is added.

    /// The shared elision state machine — disabled when no tools are configured
    /// (markup can't be a tool call then; content passes through untouched).
    private let elider: ToolMarkupElider

    /// What the user may see so far: `accumulatedContent` with tool-call markup
    /// regions elided as they stream. HTTPTransport feeds `onPartialContent`
    /// from this, so it must NEVER contain markup, not even transiently.
    var visibleContent: String { elider.visibleContent }

    /// Whether any markup region was entered this turn — the [DONE] handler uses
    /// this (not the CURRENT state, which is back to forwarding once a call
    /// closes) to decide whether to attempt text tool-call recovery.
    private var textToolCallMarkerSeen: Bool { elider.markerSeen }

    /// True while inside a markup region. Non-content events are not forwarded
    /// mid-region, mirroring the old suppression's treatment of them.
    private var isSuppressingMarkup: Bool { elider.isSuppressing }
    var isTextBasedToolCall = false
    /// Whether the wire said `data: [DONE]`. The stream is semantically over at
    /// that line; the transport must not keep reading until connection close,
    /// because a keep-alive server that frames its response with neither
    /// Content-Length nor chunking never closes — the turn then outlives its
    /// own finished reply until the request's idle timeout (observed 2026-08-06
    /// against the test harness server; the stop control sat live for minutes
    /// under a fully-streamed answer).
    private(set) var sawDone = false
    /// The `id` field from the first SSE event (e.g. "chatcmpl-abc123"). Used for signature fetch.
    var chatCompletionID: String? = nil
    var completionTokens: Int? = nil
    /// `usage.prompt_tokens` — how many input tokens the server evaluated.
    var promptTokens: Int? = nil

    init(hasTools: Bool, tools: [RecoveryToolSpec] = []) {
        self.recoveryTools = tools
        // `hasTools` gates elision: with no tools configured, markup can't be a
        // tool call, so content passes through untouched.
        self.elider = ToolMarkupElider(enabled: hasTools)
    }

    /// Keys a server may stream thinking tokens under. vLLM / near.ai / Fireworks
    /// use `reasoning_content`; **Ollama (0.32+) uses `reasoning`**. Reading only
    /// the first meant a model whose whole reply is thinking — gemma4:e2b and
    /// qwen3.5 stream `content: ""` for every frame — arrived as an EMPTY
    /// message: `accumulatedReasoning` stayed empty, so the engine's
    /// reasoning-only fallback never fired.
    static let reasoningKeys = ["reasoning_content", "reasoning"]

    /// The thinking chunk in a delta, whichever key it came under, plus that key
    /// so an E2EE rewrite puts the plaintext back where the server had it.
    static func reasoningChunk(in delta: [String: Any]) -> (key: String, text: String)? {
        for key in reasoningKeys {
            if let text = delta[key] as? String, !text.isEmpty { return (key, text) }
        }
        return nil
    }

    /// Accumulates a content chunk and returns the portion that may be shown
    /// now — the chunk with tool-call markup regions elided. `accumulatedContent`
    /// keeps the RAW text (recovery parses tool calls out of it at [DONE]);
    /// `visibleContent` gets only what the user may see.
    @discardableResult
    private func appendContent(_ chunk: String) -> String {
        accumulatedContent += chunk
        return elider.append(chunk)
    }

    /// Appends `data` to the buffer and processes every complete event in it.
    ///
    /// - Parameters:
    ///   - decrypt: E2EE per-field decryptor; returns plaintext, or nil when
    ///     decryption fails (the parser then deliberately passes the ciphertext
    ///     through). Pass nil when E2EE is inactive.
    ///   - onNonToolFinish: invoked when the stream finishes without tool calls
    ///     ([DONE] or a non-"tool_calls" finish_reason). Production hooks TEE
    ///     signature verification here so it fires before AnyLanguageModel calls
    ///     continuation.finish() → task.cancel(); tests pass nil.
    /// - Returns: the bytes to forward to the client and whether a tool call
    ///   round was detected (structured or text-based).
    func consume(
        _ data: Data,
        decrypt: ((String) -> String?)? = nil,
        onNonToolFinish: (() -> Void)? = nil
    ) -> (forwarded: Data, toolCallDetected: Bool) {
        buffer.append(data)

        var toForward = Data()
        var toolCallDetected = false
        let sep = Data("\n\n".utf8)

        while let range = buffer.range(of: sep) {
            let eventData = buffer[buffer.startIndex..<range.lowerBound]
            buffer.removeSubrange(..<range.upperBound)

            guard let line = String(data: eventData, encoding: .utf8),
                  line.hasPrefix("data: ") else {
                if toolCallStates.isEmpty && !isSuppressingMarkup {
                    toForward.append(eventData); toForward.append(sep)
                }
                continue
            }

            let jsonStr = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)

            if jsonStr == "[DONE]" {
                sawDone = true
                if !toolCallStates.isEmpty {
                    toolCallDetected = true
                } else if textToolCallMarkerSeen {
                    // A markup region appeared at SOME point this turn. The
                    // CURRENT elision state is the wrong thing to ask — a closed
                    // region has already returned it to forwarding — and the call
                    // inside it still has to be recovered and executed.
                    let textCalls = Self.parseTextToolCalls(from: accumulatedContent, tools: recoveryTools)
                    if !textCalls.isEmpty {
                        for (k, v) in textCalls { toolCallStates[k] = v }
                        isTextBasedToolCall = true
                        toolCallDetected = true
                    } else {
                        elider.finish()
                        onNonToolFinish?()
                        toForward.append(eventData); toForward.append(sep)
                    }
                } else {
                    elider.finish()
                    onNonToolFinish?()
                    toForward.append(eventData); toForward.append(sep)
                }
                continue
            }

            guard let json = try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any] else {
                if toolCallStates.isEmpty && !isSuppressingMarkup {
                    toForward.append(eventData); toForward.append(sep)
                }
                continue
            }

            // Capture the chat completion ID from the first event for TEE signature verification.
            if chatCompletionID == nil, let eventID = json["id"] as? String, !eventID.isEmpty {
                chatCompletionID = eventID
            }

            if let usage = json["usage"] as? [String: Any] {
                if let tokens = usage["completion_tokens"] as? Int {
                    completionTokens = tokens
                }
                // What the server ACTUALLY evaluated. Not decoration: a server
                // whose context window is smaller than the prompt may silently
                // drop the front of it and answer anyway, and this is the only
                // number in the response that gives that away. See
                // `PromptBudget`.
                if let tokens = usage["prompt_tokens"] as? Int {
                    promptTokens = tokens
                }
            }

            guard let choices = json["choices"] as? [[String: Any]],
                  let choice  = choices.first,
                  let delta   = choice["delta"] as? [String: Any] else {
                if toolCallStates.isEmpty && !isSuppressingMarkup {
                    toForward.append(eventData); toForward.append(sep)
                }
                continue
            }

            // Timestamps, at the one place every delta of every kind passes.
            // `firstDeltaAt` is the honest time-to-first-token; `firstVisibleAt` is
            // when the user could first see anything, and the gap between them is the
            // model thinking.
            if firstDeltaAt == nil,
               Self.reasoningChunk(in: delta) != nil
                || (delta["content"] as? String)?.isEmpty == false {
                firstDeltaAt = Date()
            }
            if firstVisibleAt == nil, (delta["content"] as? String)?.isEmpty == false {
                firstVisibleAt = Date()
            }

            // Accumulate this delta's text — decrypting first when E2EE is
            // active — and compute the VISIBLE portion of the content (markup
            // regions elided by `appendContent`). The E2EE and plain paths
            // deliberately converge here: they used to accumulate AND forward
            // separately, and a forwarding fix applied to one silently missed
            // the other.
            var mutableDelta = delta
            // Whether the event must be re-serialized before forwarding —
            // because a field was decrypted, or because only PART of the
            // content is visible (prose and markup sharing one delta).
            var needsRebuild = false
            var hadContent = false
            var visibleChunk = ""

            if let (key, rc) = Self.reasoningChunk(in: delta) {
                if let decrypt {
                    if let plaintext = decrypt(rc) {
                        mutableDelta[key] = plaintext
                        accumulatedReasoning += plaintext
                        needsRebuild = true
                    } else {
                        logger.warning("[E2EE] \(key) decrypt failed, passing through")
                        accumulatedReasoning += rc
                    }
                } else {
                    accumulatedReasoning += rc
                }
            }

            if let c = delta["content"] as? String, !c.isEmpty {
                hadContent = true
                var plaintext = c
                if let decrypt {
                    if let p = decrypt(c) {
                        plaintext = p
                        needsRebuild = true
                    } else {
                        // Deliberate passthrough: the loop above surfaces the
                        // failure via its LockedBox; the parser stays total.
                        logger.warning("[E2EE] chunk decrypt failed, passing through")
                    }
                }
                visibleChunk = appendContent(plaintext)
                if visibleChunk != plaintext {
                    mutableDelta["content"] = visibleChunk
                    needsRebuild = true
                }
            }

            if let tcArr = delta["tool_calls"] as? [[String: Any]] {
                for tcDelta in tcArr {
                    guard let idx = tcDelta["index"] as? Int else { continue }
                    var state = toolCallStates[idx] ?? ToolCallState()
                    if let id = tcDelta["id"] as? String, !id.isEmpty { state.id = id }
                    if let fn = tcDelta["function"] as? [String: Any] {
                        if let n = fn["name"] as? String, !n.isEmpty {
                            // E2EE: decrypt tool call name if encrypted.
                            if let decrypt, let plain = decrypt(n) {
                                state.name = plain
                            } else {
                                state.name = n
                            }
                        }
                        if let a = fn["arguments"] as? String {
                            // E2EE: decrypt each argument fragment independently,
                            // then concatenate plaintext (not ciphertext).
                            if let decrypt, !a.isEmpty, let plain = decrypt(a) {
                                state.arguments += plain
                            } else {
                                state.arguments += a
                            }
                        }
                    }
                    toolCallStates[idx] = state
                }
            }

            if let reason = choice["finish_reason"] as? String {
                if reason == "tool_calls" {
                    toolCallDetected = true
                } else {
                    elider.finish()
                    // Non-tool finish: production launches TEE verification NOW,
                    // before AnyLanguageModel cancels the URLSession task.
                    onNonToolFinish?()
                }
                continue
            }

            // Forward decision. A structured tool-call round still forwards
            // nothing. A content event forwards exactly its visible portion:
            // the untouched original when all of it is visible, a re-serialized
            // copy when markup was elided out of the middle (or a field was
            // decrypted), nothing when the delta was markup through and
            // through. Non-content frames (role, usage) are withheld only while
            // inside a markup region, as the sticky flag used to do.
            guard toolCallStates.isEmpty else { continue }
            if hadContent {
                guard !visibleChunk.isEmpty else { continue }
            } else if isSuppressingMarkup {
                continue
            }
            if needsRebuild {
                var mutableChoice = choice
                var mutableChoices = choices
                var mutableJson = json
                mutableChoice["delta"] = mutableDelta
                mutableChoices[0] = mutableChoice
                mutableJson["choices"] = mutableChoices
                if let rebuilt = try? JSONSerialization.data(withJSONObject: mutableJson),
                   let rebuiltStr = String(data: rebuilt, encoding: .utf8) {
                    toForward.append(Data("data: \(rebuiltStr)\n\n".utf8))
                }
                // Re-serialization of a just-deserialized dictionary can't
                // realistically fail; if it somehow does, dropping the event is
                // safer than forwarding the original, which could carry
                // ciphertext or raw markup.
            } else {
                toForward.append(eventData); toForward.append(sep)
            }
        }

        return (toForward, toolCallDetected)
    }
}

// MARK: - Text-based tool calls + testable entry point

extension SSEStreamParser {

    /// Public entry point — dispatches to the pluggable tool-call formats by marker,
    /// so non-`<tool_call>` families (Gemma, …) parse too. See ToolCallFormat.
    static func parseTextToolCalls(from content: String, tools: [RecoveryToolSpec] = []) -> [Int: ToolCallState] {
        ToolCallFormat.parseAny(content, tools: tools)
    }

    /// The `<tool_call>…</tool_call>` parser (Qwen/GLM + JSON / `<function=>` /
    /// `<arg_key>` / kwarg-collapse-recovery variants). Driven by AngleBracketToolCallFormat.
    static func parseAngleBracketToolCalls(from content: String, tools: [RecoveryToolSpec] = []) -> [Int: ToolCallState] {
        var result: [Int: ToolCallState] = [:]
        var idx = 0
        var search = content.startIndex..<content.endIndex

        while let openRange  = content.range(of: "<tool_call>",  range: search),
              let closeRange = content.range(of: "</tool_call>", range: openRange.upperBound..<content.endIndex) {
            defer {
                idx += 1
                search = closeRange.upperBound..<content.endIndex
            }
            let inner = content[openRange.upperBound..<closeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // JSON payload variant
            if let data = inner.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String, !name.isEmpty {
                let argsJSON: String
                if let argsObj = json["arguments"] {
                    argsJSON = (try? JSONSerialization.data(withJSONObject: argsObj))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                } else {
                    argsJSON = "{}"
                }
                result[idx] = ToolCallState(id: "text_tool_\(idx)", name: name, arguments: argsJSON)
                continue
            }

            // XML attribute variant: <function=name><parameter=key>value</parameter></function>
            if let funcPrefixRange = inner.range(of: "<function="),
               let funcNameEnd     = inner[funcPrefixRange.upperBound...].firstIndex(of: ">") {
                let funcName = String(inner[funcPrefixRange.upperBound..<funcNameEnd])
                guard !funcName.isEmpty else { continue }

                let funcBodyStart = inner.index(after: funcNameEnd)
                let funcBodyEnd   = inner.range(of: "</function>")?.lowerBound ?? inner.endIndex
                let funcBody      = String(inner[funcBodyStart..<funcBodyEnd])

                var args: [String: String] = [:]
                var paramSearch = funcBody.startIndex..<funcBody.endIndex
                while let paramRange    = funcBody.range(of: "<parameter=", range: paramSearch),
                      let paramNameEnd  = funcBody[paramRange.upperBound...].firstIndex(of: ">") {
                    var paramName = String(funcBody[paramRange.upperBound..<paramNameEnd])
                    if paramName.hasPrefix("parameter=") { paramName = String(paramName.dropFirst("parameter=".count)) }
                    let valueStart = funcBody.index(after: paramNameEnd)
                    guard let closeRange = funcBody.range(of: "</parameter>", range: valueStart..<funcBody.endIndex) else { break }
                    args[paramName] = String(funcBody[valueStart..<closeRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    paramSearch = closeRange.upperBound..<funcBody.endIndex
                }

                let argsJSON = (try? JSONSerialization.data(withJSONObject: args))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                result[idx] = ToolCallState(id: "text_tool_\(idx)", name: funcName, arguments: argsJSON)
                continue
            }

            // arg_key/arg_value variant: name<arg_key>k</arg_key><arg_value>v</arg_value>...
            let nameEndIdx = inner.range(of: "<arg_key>")?.lowerBound ?? inner.endIndex
            let funcName = inner[inner.startIndex..<nameEndIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !funcName.isEmpty else { continue }

            var args: [String: String] = [:]
            var kvSearch = inner.startIndex..<inner.endIndex
            while let keyOpen  = inner.range(of: "<arg_key>",    range: kvSearch),
                  let keyClose = inner.range(of: "</arg_key>",   range: keyOpen.upperBound..<inner.endIndex),
                  let valOpen  = inner.range(of: "<arg_value>",  range: keyClose.upperBound..<inner.endIndex),
                  let valClose = inner.range(of: "</arg_value>", range: valOpen.upperBound..<inner.endIndex) {
                let k = String(inner[keyOpen.upperBound..<keyClose.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let v = String(inner[valOpen.upperBound..<valClose.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !k.isEmpty { args[k] = v }
                kvSearch = valClose.upperBound..<inner.endIndex
            }
            if !args.isEmpty {
                let argsJSON = (try? JSONSerialization.data(withJSONObject: args))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                result[idx] = ToolCallState(id: "text_tool_\(idx)", name: funcName, arguments: argsJSON)
                continue
            }

            // 4th branch — kwarg-collapse RECOVERY (GLM below-grammar malformation):
            //   `NAME_ARGKEY="value"` — function name + arg key fused into one token,
            //   Python kwarg syntax, NO <arg_key>/<arg_value> tags (often a dangling
            //   </arg_value>). The server's strict `glm47` regex can't normalize this;
            //   teemoon can, because it knows the registered tool schema. HIGH-confidence
            //   recover + execute; returns nil (skip) when no registered tool matches —
            //   the low-confidence tail is left to containment, not to guessing.
            if let recovered = recoverKwargCollapse(inner: inner, idx: idx, tools: tools) {
                result[idx] = recovered
                continue
            }
        }
        return result
    }

    /// Recovers a kwarg-collapse malformed tool call (`NAME_ARGKEY="value"`). Uses the
    /// registered tool schema to disambiguate: longest-prefix-match the function name,
    /// resolve the fused remainder to a parameter, extract the quoted value. Returns nil
    /// (low confidence — do not guess) when no registered tool prefix-matches or no value
    /// is extractable.
    static func recoverKwargCollapse(inner: String, idx: Int, tools: [RecoveryToolSpec]) -> ToolCallState? {
        guard !tools.isEmpty, let eqIdx = inner.firstIndex(of: "=") else { return nil }
        let head = inner[..<eqIdx].trimmingCharacters(in: .whitespacesAndNewlines)   // web_search_query_simple
        guard !head.isEmpty else { return nil }
        // Longest-prefix match against registered tool names (web_search wins over
        // web_search_query_simple, which isn't a registered tool).
        guard let tool = tools
            .filter({ head == $0.name || head.hasPrefix($0.name) })
            .max(by: { $0.name.count < $1.name.count }) else { return nil }
        // Resolve the arg key from the remainder after the tool name.
        var remainder = String(head.dropFirst(tool.name.count))
        while let f = remainder.first, f == "_" || f == " " || f == "." { remainder.removeFirst() }
        let key = resolveParam(remainder, tool: tool)
        guard let value = extractKwargValue(inner[inner.index(after: eqIdx)...]) else { return nil }
        let argsJSON = (try? JSONSerialization.data(withJSONObject: [key: value]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolCallState(id: "text_tool_\(idx)", name: tool.name, arguments: argsJSON)
    }

    /// Maps a (possibly hallucinated) arg-key token to a real parameter: exact match →
    /// the token; else the single required param; else the first declared param; else the
    /// token itself.
    private static func resolveParam(_ token: String, tool: RecoveryToolSpec) -> String {
        if tool.paramNames.contains(token) { return token }
        if tool.requiredParams.count == 1 { return tool.requiredParams[0] }
        if let first = tool.paramNames.first { return first }
        return token.isEmpty ? "input" : token
    }

    /// Extracts a kwarg value: a double-quoted string if present, else the run up to the
    /// first stray XML tag / end. Strips a dangling `</arg_value>` and surrounding quotes.
    private static func extractKwargValue(_ tail: Substring) -> String? {
        let s = tail.trimmingCharacters(in: .whitespaces)
        if let open = s.firstIndex(of: "\"") {
            let after = s.index(after: open)
            if let close = s[after...].firstIndex(of: "\"") {
                return String(s[after..<close])
            }
        }
        // No closing quote — take up to the first stray tag.
        let cut = s.firstIndex(of: "<").map { String(s[..<$0]) } ?? String(s)
        let v = cut.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        return v.isEmpty ? nil : v
    }

    static func stripTextToolCalls(from content: String) -> String {
        var result = content
        while let openRange  = result.range(of: "<tool_call>"),
              let closeRange = result.range(of: "</tool_call>") {
            result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Final CONTAINMENT pass, run on the user-visible answer AFTER recovery. This
    /// is the guarantee the leak's root cause lacked: it removes residual tool-call
    /// markup independent of whether any parse succeeded, across every known model
    /// family, so an unrecognized or unrecoverable form (a malformed call for an
    /// unregistered tool, a family with no handler yet, a truncated call) can never
    /// reach the user. Returns the cleaned text and the fragments removed — the caller
    /// MUST log a non-empty removal so containment stays observable, never a silent drop.
    ///
    /// Deliberately conservative: only strips the specific literal tokens/spans from the
    /// per-model reference matrix, never arbitrary `<…>`, so code and prose survive.
    /// Reasoning (`<think>`) is intentionally left for the display layer.
    static func sanitizeToolMarkup(from text: String) -> (clean: String, removed: [String]) {
        var s = text
        var removed: [String] = []

        // Paired blocks — remove the whole span (DOTALL).
        for p in [
            "<tool_call>.*?</tool_call>",                               // GLM / Qwen
            "<｜tool▁calls▁begin｜>.*?<｜tool▁calls▁end｜>",                // DeepSeek V3/V3.1 (Unicode)
            "<｜DSML｜tool_calls>.*?</｜DSML｜tool_calls>",                 // DeepSeek V4 DSML
            "<｜DSML｜function_calls>.*?</｜DSML｜function_calls>",         // DeepSeek V3.2 DSML
            "```tool_code.*?```",                                       // Gemma 3
            "```tool_output.*?```",                                     // Gemma 3
        ] { s = removeMatches(p, in: s, dotAll: true, into: &removed) }

        // Attribute-bearing opener tags.
        for p in [
            "<function=[^>]*>", "<parameter=[^>]*>",
            "<｜DSML｜invoke[^>]*>", "<｜DSML｜parameter[^>]*>",
        ] { s = removeMatches(p, in: s, dotAll: false, into: &removed) }

        // Residual individual tokens / orphans (any family, any truncation state).
        for t in [
            "<tool_call>", "</tool_call>",
            "<arg_key>", "</arg_key>", "<arg_value>", "</arg_value>",
            "</function>", "</parameter>",
            "<｜tool▁calls▁begin｜>", "<｜tool▁calls▁end｜>",
            "<｜tool▁call▁begin｜>", "<｜tool▁call▁end｜>", "<｜tool▁sep｜>",
            "</｜DSML｜invoke>", "</｜DSML｜parameter>",
            "</｜DSML｜tool_calls>", "</｜DSML｜function_calls>",
            "<|start|>", "<|end|>", "<|message|>", "<|channel|>",
            "<|constrain|>", "<|call|>", "<|return|>",
        ] where s.contains(t) {
            removed.append(t)
            s = s.replacingOccurrences(of: t, with: "")
        }

        return (s.trimmingCharacters(in: .whitespacesAndNewlines), removed)
    }

    /// Removes every match of `pattern`, recording a truncated copy of each removed
    /// fragment into `removed` (for the caller's containment log).
    private static func removeMatches(_ pattern: String, in text: String,
                                      dotAll: Bool, into removed: inout [String]) -> String {
        let opts: NSRegularExpression.Options = dotAll ? [.dotMatchesLineSeparators] : []
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return text }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = re.matches(in: text, range: full)
        guard !matches.isEmpty else { return text }
        for m in matches { removed.append(String(ns.substring(with: m.range).prefix(80))) }
        return re.stringByReplacingMatches(in: text, range: full, withTemplate: "")
    }

    /// Test-visible SSE parsing entry point.
    ///
    /// Thin wrapper over `SSEStreamParser` — the exact implementation the
    /// production streaming path uses (see SSEParser.swift) — with no E2EE
    /// decryption and no TEE-verification hook.
    static func processSSEChunks(
        _ sseData: Data,
        hasTools: Bool
    ) -> (forwarded: Data, toolCalls: [Int: ToolCallState], toolCallDetected: Bool) {
        let parser = SSEStreamParser(hasTools: hasTools)
        let (forwarded, toolCallDetected) = parser.consume(sseData)
        return (forwarded, parser.toolCallStates, toolCallDetected)
    }
}
