//
//  ChatGeneration+Stream.swift
//  teemoon
//
//  How the engine talks back to observable state, which LanguageModel
//  this turn runs, and how an empty reply becomes a stated failure.
//  Kept off ChatGeneration.swift so generate is the loop, not also
//  the wiring.
//

import Foundation
import ModelBackend

extension ChatGeneration {

    func makeStreamCallbacks(
        providerName: String,
        modelID: String,
        threadID: UUID,
        toolCallsBag: LockedBox<[ToolCallRecord]>,
        resultBag: LockedBox<RequestResult?>
    ) -> StreamCallbacks {
        let origin = turnOrigin
        return StreamCallbacks(
            onSourcesFound: { [weak self] sources in
                Task { @MainActor [weak self] in
                    self?.groundingSources.append(contentsOf: sources)
                    #if DEBUG
                    StreamTrace.event("sourcesFound count=\(sources.count) total=\(self?.groundingSources.count ?? 0)")
                    #endif
                }
            },
            onQueriesFound: { [weak self] queries in
                Task { @MainActor [weak self] in
                    self?.searchQueries.append(contentsOf: queries)
                    self?.isExecutingTools = true
                    #if DEBUG
                    StreamTrace.event("toolExecStart queries=\(queries.count)")
                    #endif
                }
            },
            onToolExecutionEnded: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.isExecutingTools = false
                    #if DEBUG
                    StreamTrace.event("toolExecEnd")
                    #endif
                }
            },
            onSuccess: { [weak self] result in
                toolCallsBag.value = result.toolCalls
                resultBag.value = result
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let preservedResponse = result.responseBody ?? self.lastRequestDebugInfo?.responseBody
                    // Thinking = first delta → first visible character, both stamped by
                    // the parser at the one place every delta passes.
                    let thought: TimeInterval? = {
                        guard let first = result.firstTokenAt,
                              let visible = result.firstVisibleTokenAt else { return nil }
                        let gap = visible.timeIntervalSince(first)
                        return gap > 0.05 ? gap : nil     // below that it is jitter
                    }()
                    self.lastRequestDebugInfo = LastRequestDebugInfo(
                        providerName: providerName,
                        modelID: modelID,
                        url: result.url,
                        requestHeaders: result.requestHeaders,
                        requestBodyJSON: result.requestBodyJSON,
                        sealedBodyJSON: result.sealedBodyJSON,
                        responseBody: preservedResponse,
                        toolCalls: result.toolCalls,
                        threadID: threadID,
                        totalDuration: self.lastRequestDebugInfo?.totalDuration,
                        timeToFirstToken: self.lastRequestDebugInfo?.timeToFirstToken,
                        thinkingTime: thought ?? self.lastRequestDebugInfo?.thinkingTime,
                        outputTokens: result.outputTokens ?? self.lastRequestDebugInfo?.outputTokens,
                        engineTimings: result.engineTimings,
                        onDeviceRun: result.onDeviceRun,
                        promptBudget: result.promptBudget ?? self.lastRequestDebugInfo?.promptBudget,
                        isE2EEActive: result.isE2EEActive,
                        teeVerification: result.teeVerification ?? self.lastRequestDebugInfo?.teeVerification,
                        effortLevels: result.effortLevels.isEmpty
                            ? (self.lastRequestDebugInfo?.effortLevels ?? []) : result.effortLevels
                    )
                }
            },
            onAwaitingModel: { [weak self] turn, awaiting in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if awaiting {
                        // Never step backwards onto an older turn.
                        if (self.awaitingTurn ?? Int.min) < turn { self.awaitingTurn = turn }
                    } else if self.awaitingTurn == turn {
                        self.awaitingTurn = nil
                    }
                    #if DEBUG
                    StreamTrace.event("awaitingModel turn=\(turn) awaiting=\(awaiting ? 1 : 0)")
                    #endif
                }
            },
            onAwaitingResponse: { [weak self] turn, sentAt in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let sentAt {
                        if (self.providerWait?.turn ?? Int.min) < turn {
                            self.providerWait = ProviderWait(turn: turn, sentAt: sentAt, providerName: providerName)
                        }
                    } else if self.providerWait?.turn == turn {
                        self.providerWait = nil
                    }
                }
            },
            onVerified: { [weak self] verification in
                Task { @MainActor [weak self] in
                    self?.applyLateVerification(verification, threadID: threadID, origin: origin)
                }
            }
        )
    }

    /// The reply-signature verdict, after the turn closed. Only the card of the
    /// same send takes it; the session's counters always do.
    func applyLateVerification(_ verification: ResponseVerification, threadID: UUID, origin: Date?) {
        if var info = lastRequestDebugInfo, info.threadID == threadID, turnOrigin == origin {
            info.teeVerification = verification
            if let origin { info.phases?.append(.verified, at: Date(), origin: origin) }
            lastRequestDebugInfo = info
        }
        onReplyVerified?(verification)
    }

    /// Local, remote, or the test hook. nil when the on-device weights
    /// are not downloaded — `lastError` is already set.
    func resolveLanguageModel(
        provider: Provider,
        apiKey: String,
        priorMessages: [WireMessage],
        teeContext: TEEContext?,
        callbacks: StreamCallbacks,
        threadID: UUID,
        effort: ReasoningEffort? = nil
    ) -> (any LanguageModel)? {
        if let makeLanguageModel {
            return makeLanguageModel(provider, apiKey, priorMessages, teeContext, callbacks)
        }
        if let localModelID = provider.localModelID {
            guard let ref = LocalModelStorage.ref(for: localModelID) else {
                lastError = LLMError(
                    source: .provider(name: provider.name),
                    userMessage: "\(provider.name) isn't downloaded on this device. Open Settings → Providers to download it.",
                    httpStatus: nil, url: nil, requestHeaders: nil, requestBodyJSON: nil,
                    messageHistory: nil, responseBody: nil, underlyingError: nil
                )
                lastErrorThreadID = threadID
                return nil
            }
            return LocalLanguageModel(
                model: ref, priorMessages: priorMessages, events: callbacks,
                enableThinking: effort == .thinkHarder
            )
        }
        return ConfidentialLanguageModel(
            provider: provider, apiKey: apiKey, priorMessages: priorMessages,
            context: teeContext, events: callbacks, effort: effort,
            affinityID: SessionAffinity.id(for: threadID)
        )
    }

    /// Placeholder so the developer-mode card appears before the first delta.
    func seedDebugInfo(
        providerName: String,
        modelID: String,
        url: URL?,
        threadID: UUID,
        expectingE2EE: Bool
    ) {
        lastRequestDebugInfo = LastRequestDebugInfo(
            providerName: providerName,
            modelID: modelID,
            url: url,
            requestHeaders: nil,
            requestBodyJSON: nil,
            responseBody: nil,
            toolCalls: [],
            threadID: threadID,
            totalDuration: nil,
            timeToFirstToken: nil,
            outputTokens: nil,
            isE2EEActive: expectingE2EE,
            teeVerification: nil
        )
    }

    /// Timings, tool records, and the empty-reply error. An empty reply
    /// with no error is invisible — `ChatViewModel` will not persist a
    /// blank assistant message, and with `lastError` nil there is no
    /// banner either.
    func finishGeneration(
        provider: Provider,
        baseURL: URL?,
        threadID: UUID,
        toolCallsBag: LockedBox<[ToolCallRecord]>,
        resultBag: LockedBox<RequestResult?>
    ) {
        if lastError == nil, let existing = lastRequestDebugInfo {
            let total = startTime.map { Date().timeIntervalSince($0) }
            let ttft = firstTokenTime.flatMap { ft in startTime.map { ft.timeIntervalSince($0) } }
            let finalToolCalls = toolCallsBag.value
            let landed = resultBag.value
            lastRequestDebugInfo = LastRequestDebugInfo(
                providerName: existing.providerName,
                modelID: existing.modelID,
                url: existing.url,
                requestHeaders: existing.requestHeaders,
                requestBodyJSON: existing.requestBodyJSON,
                // Carry every field: a dropped one defaults to nil silently.
                sealedBodyJSON: existing.sealedBodyJSON,
                responseBody: output.isEmpty ? nil : output,
                toolCalls: finalToolCalls.isEmpty ? existing.toolCalls : finalToolCalls,
                threadID: existing.threadID,
                totalDuration: total,
                timeToFirstToken: ttft,
                thinkingTime: existing.thinkingTime,
                outputTokens: existing.outputTokens ?? (output.isEmpty ? nil : output.count / 4),
                engineTimings: existing.engineTimings,
                onDeviceRun: existing.onDeviceRun,
                promptBudget: existing.promptBudget,
                phases: turnOrigin.map { origin in
                    var phases = TurnPhases(origin: origin,
                               events: (gateEndedAt.map { [PhaseEvent(kind: .gate, at: $0)] } ?? []) + (landed?.phaseEvents ?? []),
                               promptTokens: landed?.promptTokens, cachedTokens: landed?.cachedTokens)
                    phases.firstMessage = turnIsFirstMessage
                    phases.cacheReporting = TurnPhases.cacheReporting(
                        host: existing.url?.host, onDevice: existing.onDeviceRun != nil,
                        isE2EE: landed?.isE2EEActive ?? existing.isE2EEActive)
                    return phases
                },
                isE2EEActive: landed?.isE2EEActive ?? existing.isE2EEActive,
                teeVerification: landed?.teeVerification ?? existing.teeVerification,
                effortLevels: existing.effortLevels
            )
        }
        // NEVER FAIL SILENTLY.
        //
        // Observed on GLM-5.1 via near.ai: four rounds of real web searches, then
        // one more tool call instead of an answer, which recovery parsed, the
        // round-budget guard dropped and containment stripped to "". Six searches
        // billed, 44 sources fetched, nothing shown. `searchesExhaustedNotice`
        // makes that rare; it cannot make it impossible, because the model is
        // free to ignore it and a provider can always return an empty turn.
        if lastError == nil, !cancelled,
           output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let searches = toolCallsBag.value.count
            lastError = LLMError(
                source: .provider(name: provider.name),
                userMessage: searches > 0
                    ? "\(provider.name) ran \(searches) search\(searches == 1 ? "" : "es") but didn't write an answer. Ask again to retry."
                    : "\(provider.name) returned an empty response. Ask again to retry.",
                httpStatus: nil, url: baseURL, requestHeaders: nil,
                requestBodyJSON: nil, messageHistory: nil, responseBody: nil,
                underlyingError: nil
            )
            lastErrorThreadID = threadID
        }
    }
}
