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

    /// The preset's model: a pinned id goes stale when Fireworks retires it (gpt-oss-120b, 404 on 2026-11-22).
    @Test @MainActor func fireworksPresetModel() async throws {
        guard let key = hostHomeFile(".FIREWORKS_API_KEY") else { return }
        var p = Provider.fireworks
        p.extraParams = ["max_tokens": "32"]
        try await smoke(p, apiKey: key)
    }

    @Test @MainActor func grokBuild() async throws {
        guard let key = hostHomeFile(".XAI_API_KEY") else { return }
        var p = Provider.grok
        p.model = Provider.grok.model   // the preset's own fallback, kept on xAI's live list; grok-build-0.1 was retired 2026-11
        p.extraParams = ["max_tokens": "32"]
        try await smoke(p, apiKey: key)
    }

    @Test @MainActor func openRouterDeepSeekV4Flash() async throws {
        guard let key = hostHomeFile(".OPENROUTER_API_KEY") else { return }
        var p = Provider.openRouter
        p.model = "deepseek/deepseek-v4-flash"
        p.extraParams = ["max_tokens": "32"]
        try await smoke(p, apiKey: key)
    }

    /// nemotron-3-super 404s since 2026-10; lightning is the preset default now.
    @Test @MainActor func nvidiaNemotronLightning() async throws {
        guard let key = hostHomeFile(".NVIDIA_API_KEY") else { return }
        var p = Provider.nvidia
        p.extraParams = ["max_tokens": "512"]
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
        for (attempt, wait) in (SmokeOverload.backoffSeconds + [0]).enumerated() {
            guard let status = try await smokeOnce(provider, apiKey: apiKey, prompt: prompt) else { return }
            if attempt == SmokeOverload.backoffSeconds.count {
                // Never a pass: a known issue in the run, and a line the gate lists by name.
                let reason = "provider overloaded: \(provider.name) \(provider.model) \(status)"
                print("SMOKE-SKIP \(reason)")
                withKnownIssue(Comment(rawValue: reason)) { Issue.record(Comment(rawValue: reason)) }
                return
            }
            try await Task.sleep(for: .seconds(wait))
        }
    }

    /// One call; the status when the provider answered "overloaded" (retry), nil when the call is settled.
    @MainActor
    private func smokeOnce(_ provider: Provider, apiKey: String, prompt: String) async throws -> Int? {
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
            if let status = SmokeOverload.status(in: msg) { return status }
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
                return nil // unreachable box / network — skip
            } else {
                Issue.record("\(provider.name) smoke failed: \(msg)")
            }
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!trimmed.isEmpty, "\(provider.name) returned an empty reply")
        print("[smoke] \(provider.name)/\(provider.model) \(trimmed.count) chars")
        return nil
    }
}

/// Live-provider overload, for the smoke suite (pm 2026-11-13). A test-target helper, not app code.
/// Retried with this backoff, then recorded as a named skip, never a pass; the gate lists every such skip. The error
/// text carries no Retry-After, so the backoff is fixed. Any other failure still fails.
enum SmokeOverload {
    static let backoffSeconds: [UInt64] = [2, 4, 8]

    /// For a trust check: an outage counts only before any reply was verified. After a verified turn, or for a
    /// verification failure (not an outage status), nil: it fails (pm 2026-11-13).
    static func outageBeforeVerification(verifiedTurns: Int, message: String) -> Int? {
        verifiedTurns == 0 ? status(in: message) : nil
    }

    /// 429 saying overloaded or retry, or 502/503/504 saying unavailable, overloaded, try again or retry (a provider
    /// outage, pm 2026-11-13); nil for anything else, which still fails.
    static func status(in message: String) -> Int? {
        guard let range = message.range(of: #"http (429|502|503|504)"#, options: .regularExpression),
              let status = Int(message[range].dropFirst(5)) else { return nil }
        let lower = message.lowercased()
        let words = status == 429 ? ["overloaded", "retry"] : ["unavailable", "overloaded", "try again", "retry"]
        return words.contains { lower.contains($0) } ? status : nil
    }
}
