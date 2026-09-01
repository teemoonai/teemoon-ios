//
//  ChatGeneration.swift
//  teemoon
//
//  Observable state + orchestration for one streaming chat generation.
//

import Foundation
import ModelBackend
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "llm")

@Observable
@MainActor
final class ChatGeneration {
    var running = false
    var cancelled = false
    /// The accumulated response text, updated per snapshot. Views that render
    /// it during streaming pace it through DisplayLinkPacer.
    var output = ""
    var thinkingTime: TimeInterval?
    var isThinking: Bool = false
    var collapsed: Bool = false
    var lastError: LLMError? = nil
    var lastErrorThreadID: UUID? = nil
    var lastRequestDebugInfo: LastRequestDebugInfo? = nil
    var groundingSources: [GroundingSource] = []
    var searchQueries: [String] = []
    var isExecutingTools: Bool = false

    /// The turn teemoon is waiting on, when that turn has produced no visible
    /// text yet — nil when text is flowing or nothing is in flight.
    ///
    /// Held as the turn's INDEX rather than a Bool so a late "finished" for an
    /// earlier turn cannot clear a later turn's wait. Both edges cross an actor
    /// hop; only their order relative to the same turn is meaningful.
    var awaitingTurn: Int?

    /// Whether the model is working with nothing yet to show. Drives the
    /// activity chip — see `StreamingMessageView.showTrailingChip`.
    var isAwaitingModel: Bool { awaitingTurn != nil }

    /// The query the model asked to search when no provider was configured, or
    /// nil. Set from the tool's own call, so it is evidence rather than a guess.
    ///
    /// IN MEMORY ONLY — deliberately not on `Message`. Persisting it would mean
    /// a SwiftData schema change on the type that holds every conversation, and
    /// the card is worth nothing next to that risk. Cost of not persisting: the
    /// offer disappears on relaunch, which is the correct behaviour anyway —
    /// an offer about a question you asked last week is nagging, not helping.
    var unconfiguredSearchQuery: String?
    /// Which thread asked. Without it the card would follow the user into
    /// whatever chat they opened next — the same bug the error banner and the
    /// debug card each carry a thread ID to avoid.
    var unconfiguredSearchThreadID: UUID?

    /// Assistant message ID -> the query that turn wanted to look up.
    ///
    /// THE CARD BELONGS TO ITS TURN. Rendering it from the single per-turn
    /// value above put it at the bottom of the transcript, where it vanished
    /// the moment the next message arrived — so ignoring the offer lost it
    /// silently and forever. Keying it to the message pins it in place: it
    /// scrolls away with the answer it explains, and it never reappears under
    /// an unrelated reply, which is the nagging version.
    ///
    /// In memory only — see the note on `unconfiguredSearchQuery`. Persisting
    /// would mean a schema change on `Message`.
    var offerByMessageID: [UUID: String] = [:]

    /// Builds the `LanguageModel` for one generation. Production is nil —
    /// `generate` constructs `LocalLanguageModel` / `ConfidentialLanguageModel`.
    /// Tests set this to wrap a stub `GenerationTransport` so the send path
    /// is what runs, not a second copy of the loop.
    @ObservationIgnored
    var makeLanguageModel: ((
        Provider, String, [WireMessage], TEEContext?, StreamCallbacks
    ) -> any LanguageModel)?

    /// The question that was waiting on web search when the user tapped
    /// "set it up" — chosen-path frame 6, "re-run the pending question on
    /// success".
    ///
    /// Not polish. Without it, finishing setup strands the user in the ONE
    /// thread that cannot use what they just configured: the refusal from
    /// before the key existed is still in the history, and the model copies it
    /// instead of calling the tool. Measured on device — a fresh thread with
    /// the same key searches fine, the poisoned one never does.
    ///
    /// `ChatViewModel.retry(from:)` is the right instrument because it DELETES
    /// everything after the user's message, so the refusal goes with it. Re-
    /// asking without deleting would just poison the new turn too.
    struct PendingSearchRetry: Equatable {
        let threadID: UUID
        let userMessageID: UUID
    }
    var pendingSearchRetry: PendingSearchRetry?

    /// Threads where the offer was declined. Suppresses the card AND stops
    /// attaching the keyless tool at all — see `makeGroundingTools`.
    var declinedOfferThreadIDs: Set<UUID> = []

