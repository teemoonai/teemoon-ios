//
//  HTTPTransport.swift
//  teemoon
//
//  The remote transport: one OpenAI-compatible chat/completions round-trip.
//
//  Per turn, in order:
//    1. wire-format request construction (messages, tools, extraParams)
//    2. auth (Bearer or provider-specific header)
//    3. optional field-level E2EE sealing (E2EEPeer/E2EEStreamCodec)
//    4. one plain URLSession request; SSE parsing via SSEStreamParser (with
//       E2EE decryption — decrypt failures FAIL the stream, they are never
//       rendered as message content), or direct JSON handling when the server
//       responds non-streaming
//    5. a `verify` closure that will check the TEE response signature
//
//  Everything past that — executing tool calls, chaining rounds, coercing
//  arguments — is `GenerationEngine`, shared with on-device inference.
//
//  This file is the extracted transport half of what used to be one
//  GenerationEngine. Behaviour is unchanged; the seam is new.
//

import Foundation
import ModelBackend
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "inference")

/// Streams chat completions from an OpenAI-compatible HTTP endpoint.
struct HTTPTransport: GenerationTransport {
    let provider: Provider
    let apiKey: String
    let teeContext: TEEContext?
    let tools: [any Tool]
    let urlSession: URLSession

    init(
        provider: Provider,
        apiKey: String,
        teeContext: TEEContext?,
        tools: [any Tool],
        urlSession: URLSession
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.teeContext = teeContext
        self.tools = tools
        self.urlSession = urlSession
    }

    // MARK: - GenerationTransport

