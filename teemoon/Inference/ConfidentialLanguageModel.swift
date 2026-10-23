//
//  ConfidentialLanguageModel.swift
//  teemoon
//
//  Thin `LanguageModel` wrapper around `GenerationEngine` + `HTTPTransport`.
//  Construction and the tool loop live in the engine; this type is the
//  AnyLanguageModel conformance the session object talks to.
//
//  Related: GenerationEngine.swift, HTTPTransport.swift, EngineBackedModel.swift.
//

import Foundation
import ModelBackend
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "inference")

// MARK: - Supporting types

/// One prior conversation turn in OpenAI wire terms.
struct WireMessage: Sendable {
    let role: String
    let content: String
}

/// Everything a TEE-attested request needs beyond the plain provider config.
struct TEEContext: Sendable {
    let baseURL: URL
    let model: String
    let apiKey: String
    let attestation: AttestationRecord
    /// Direct GPU node URL for re-fetching attestation on signing key rotation.
    let gpuNodeURL: URL?
    /// E2EE peer for encrypting requests and decrypting responses.
    /// nil when the model doesn't have an Ed25519 public key.
    let e2eePeer: E2EEPeer?

    /// Derives the context for one attested request. The only place this
    /// derivation lives — production reaches it via
    /// `ConfidentialSession.currentTEEContext()`.
    init?(provider: Provider, apiKey: String, attestation: AttestationRecord) {
        // Completions are routed through the gateway (cloud-api.near.ai), which
        // generates and stores ECDSA signatures. Fetching signatures from the
        // gateway is reliable because it has routing-fix logic to find the
        // correct backend instance. Direct GPU-node URLs do not reliably sign.
        guard let gwBase = provider.openAIBaseURL else { return nil }
        self.baseURL = gwBase
        self.model = provider.model
        self.apiKey = apiKey
        self.attestation = attestation
        self.gpuNodeURL = provider.directGPUNodeURL
        self.e2eePeer = attestation.modelEd25519PubKey.flatMap { key in
            do {
                let peer = try E2EEPeer(modelEd25519PubKey: key)
                logger.debug("[E2EE] peer created — client pub: \(peer.clientPubKeyHex.prefix(16))...")
                return peer
            } catch {
                logger.error("[E2EE] peer creation failed: \(error)")
                return nil
            }
        }
    }

    /// TEST SEAM (internal): a context with an explicitly supplied peer,
    /// bypassing the derivation above. Lets the exploit suite pin transport
    /// behavior for peers the conversion guard would now refuse to build.
    init(baseURL: URL, model: String, apiKey: String,
         attestation: AttestationRecord, gpuNodeURL: URL?, e2eePeer: E2EEPeer?) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.attestation = attestation
        self.gpuNodeURL = gpuNodeURL
        self.e2eePeer = e2eePeer
    }
}

extension URLSession {
    /// One session for chat and attestation, for the app's life. A session per
    /// generation opened a new TCP + TLS connection every turn and was never
    /// invalidated. The long idle limit is the wait for headers; the stream's
    /// own idle limit is `StreamStallWatchdog`.
    static let chat: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = StreamStallWatchdog.headerWait
        // Authenticated traffic only: nothing is cached, not even in memory.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
}

// MARK: - ConfidentialLanguageModel

/// An OpenAI-compatible chat-completions model with optional attested E2EE.
///
/// Construct one per generation. Prior turns are passed in as wire messages
/// (the app owns its transcript in SwiftData); the prompt for the current
/// turn arrives through `LanguageModelSession.streamResponse(to:)`.
struct ConfidentialLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    let provider: Provider
    let apiKey: String
    let priorMessages: [WireMessage]
    let teeContext: TEEContext?
    let events: StreamCallbacks
    /// Injection point for tests (stub URLProtocol). Defaults to an ephemeral
    /// session with streaming-friendly timeouts.
    let urlSession: URLSession
    let effort: ReasoningEffort?
    let affinityID: String?

    init(
        provider: Provider,
        apiKey: String,
        priorMessages: [WireMessage],
        context: TEEContext? = nil,
        events: StreamCallbacks,
        urlSession: URLSession? = nil,
        effort: ReasoningEffort? = nil,
        affinityID: String? = nil
    ) {
        self.effort = effort
        self.affinityID = affinityID
        self.provider = provider
        self.apiKey = apiKey
        self.priorMessages = priorMessages
        self.events = events
        self.teeContext = context
        self.urlSession = urlSession ?? .chat
    }

    // MARK: LanguageModel

    private func engine(session: LanguageModelSession, prompt: Prompt) -> GenerationEngine {
        GenerationEngine(
            provider: provider, apiKey: apiKey, teeContext: teeContext,
            events: events, tools: session.tools,
            initialMessages: priorMessages, prompt: prompt.description,
            urlSession: urlSession, effort: effort, affinityID: affinityID
        )
    }

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        try await EngineBackedModel.respond(
            engine: engine(session: session, prompt: prompt), generating: type
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        EngineBackedModel.streamResponse(
            engine: engine(session: session, prompt: prompt), generating: type
        )
    }
}
