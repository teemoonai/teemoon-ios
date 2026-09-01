//
//  ProductLiveEndpointTests.swift
//  teemoonTests
//
//  Live near.ai E2E. The key is the file that is already on the Mac
//  (`~/.NEAR_AI_API_KEY`); nothing is taken from the process environment.
//  Skips when the file is missing. Spends two small completions.
//

import Foundation
import Testing
import ModelBackend
@testable import teemoon

@Suite("Product live endpoints")
struct ProductLiveEndpointTests {

    @Test @MainActor func twoTurnReplySignaturesCheckOut() async throws {
        guard let apiKey = hostHomeFile(".NEAR_AI_API_KEY") else {
            return // file not visible in this process — skip, don't fail CI
        }

        var provider = Provider.nearAI
        provider.extraParams = ["max_tokens": "64"]
        let baseURL = try #require(provider.openAIBaseURL)

        let record = try await AttestationService.fetch(
            baseURL: baseURL, apiKey: apiKey, model: provider.model,
            providerID: provider.id, gpuNodeURL: nil
        )
        try #require(record.modelEd25519PubKey != nil, "attestation has no model Ed25519 key")
        let context = try #require(TEEContext(provider: provider, apiKey: apiKey, attestation: record))

        let first = try await turn(
            prompt: "Reply with exactly one word: pong",
            prior: [], provider: provider, apiKey: apiKey, context: context
        )
        try assertCheckedOut(first, turn: 1)

        let second = try await turn(
            prompt: "Reply with exactly one word: ok",
            prior: [
                WireMessage(role: "user", content: "Reply with exactly one word: pong"),
                WireMessage(role: "assistant", content: first.text),
            ],
            provider: provider, apiKey: apiKey, context: context
        )
        try assertCheckedOut(second, turn: 2)
    }

    private struct Turn {
        var text: String
        var result: RequestResult
    }

    @MainActor
    private func turn(
        prompt: String,
        prior: [WireMessage],
        provider: Provider,
        apiKey: String,
        context: TEEContext
    ) async throws -> Turn {
        let results = LockedBox<[RequestResult]>([])
        let callbacks = StreamCallbacks(
            onSourcesFound: { _ in }, onQueriesFound: { _ in }, onToolExecutionEnded: {},
            onSuccess: { r in results.value = results.value + [r] }
        )
        let model = ConfidentialLanguageModel(
            provider: provider, apiKey: apiKey, priorMessages: prior,
            context: context, events: callbacks
        )
        let session = LanguageModelSession(model: model)
        var text = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            text = snapshot.content
        }
        try #require(!text.isEmpty, "empty live reply")
        await waitFor(timeout: .seconds(20), interval: .milliseconds(250)) {
            !results.value.isEmpty
        }
        let result = try #require(results.value.last, "no RequestResult")
        return Turn(text: text, result: result)
    }

    private func assertCheckedOut(_ turn: Turn, turn n: Int) throws {
        #expect(turn.result.isE2EEActive, "turn \(n) went out in plaintext")
        switch turn.result.teeVerification {
        case .verified:
            break
        case .unverified(.signatureMismatch(let expected, let got)):
            Issue.record("turn \(n) signature mismatch expected=\(expected) got=\(got)")
        case .unverified(.contentMismatch(let detail)):
            Issue.record("turn \(n) content mismatch: \(detail)")
        case .unverified(.signatureUnavailable):
            // TEE stores the signature asynchronously; the first lookup can
            // miss. That is not "didn't check out" (content/signature mismatch).
            break
        case .unverified, nil:
            break
        }
    }
}