    var scrollInterrupted: Bool = false
    var scrollToBottomToken: Int = 0

    var elapsedTime: TimeInterval? {
        if let startTime { return Date().timeIntervalSince(startTime) }
        return nil
    }

    var startTime: Date?
    var firstTokenTime: Date?

    /// Called once per generation, the first time the model produces output —
    /// i.e. when a provider+model has demonstrably *answered*.
    ///
    /// The recents list is "recently used", not "recently selected": picking a
    /// model in the Where sheet and never sending anything shouldn't put it in
    /// a history of what you use, and an unusable setup (dead key, host asleep)
    /// should drop out of that history rather than sit at the top of it.
    ///
    /// First token rather than completion: it proves the model answered, and it
    /// doesn't lose the record to a mid-stream cancel or a network drop. Wired
    /// at the app entry point, the same way `onActiveProviderChanged` keeps
    /// ProviderStore from depending on the attestation layer — this type has no
    /// business knowing what a recents store is.
    @ObservationIgnored
    var onFirstToken: ((Provider) -> Void)?

    func stop() {
        isThinking = false
        cancelled = true
    }

    /// Waiters for `waitUntilStopped`. Resumed when `generate` clears
    /// `running` — `stop()` only sets `cancelled`; the defer ends the turn.
    @ObservationIgnored
    private var stoppedWaiters: [(UUID, CheckedContinuation<Void, Never>)] = []

