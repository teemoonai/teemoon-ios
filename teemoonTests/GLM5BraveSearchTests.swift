//  GLM5BraveSearchTests.swift
//  teemoonTests
//
//  Integration test: exercises the full app stack (ChatGeneration → ProviderAuthURLProtocol
//  → ToolAwareForwardingDelegate → BraveWebSearchTool) with near.ai GLM-5 via its
//  direct completions endpoint.
//
//  NOTE: Run in the iOS Simulator, not on a physical device.
//        The file-based key fallback reads from the host Mac's home directory,
//        which is only accessible from the simulator via SIMULATOR_HOST_HOME.
//
//  To run:
//  1. In Xcode: Edit Scheme → Test → Arguments → Environment Variables
//     Add: NEAR_AI_API_KEY = <your near.ai key>
//          BRAVE_API_KEY   = <your Brave Search API key>
//  2. Alternatively, create ~/.NEAR_AI_API_KEY and ~/.BRAVE_API_KEY on the host Mac.
//  3. If neither key is found the test is silently skipped (not a failure).
//  4. Run in the simulator — makes real network requests, may take ~30 seconds.

import Foundation
import Testing
import SwiftData
@testable import teemoon

@Suite("GLM-5 + Brave Search (full stack)", .disabled("Costs money — to run, remove this trait locally and provide API keys (see README)"))
struct GLM5BraveSearchTests {

    // MARK: - Helpers

