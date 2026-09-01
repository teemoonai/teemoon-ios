//
//  E2EELiveSmokeTests.swift
//  teemoonTests
//
//  Minimal live E2EE check: one attestation fetch and one tiny (max_tokens-
//  capped) encrypted chat completion against near.ai, asserting the response
//  decrypts and E2EE was actually active. This is the cheap "is the E2EE
//  stack alive end-to-end" test — the broader paid suites (NearAIBenchmark,
//  GLM5BraveSearch) measure performance and grounding, not E2EE.
//
//  To run: remove the `.disabled` trait locally and provide the key via the
//  NEAR_AI_API_KEY environment variable or a ~/.NEAR_AI_API_KEY file on the
//  host Mac (simulator only). If no key is found the test silently skips.
//

import Foundation
import Testing
import ModelBackend
@testable import teemoon

@Suite("E2EE live smoke", .disabled("Costs money (one tiny request) — remove this trait locally and provide NEAR_AI_API_KEY (see README)"))
struct E2EELiveSmokeTests {

    private func resolveKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env["NEAR_AI_API_KEY"], !v.isEmpty { return v }
        let home = env["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        let file = URL(fileURLWithPath: home).appendingPathComponent(".NEAR_AI_API_KEY")
        return try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test @MainActor func attestedEncryptedRoundTrip() async throws {
        guard let apiKey = resolveKey() else { return } // no key → skip silently

        // Keep the response tiny: extraParams flow into the request body.
        var provider = Provider.nearAI
        provider.extraParams = ["max_tokens": "512"]  // reasoning models spend budget on thinking before any content
        let baseURL = provider.openAIBaseURL!

        // 1. Real attestation — must carry the model's Ed25519 key for E2EE.
        let record = try await AttestationService.fetch(
            baseURL: baseURL, apiKey: apiKey, model: provider.model,
            providerID: provider.id, gpuNodeURL: nil
        )
        try #require(record.modelEd25519PubKey != nil,
                     "attestation has no model Ed25519 key — E2EE unavailable server-side")

        // 2. One encrypted completion through the production engine.
        let results = LockedBox<[RequestResult]>([])
        let callbacks = StreamCallbacks(
            onSourcesFound: { _ in }, onQueriesFound: { _ in }, onToolExecutionEnded: {},
            onSuccess: { r in results.value = results.value + [r] }
        )
        let context = try #require(TEEContext(provider: provider, apiKey: apiKey, attestation: record))
        let model = ConfidentialLanguageModel(
            provider: provider, apiKey: apiKey, priorMessages: [],
            context: context, events: callbacks
        )
        let session = LanguageModelSession(model: model)

        var text = ""
        for try await snapshot in session.streamResponse(to: "Reply with exactly one word: pong") {
            text = snapshot.content
        }

        #expect(!text.isEmpty, "empty response — decryption produced nothing")
        print("[e2ee-smoke] response: \(text.prefix(80))")

        // 3. E2EE must have actually been active (headers + sealed body), and
        //    the verification outcome is reported honestly.
        await waitFor(timeout: .seconds(20), interval: .milliseconds(250)) {
            !results.value.isEmpty
        }
        let result = try #require(results.value.last, "no RequestResult delivered")
        #expect(result.isE2EEActive == true, "request went out in plaintext")
        switch result.teeVerification {
        case .verified(let sig):
            print("[e2ee-smoke] response signature verified — \(sig.signingAddress)")
        case .unverified(let reason):
            print("[e2ee-smoke] response unverified: \(reason)")
        case nil:
            print("[e2ee-smoke] no verification performed (no chat ID?)")
        }
    }
}
