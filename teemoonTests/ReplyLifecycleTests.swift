//
//  ReplyLifecycleTests.swift
//  teemoonTests
//
//  reply-machine.json G1/G2 in the app: a stopped turn's engine keeps calling back after the next turn starts, and
//  an overlapping retry's old task ends while the new one runs. Neither may touch the new turn.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@Suite("A reply's late callbacks and overlaps", .serialized)
@MainActor struct ReplyLifecycleTests {

    /// Streams `partial`, then waits until cancelled.
    final class Hangs: GenerationTransport, @unchecked Sendable {
        func runTurn(messages: [[String: Any]], includeTools: Bool,
                     onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
            onPartialContent("partial")
            try await Task.sleep(for: .seconds(30))
            return TurnOutput(content: "partial")
        }
    }

    /// Answers after `delay`.
    final class Answers: GenerationTransport, @unchecked Sendable {
        let delay: Duration
        init(after delay: Duration) { self.delay = delay }
        func runTurn(messages: [[String: Any]], includeTools: Bool,
                     onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
            try await Task.sleep(for: delay)
            onPartialContent("fresh")
            return TurnOutput(content: "fresh")
        }
    }

    struct Harness {
        let container: ModelContainer
        let store: ProviderStore
        let session: ConfidentialSession
        let llm: ChatGeneration
        let callbacks: LockedBox<[StreamCallbacks]>
    }

    /// One plain provider; each language model the turn builds takes the next transport and records its callbacks.
    private func harness(_ transports: [any GenerationTransport]) throws -> Harness {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ProviderStore(inMemory: true)
        let provider = Provider(name: "p", endpoint: "http://127.0.0.1:9/v1", model: "m", requiresAPIKey: false)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let llm = ChatGeneration()
        let callbacks = LockedBox<[StreamCallbacks]>([])
        llm.makeLanguageModel = { _, _, prior, _, events in
            let index = callbacks.value.count
            callbacks.value = callbacks.value + [events]
            return TransportLanguageModel(transport: transports[min(index, transports.count - 1)], priorMessages: prior,
                                          events: events)
        }
        return Harness(container: container, store: store, session: ConfidentialSession(providers: store), llm: llm,
                       callbacks: callbacks)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// G1: sources, queries and the tool chip from the stopped turn land after the next turn started.
    @Test func aStoppedTurnsLateCallbacksDoNotTouchTheNextTurn() async throws {
        let h = try harness([Hangs(), Answers(after: .milliseconds(400))])
        let vm = ChatViewModel()
        var thread: ChatThread?
        vm.prompt = "first"
        vm.generate(currentThread: &thread, modelContext: h.container.mainContext, settings: AppSettings(),
                    providers: h.store, session: h.session, llm: h.llm)
        try await waitFor { h.llm.output == "partial" }
        h.llm.stop()
        try await waitFor { vm.generatingThreadID == nil }
        try #require(vm.generatingThreadID == nil)

        vm.prompt = "second"
        vm.generate(currentThread: &thread, modelContext: h.container.mainContext, settings: AppSettings(),
                    providers: h.store, session: h.session, llm: h.llm)
        try await waitFor { h.callbacks.value.count == 2 }
        let stale = try #require(h.callbacks.value.first)
        stale.onQueriesFound(["old query"])
        stale.onSourcesFound([GroundingSource(url: "https://old.example", domain: "old.example", title: "Old")])
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.llm.searchQueries.isEmpty, "the stopped turn's query reached the new turn")
        #expect(h.llm.groundingSources.isEmpty, "the stopped turn's sources reached the new turn")
        #expect(!h.llm.isExecutingTools, "the stopped turn's tool chip showed on the new turn")

        try await waitFor { vm.generatingThreadID == nil }
        try #require(vm.generatingThreadID == nil)
        let reply = try #require(thread?.sortedMessages.last)
        #expect(reply.content == "fresh")
        #expect(reply.sourcesJSON == nil, "the stopped turn's sources were saved on the new reply")
    }

    /// G2: a retry while a reply streams; the old task's end must not clear the new turn's busy flag.
    @Test func anOverlappingRetryKeepsTheNewTurnBusy() async throws {
        let h = try harness([Hangs(), Answers(after: .milliseconds(800))])
        let vm = ChatViewModel()
        var thread: ChatThread?
        vm.prompt = "question"
        vm.generate(currentThread: &thread, modelContext: h.container.mainContext, settings: AppSettings(),
                    providers: h.store, session: h.session, llm: h.llm)
        try await waitFor { h.llm.output == "partial" }
        let question = try #require(thread?.sortedMessages.first { $0.role == .user })

        vm.retry(from: question, currentThread: &thread, modelContext: h.container.mainContext, settings: AppSettings(),
                 providers: h.store, session: h.session, llm: h.llm)
        try await waitFor { h.callbacks.value.count == 2 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(vm.generatingThreadID == thread?.id, "the old turn's end cleared the new turn's busy flag")

        try await waitFor { vm.generatingThreadID == nil }
        try #require(vm.generatingThreadID == nil)
        #expect(thread?.sortedMessages.filter { $0.role == .assistant }.map(\.content) == ["fresh"])
    }
}
