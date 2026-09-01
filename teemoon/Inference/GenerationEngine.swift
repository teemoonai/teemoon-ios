//
//  GenerationEngine.swift
//  teemoon
//
//  The transport-agnostic generation loop: ask a `GenerationTransport` for one
//  turn, execute any tool calls it requested, feed the results back, repeat
//  until the model answers.
//
//  Everything in here is the part that must NOT differ between a model running
//  on near.ai and the same weights running on the phone:
//    - which tools are offered, and for how many rounds
//    - `$ref` flattening of `@Generable` schemas (small models can't resolve it)
//    - string→scalar argument coercion against the schema we actually sent
//    - the shape of the follow-up messages (structured vs. text-based)
//    - the reasoning-only fallback
//    - residual tool-markup containment
//    - self-grounding providers' citation split
//
//  The transport owns bytes/tokens and parsing; this owns meaning. Errors are
//  thrown, never side-channeled.
//

import Foundation
import ModelBackend
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "inference")

/// Runs one generation to completion across however many tool rounds it takes.
struct GenerationEngine: Sendable {
    let events: StreamCallbacks
    let tools: [any Tool]
    let initialMessages: [WireMessage]
    let prompt: String
    /// Produces each turn. Swapping this is the whole point: HTTP for remote,
    /// MLX for on-device, a stub in tests.
    let transport: any GenerationTransport
    /// Whether the answering provider grounds its own answers and so interleaves
    /// citation markup into `content` (Brave Answers). A single Bool rather than
    /// the whole `Provider`: it is the only thing the loop needs to know about
    /// who is answering, and an on-device model has no `Provider` to hand over.
    let groundsItsOwnAnswers: Bool

    /// Tool-call follow-up rounds allowed after the initial request.
    ///
    /// Configurable because the right number depends on **whose GPU pays**. A
    /// hosted model can afford 4 rounds; on device each round is a full
    /// re-prefill plus a serial decode on the phone, so 4 rounds compounds into
    /// minutes of saturated GPU — enough to heat the device and take the app
    /// down with it. See `LocalLanguageModel`.
    let maxToolRounds: Int

    /// The default, for hosted providers.
    static let defaultMaxToolRounds = 4

    /// What the model is told on the turn where tools stop being offered.
    ///
    /// WITHOUT THIS THE TURN IS SILENTLY DIFFERENT. When the budget runs out,
    /// `includeTools` goes false and the `tools` key simply vanishes from the
    /// body — while the history the model reads is still full of its own tool
    /// calls and their results. Nothing says anything changed, so a model that
    /// was mid-hunt does the obvious thing and asks for one more search. With
    /// no schema to make it structured, it arrives as raw `<tool_call>` markup;
    /// recovery parses it, the budget guard below drops it, containment strips
    /// what is left, and the answer is the empty string.
    ///
    /// Measured — GLM-5.1 on near.ai, one captured exhausted history (4 rounds,
    /// ~20k tokens) with the final turn replayed 52 times:
    ///
    ///     nothing said (what teemoon did)   5 of 18 turns → empty answer
    ///     told, any of three wordings       0 of 34 turns → empty answer
    ///
    /// p = 0.0033 (Fisher exact). The three wordings were indistinguishable on
    /// failure rate, so it is being TOLD that matters, not how — do not treat
    /// this exact prose as load-bearing.
    ///
    /// Framed as a SETTING rather than a failed call, which is the lesson
    /// `BraveWebSearchTool`'s keyless string already paid for: a string that
    /// reads like a tool error makes a model apologise and redirect instead of
    /// answering.
    static let searchesExhaustedNotice = """
        SEARCH POLICY: this conversation has used the searches available to it, \
        so no further searches will run. This is a setting, not a failure.
        Answer the question now from the results already gathered above. Where \
        they are inconclusive, say what you found and what is still uncertain.
        """

    init(
        events: StreamCallbacks,
        tools: [any Tool],
        initialMessages: [WireMessage],
        prompt: String,
        transport: any GenerationTransport,
        groundsItsOwnAnswers: Bool = false,
        maxToolRounds: Int = GenerationEngine.defaultMaxToolRounds
    ) {
        self.maxToolRounds = maxToolRounds
        self.events = events
        self.tools = tools
        self.initialMessages = initialMessages
        self.prompt = prompt
        self.transport = transport
        self.groundsItsOwnAnswers = groundsItsOwnAnswers
    }

