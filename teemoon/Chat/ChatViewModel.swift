//
//  ChatViewModel.swift
//  teemoon

import Foundation
import Observation
import SwiftData
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "chat")

@Observable
@MainActor
final class ChatViewModel {
    var prompt = ""
    var generatingThreadID: UUID?

    /// Soft tap. Wired by the view — this type must not import Haptics.
    @ObservationIgnored
    var onPlayHaptic: (() -> Void)?

    /// Wraps a store mutation so the view can animate it. Defaults to
    /// running the work immediately — this type must not import SwiftUI.
    @ObservationIgnored
    var onBatchUpdate: ((() -> Void) -> Void)?

    var isPromptEmpty: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Same send policy the ladder and title block render — delegated to the
    /// session's canonical `sendPolicy` so there is exactly ONE definition
    /// (the Siri/Shortcuts intent consults the same one). The view shows the
    /// alert; the send path refuses to generate unless the policy is `.allow`.
    func sendPolicy(session: ConfidentialSession) -> TrustSendPolicy {
        session.sendPolicy
    }

    /// Why send cannot proceed. Trust allow/confirm/block is `TrustSendPolicy`;
    /// this adds no-provider and still-downloading. The view presents; it does
    /// not decide. See SendPrepTests.
    enum SendPrep: Equatable {
        case blockedEmptyPrompt
        case blockedNoProvider
        case blockedNoKey
        case blockedDownloading
        case confirmE2EE
        case blockedE2EE
        case ready
    }

    func prepareSend(
        hasProvider: Bool,
        hasKey: Bool,
        isDownloading: Bool,
        trust: TrustSendPolicy,
        requirePrompt: Bool = true
    ) -> SendPrep {
        if requirePrompt, isPromptEmpty { return .blockedEmptyPrompt }
        if !hasProvider { return .blockedNoProvider }
        if !hasKey { return .blockedNoKey }
        if isDownloading { return .blockedDownloading }
        switch trust {
        case .allow: return .ready
        case .confirm: return .confirmE2EE
        case .block: return .blockedE2EE
        }
    }

    /// Weights still arriving on the phone or a home pull. Copy is data.
    /// See SendPrepTests.
    struct Arrival: Equatable {
        enum Kind: Equatable { case phone, home, homeManifest }
        var name: String
        var fraction: Double?
        var kind: Kind

        var alertMessage: String {
            if let fraction {
                return "\(name) is \(Int(fraction * 100))% downloaded. it'll answer as soon as the rest lands — you can leave this message here and send it then."
            }
            if kind == .homeManifest {
                return "\(name) is still downloading onto that machine. it'll answer as soon as it lands — you can leave this message here and send it then."
            }
            return "\(name) isn't downloaded. pick it again in where to restart the download, or choose something else to send now."
        }
    }

    /// Whether this turn must be refused because the provider promised
    /// attestation + E2EE but no peer could be established — the transport
    /// would run with a nil codec and send PLAINTEXT under that promise
    /// Pure so the regression tests can pin the decision.
    /// Non-attested providers (peer legitimately absent) are unaffected.
    static func mustRefuseUnsealedSend(provider: Provider, teeContext: TEEContext?) -> Bool {
        provider.capabilities.contains(.attestation) && teeContext?.e2eePeer == nil
    }

