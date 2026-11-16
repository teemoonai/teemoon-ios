//
//  ReverifyRetryTests.swift
//  teemoonTests
//
//  reply-machine.json G6: "retry verification" waits up to 10 s and then retried the turn it was scheduled for,
//  deleting everything after that question, including a turn the user sent meanwhile. It now runs only while the
//  turn it captured is still the chat's newest.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@Suite("A re-verify retry never deletes a newer turn", .serialized)
@MainActor struct ReverifyRetryTests {

    final class Answers: GenerationTransport, @unchecked Sendable {
        func runTurn(messages: [[String: Any]], includeTools: Bool,
                     onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
            onPartialContent("newer answer")
            return TurnOutput(content: "newer answer", finish: .stop)
        }
    }

    @Test func aTurnSentDuringTheWaitCancelsTheScheduledRetry() async throws {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ProviderStore(inMemory: true)
        let provider = Provider(name: "p", endpoint: "http://127.0.0.1:9/v1", model: "m", requiresAPIKey: false)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: Answers(), priorMessages: prior, events: events)
        }
        let session = ConfidentialSession(providers: store)
        let vm = ChatViewModel()
        var thread: ChatThread?

        vm.prompt = "first"
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm)
        for _ in 0..<250 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.generatingThreadID == nil)

        let captured = vm.reverifyCapture(in: thread)
        #expect(vm.reverifyStillCurrent(captured, in: thread), "nothing newer yet: the retry may run")

        vm.prompt = "second"
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm)
        for _ in 0..<250 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.generatingThreadID == nil)

        #expect(!vm.reverifyStillCurrent(captured, in: thread), "the scheduled retry would delete the newer turn")
    }
}