    /// Convenience for the remote path: builds the HTTP transport itself so
    /// call sites that only know about a provider don't have to.
    init(
        provider: Provider,
        apiKey: String,
        teeContext: TEEContext?,
        events: StreamCallbacks,
        tools: [any Tool],
        initialMessages: [WireMessage],
        prompt: String,
        urlSession: URLSession
    ) {
        self.init(
            events: events,
            tools: tools,
            initialMessages: initialMessages,
            prompt: prompt,
            transport: HTTPTransport(
                provider: provider, apiKey: apiKey, teeContext: teeContext,
                tools: tools, urlSession: urlSession
            ),
            groundsItsOwnAnswers: provider.capabilities.contains(.builtInGrounding)
        )
    }

    /// Distills a registered tool into the minimal schema the client-side recovery
    /// parser needs (name + parameter names + required) so it can disambiguate
    /// malformed tool calls the server parser couldn't normalize. Derived from the
    /// same `tool.parameters` schema teemoon sends in the request.
    static func recoverySpec(_ tool: any Tool) -> RecoveryToolSpec {
        let schema = (try? JSONSerialization.jsonObject(
            with: JSONEncoder().encode(tool.parameters))) as? [String: Any]
        let params = (schema?["properties"] as? [String: Any]).map { Array($0.keys) } ?? []
        let required = schema?["required"] as? [String] ?? []
        return .init(name: tool.name, paramNames: params, requiredParams: required)
    }

    /// Answer text as the user should see it: provider markup removed. Identity
    /// for every other provider, so no shared path changes shape.
    ///
    /// Vended as a `@Sendable` value rather than a method because the partial-text
    /// closure handed to the transport escapes — it must not capture `self`.
    private var displayText: @Sendable (String) -> String {
        let grounds = groundsItsOwnAnswers
        return { raw in grounds ? BraveAnswersFormat.split(raw).visible : raw }
    }

    // MARK: - The loop