    func runTurn(
        messages: [[String: Any]],
        includeTools: Bool,
        onPartialContent: @escaping @Sendable (String) -> Void
    ) async throws -> TurnOutput {
        guard let baseURL = provider.openAIBaseURL else {
            throw LLMError(
                source: .provider(name: provider.name),
                userMessage: "Invalid endpoint URL: \(provider.endpoint)",
                httpStatus: nil, url: nil, requestHeaders: nil, requestBodyJSON: nil,
                messageHistory: nil, responseBody: nil, underlyingError: nil
            )
        }
        let endpoint = baseURL.appendingPathComponent("chat/completions")
        let codec = teeContext?.e2eePeer.map { E2EEStreamCodec(peer: $0) }

        // 1. Wire-format request body (plaintext).
        let plaintextBody = try makeBody(messages: messages, includeTools: includeTools)

        // 2. Auth.
        var request = URLRequest(url: endpoint, timeoutInterval: 240)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let headerName = provider.authHeaderName {
            if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: headerName) }
        } else if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // 3. E2EE sealing. `codec != nil` means THIS turn promised sealing
        // (attested provider with an established E2EE peer), so a sealing
        // failure must fail CLOSED: throw before anything touches the wire.
        // This used to `try?` the encryption and fall through to sending
        // `plaintextBody` — cleartext to the provider under an E2EE promise.
        // The plaintext path below exists ONLY for `codec == nil`
        // (non-attested providers, which must keep sending normally).
        var isE2EEActive = false
        var bodyToSend = plaintextBody
        if let codec {
            bodyToSend = try e2eeSealedBody(plaintextBody, codec: codec,
                                            endpoint: endpoint, request: &request)
            isE2EEActive = true
        }
        request.httpBody = bodyToSend

        // 4. One plain request.
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let requestHeaders = request.allHTTPHeaderFields ?? [:]
        let prettyBody = String(data: plaintextBody, encoding: .utf8).map { prettyPrintedJSON($0) }
        // What ACTUALLY went out. Only meaningful when sealing changed the
        // bytes — `bodyToSend` is `plaintextBody` when E2EE is off, and showing
        // the same text twice under two different labels would be worse than
        // showing it once.
        let sealedBody = isE2EEActive
            ? String(data: bodyToSend, encoding: .utf8).map { prettyPrintedJSON($0) }
            : nil

        if http.statusCode >= 400 {
            var drainer = ErrorDrainer(
                status: http.statusCode, providerName: provider.name,
                requestURL: endpoint, requestHeaders: requestHeaders, requestBody: plaintextBody
            )
            var errorBody = Data()
            for try await byte in bytes { errorBody.append(byte) }
            drainer.append(errorBody)
            throw drainer.makeLLMError(underlyingError: nil)
        }

        let parser = SSEStreamParser(hasTools: !tools.isEmpty,
                                     tools: tools.map(GenerationEngine.recoverySpec))
        // The decrypt hook is a non-throwing closure fed to SSEStreamParser;
        // failure is reported through the box and thrown by the loop.
        let decryptFailure = LockedBox<Bool>(false)
        let decrypt: ((String) -> String?)? = (isE2EEActive ? codec : nil).map { codec in
            { ciphertext in
                let plaintext = codec.decryptField(ciphertext)
                if plaintext == nil { decryptFailure.value = true }
                return plaintext
            }
        }

        let isSSE = (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream")
        var toolCallRoundDetected = false

        #if DEBUG
        // -scrollTrace only: stamp each SSE event as it ARRIVES, so the wire's
        // own cadence can be read against what was forwarded for display.
        let wireTurn = WireTrace.nextTurn()
        WireTrace.event(turn: wireTurn, "requestSent sse=\(isSSE ? 1 : 0)")
        #endif

        // Raw response text for signature content binding: near.ai signs
        // sha256 over the response lines re-joined with "\n" (streaming)
        // or the whole raw body (non-streaming), so it must be captured
        // exactly as received — including blank SSE separator lines,
        // which `bytes.lines` would drop.
        var rawResponseText = ""

        if isSSE {
            // Manual line assembly (split on \n, strip trailing \r):
            // preserves blank lines for `rawResponseText` while feeding
            // the parser the same non-empty lines `bytes.lines` yielded.
            var lineBuffer = [UInt8]()
            func processLine() throws {
                if lineBuffer.last == 0x0D { lineBuffer.removeLast() }
                let line = String(decoding: lineBuffer, as: UTF8.self)
                lineBuffer.removeAll(keepingCapacity: true)
                rawResponseText += line + "\n"
                guard !line.isEmpty else { return }
                let (_, detected) = parser.consume(Data((line + "\n\n").utf8), decrypt: decrypt)
                if decryptFailure.value {
                    throw decryptionFailedError(endpoint: endpoint, headers: requestHeaders, body: prettyBody)
                }
                if detected { toolCallRoundDetected = true }
                #if DEBUG
                WireTrace.record(turn: wireTurn,
                                 raw: parser.accumulatedContent.count,
                                 visible: parser.visibleContent.count,
                                 reasoning: parser.accumulatedReasoning.count)
                #endif
                // `visibleContent`, not `accumulatedContent`: the parser elides
                // tool-call markup regions as they stream, so this is safe to
                // show mid-region — and prose AFTER a closed tool call keeps
                // streaming instead of arriving in one batch at end of turn
                // (the old sticky-suppression defect, StreamSuppressionTests).
                if parser.toolCallStates.isEmpty && !parser.visibleContent.isEmpty {
                    onPartialContent(parser.visibleContent)
                }
            }
            for try await byte in bytes {
                if byte == 0x0A {
                    try processLine()
                    // Stop after the [DONE] *event*, not the [DONE] line.
                    // An SSE event is `data: [DONE]\n\n` — the trailing blank
                    // line is in the signed payload (see
                    // Fixtures/nearai_signed_response.json). Breaking on the
                    // data line dropped that "\n" and failed content binding
                    // on live streams (the "reply didn't check out" caption).
                    // A keep-alive server never closes; once the terminator
                    // is in `rawResponseText` we can leave.
                    if parser.sawDone, rawResponseText.hasSuffix("\n\n") { break }
                } else {
                    lineBuffer.append(byte)
                }
            }
            if !parser.sawDone, !lineBuffer.isEmpty { try processLine() }
            // Stream closed right after `data: [DONE]\n` with no terminator.
            // The signed form still includes the event's blank line.
            if parser.sawDone, !rawResponseText.hasSuffix("\n\n") {
                rawResponseText += "\n"
            }
            // Stream ended without [DONE]: give the parser a chance to
            // resolve buffered text-based tool calls.
            if !toolCallRoundDetected {
                let (_, detected) = parser.consume(Data("data: [DONE]\n\n".utf8), decrypt: decrypt)
                if detected { toolCallRoundDetected = true }
            }
        } else {
            // Non-streaming JSON (E2EE servers force stream=false; also any
            // provider that ignores the stream flag).
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            rawResponseText = String(decoding: data, as: UTF8.self)
            let detected = try consumeNonStreamingResponse(
                data, into: parser, decrypt: decrypt, decryptFailure: decryptFailure,
                endpoint: endpoint, headers: requestHeaders, body: prettyBody
            )
            if detected { toolCallRoundDetected = true }
            if !detected {
                onPartialContent(parser.accumulatedContent)
            }
        }

        #if DEBUG
        WireTrace.event(turn: wireTurn,
                        "turnEnd raw=\(parser.accumulatedContent.count) "
                        + "vis=\(parser.visibleContent.count) "
                        + "reas=\(parser.accumulatedReasoning.count) "
                        + "toolRound=\(toolCallRoundDetected ? 1 : 0)")
        #endif

        // 5. Package the turn. Tool markup is stripped here (parser knowledge);
        // the engine sees only clean text.
        let isTextBased = parser.isTextBasedToolCall
        let content: String
        if toolCallRoundDetected && isTextBased {
            content = SSEStreamParser.stripTextToolCalls(from: parser.accumulatedContent)
        } else {
            content = parser.accumulatedContent
        }

        // The signature covers this round's request/response pair. Under E2EE
        // the signer may hash either the wire (encrypted) or plaintext request
        // body — offer both candidates.
        let exchange = SignedExchange(
            requestBodyCandidates: bodyToSend == plaintextBody ? [bodyToSend] : [bodyToSend, plaintextBody],
            responseText: rawResponseText
        )
        // Input-token accounting. Skipped under E2EE, where the sent-size
        // estimate would be measuring ciphertext.
        let promptBudget: PromptBudget? = {
            guard !isE2EEActive, let evaluated = parser.promptTokens else { return nil }
            return PromptBudget(
                sentEstimate: PromptBudget.estimateSentTokens(messages: messages),
                evaluated: evaluated
            )
        }()
        if let promptBudget, promptBudget.looksTruncated {
            logger.warning("""
                [context] \(provider.name, privacy: .public) evaluated only \
                \(promptBudget.evaluated) input tokens of an estimated \
                \(promptBudget.sentEstimate) — the server is discarding the front of \
                the prompt (system prompt and question go first). Raise its context \
                window; for Ollama that is OLLAMA_CONTEXT_LENGTH.
                """)
        }

        let chatID = parser.chatCompletionID
        let ctx = teeContext
        let verify: (@Sendable () async -> ResponseVerification?)? = {
            guard let ctx else {
                logger.debug("[TEE] verification skipped — no attestation context")
                return nil
            }
            guard let chatID else {
                logger.debug("[TEE] verification skipped — no chat ID in response")
                return nil
            }
            return { await TEESignatureVerifier.verify(chatID: chatID, ctx: ctx, exchange: exchange) }
        }()

        return TurnOutput(
            content: content,
            reasoning: parser.accumulatedReasoning,
            toolCalls: toolCallRoundDetected ? parser.toolCallStates : [:],
            isTextBasedToolCall: toolCallRoundDetected && isTextBased,
            completionTokens: parser.completionTokens,
            report: TurnReport(
                url: endpoint,
                requestHeaders: requestHeaders,
                requestBodyJSON: prettyBody,
                sealedBodyJSON: sealedBody,
                isE2EEActive: isE2EEActive,
                firstTokenAt: parser.firstDeltaAt,
                firstVisibleTokenAt: parser.firstVisibleAt,
                promptBudget: promptBudget,
                verify: verify
            )
        )
    }

    // MARK: - Request construction

    private func makeBody(messages: [[String: Any]], includeTools: Bool) throws -> Data {
        var body: [String: Any] = [
            "model": provider.model,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if includeTools {
            body["tools"] = tools.map { tool -> [String: Any] in
                return ["type": "function",
                        "function": ["name": tool.name,
                                     "description": tool.description,
                                     "parameters": GenerationEngine.flattenedToolSchema(tool)] as [String: Any]]
            }
        }
        // Provider extras, auto-coerced: "true"/"false" → Bool, numbers → Double, else String.
        for (key, value) in provider.extraParams {
            switch value {
            case "true":  body[key] = true
            case "false": body[key] = false
            default:      body[key] = Double(value) ?? value
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Non-streaming responses

    /// Feeds a complete (non-SSE) chat-completion JSON into the parser state
    /// so the finish path is identical to streaming. Returns whether a
    /// tool-call round was detected.
    private func consumeNonStreamingResponse(
        _ data: Data, into parser: SSEStreamParser,
        decrypt: ((String) -> String?)?, decryptFailure: LockedBox<Bool>,
        endpoint: URL, headers: [String: String], body: String?
    ) throws -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first else {
            throw LLMError(
                source: .provider(name: provider.name),
                userMessage: "\(provider.name) returned an unreadable response.",
                httpStatus: nil, url: endpoint, requestHeaders: headers,
                requestBodyJSON: body, messageHistory: nil,
                responseBody: String(data: data, encoding: .utf8), underlyingError: nil
            )
        }
        if let id = json["id"] as? String, !id.isEmpty { parser.chatCompletionID = id }
        if let usage = json["usage"] as? [String: Any],
           let tokens = usage["completion_tokens"] as? Int {
            parser.completionTokens = tokens
        }

        let message = choice["message"] as? [String: Any] ?? [:]
        // Thinking tokens, under whichever key this server uses — the same
        // reasoning-only fallback has to work when the server ignores `stream`.
        if let (_, reasoning) = SSEStreamParser.reasoningChunk(in: message) {
            parser.accumulatedReasoning = decrypt.flatMap { $0(reasoning) } ?? reasoning
        }
        if let content = message["content"] as? String, !content.isEmpty {
            if let decrypt {
                if let plaintext = decrypt(content) {
                    parser.accumulatedContent = plaintext
                } else {
                    throw decryptionFailedError(endpoint: endpoint, headers: headers, body: body)
                }
            } else {
                parser.accumulatedContent = content
            }
        }

        if choice["finish_reason"] as? String == "tool_calls",
           let tcArray = message["tool_calls"] as? [[String: Any]] {
            for (fallbackIdx, tc) in tcArray.enumerated() {
                guard let fn = tc["function"] as? [String: Any] else { continue }
                var state = ToolCallState()
                let idx = tc["index"] as? Int ?? fallbackIdx
                state.id = tc["id"] as? String ?? "tool_\(idx)"
                let rawName = fn["name"] as? String ?? ""
                let rawArgs = fn["arguments"] as? String ?? "{}"
                if let decrypt {
                    state.name = decrypt(rawName) ?? rawName
                    state.arguments = decrypt(rawArgs) ?? rawArgs
                    if decryptFailure.value {
                        throw decryptionFailedError(endpoint: endpoint, headers: headers, body: body)
                    }
                } else {
                    state.name = rawName
                    state.arguments = rawArgs
                }
                let key = (parser.toolCallStates.keys.max() ?? -1) + 1
                parser.toolCallStates[key] = state
            }
            return !parser.toolCallStates.isEmpty
        }
        return false
    }

    // MARK: - E2EE sealing (fail-closed)

    /// Seals one request body for an E2EE turn, adding the codec's headers to
    /// `request`. Both failure modes — encryption THROWING, and
    /// `encryptedBodyIfChanged` returning nil because the body came back
    /// unchanged (a parse failure inside `encryptRequestBody`) — become a
    /// thrown `LLMError`, so a caller can never fall back to sending the
    /// plaintext body under an E2EE promise. Internal (not private) so the
    /// regression tests can drive each mode directly.
    func e2eeSealedBody(_ plaintextBody: Data, codec: E2EEStreamCodec,
                        endpoint: URL, request: inout URLRequest) throws -> Data {
        let sealed: Data?
        do {
            sealed = try codec.encryptedBodyIfChanged(plaintextBody)
        } catch {
            // Mode 1: encryption itself threw (bad key, RNG failure, …).
            logger.error("[E2EE] encryption threw — request NOT sent: \(error)")
            throw encryptionFailedError(endpoint: endpoint,
                                        headers: request.allHTTPHeaderFields ?? [:],
                                        plaintextBody: plaintextBody)
        }
        guard let sealed else {
            // Mode 2: the body came back byte-identical — nothing was sealed.
            logger.error("[E2EE] encryption returned unchanged body — request NOT sent")
            throw encryptionFailedError(endpoint: endpoint,
                                        headers: request.allHTTPHeaderFields ?? [:],
                                        plaintextBody: plaintextBody)
        }
        for (k, v) in codec.headers { request.setValue(v, forHTTPHeaderField: k) }
        return sealed
    }

    // MARK: - Errors

    private func encryptionFailedError(endpoint: URL, headers: [String: String], plaintextBody: Data) -> LLMError {
        LLMError(
            source: .provider(name: provider.name),
            userMessage: "The request could not be encrypted, so it was not sent. Try again — if this keeps happening, re-verify the connection from the lock icon.",
            httpStatus: nil, url: endpoint, requestHeaders: headers,
            requestBodyJSON: String(data: plaintextBody, encoding: .utf8).map { prettyPrintedJSON($0) },
            messageHistory: nil, responseBody: nil,
            underlyingError: E2EEError.encryptionFailed
        )
    }

    private func decryptionFailedError(endpoint: URL, headers: [String: String], body: String?) -> LLMError {
        LLMError(
            source: .provider(name: provider.name),
            userMessage: "The encrypted response could not be decrypted, so it was not displayed. Try again — if this keeps happening, re-verify the connection from the lock icon.",
            httpStatus: nil, url: endpoint, requestHeaders: headers,
            requestBodyJSON: body, messageHistory: nil, responseBody: nil,
            underlyingError: E2EEError.decryptionFailed
        )
    }
}
