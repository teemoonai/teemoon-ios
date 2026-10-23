//
//  LocalLanguageModel.swift
//  teemoon
//
//  On-device inference, behind the same `LanguageModel` protocol as every
//  remote provider.
//
//  This file is the payoff for the transport split: it is short because
//  everything that makes teemoon's tool calling work — schema flattening,
//  argument coercion, `ToolCallFormat` recovery, round chaining, markup
//  containment, the reasoning-only fallback — is in `GenerationEngine`, shared
//  with `ConfidentialLanguageModel`. A model running on the phone and the same
//  model running on near.ai go through identical code from the tool loop up.
//
//  `ChatGeneration` does not know which one it got, and must not need to.
//
//  Related: LiteRTTransport.swift (the transport), GenerationEngine.swift (the
//  shared loop), ConfidentialLanguageModel.swift (the remote sibling).
//

import Foundation
import ModelBackend

/// A model whose weights live on this device.
struct LocalModelRef: Sendable, Equatable {
    /// HuggingFace repo id, e.g. `mlx-community/gemma-4-e4b-it-4bit`. Identity
    /// and display name; also what a re-download would fetch.
    let id: String
    /// Where the weights, tokenizer and `config.json` actually are.
    let directory: URL
    /// On-disk size in MB, for the pre-load memory gate.
    let sizeMB: Int
    /// The `.litertlm` artefact itself; `directory` is its containing folder.
    let bundleFile: URL

    init(id: String, directory: URL, sizeMB: Int, bundleFile: URL) {
        self.id = id
        self.directory = directory
        self.sizeMB = sizeMB
        self.bundleFile = bundleFile
    }

    var displayName: String { id.components(separatedBy: "/").last ?? id }
}

/// Generates on-device with LiteRT-LM.
///
/// Constructed per generation, like its remote sibling: prior turns are passed
/// in as wire messages (the app owns its transcript in SwiftData) and the
/// current turn's prompt arrives through `LanguageModelSession`.
struct LocalLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    let model: LocalModelRef
    let priorMessages: [WireMessage]
    let events: StreamCallbacks
    let temperature: Float
    let maxTokens: Int
    let enableThinking: Bool

    /// Deliberately far below what a hosted model gets.
    ///
    /// Every token is decoded serially on the phone's GPU at ~40–60 tok/s, so
    /// 2048 tokens is ~40 seconds of work — per round, and with tool rounds that
    /// compounds into minutes of saturated GPU: not merely slow, but hot enough
    /// to take Wi-Fi and the app down with it.
    ///
    /// 1024 rather than something smaller because the model has to be able to
    /// FINISH thinking (see `enableThinking`) — a truncated think block is a
    /// turn that decided nothing. Measured at 1024: a tool decision completes in
    /// ~6.7 s.
    static let defaultMaxTokens = 1024

    /// Off: what every on-device turn ran before 1.0.6, and Android's explicit off.
    /// Think Harder turns it on (`ReasoningControl.onDevice`).
    static let defaultEnableThinking = false

    init(
        model: LocalModelRef,
        priorMessages: [WireMessage],
        events: StreamCallbacks,
        temperature: Float = 0.7,
        maxTokens: Int = LocalLanguageModel.defaultMaxTokens,
        enableThinking: Bool = LocalLanguageModel.defaultEnableThinking
    ) {
        self.model = model
        self.priorMessages = priorMessages
        self.events = events
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.enableThinking = enableThinking
    }

    /// The on-device runtime. One line, because there is one runtime — but it
    /// stays behind `GenerationTransport` rather than being called directly,
    /// which is what made removing the other one a deletion instead of a
    /// rewrite.
    private func transport(for tools: [any Tool]) -> any GenerationTransport {
        // `contextTokens`, not a generation cap: LiteRT's budget covers input +
        // output together. See LiteRTTransport.
        LiteRTTransport(
            modelPath: model.bundleFile,
            estimatedSizeMB: model.sizeMB,
            tools: tools,
            events: events,
            thinking: enableThinking
        )
    }

    private func engine(session: LanguageModelSession, prompt: Prompt) -> GenerationEngine {
        GenerationEngine(
            events: events,
            tools: session.tools,
            initialMessages: priorMessages,
            prompt: prompt.description,
            transport: transport(for: session.tools),
            // No local model grounds its own answers — that is a hosted-provider
            // feature (Brave Answers). Grounding here goes through the web-search
            // tool like everywhere else.
            groundsItsOwnAnswers: false,
            // Each extra round is a full re-prefill plus a serial decode on the
            // phone. Four (the hosted default) compounds into minutes of pinned
            // GPU; two still allows search-then-answer, which is the shape
            // essentially every grounded query actually takes.
            maxToolRounds: 2
        )
    }

    // MARK: LanguageModel

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