    func run(onText: @escaping @Sendable (String) -> Void) async throws {
        // Hoisted once: several escaping closures below need it, and a
        // per-iteration `let events = events` shadowed the property in a way
        // that made an earlier capture in the same scope illegal.
        let events = events
        var messages: [[String: Any]] = initialMessages.map { ["role": $0.role, "content": $0.content] }
        messages.append(["role": "user", "content": prompt])

        var remainingToolRounds = maxToolRounds
        var textToolCallRoundHappened = false
        var allToolRecords: [ToolCallRecord] = []
        var textSoFar = ""
        var toolRoundsRun = 0
        var toldSearchesAreOver = false
        var turnIndex = 0

        while true {
            let includeTools = !tools.isEmpty && !textToolCallRoundHappened && remainingToolRounds > 0

            // The tools are about to disappear from the request. Say so, in the
            // turn that is already being sent — see `searchesExhaustedNotice`.
            //
            // `toolRoundsRun > 0` because a budget of zero would otherwise open
            // the conversation by telling the model it had used up searches it
            // never got. Nothing ships with that today (4 hosted, 2 on device)
            // and this is the guard that keeps it from becoming a bug if
            // something does.
            //
            // Skipped when the last message is already a user turn: that is the
            // TEXT-BASED path, whose follow-up ends "Please answer based on
            // these results" — the same instruction, and two user messages in a
            // row is a shape some servers reject.
            if !includeTools, toolRoundsRun > 0, !toldSearchesAreOver,
               (messages.last?["role"] as? String) != "user" {
                messages.append(["role": "user", "content": Self.searchesExhaustedNotice])
                toldSearchesAreOver = true
            }

            // Partial text is per-turn; everything before it is ours.
            let prefix = textSoFar
            let visible = displayText
            // "Working, nothing to show yet" — from here to this turn's first
            // visible character. The UI cannot infer this: after a tool round
            // the transcript already holds text, so nothing changes on screen
            // while the follow-up request flies and its prompt prefills.
            turnIndex += 1
            let thisTurn = turnIndex
            let producedText = LockedBox<Bool>(false)
            events.onAwaitingModel(thisTurn, true)
            defer { events.onAwaitingModel(thisTurn, false) }
            let turn = try await transport.runTurn(
                messages: messages,
                includeTools: includeTools
            ) { partial in
                if !partial.isEmpty, !producedText.value {
                    producedText.value = true
                    events.onAwaitingModel(thisTurn, false)
                }
                onText(prefix + visible(partial))
            }

            // Tool round: execute, append follow-up messages, loop.
            //
            // The budget check is on the LOOP, not just on `includeTools`.
            // Withholding tools only stops teemoon *asking* — it does not stop a
            // model answering with a tool call anyway, and teemoon's own text
            // recovery will happily parse one out of raw output whether or not
            // tools were offered. Without this guard such a model loops forever,
            // executing real tool calls (real web searches) every round. Small
            // on-device models are the likeliest to do it, since there is no
            // server-side template deciding when tool syntax is even legal.
            if !turn.toolCalls.isEmpty, remainingToolRounds > 0 {
                let roundRecords = try await executeToolRound(
                    toolCalls: turn.toolCalls,
                    completionTokens: turn.completionTokens,
                    report: turn.report,
                    priorRecords: allToolRecords
                )
                allToolRecords += roundRecords.records
                appendFollowUpMessages(
                    to: &messages, assistantContent: turn.content,
                    toolCalls: turn.toolCalls, toolResults: roundRecords.results,
                    isTextBased: turn.isTextBasedToolCall
                )
                textSoFar += turn.content
                if !textSoFar.isEmpty { onText(textSoFar) }
                if turn.isTextBasedToolCall { textToolCallRoundHappened = true }
                remainingToolRounds -= 1
                toolRoundsRun += 1
                continue
            }
            if !turn.toolCalls.isEmpty {
                // Budget spent and the model is still asking. Stop here and
                // answer with what we have; the containment net below strips the
                // unexecuted call so it can't surface as visible markup.
                logger.warning("[ToolCall] round budget exhausted — model still requested \(turn.toolCalls.count) tool call(s); ending the generation")
            }

            // Finished. A self-grounding provider's answer carries its citations
            // inline; split them out so the saved text is prose and the citations
            // reach the same sources rail the web-search tool feeds.
            if groundsItsOwnAnswers {
                let (visible, sources) = BraveAnswersFormat.split(turn.content)
                textSoFar += visible
                if !sources.isEmpty { events.onSourcesFound(sources) }
            } else {
                textSoFar += turn.content
            }

            // Reasoning-model fallback: some models stream their entire visible
            // answer as reasoning — DeepSeek V4 Flash under `reasoning_content`,
            // and every *thinking* model on Ollama under `reasoning` — leaving
            // `content` empty for the whole stream. Without this the reply is
            // silently dropped: a blank message and no thread preview.
            //
            // The fallback also has to be EMITTED, not just persisted. Nothing
            // was streamed (there was no content to stream), so the UI is still
            // showing an empty answer at this point; onText is what puts the
            // text on screen. Observed live with gemma4:e2b-it-qat and
            // qwen3.5:4b, whose replies are 100% reasoning frames.
            //
            // UNLESS the turn was TRUNCATED. "The answer arrived as reasoning"
            // and "the model spiralled until it ran out of budget" both look
            // like empty content plus a full reasoning field, and only the
            // second must be withheld — its reasoning is a scratchpad cut off
            // mid-thought, not a reply.
            //
            // Measured on device: Qwen3-0.6B looping on the injected date
            // produced 3,616 characters over exactly 1024 tokens, ending
            // "...asking about the 2026 F". teemoon displayed that as the
            // assistant's answer. Showing nothing is better; showing a stated
            // failure is better still, which is what the empty reply becomes
            // once `onSuccess` sees no text.
            if textSoFar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !turn.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if turn.wasTruncated {
                    logger.warning("""
                        reasoning-only reply hit the token budget — withholding it: a truncated \
                        scratchpad is not an answer
                        """)
                } else {
                    logger.info("content empty but reasoning present — using reasoning as the reply text")
                    textSoFar = turn.reasoning
                    onText(textSoFar)
                }
            }

            // Containment net: strip any residual tool-call markup recovery didn't
            // consume (unregistered tool, no handler yet, truncated call) so it can
            // never leak into the answer. Log removals — never a silent drop.
            let (sanitizedText, removedMarkup) = SSEStreamParser.sanitizeToolMarkup(from: textSoFar)
            if !removedMarkup.isEmpty {
                logger.warning("[containment] stripped \(removedMarkup.count) residual tool-markup fragment(s) from the answer (unrecovered/unknown format): \(removedMarkup.prefix(4).joined(separator: " | "))")
            }
            let finalText = sanitizedText
            // Emit the canonical text last, so the final snapshot the UI keeps
            // is exactly what gets persisted.
            //
            // Load-bearing for on-device: `LiteRTTransport` streams RAW text so the
            // live view can render its "thinking…" block, but a local model's
            // raw stream contains `<think>` and the saved message must not.
            // Without this the last partial would win and the tags would be
            // stored. It also means any residual tool markup `sanitizeToolMarkup`
            // stripped can never survive in the visible answer.
            // Unconditional: `textSoFar` is already the clean accumulation, so
            // comparing against it would skip the emit precisely when the last
            // *partial* was the raw one — which is the case this exists for.
            onText(finalText)
            let records = allToolRecords
            let report = turn.report
            let outputTokens = turn.completionTokens
            // Await the check here so the turn's result includes it. A
            // detached Task forced ChatViewModel to poll `lastRequestDebugInfo`
            // for 8s after generate returned.
            let verification = await report.verify?()
            if let verification {
                switch verification {
                case .verified(let sig):
                    logger.info("[TEE] Signature verified — signing address: \(sig.signingAddress, privacy: .public)")
                case .unverified(.gatewayTrustOnly(let addr)):
                    logger.warning("[TEE] Accepted via gateway trust only — signer \(addr, privacy: .public) not individually attested")
                case .unverified(.signatureMismatch(let expected, let got)):
                    logger.warning("[TEE] Signature MISMATCH — expected \(expected, privacy: .public), got \(got, privacy: .public)")
                case .unverified(.contentMismatch(let detail)):
                    logger.warning("[TEE] Content binding MISMATCH — \(detail, privacy: .public)")
                case .unverified(.signatureUnavailable):
                    logger.info("[TEE] Signature not yet available")
                case .unverified(.fetchFailed(let err)):
                    logger.error("[TEE] Signature fetch failed: \(err)")
                }
            }
            events.onSuccess(RequestResult(
                url: report.url, requestHeaders: report.requestHeaders,
                requestBodyJSON: report.requestBodyJSON,
                sealedBodyJSON: report.sealedBodyJSON,
                responseBody: finalText.isEmpty ? nil : finalText,
                // Plus anything the transport ran on its own behalf — see
                // `TurnReport.executedToolCalls`.
                toolCalls: records + report.executedToolCalls,
                outputTokens: outputTokens,
                promptBudget: report.promptBudget,
                firstTokenAt: report.firstTokenAt,
                firstVisibleTokenAt: report.firstVisibleTokenAt,
                teeVerification: verification,
                isE2EEActive: report.isE2EEActive
            ))
            return
        }
    }

    // MARK: - Tool execution

    private func executeToolRound(
        toolCalls: [Int: ToolCallState],
        completionTokens: Int?,
        report: TurnReport,
        priorRecords: [ToolCallRecord]
    ) async throws -> (records: [ToolCallRecord], results: [(id: String, content: String)]) {
        logger.debug("[ToolCall] executing \(toolCalls.count) tool call(s)")
        let sortedIndices = toolCalls.keys.sorted()

        let queries: [String] = sortedIndices.compactMap { idx in
            guard let tc = toolCalls[idx] else { return nil }
            let normalized = Self.normalizeToolArgsJSON(tc.arguments)
            guard let data = normalized.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = json["query"] as? String
            else { return nil }
            return query
        }
        events.onQueriesFound(queries)

        var resultMap: [Int: (id: String, content: String)] = [:]
        do {
            try await withThrowingTaskGroup(of: (Int, String, String).self) { group in
                for idx in sortedIndices {
                    let tc = toolCalls[idx]!
                    logger.debug("[ToolCall] '\(tc.name)' args=\(tc.arguments)")
                    group.addTask {
                        let result = try await self.executeToolCall(name: tc.name, argsJSON: tc.arguments)
                        return (idx, tc.id, result)
                    }
                }
                for try await (idx, id, result) in group {
                    resultMap[idx] = (id: id, content: result)
                }
            }
        } catch {
            events.onToolExecutionEnded()
            throw error
        }
        let results = sortedIndices.compactMap { resultMap[$0] }

        let roundRecords: [ToolCallRecord] = sortedIndices.compactMap { idx in
            guard let tc = toolCalls[idx], let r = resultMap[idx] else { return nil }
            return ToolCallRecord(name: tc.name, arguments: tc.arguments, result: r.content)
        }

        // Publish intermediate debug info so the developer panel shows the
        // tool round even if a later round fails.
        let allRecords = priorRecords + roundRecords
        if !allRecords.isEmpty {
            events.onSuccess(RequestResult(
                url: report.url, requestHeaders: report.requestHeaders,
                requestBodyJSON: report.requestBodyJSON,
                sealedBodyJSON: report.sealedBodyJSON, responseBody: nil,
                toolCalls: allRecords, outputTokens: completionTokens,
                promptBudget: report.promptBudget,
                teeVerification: nil, isE2EEActive: report.isE2EEActive
            ))
        }

        let sources = results.flatMap { BraveWebSearchTool.parseSources(from: $0.content) }
        if !sources.isEmpty { events.onSourcesFound(sources) }
        events.onToolExecutionEnded()
        return (roundRecords, results)
    }

    private func executeToolCall(name: String, argsJSON: String) async throws -> String {
        guard let tool = tools.first(where: { $0.name == name }) else {
            return "[Tool '\(name)' not found]"
        }
        return try await executeTool(tool, argumentsJSON: Self.normalizeToolArgsJSON(argsJSON))
    }

    private func executeTool(_ tool: some Tool, argumentsJSON: String) async throws -> String {
        // Some models (notably GLM on near.ai) emit numeric/boolean arguments as
        // JSON strings — e.g. {"count": "15"} instead of {"count": 15}. Strict
        // @Generable decoding then throws `typeMismatch`. Coerce string scalars
        // back to the types declared in the tool's schema first. The reference
        // is `tool.parameters` — the exact schema we sent the model — so there is
        // a single source of truth for argument types.
        let coercedJSON = Self.toolSchemaJSON(tool)
            .map { Self.coerceArgsToSchema(argumentsJSON, schema: $0) } ?? argumentsJSON
        guard let content = try? GeneratedContent(json: coercedJSON) else {
            return "[Failed to parse tool arguments JSON]"
        }
        do {
            let args = try type(of: tool).Arguments(content)
            let output = try await tool.call(arguments: args)
            if let str = output as? String { return str }
            return output.promptRepresentation.description
        } catch let error as LLMError {
            if let status = error.httpStatus, status == 401 || status == 402 || status == 403 {
                throw error
            }
            return "[web_search error: \(error.userMessage) Try rephrasing the query or omitting the freshness filter.]"
        } catch {
            return "[Tool call failed: \(error)]"
        }
    }

    /// Models sometimes wrap real arguments in {"parameters": "<json string>"} — unwrap.
    private static func normalizeToolArgsJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parametersStr = obj["parameters"] as? String,
              let innerData = parametersStr.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
              let normalized = try? JSONSerialization.data(withJSONObject: inner),
              let normalizedStr = String(data: normalized, encoding: .utf8)
        else { return json }
        return normalizedStr
    }

    // MARK: - Tool schemas

    /// The tool's argument schema as a plain JSON dictionary — the same
    /// `@Generable`-derived schema teemoon sends the model in the request.
    /// Used as the type reference for `coerceArgsToSchema`.
    static func toolSchemaJSON(_ tool: some Tool) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(tool.parameters) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Inlines the `$ref`/`$defs` indirection the `@Generable` macro emits into a plain,
    /// self-contained JSON Schema for the wire. The raw form is
    /// `{"$defs": {"Name": {…}}, "$ref": "#/$defs/Name"}`; a small model (or the server's
    /// prompt template) can't resolve a top-level `$ref` rendered into the prompt, so it
    /// can't see the real parameters and hallucinates the argument shape — verified: with
    /// the `$ref` form gemma4:e2b emits `{"queries": [...]}` 5/5 at temp 0; flattened, it
    /// emits the declared `{"query": "..."}` 5/5. Cloud/vLLM servers tolerate `$ref`, so
    /// this is a net-safe normalization: flat is more broadly compatible for everyone.
    ///
    /// On-device this matters more, not less: there is no server-side template to
    /// paper over it, and every model small enough to run on a phone is in exactly
    /// the size class that gets this wrong.
    static func flattenedToolSchema(_ tool: some Tool) -> [String: Any] {
        guard let raw = toolSchemaJSON(tool) else { return ["type": "object"] }
        let defs = raw["$defs"] as? [String: Any] ?? [:]
        return inlineRefs(raw, defs: defs)
    }

    /// Resolves a node's `$ref` against `defs`, drops `$ref`/`$defs`, and recurses into
    /// `properties` and array `items` so nested references are inlined too.
    private static func inlineRefs(_ node: [String: Any], defs: [String: Any]) -> [String: Any] {
        var schema = resolveRef(node, defs: defs)
        schema.removeValue(forKey: "$ref")
        schema.removeValue(forKey: "$defs")
        if let props = schema["properties"] as? [String: Any] {
            schema["properties"] = props.mapValues { v in
                (v as? [String: Any]).map { inlineRefs($0, defs: defs) } ?? v
            }
        }
        if let items = schema["items"] as? [String: Any] {
            schema["items"] = inlineRefs(items, defs: defs)
        }
        return schema
    }

    /// Coerces string-encoded scalar arguments to the types declared in the
    /// tool's schema, tolerating models that emit numbers/booleans as strings
    /// (`"count": "15"` → `"count": 15`). Recurses into object properties and
    /// array items, resolving `$ref`/`$defs` indirection in the `@Generable`
    /// schema. Unresolvable refs and unparseable values are left untouched, and
    /// the input is returned unchanged if it isn't valid JSON.
    static func coerceArgsToSchema(_ json: String, schema: [String: Any]) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return json }
        let defs = schema["$defs"] as? [String: Any] ?? [:]
        let out = coerceValue(obj, schema: schema, defs: defs)
        guard let outData = try? JSONSerialization.data(withJSONObject: out),
              let str = String(data: outData, encoding: .utf8) else { return json }
        return str
    }

    /// Resolves a `{"$ref": "#/$defs/Name"}` node against `defs`; returns the
    /// schema unchanged when there is no ref or the target is missing.
    private static func resolveRef(_ schema: [String: Any], defs: [String: Any]) -> [String: Any] {
        guard let ref = schema["$ref"] as? String,
              let name = ref.components(separatedBy: "/").last,
              let resolved = defs[name] as? [String: Any] else { return schema }
        return resolved
    }

    private static func coerceValue(_ value: Any, schema rawSchema: [String: Any], defs: [String: Any]) -> Any {
        let schema = resolveRef(rawSchema, defs: defs)
        switch schema["type"] as? String {
        case "object":
            guard var dict = value as? [String: Any],
                  let props = schema["properties"] as? [String: Any] else { return value }
            for (key, propSchemaAny) in props {
                guard let v = dict[key], let propSchema = propSchemaAny as? [String: Any]
                else { continue }
                dict[key] = coerceValue(v, schema: propSchema, defs: defs)
            }
            return dict
        case "array":
            guard let arr = value as? [Any],
                  let itemSchema = schema["items"] as? [String: Any] else { return value }
            return arr.map { coerceValue($0, schema: itemSchema, defs: defs) }
        case "integer":
            guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces) else { return value }
            if let i = Int(s) { return i }
            // Some models emit whole numbers with a decimal point ("20.0"); accept
            // when finite, integral, and representable as Int. Out-of-range values
            // (e.g. Int.max + 1) fall through and decode fails loudly, unchanged.
            if let d = Double(s), d.isFinite, d.rounded(.towardZero) == d,
               d >= -9_223_372_036_854_775_808.0, d < 9_223_372_036_854_775_808.0 {
                return Int(d)
            }
            return value
        case "number":
            // The `.isFinite` guard is load-bearing: "NaN"/"inf"/"-Infinity" all
            // parse via Double(), but a non-finite number crashes
            // JSONSerialization with an ObjC exception `try?` cannot catch.
            if let s = value as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)),
               d.isFinite {
                return d
            }
            return value
        case "boolean":
            if let s = value as? String {
                switch s.trimmingCharacters(in: .whitespaces).lowercased() {
                case "true":  return true
                case "false": return false
                default:      return value
                }
            }
            return value
        default:
            return value
        }
    }

    // MARK: - Follow-up construction

    private func appendFollowUpMessages(
        to messages: inout [[String: Any]],
        assistantContent: String,
        toolCalls: [Int: ToolCallState],
        toolResults: [(id: String, content: String)],
        isTextBased: Bool
    ) {
        if isTextBased {
            if !assistantContent.isEmpty {
                messages.append(["role": "assistant", "content": assistantContent])
            }
            let combined = toolResults.map { $0.content }.joined(separator: "\n\n---\n\n")
            messages.append(["role": "user",
                             "content": "Search results:\n\n\(combined)\n\nPlease answer based on these results."])
        } else {
            let openAIToolCalls: [[String: Any]] = toolCalls.keys.sorted().map { idx in
                let tc = toolCalls[idx]!
                return ["id": tc.id, "type": "function",
                        "function": ["name": tc.name, "arguments": tc.arguments]]
            }
            messages.append(["role": "assistant", "content": assistantContent,
                             "tool_calls": openAIToolCalls])
            for r in toolResults {
                messages.append(["role": "tool", "tool_call_id": r.id, "content": r.content])
            }
        }
    }
}
