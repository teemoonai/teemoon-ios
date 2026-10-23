//
//  ThinkHarderKeepReplyTests.swift
//  teemoonTests
//
//  The maintainer, 2026-10-21 ("think-harder-keep-reply"): the old reply stays, dimmed,
//  until the new one shows text; a failed, stopped or interrupted Think Harder
//  leaves it as it was. Build 50 deleted and saved it before asking, so a
//  failure lost the answer.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@Suite("Think Harder keeps the reply", .serialized)
@MainActor struct ThinkHarderKeepReplyTests {

    final class Transport: GenerationTransport, @unchecked Sendable {
        enum Mode { case answer(String), fail, stall, interrupt, holdThenAnswer(String) }
        private(set) var sawCancel = false
        private(set) var lateWrites = 0
        let mode: Mode
        private(set) var sent: [[[String: Any]]] = []
        init(_ mode: Mode) { self.mode = mode }
        func runTurn(messages: [[String: Any]], includeTools: Bool,
                     onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
            sent.append(messages)
            switch mode {
            case .answer(let text): onPartialContent(text); return TurnOutput(content: text)
            case .fail: throw URLError(.timedOut)
            case .stall: try await Task.sleep(for: .seconds(3600)); return TurnOutput(content: "")
            case .interrupt: throw CancellationError()
            case .holdThenAnswer(let text):
                // A provider holding the response headers (Android 3917.7: a stop left this running).
                do { try await Task.sleep(for: .seconds(2)) } catch { sawCancel = true; throw error }
                lateWrites += 1
                onPartialContent(text)
                return TurnOutput(content: text)
            }
        }
    }

    @MainActor struct Rig {
        let container: ModelContainer
        let thread: ChatThread
        let question: Message
        let oldReply: Message
        let askedAt: Date
        let vm = ChatViewModel()
        let llm = ChatGeneration()
        let store = ProviderStore(inMemory: true)
        let settings = AppSettings()

        init(_ transport: Transport) throws {
            container = try ModelContainer(for: ChatThread.self, Message.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = container.mainContext
            thread = ChatThread()
            context.insert(thread)
            askedAt = Date(timeIntervalSince1970: 1_000)
            question = Message(role: .user, content: "why is the sky blue", thread: thread)
            question.timestamp = askedAt
            oldReply = Message(role: .assistant, content: "OLD ANSWER", thread: thread)
            oldReply.timestamp = askedAt.addingTimeInterval(5)
            context.insert(question)
            context.insert(oldReply)
            try context.save()
            let provider = Provider(name: "p", endpoint: "http://127.0.0.1:9/v1", model: "m", requiresAPIKey: false)
            store.addProvider(provider)
            store.currentProviderID = provider.id.uuidString
            llm.makeLanguageModel = { _, _, prior, _, events in
                TransportLanguageModel(transport: transport, priorMessages: prior, events: events)
            }
        }

        func thinkHarder() {
            var current: ChatThread? = thread
            vm.retry(from: question, currentThread: &current, modelContext: container.mainContext,
                     settings: settings, providers: store, session: ConfidentialSession(providers: store),
                     llm: llm, effort: .thinkHarder)
        }

        func finish() async {
            for _ in 0..<200 where vm.generatingThreadID != nil { try? await Task.sleep(for: .milliseconds(20)) }
        }

        var contents: [String] { thread.sortedMessages.map(\.content) }
    }

    @Test func aNewReplyReplacesTheOldOneInOneSave() async throws {
        let transport = Transport(.answer("NEW ANSWER"))
        let rig = try Rig(transport)
        rig.thinkHarder()
        #expect(rig.llm.superseding.isDimmed(rig.oldReply.id), "dimmed until the new reply has text")
        await rig.finish()
        #expect(rig.contents == ["why is the sky blue", "NEW ANSWER"])
        #expect(rig.question.timestamp > rig.askedAt, "restamped when the new reply lands")
        #expect(!rig.llm.superseding.isActive)
        let wire = try #require(transport.sent.first).compactMap { $0["content"] as? String }
        #expect(!wire.contains("OLD ANSWER"), "the model is never sent the reply it replaces")
    }

