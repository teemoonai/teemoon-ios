//
//  ProviderSmokeTests.swift
//  teemoonTests
//
//  One cheap live completion per shipped place. Keys come from host files
//  (`~/.NEAR_AI_API_KEY` etc.), never from the process environment. A missing
//  file or unreachable home box skips rather than fails.
//
//    xcodebuild test -project teemoon.xcodeproj -scheme teemoon \
//      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//      -only-testing:teemoonTests/ProviderSmokeTests
//

import Foundation
import Testing
import ModelBackend
@testable import teemoon

@Suite("Provider smoke", .serialized)
struct ProviderSmokeTests {

    private static let prompt = "Reply with exactly one word: pong"

    @Test @MainActor func nearAIDeepSeekV4Flash() async throws {
        // Missing file → return, not `#require`. A machine without the key
        // must skip; failing would contradict this file's own header.
        guard let key = hostHomeFile(".NEAR_AI_API_KEY") else { return }
        var p = Provider.nearAI
        p.model = "deepseek-ai/DeepSeek-V4-Flash"
        p.extraParams = ["max_tokens": "32"]
        try await smoke(p, apiKey: key)
    }

    @Test @MainActor func fireworksGptOss120B() async throws {
        guard let key = hostHomeFile(".FIREWORKS_API_KEY") else { return }
        var p = Provider.fireworks
        p.model = "accounts/fireworks/models/gpt-oss-120b"
        p.extraParams = ["max_tokens": "32"]
        try await smoke(p, apiKey: key)
    }

    @Test @MainActor func grokBuild() async throws {
        guard let key = hostHomeFile(".XAI_API_KEY") else { return }
        var p = Provider.grok
        p.model = "grok-build-0.1"
        p.extraParams = ["max_tokens": "32"]
        try await smoke(p, apiKey: key)
    }

    @Test @MainActor func braveAnswers() async throws {
        guard let key = hostHomeFile(".BRAVE_ANSWERS_API_KEY") else { return }
        var p = Provider.braveAnswers
        try await smoke(p, apiKey: key, prompt: "In one word, what color is a clear daytime sky?")
    }

    @Test @MainActor func ollamaHomeBoxGemma4E4B() async throws {
        // The home box's endpoint is machine-specific (a private tailnet
        // hostname), so like the keys above it lives in a host file, not in
        // the tree: `~/.TEEMOON_HOME_BOX` containing e.g.
        // `https://machine.tailnet-name.ts.net:11434/v1`. Absent → skip.
        guard let endpoint = hostHomeFile(".TEEMOON_HOME_BOX") else { return }
        let p = Provider(
            name: "ollama",
            endpoint: endpoint,
            model: "gemma4:e4b",
            requiresAPIKey: false,
            extraParams: ["max_tokens": "32"]
        )
        try await smoke(p, apiKey: "")
    }

    @MainActor
    private func smoke(_ provider: Provider, apiKey: String, prompt: String = prompt) async throws {
        let callbacks = StreamCallbacks(
            onSourcesFound: { _ in }, onQueriesFound: { _ in },
            onToolExecutionEnded: {}, onSuccess: { _ in }
        )
        let model = ConfidentialLanguageModel(
            provider: provider, apiKey: apiKey, priorMessages: [],
            context: nil, events: callbacks
        )
        let session = LanguageModelSession(model: model)
        var text = ""
        do {
            for try await snapshot in session.streamResponse(to: prompt) {
                text = snapshot.content
            }
        } catch {
            let msg = error.localizedDescription
            if msg.localizedCaseInsensitiveContains("401")
                || msg.localizedCaseInsensitiveContains("unauthorized") {
                Issue.record("\(provider.name) rejected the key (\(msg))")
            } else if msg.localizedCaseInsensitiveContains("could not connect")
                || msg.localizedCaseInsensitiveContains("offline")
                || msg.localizedCaseInsensitiveContains("timed out")
                // DNS FAILURE IS UNREACHABILITY TOO, and for a tailnet host it
                // is the usual shape: NSURLErrorDNSLookupFailed / -1003 reads
                // "A server with the specified hostname could not be found",
                // which matched none of the clauses above and so failed the
                // suite instead of skipping. Worse, it only bites in a long
                // run: a negative DNS entry gets cached ("Resolved 0 endpoints
                // ... from cache"), so the test passes in isolation and fails
                // in a full run, which reads as flakiness rather than as a
                // box that is simply not on the network.
                || msg.localizedCaseInsensitiveContains("hostname could not be found")
                || msg.localizedCaseInsensitiveContains("hostname could not be resolved") {
                return // unreachable box / network — skip
            } else {
                Issue.record("\(provider.name) smoke failed: \(msg)")
            }
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!trimmed.isEmpty, "\(provider.name) returned an empty reply")
        print("[smoke] \(provider.name)/\(provider.model) \(trimmed.count) chars")
    }
}