    /// Resolves an API key from (in priority order):
    /// 1. An environment variable named `envVar`
    /// 2. One of the `files` in the host Mac's home directory (simulator only)
    private func resolveKey(_ envVar: String, files: [String]) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env[envVar], !v.isEmpty { return v }
        // SIMULATOR_HOST_HOME points to the real Mac home; NSHomeDirectory() is the sandbox.
        let home = env["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        for name in files {
            let file = URL(fileURLWithPath: home).appendingPathComponent(name)
            if let v = try? String(contentsOf: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        return nil
    }

    /// Builds an in-memory SwiftData stack with a single Thread containing one user message.
    @MainActor
    private func makeThread(userMessage: String) throws -> (thread: teemoon.Thread, container: ModelContainer) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: teemoon.Thread.self, Message.self, configurations: config)
        let context = container.mainContext
        let thread = teemoon.Thread()
        context.insert(thread)
        let message = Message(role: .user, content: userMessage, thread: thread)
        context.insert(message)
        try context.save()
        return (thread, container)
    }

    // MARK: - Test

    /// Verifies that GLM-5 on near.ai:
    ///   1. Issues at least one `web_search` tool call (captured in `llm.searchQueries`)
    ///   2. Brave returns sources (captured in `llm.groundingSources`)
    ///   3. The final answer is non-empty and contains at least one markdown citation
    ///
    /// The full stack exercised: ChatGeneration → ProviderAuthURLProtocol.makeSession →
    /// ToolAwareForwardingDelegate (SSE parse + tool execution + follow-up request) →
    /// BraveWebSearchTool → final streamed response.
    ///
    /// If API keys are not configured the test is silently skipped.
    @Test @MainActor
    func glm5_callsBraveSearchAndCites() async throws {
        guard let nearKey = resolveKey("NEAR_AI_API_KEY", files: [".NEAR_AI_API_KEY", ".nearai_api_key"]) else {
            print("⚠️  GLM5BraveSearchTests: NEAR_AI_API_KEY not found — skipping.")
            return
        }
        guard let braveKey = resolveKey("BRAVE_API_KEY", files: [".BRAVE_API_KEY", ".brave_api_key"]) else {
            print("⚠️  GLM5BraveSearchTests: BRAVE_API_KEY not found — skipping.")
            return
        }

        // Build a provider using the near.ai preset UUID so inferenceBaseURL resolves
        // GLM-5's direct completions endpoint (https://glm-5.completions.near.ai/v1).
        var provider = Provider.nearAI
        provider.model = "zai-org/GLM-5-FP8"

        // Populate Keychain with the test key; always clean up afterward.
        try Keychain.save(nearKey, for: provider.id.uuidString)
        defer { try? Keychain.delete(for: provider.id.uuidString) }

        // A question that reliably requires a live web search to answer well.
        let (thread, container) = try makeThread(userMessage: "What are the most important AI news stories from the past week?")
        defer { withExtendedLifetime(container) {} }

        let llm = ChatGeneration()
        let wallStart = Date()
        let result = await llm.generate(
            provider: provider,
            thread: thread,
            systemPrompt: AppSettings.defaultSystemPrompt,
            groundingAPIKey: braveKey,
            apiKey: nearKey
        )
        let wallTotal = Date().timeIntervalSince(wallStart)

        let ttft  = llm.lastRequestDebugInfo?.timeToFirstToken
        let total = llm.lastRequestDebugInfo?.totalDuration
        let tps   = llm.lastRequestDebugInfo?.tokensPerSecond

        print("── GLM-5 + Brave result ──────────────────────────────")
        print("wall time      : \(String(format: "%.2f", wallTotal))s")
        if let ttft  { print("TTFT           : \(String(format: "%.2f", ttft))s") }
        if let total { print("total (LLM)    : \(String(format: "%.2f", total))s") }
        if let tps   { print("tokens/sec     : \(String(format: "%.1f", tps))") }
        print("search queries : \(llm.searchQueries)")
        print("sources found  : \(llm.groundingSources.count)")
        print("output length  : \(result.count) chars")
        print(result)
        print("──────────────────────────────────────────────────────")

        #expect(!result.isEmpty, "ChatGeneration.generate() returned an empty string")
        #expect(!llm.searchQueries.isEmpty, "GLM-5 should have issued at least one web_search tool call")
        #expect(!llm.groundingSources.isEmpty, "Brave should have returned at least one source")
        #expect(result.contains("](http"), "Final answer should contain at least one markdown citation link")
    }

    /// A question that SPENDS THE WHOLE ROUND BUDGET must still be answered.
    ///
    /// The test above cannot reach that state: "AI news this week" is satisfied
    /// by one search, so it exercises the happy path and stops. This one is
    /// built to exhaust the budget — an abbreviation with plausible partial
    /// matches, so the model neither finds it nor gives up, plus trailing
    /// sub-questions that keep it searching after the main one is settled.
    ///
    /// That exhausted turn is where a grounded answer used to become nothing at
    /// all: tools drop out of the request, nothing says so, the model asks for
    /// one more search, recovery parses it, the budget guard drops it,
    /// containment strips it, and the reply is "". See
    /// `GenerationEngine.searchesExhaustedNotice`; a tool-round-exhaustion
    /// measurement chose that wording.
    ///
    /// STOCHASTIC BY NATURE — the model is free to converge early, in which
    /// case this just re-tests the happy path. It is not a deterministic
    /// regression net; `GenerationTransportTests` owns that. What it adds is
    /// live coverage of a state no stub can produce, against a real server.
    ///
    /// The prompt is deliberately about nowhere anyone here lives. Both this
    /// and the tool's default used to name a real hometown, which is a location
    /// this repo has no reason to carry.
    @Test @MainActor
    func glm5_answersEvenWhenTheRoundBudgetRunsOut() async throws {
        guard let nearKey = resolveKey("NEAR_AI_API_KEY", files: [".NEAR_AI_API_KEY", ".nearai_api_key"]) else {
            print("⚠️  GLM5BraveSearchTests: NEAR_AI_API_KEY not found — skipping.")
            return
        }
        guard let braveKey = resolveKey("BRAVE_API_KEY", files: [".BRAVE_API_KEY", ".brave_api_key"]) else {
            print("⚠️  GLM5BraveSearchTests: BRAVE_API_KEY not found — skipping.")
            return
        }

        var provider = Provider.nearAI
        provider.model = "zai-org/GLM-5.1-FP8"
        try Keychain.save(nearKey, for: provider.id.uuidString)
        defer { try? Keychain.delete(for: provider.id.uuidString) }

        let (thread, container) = try makeThread(userMessage: """
            what is the best CP car wash near downtown Sacramento, what are their \
            hours, and how much is the top wash package
            """)
        defer { withExtendedLifetime(container) {} }

        let llm = ChatGeneration()
        let result = await llm.generate(
            provider: provider,
            thread: thread,
            systemPrompt: AppSettings.defaultSystemPrompt,
            groundingAPIKey: braveKey,
            apiKey: nearKey
        )

        let rounds = llm.lastRequestDebugInfo?.toolCalls.count ?? 0
        print("── budget-exhaustion result ──────────────────────────")
        print("tool calls    : \(rounds)")
        print("search queries: \(llm.searchQueries)")
        print("output length : \(result.count) chars")
        print(result)
        print("──────────────────────────────────────────────────────")

        #expect(!llm.searchQueries.isEmpty, "the prompt should have driven at least one search")
        // THE POINT: searched and then said nothing is the regression.
        #expect(!result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "GLM searched \(rounds) time(s) and returned an empty answer")
        // ...and if it ever does go empty, it must at least SAY so rather than
        // vanishing — the floor in `ChatGeneration`.
        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            #expect(llm.lastError != nil, "an empty reply was reported as success")
        }
    }
}