    @Test func aFailureKeepsTheOldReply() async throws {
        let rig = try Rig(Transport(.fail))
        rig.thinkHarder()
        await rig.finish()
        #expect(rig.llm.lastError != nil)
        #expect(rig.contents == ["why is the sky blue", "OLD ANSWER"])
        #expect(rig.question.timestamp == rig.askedAt)
        #expect(!rig.llm.superseding.isActive, "not left dimmed")
    }

    @Test func aStopKeepsTheOldReply() async throws {
        let rig = try Rig(Transport(.stall))
        rig.thinkHarder()
        try await Task.sleep(for: .milliseconds(300))
        rig.llm.stop()
        await rig.finish()
        #expect(rig.contents == ["why is the sky blue", "OLD ANSWER"])
        #expect(!rig.llm.superseding.isActive)
    }

    /// pm: a kill mid-Think-Harder must keep the old reply and must not re-ask at default effort.
    @Test func anInterruptionKeepsTheOldReplyAndIsNotReasked() async throws {
        let rig = try Rig(Transport(.interrupt))
        rig.thinkHarder()
        await rig.finish()
        #expect(rig.contents == ["why is the sky blue", "OLD ANSWER"])
        #expect(rig.vm.interruptedUserMessage(in: rig.thread, llm: rig.llm) == nil)
    }

    @Test func theTranscriptDropsTheOldReplyAtTheFirstText() {
        let a = Message(role: .user, content: "q"), b = Message(role: .assistant, content: "old")
        var s = ReplySupersession(replyIDs: [b.id])
        #expect(s.visible([a, b]).map(\.content) == ["q", "old"])
        #expect(s.history([a, b]).map(\.content) == ["q"])
        s.noteText("")
        #expect(s.isDimmed(b.id))
        s.noteText("N")
        #expect(!s.isDimmed(b.id))
        #expect(s.visible([a, b]).map(\.content) == ["q"])
        #expect(s.outcome(failed: false, cancelled: false, output: "N") == .replace([b.id]))
        #expect(s.outcome(failed: true, cancelled: false, output: "N") == .restore)
        #expect(s.outcome(failed: false, cancelled: true, output: "N") == .restore, "a stopped partial is not saved")
        #expect(ReplySupersession().outcome(failed: false, cancelled: false, output: "x") == nil)
    }

    /// Android 3917.7 / release: a stop while the provider still held the request left it running,
    /// and the late reply was drawn over the restored reply. iOS must cancel it and draw nothing.
    @Test func aStoppedThinkHarderCancelsTheRequestAndDrawsNoLateReply() async throws {
        let transport = Transport(.holdThenAnswer("LATE REPLY"))
        let rig = try Rig(transport)
        rig.thinkHarder()
        try await Task.sleep(for: .milliseconds(400))
        rig.llm.stop()
        await rig.finish()
        try await Task.sleep(for: .seconds(3))
        #expect(transport.sawCancel, "the held request was cancelled")
        #expect(transport.lateWrites == 0)
        #expect(rig.llm.output.isEmpty)
        #expect(rig.contents == ["why is the sky blue", "OLD ANSWER"])
    }

    @Test func aStoppedPlainSendCancelsTheRequestAndSavesNothing() async throws {
        let transport = Transport(.holdThenAnswer("LATE REPLY"))
        let rig = try Rig(transport)
        rig.vm.prompt = "and the sunset?"
        var current: ChatThread? = rig.thread
        rig.vm.generate(currentThread: &current, modelContext: rig.container.mainContext, settings: rig.settings,
                        providers: rig.store, session: ConfidentialSession(providers: rig.store), llm: rig.llm)
        try await Task.sleep(for: .milliseconds(400))
        rig.llm.stop()
        await rig.finish()
        try await Task.sleep(for: .seconds(3))
        #expect(transport.sawCancel)
        #expect(transport.lateWrites == 0)
        #expect(rig.llm.output.isEmpty)
        #expect(rig.contents == ["why is the sky blue", "OLD ANSWER", "and the sunset?"])
    }
}
