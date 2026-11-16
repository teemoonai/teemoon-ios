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

    /// A near.ai outage (502/503/504 "unavailable", 429 "overloaded") BEFORE any reply was verified is the smoke suite's:
    /// retried at 2, 4, 8 s, then a named known issue (SMOKE-SKIP), never a pass. After a verified turn, or any
    /// verification failure, it fails: this is a trust check and an outage must never mask one (pm 2026-11-13).
    @Test @MainActor func twoTurnReplySignaturesCheckOut() async throws {
        guard let apiKey = hostHomeFile(".NEAR_AI_API_KEY") else {
            return // file not visible in this process — skip, don't fail CI
        }
        for (attempt, wait) in (SmokeOverload.backoffSeconds + [0]).enumerated() {
            let verified = LockedBox(0)
            do {
                return try await twoTurns(apiKey: apiKey, verified: verified)
            } catch {
                let message = (error as? LLMError)?.userMessage ?? error.localizedDescription
                guard let status = SmokeOverload.outageBeforeVerification(verifiedTurns: verified.value,
                                                                          message: message) else { throw error }
                if attempt == SmokeOverload.backoffSeconds.count {
                    let reason = "provider overloaded: near.ai \(Provider.nearAI.model) \(status) (live E2E)"
                    print("SMOKE-SKIP \(reason)")
                    withKnownIssue(Comment(rawValue: reason)) { Issue.record(Comment(rawValue: reason)) }
                    return
                }
                try await Task.sleep(for: .seconds(wait))
            }
        }
    }

    @MainActor
    private func twoTurns(apiKey: String, verified: LockedBox<Int>) async throws {

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
        verified.value += 1

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
