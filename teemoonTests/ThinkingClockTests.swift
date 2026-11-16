//
//  ThinkingClockTests.swift
//  teemoonTests
//
//  On the stream rig (2026-10-25) an inline-<think> reply read "thought for 4s" while streaming and
//  "thought for 7s" once saved: the header stamped the paced view's clock, and the saved row showed the whole
//  turn. Parity with Android (7f8dff3): the time is turn start → the first `</think>`, stamped where the
//  text arrives, saved with the reply; a reply that did not think keeps the whole turn. While thinking, the
//  header reads the chip's own label.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@MainActor
@Suite("Thinking clock")
struct ThinkingClockTests {

    @Test func stampsWhenTheThinkBlockClosesAndNeverAgain() {
        #expect(ThinkingClock.stamp(nil, output: "<think>still going", elapsed: 2) == nil)
        #expect(ThinkingClock.stamp(nil, output: "<think>done</think>", elapsed: 3) == 3)
        #expect(ThinkingClock.stamp(3, output: "<think>done</think> and more", elapsed: 9) == 3)
        #expect(ThinkingClock.stamp(nil, output: "no thinking here", elapsed: 5) == nil)
    }

    /// Found on Android's Pixel clips and the iOS rig (4b, with the reveal on): during the answer's 600 ms hold
    /// the closed block read "thinking... 5s" between "thinking... 4s" and "thought for 4s". A closed block is done
    /// thinking whether or not any answer is drawn yet.
    @Test func aClosedThinkBlockIsDoneBeforeAnyAnswerShows() {
        #expect(ThinkingClock.isStillThinking("<think>weighing"))
        #expect(!ThinkingClock.isStillThinking("<think>weighed</think>"))
        #expect(!ThinkingClock.isStillThinking("<think>weighed</think>\n\n"))
        #expect(!ThinkingClock.isStillThinking("no thinking"))
    }

    @Test func theSavedReplyKeepsItsThinkingTimeElseTheWholeTurn() {
        #expect(ThinkingClock.savedTime(thinking: 3, turn: 7) == 3)
        #expect(ThinkingClock.savedTime(thinking: nil, turn: 7) == 7)
    }

    @Test func theHeaderAndTheChipReadTheSameLabel() {
        #expect(ThinkingClock.liveLabel(elapsed: 0.4) == "thinking…")
        #expect(ThinkingClock.liveLabel(elapsed: 4.6) == "thinking… 4s")
        #expect(GenerationActivityChipView.label(for: .thinking, elapsed: 4.6) == ThinkingClock.liveLabel(elapsed: 4.6))
    }

    /// Through the real send: think, then answer after a pause. The saved time is the thinking, not the turn,
    /// and the next turn does not inherit it.
    @Test func aSavedReplyIsStampedWithItsThinkingTime() async throws {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ProviderStore(inMemory: true)
        let provider = Provider(name: "p", endpoint: "http://127.0.0.1:9/v1", model: "m", requiresAPIKey: false)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: Scripted(), priorMessages: prior, events: events)
        }
        let vm = ChatViewModel()
        var thread: ChatThread?
        for prompt in ["think first", "plain"] {
            vm.prompt = prompt
            vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                        providers: store, session: ConfidentialSession(providers: store), llm: llm)
            for _ in 0..<300 where vm.generatingThreadID != nil || llm.running { try await Task.sleep(for: .milliseconds(20)) }
        }
        let replies = try #require(thread?.sortedMessages.filter { $0.role == .assistant })
        try #require(replies.count == 2)
        let thought = try #require(replies[0].generatingTime)
        #expect(thought < 0.5, "saved \(thought)s: the whole turn, not the thinking")
        #expect((replies[1].generatingTime ?? 0) >= 0.5, "the plain reply keeps its whole turn")
        #expect(llm.thinkingTime == nil, "the second turn inherited the first one's thinking time")
    }

    private struct Scripted: GenerationTransport {
        func runTurn(messages: [[String: Any]], includeTools: Bool,
                     onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
            let thinks = (messages.last?["content"] as? String)?.contains("think") == true
            let head = thinks ? "<think>a short thought</think>" : ""
            onPartialContent(head)
            try await Task.sleep(for: .milliseconds(700))
            onPartialContent(head + "the answer")
            return TurnOutput(content: head + "the answer")
        }
    }
}
