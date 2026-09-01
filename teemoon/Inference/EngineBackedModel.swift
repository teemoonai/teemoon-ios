//
//  EngineBackedModel.swift
//  teemoon
//
//  The adapter between `GenerationEngine` and AnyLanguageModel's
//  `LanguageModel` protocol.
//
//  Both of teemoon's models — `ConfidentialLanguageModel` (remote, E2EE,
//  attested) and `LocalLanguageModel` (on-device, MLX) — are the same object
//  from the framework's point of view: something that runs an engine and yields
//  text. Only the transport underneath differs. This is where that sameness
//  lives, so neither model carries a copy of the `Generable` plumbing.
//

import Foundation
import ModelBackend

/// Runs a `GenerationEngine` and shapes its output the way `LanguageModel`
/// wants it.
enum EngineBackedModel {

    /// Non-streaming: run to completion, hand back the final content.
    static func respond<Content>(
        engine: GenerationEngine,
        generating type: Content.Type
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        let finalText = LockedBox<String>("")
        try await engine.run { text in finalText.value = text }
        let text = finalText.value
        let raw = GeneratedContent(text)
        let content: Content
        if type == String.self {
            content = text as! Content
        } else {
            content = try type.init((try? GeneratedContent(json: text)) ?? raw)
        }
        return .init(content: content, rawContent: raw, transcriptEntries: [])
    }

    /// Streaming: yield a snapshot per engine update.
    ///
    /// The engine emits *cumulative* text, which is exactly what a
    /// `ResponseStream` snapshot is, so there is no re-assembly here.
    static func streamResponse<Content>(
        engine: GenerationEngine,
        generating type: Content.Type
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            let task = Task {
                do {
                    try await engine.run { text in
                        if type == String.self {
                            continuation.yield(.init(
                                content: (text as! Content).asPartiallyGenerated(),
                                rawContent: GeneratedContent(text)
                            ))
                        } else {
                            // Mid-stream the JSON is usually incomplete; skip the
                            // snapshot rather than yielding a half-parsed value.
                            let raw = (try? GeneratedContent(json: text)) ?? GeneratedContent(text)
                            if let parsed = try? type.init(raw) {
                                continuation.yield(.init(content: parsed.asPartiallyGenerated(), rawContent: raw))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}