    /// Awaitable: the current turn has left `running`. No 50ms spin.
    func waitUntilStopped(timeout: Duration) async {
        guard running else { return }
        let id = UUID()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            stoppedWaiters.append((id, cont))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeStopped(id: id)
            }
        }
    }

    private func resumeStopped(id: UUID? = nil) {
        if let id {
            guard let i = stoppedWaiters.firstIndex(where: { $0.0 == id }) else { return }
            stoppedWaiters.remove(at: i).1.resume()
        } else {
            let all = stoppedWaiters
            stoppedWaiters.removeAll()
            all.forEach { $0.1.resume() }
        }
    }

    /// Streams a response from an OpenAI-compatible provider.
    ///
    /// Tool calls (e.g. BraveWebSearchTool) are executed by
    /// `GenerationEngine` mid-stream. `apiKey` comes from the caller — this
    /// type does not read the Keychain.
    func generate(
        provider: Provider,
        thread: Thread,
        systemPrompt: String,
        groundingAPIKey: String?,
        apiKey: String,
        teeContext: TEEContext? = nil
    ) async -> String {
        guard !running else { return "" }

        running = true
        cancelled = false
        output = ""
        groundingSources = []
        searchQueries = []
        isExecutingTools = false
        awaitingTurn = nil
        // Only the PENDING capture resets. `offerByMessageID` deliberately
        // survives: those cards belong to turns that already happened.
        unconfiguredSearchQuery = nil
        unconfiguredSearchThreadID = nil
        scrollInterrupted = false
        lastError = nil
        lastErrorThreadID = nil
        lastRequestDebugInfo = nil
        startTime = Date()
        firstTokenTime = nil
        // The chip must not outlive the generation that justified it: a cancel
        // or a throw leaves the last `onAwaitingModel(_, true)` unanswered.
        defer {
            running = false
            awaitingTurn = nil
            resumeStopped()
        }

        let bgTask = BackgroundWork.begin("LLM Inference") { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        defer { BackgroundWork.end(bgTask) }

        let allMessages = thread.sortedMessages
        guard let lastMessage = allMessages.last, lastMessage.role == .user else { return "" }

        guard let baseURL = provider.openAIBaseURL else {
            output = "Invalid endpoint URL: \(provider.endpoint)"
            return output
        }
        // A SwiftData model must not be captured in an escaping closure, so the
        // id is lifted out here rather than reaching through `thread`.
        let capturedThreadID = thread.id
        let tools = makeGroundingTools(
            provider: provider, groundingAPIKey: groundingAPIKey, threadID: capturedThreadID
        )

        // CANONICAL, not `provider.name` — see `LastRequestDebugInfo.providerName`.
        let capturedProviderName = provider.canonicalName
        let capturedModelID = provider.model
        let toolCallsBag = LockedBox<[ToolCallRecord]>([])
        let resultBag = LockedBox<RequestResult?>(nil)
        let callbacks = makeStreamCallbacks(
            providerName: capturedProviderName,
            modelID: capturedModelID,
            threadID: capturedThreadID,
            toolCallsBag: toolCallsBag,
            resultBag: resultBag
        )

        // No tool-use stanza is appended to the persona. It was added on the theory that
        // small models read a persona like "if you don't know, say so" as license to ask
        // for clarification instead of searching — but the A/B in `ProviderSweepTests`
        // (5 trials each, easy and terse prompts) measured a 5/5 tool-call rate with no
        // system prompt, with the persona, and with persona+guidance alike. The real bugs
        // were elsewhere: the `@Generable` $ref schema and the dropped `reasoning` key.
        let resolvedPrompt = Self.resolvePromptTemplates(systemPrompt)
        // `effective…` rather than the stored fields: the one-message cap and the
        // omitted system prompt are HARD constraints of the endpoint (Brave 422s
        // otherwise), so a provider whose stored config predates them — or was
        // edited — must not be able to send a shape the API will reject.
        let priorMessages = Self.buildWireMessages(
            from: allMessages, systemPrompt: resolvedPrompt,
            maxMessages: provider.effectiveMaxMessages,
            omitSystemPrompt: provider.effectiveOmitSystemPrompt
        )
        // The one place local and remote diverge. Both conform to
        // `LanguageModel`, both run the same `GenerationEngine` underneath, so
        // everything past this line — the session, the tool loop, the streaming,
        // the UI — is identical. Tests replace the whole construction.
        guard let model = resolveLanguageModel(
            provider: provider, apiKey: apiKey, priorMessages: priorMessages,
            teeContext: teeContext, callbacks: callbacks, threadID: capturedThreadID
        ) else { return "" }

        seedDebugInfo(
            providerName: capturedProviderName,
            modelID: capturedModelID,
            url: baseURL,
            threadID: capturedThreadID,
            expectingE2EE: teeContext?.e2eePeer != nil
        )

        let session = LanguageModelSession(model: model, tools: tools)
        let stream = session.streamResponse(to: lastMessage.content)
        var snapshotCount = 0
        do {
            for try await snapshot in stream {
                if cancelled { break }
                if firstTokenTime == nil {
                    firstTokenTime = Date()
                    // `provider` is the one this generation actually ran on,
                    // which is not necessarily the store's current provider by
                    // the time the stream ends — the user can switch mid-answer.
                    onFirstToken?(provider)
                }
                snapshotCount += 1
                // ONLY write when the text actually changed. A same-value
                // write to @Observable state still notifies every observer,
                // and reasoning models yield a snapshot per REASONING chunk
                // with `content` still empty — ~50 no-op writes/second, each
                // one a full SwiftUI transaction that re-resolves every
                // realized table's anchor overlays in a long thread. On
                // device that flood WAS the thinking-phase freeze
                // (hang-reporter, 2026-08-07: 92 samples inside per-frame
                // beginTransaction doing anchor/TextKit work with no visible
                // text moving).
                if output != snapshot.content { output = snapshot.content }
            }
        } catch is CancellationError {
            // normal task cancellation
        } catch let llmError as LLMError {
            // The engine's single error channel: everything it can diagnose
            // arrives here as a fully-populated LLMError.
            logger.error("Stream error: \(llmError.userMessage)")
            lastError = llmError
            lastErrorThreadID = thread.id
            output = ""
        } catch {
            logger.error("Stream error: \(error)")
            lastError = LLMError(
                source: .provider(name: provider.name),
                userMessage: "An unexpected error occurred with \(provider.name). \(error.localizedDescription)",
                httpStatus: nil,
                url: baseURL,
                requestHeaders: nil,
                requestBodyJSON: nil,
                messageHistory: nil,
                responseBody: nil,
                underlyingError: error
            )
            lastErrorThreadID = thread.id
            output = ""
        }
        finishGeneration(
            provider: provider, baseURL: baseURL, threadID: capturedThreadID,
            toolCallsBag: toolCallsBag, resultBag: resultBag
        )

        logger.debug("Done — \(snapshotCount) snapshots, output='\(self.output.prefix(120))'")
        return output
    }
}
