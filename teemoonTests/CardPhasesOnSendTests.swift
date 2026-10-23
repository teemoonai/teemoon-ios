//
//  CardPhasesOnSendTests.swift
//  teemoonTests
//
//  Build 51 on the maintainer's phone: a plain send's card had no cache figure, because
//  only a retry set `turnOrigin`, so a send's phases were nil (or a stale retry's).
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@Suite("The card's phases on a plain send", .serialized)
@MainActor struct CardPhasesOnSendTests {

    final class Cached: GenerationTransport, @unchecked Sendable {
        func runTurn(messages: [[String: Any]], includeTools: Bool,
                     onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
            onPartialContent("an answer")
            var out = TurnOutput(content: "an answer")
            out.report.promptTokens = 4_000
            out.report.cachedTokens = 3_680
            return out
        }
    }

    @Test func aPlainSendHasPhasesAndACacheFigure() async throws {
        let container = try ModelContainer(for: ChatThread.self, Message.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ProviderStore(inMemory: true)
        let provider = Provider(name: "p", endpoint: "http://127.0.0.1:9/v1", model: "m", requiresAPIKey: false)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: Cached(), priorMessages: prior, events: events)
        }
        // A stale origin from an earlier retry must not survive into the next send.
        llm.turnOrigin = Date(timeIntervalSince1970: 1)
        let vm = ChatViewModel()
        vm.prompt = "hello"
        var thread: ChatThread?
        let tapped = Date()
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: ConfidentialSession(providers: store), llm: llm)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }

        let origin = try #require(llm.turnOrigin)
        #expect(origin >= tapped, "the send set its own origin")
        let info = try #require(llm.lastRequestDebugInfo)
        let phases = try #require(info.phases, "a plain send has phases")
        #expect(phases.cacheLine == "cache 92%")
        #expect(info.cardTimingLine?.hasSuffix("cache 92%") == true)
    }

    /// The maintainer (cache-first-message-retry): a Think Harder or retry of the first question
    /// re-sends a prompt the provider just saw, so 0 cached is a miss, not "first message".
    @Test func aReaskOfTheFirstQuestionIsNotAFirstMessage() async throws {
        final class Uncached: GenerationTransport, @unchecked Sendable {
            func runTurn(messages: [[String: Any]], includeTools: Bool,
                         onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
                onPartialContent("an answer")
                var out = TurnOutput(content: "an answer")
                out.report.promptTokens = 4_000
                out.report.cachedTokens = 0
                return out
            }
        }
        let container = try ModelContainer(for: ChatThread.self, Message.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ProviderStore(inMemory: true)
        let provider = Provider(name: "p", endpoint: "http://127.0.0.1:9/v1", model: "m", requiresAPIKey: false)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: Uncached(), priorMessages: prior, events: events)
        }
        let vm = ChatViewModel()
        let session = ConfidentialSession(providers: store)
        vm.prompt = "hello"
        var thread: ChatThread?
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(llm.lastRequestDebugInfo?.phases?.cacheLine == "cache — first message")

        let question = try #require(thread?.sortedMessages.first { $0.role == .user })
        for effort in [ReasoningEffort.thinkHarder, .chatDefault] {
            vm.retry(from: question, currentThread: &thread, modelContext: container.mainContext,
                     settings: AppSettings(), providers: store, session: session, llm: llm, effort: effort)
            for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(llm.lastRequestDebugInfo?.phases?.cacheLine == "cache 0%", "\(effort)")
        }
        vm.prompt = "and then?"
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(llm.lastRequestDebugInfo?.phases?.cacheLine == "cache 0%", "a later send is never first")
    }
}