    /// Whether this turn must be refused because the provider needs an API
    /// key and none is stored. Consulted BEFORE `prepareTurn`, so a missing
    /// key is reported as a missing key — not as the E2EE failure an
    /// unauthenticated attestation fetch would produce. Keyless providers
    /// (self-hosted, on-device) are unaffected. Pure; see SendPrepTests.
    static func mustRefuseMissingKey(provider: Provider, credential: String) -> Bool {
        provider.requiresAPIKey && !provider.isLocal
            && credential.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The card for a refused keyless send. Names the key and where it goes;
    /// no HTTP status, because nothing went over the wire.
    static func missingKeyError(for provider: Provider) -> LLMError {
        LLMError(
            source: .provider(name: provider.name),
            userMessage: "\(provider.name) needs an API key and none is saved, so nothing was sent. Paste one in settings → places & keys → cloud keys, then retry.",
            httpStatus: nil, url: provider.openAIBaseURL, requestHeaders: nil,
            requestBodyJSON: nil, messageHistory: nil, responseBody: nil,
            underlyingError: nil
        )
    }

    func generate(
        currentThread: inout Thread?,
        modelContext: ModelContext,
        settings: AppSettings,
        providers: ProviderStore,
        session: ConfidentialSession,
        llm: ChatGeneration
    ) {
        guard !isPromptEmpty else { return }
        if currentThread == nil {
            let newThread = Thread()
            currentThread = newThread
            modelContext.insert(newThread)
            do { try modelContext.save() } catch { logger.error("Failed to save new thread: \(error)") }
        }
        guard let thread = currentThread else { return }
        generatingThreadID = thread.id
        let message = prompt
        prompt = ""
        onPlayHaptic?()
        sendMessage(Message(role: .user, content: message, thread: thread,
                            isE2EE: session.canSeal), modelContext: modelContext)
        Task {
            await generateResponse(in: thread, settings: settings, providers: providers, session: session, llm: llm, modelContext: modelContext)
            generatingThreadID = nil
        }
    }

    /// The user message to re-ask when the app returns to the foreground, or
    /// nil. Non-nil only when `thread` is the one whose last turn the on-device
    /// transport abandoned because the app left the foreground (iOS revokes
    /// GPU access), AND that turn left the user message unanswered. A turn the
    /// user stopped is not resumed — they asked for it to stop.
    ///
    /// CONSUMES the flag: the caller re-asks exactly once. Without the resume
    /// the thread carries an orphaned request, and the next question is
    /// answered as if it were that request — "hello" got the potato essay.
    func interruptedUserMessage(in thread: Thread?, llm: ChatGeneration) -> Message? {
        guard let thread, llm.interruptedThreadID == thread.id, !llm.running else { return nil }
        llm.interruptedThreadID = nil
        guard let last = thread.sortedMessages.last, last.role == .user else { return nil }
        return last
    }

    func retry(
        from message: Message,
        currentThread: inout Thread?,
        modelContext: ModelContext,
        settings: AppSettings,
        providers: ProviderStore,
        session: ConfidentialSession,
        llm: ChatGeneration
    ) {
        guard let thread = message.thread ?? currentThread else { return }

        // Stop any in-progress generation (e.g. stuck after background timeout)
        if llm.running {
            llm.stop()
        }

        // Delete all messages after this one with an animated exit
        let sorted = thread.sortedMessages
        if let idx = sorted.firstIndex(where: { $0.id == message.id }) {
            let toDelete = Array(sorted[(idx + 1)...])
            let apply = onBatchUpdate ?? { $0() }
            ChatSearchService.shared.didDelete(messageIDs: toDelete.map(\.id))
            apply {
                for msg in toDelete {
                    modelContext.delete(msg)
                }
                thread.invalidateSortedMessages()
                do { try modelContext.save() } catch { logger.error("Failed to save after retry cleanup: \(error)") }
            }
        }

        // Clear stale state so the pending activity chip appears immediately.
        llm.lastError = nil
        llm.lastErrorThreadID = nil
        llm.output = ""

        currentThread = thread
        generatingThreadID = thread.id
        Task {
            await llm.waitUntilStopped(timeout: .seconds(1))
            onPlayHaptic?()
            await generateResponse(in: thread, settings: settings, providers: providers, session: session, llm: llm, modelContext: modelContext)
            generatingThreadID = nil
        }
    }

    private func generateResponse(
        in thread: Thread,
        settings: AppSettings,
        providers: ProviderStore,
        session: ConfidentialSession,
        llm: ChatGeneration,
        modelContext: ModelContext
    ) async {
        guard let provider = providers.activeProvider else { return }
        let groundingKey = provider.capabilities.contains(.builtInGrounding)
            ? nil : settings.groundingAPIKey

        // FAIL CLOSED, and keep this ahead of `prepareTurn`: attestation with
        // no key 401s and would surface below as an E2EE failure that no
        // lock-icon re-verify can fix. Same presentation as a generation error.
        let apiKey = providers.credential(for: provider)
        if Self.mustRefuseMissingKey(provider: provider, credential: apiKey) {
            logger.warning("[send] \(provider.name, privacy: .public) requires an API key and none is stored — refusing to send")
            llm.output = ""
            llm.lastError = Self.missingKeyError(for: provider)
            llm.lastErrorThreadID = thread.id
            session.beginRequest(expectingE2EE: false)
            session.finishTurn(debugInfo: nil, error: llm.lastError)
            llm.scrollToBottomToken += 1
            return
        }

        let teeContext = await session.prepareTurn()
        if Self.mustRefuseUnsealedSend(provider: provider, teeContext: teeContext) {
            // FAIL CLOSED. This used to log a warning and
            // proceed — an attested provider with no E2EE peer reached the
            // transport with a nil codec and sent PLAINTEXT under an E2EE
            // promise. Surface the degraded state exactly like a generation
            // error (the view renders `lastError` keyed to the thread;
            // `retry(...)` clears it) and send NOTHING.
            logger.warning("[E2EE] Ed25519 key unavailable after wait — refusing to send")
            llm.output = ""
            llm.lastError = LLMError(
                source: .provider(name: provider.name),
                userMessage: "End-to-end encryption could not be established, so nothing was sent. Try again — if this keeps happening, re-verify the connection from the lock icon.",
                httpStatus: nil, url: provider.openAIBaseURL, requestHeaders: nil,
                requestBodyJSON: nil, messageHistory: nil, responseBody: nil,
                underlyingError: E2EEError.encryptionFailed
            )
            llm.lastErrorThreadID = thread.id
            session.finishTurn(debugInfo: nil, error: llm.lastError)
            llm.scrollToBottomToken += 1
            return
        }

        let output = await llm.generate(
            provider: provider,
            thread: thread,
            systemPrompt: settings.systemPrompt,
            groundingAPIKey: groundingKey,
            apiKey: apiKey,
            teeContext: teeContext
        )
        // `generate` has already set `running = false`. Do not yield before
        // the assistant row is in SwiftData — a hop here lets SwiftUI paint
        // one frame with the streaming view gone and no persisted message,
        // which is the flash before the debug panel.
        session.finishTurn(debugInfo: llm.lastRequestDebugInfo, error: llm.lastError)

        // Save the assistant message immediately so it appears in the conversation
        // as soon as the StreamingMessageView disappears (llm.running became false).
        // Don't save if generation ended in an error — the error is shown
        // ephemerally. And never persist an EMPTY reply: a blank assistant
        // message renders as a hole in the thread and kills the list preview.
        if llm.lastError == nil, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let sources = GroundingSource.citedOrAll(in: output, grounding: llm.groundingSources)
            let assistantMessage = Message(role: .assistant, content: output, thread: thread,
                                           generatingTime: llm.elapsedTime,
                                           sourcesJSON: GroundingSource.encodedJSON(sources),
                                           isE2EE: session.lastRequestUsedE2EE == true)
            sendMessage(assistantMessage, modelContext: modelContext)
            // The first moment the turn's web-search request can be tied to the
            // reply it produced. Before this the message did not exist, which is
            // why the offer was previously keyed to nothing and rendered at the
            // bottom of the transcript.
            llm.attachPendingOffer(to: assistantMessage.id)
        }
        llm.scrollToBottomToken += 1
        // Verification bookkeeping that used to sit in a pre-save yield.
        await Task.yield()
    }

    private func sendMessage(_ message: Message, modelContext: ModelContext) {
        onPlayHaptic?()
        modelContext.insert(message)
        message.thread?.invalidateSortedMessages()
        do { try modelContext.save() } catch { logger.error("Failed to save message: \(error)") }
        // Best-effort; the launch reconcile is what guarantees correctness.
        ChatSearchService.shared.didWrite(message)
    }
}
