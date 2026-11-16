//
//  ReplyPersistenceTests.swift
//  teemoonTests
//
//  reply-machine.json G3/G4/G5 through ChatViewModel: a reply row is written (statusRaw=interrupted) before the
//  request goes out and rewritten once with how the turn ended. Stopped, cut-short, failed and undecryptable turns
//  never read as complete replies, and the next request never carries an empty reply row.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@Suite("A reply row says how its turn ended", .serialized)
@MainActor struct ReplyPersistenceTests {

    final class Scripted: GenerationTransport, @unchecked Sendable {
        let script: @Sendable (@escaping @Sendable (String) -> Void) async throws -> TurnOutput
        let seen = LockedBox<[[[String: Any]]]>([])
        init(_ script: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> TurnOutput) {
            self.script = script
        }
        func runTurn(messages: [[String: Any]], includeTools: Bool,
                     onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
            seen.value = seen.value + [messages]
            return try await script(onPartialContent)
        }
    }

    struct Run {
        let vm: ChatViewModel
        let llm: ChatGeneration
        let container: ModelContainer
        var thread: ChatThread?
        let store: ProviderStore
        let session: ConfidentialSession
        var replies: [Message] { thread?.sortedMessages.filter { $0.role == .assistant } ?? [] }
    }

    private func start(_ transport: Scripted, endpoint: String = "http://127.0.0.1:9/v1",
                       prompt: String = "question") throws -> Run {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ProviderStore(inMemory: true)
        let provider = Provider(name: "p", endpoint: endpoint, model: "m", requiresAPIKey: false)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: transport, priorMessages: prior, events: events)
        }
        let vm = ChatViewModel()
        vm.prompt = prompt
        var thread: ChatThread?
        let session = ConfidentialSession(providers: store)
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm)
        return Run(vm: vm, llm: llm, container: container, thread: thread, store: store, session: session)
    }

    private func settle(_ run: Run) async throws {
        for _ in 0..<250 where run.vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(run.vm.generatingThreadID == nil, "the turn is still running; reading its rows now would race it")
    }

    /// G3: the row exists, reading interrupted, while the answer streams; a kill now leaves it for launch recovery.
    @Test func theReplyRowIsWrittenBeforeTheRequestAndReadsInterruptedWhileLive() async throws {
        let transport = Scripted { partial in
            partial("Half an ans")
            try await Task.sleep(for: .seconds(30))
            return TurnOutput(content: "Half an ans")
        }
        let run = try start(transport)
        for _ in 0..<250 where run.llm.output != "Half an ans" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(run.replies.map(\.statusRaw) == ["interrupted"], "no reply row while the turn was live")
        #expect(run.replies.first?.content == "")
        run.llm.stop()
        try await settle(run)
    }

    /// G3: a stop keeps what was shown, as stopped.
    @Test func aStoppedPartialIsSavedAsStopped() async throws {
        let transport = Scripted { partial in
            partial("Partial")
            try await Task.sleep(for: .seconds(30))
            return TurnOutput(content: "Partial")
        }
        let run = try start(transport)
        for _ in 0..<250 where run.llm.output != "Partial" { try await Task.sleep(for: .milliseconds(20)) }
        run.llm.stop()
        try await settle(run)
        #expect(run.replies.map(\.statusRaw) == ["stopped"])
        #expect(run.replies.map(\.content) == ["Partial"])
    }

    @Test func aCompleteReplyReadsComplete() async throws {
        let run = try start(Scripted { partial in partial("Done."); return TurnOutput(content: "Done.", finish: .stop) })
        try await settle(run)
        #expect(run.replies.map(\.statusRaw) == ["complete"])
        #expect(run.replies.map(\.content) == ["Done."])
    }

    /// G4: finish_reason length keeps the text, marked cut short.
    @Test func aLengthFinishIsCutShort() async throws {
        let run = try start(Scripted { partial in
            partial("An essay that"); return TurnOutput(content: "An essay that", finish: .length)
        })
        try await settle(run)
        #expect(run.replies.map(\.statusRaw) == ["cutOff"])
        #expect(run.replies.map(\.content) == ["An essay that"])
    }

    /// G4: a stream that closed with neither [DONE] nor a finish_reason is cut short.
    @Test func anEndWithoutDoneIsCutShort() async throws {
        let run = try start(Scripted { partial in
            partial("The answer is"); return TurnOutput(content: "The answer is", finish: .endedWithoutDone)
        })
        try await settle(run)
        #expect(run.replies.map(\.statusRaw) == ["cutOff"])
    }

    /// G5: an undecryptable sealed reply keeps no text and says so.
    @Test func aDecryptFailureKeepsNoText() async throws {
        let run = try start(Scripted { partial in
            partial("Sealed start")
            throw LLMError(source: .provider(name: "p"), userMessage: "couldn't decrypt", httpStatus: nil, url: nil,
                           requestHeaders: nil, requestBodyJSON: nil, messageHistory: nil, responseBody: nil,
                           underlyingError: E2EEError.decryptionFailed)
        })
        try await settle(run)
        #expect(run.replies.map(\.statusRaw) == ["decryptFailed"])
        #expect(run.replies.map(\.content) == [""])
    }

    /// G3: an invalid server address was saved as the reply's text.
    @Test func aConfigErrorIsAFailedTurnNotAReply() async throws {
        // Schemeless: no base URL (ProviderTests.openAIBaseURL_schemelessFails). URL(string:) accepts spaces now.
        let run = try start(Scripted { _ in TurnOutput(content: "unused") }, endpoint: "192.168.1.1:8080/v1")
        try await settle(run)
        #expect(run.replies.map(\.statusRaw) == ["failed"])
        #expect(run.replies.map(\.content) == [""], "the error string was saved as the reply")
    }

    /// G3: an empty answer is a failed turn, kept as a row (with retry), never a blank reply.
    @Test func anEmptyAnswerIsAFailedRow() async throws {
        let run = try start(Scripted { _ in TurnOutput(content: "", finish: .stop) })
        try await settle(run)
        #expect(run.replies.map(\.statusRaw) == ["failed"])
    }

    /// The next request never carries an empty reply row (a failed turn's, or the live one).
    @Test func theNextRequestSkipsEmptyReplyRows() async throws {
        let answers = LockedBox(0)
        let transport = Scripted { partial in
            answers.value += 1
            if answers.value == 1 { return TurnOutput(content: "", finish: .stop) }
            partial("Second"); return TurnOutput(content: "Second", finish: .stop)
        }
        var run = try start(transport)
        try await settle(run)
        run.vm.prompt = "again"
        run.vm.generate(currentThread: &run.thread, modelContext: run.container.mainContext, settings: AppSettings(),
                        providers: run.store, session: run.session, llm: run.llm)
        try await settle(run)
        let second = try #require(transport.seen.value.last)
        let emptyAssistant = second.filter {
            $0["role"] as? String == "assistant" && (($0["content"] as? String) ?? "x").isEmpty
        }
        #expect(emptyAssistant.isEmpty, "an empty reply row went out as history")
        #expect(second.last?["role"] as? String == "user")
    }
}
