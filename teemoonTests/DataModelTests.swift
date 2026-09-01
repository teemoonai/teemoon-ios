import Foundation
import SwiftData
import Testing
@testable import teemoon

@Suite("SwiftData models")
struct DataModelTests {

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: ChatThread.self, Message.self, configurations: config)
    }

    // MARK: - Message

    @Test @MainActor func message_initSetsDefaults() {
        let message = Message(role: .user, content: "Hello")
        #expect(message.role == .user)
        #expect(message.content == "Hello")
        #expect(message.generatingTime == nil)
        #expect(message.sourcesJSON == nil)
        #expect(message.isE2EE == false)
    }

    @Test @MainActor func message_e2eeFlag() {
        let message = Message(role: .assistant, content: "Hi", isE2EE: true)
        #expect(message.isE2EE == true)
    }

    @Test @MainActor func message_groundingSources_empty() {
        let message = Message(role: .assistant, content: "No sources")
        #expect(message.groundingSources.isEmpty)
    }

    @Test @MainActor func message_groundingSources_parsesJSON() throws {
        let sources = [GroundingSource(url: "https://test.com", domain: "test.com", title: "Test")]
        let json = String(data: try JSONEncoder().encode(sources), encoding: .utf8)
        let message = Message(role: .assistant, content: "With sources", sourcesJSON: json)
        #expect(message.groundingSources.count == 1)
        #expect(message.groundingSources[0].url == "https://test.com")
    }

    @Test @MainActor func message_groundingSources_invalidJSON_returnsEmpty() {
        let message = Message(role: .assistant, content: "Bad JSON", sourcesJSON: "not json")
        #expect(message.groundingSources.isEmpty)
    }

    @Test @MainActor func message_groundingSources_cachesResult() throws {
        let sources = [GroundingSource(url: "https://test.com", domain: "test.com", title: "Test")]
        let json = String(data: try JSONEncoder().encode(sources), encoding: .utf8)
        let message = Message(role: .assistant, content: "test", sourcesJSON: json)
        let first = message.groundingSources
        let second = message.groundingSources
        #expect(first.count == second.count)
    }

    // MARK: - Thread

    @Test @MainActor func thread_initGeneratesUniqueID() {
        let t1 = ChatThread()
        let t2 = ChatThread()
        #expect(t1.id != t2.id)
    }

    @Test @MainActor func thread_sortedMessages_ordersByTimestamp() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let thread = ChatThread()
        context.insert(thread)

        let m1 = Message(role: .user, content: "First", thread: thread)
        m1.timestamp = Date(timeIntervalSince1970: 100)
        context.insert(m1)

        let m2 = Message(role: .assistant, content: "Second", thread: thread)
        m2.timestamp = Date(timeIntervalSince1970: 200)
        context.insert(m2)

        let m3 = Message(role: .user, content: "Third", thread: thread)
        m3.timestamp = Date(timeIntervalSince1970: 150)
        context.insert(m3)

        try context.save()

        let sorted = thread.sortedMessages
        #expect(sorted.count == 3)
        #expect(sorted[0].content == "First")
        #expect(sorted[1].content == "Third")
        #expect(sorted[2].content == "Second")
    }

    @Test @MainActor func thread_invalidateSortedMessages_clearsCacheAndResorts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let thread = ChatThread()
        context.insert(thread)

        let m1 = Message(role: .user, content: "A", thread: thread)
        context.insert(m1)
        try context.save()

        _ = thread.sortedMessages // populate cache

        let m2 = Message(role: .assistant, content: "B", thread: thread)
        context.insert(m2)
        try context.save()

        thread.invalidateSortedMessages()
        let sorted = thread.sortedMessages
        #expect(sorted.count == 2)
    }

    // MARK: - Role

    @Test func role_rawValues() {
        #expect(Role.assistant.rawValue == "assistant")
        #expect(Role.user.rawValue == "user")
        #expect(Role.system.rawValue == "system")
    }

    @Test func role_codable_roundtrip() throws {
        let data = try JSONEncoder().encode(Role.assistant)
        let decoded = try JSONDecoder().decode(Role.self, from: data)
        #expect(decoded == .assistant)
    }

    // MARK: - Persistence roundtrip

    @Test @MainActor func message_persistenceRoundtrip() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let thread = ChatThread()
        context.insert(thread)
        let msg = Message(role: .user, content: "Persist me", thread: thread, isE2EE: true)
        context.insert(msg)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Message>())
        #expect(fetched.count == 1)
        #expect(fetched[0].content == "Persist me")
        #expect(fetched[0].isE2EE == true)
        #expect(fetched[0].thread?.id == thread.id)
    }

    // MARK: - Thread delete rule

    // `Thread.messages` carries no delete rule, so the default applies. These two
    // tests record which one it actually is: the chat search index keys off
    // `Message.thread` to decide what is indexable, and an orphaned message is
    // invisible to search forever. Do not change the relationship without
    // re-running these.
    //
    // The APP no longer takes this path bare — `ThreadDeletion` cascades at the
    // application layer (tests below) — but the raw rule is deliberately
    // unchanged (a rule change is a migration hazard) and these keep recording
    // what a bare delete does.

    @Test @MainActor func threadDelete_leavesMessagesBehindAsOrphans() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let thread = ChatThread()
        context.insert(thread)
        for text in ["first", "second", "third"] {
            context.insert(Message(role: .user, content: text, thread: thread))
        }
        try context.save()

        context.delete(thread)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ChatThread>()).isEmpty)
        let surviving = try context.fetch(FetchDescriptor<Message>())
        #expect(surviving.count == 3)
        #expect(surviving.allSatisfy { $0.thread == nil })
    }

    @Test @MainActor func bulkThreadDelete_alsoLeavesMessagesBehind() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let thread = ChatThread()
        context.insert(thread)
        context.insert(Message(role: .user, content: "kept?", thread: thread))
        try context.save()

        // The shape of `ChatsSettingsView.deleteChats()`, minus its second sweep.
        try context.delete(model: ChatThread.self)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ChatThread>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Message>()).count == 1)
    }

    // MARK: - App-level cascade (ThreadDeletion)

    @Test @MainActor func threadDeletion_deletesItsMessages() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let doomed = ChatThread(); context.insert(doomed)
        let kept = ChatThread(); context.insert(kept)
        context.insert(Message(role: .user, content: "going", thread: doomed))
        context.insert(Message(role: .assistant, content: "also going", thread: doomed))
        context.insert(Message(role: .user, content: "staying", thread: kept))
        try context.save()

        ThreadDeletion.delete(doomed, in: context)
        try context.save()

        let messages = try context.fetch(FetchDescriptor<Message>())
        #expect(messages.count == 1, "delete means delete — no orphans")
        #expect(messages.first?.content == "staying")
    }

    @Test @MainActor func threadDeletion_deleteAllSweepsThreadsAndMessages() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let thread = ChatThread(); context.insert(thread)
        context.insert(Message(role: .user, content: "gone", thread: thread))
        try context.save()

        try ThreadDeletion.deleteAll(in: context)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ChatThread>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Message>()).isEmpty)
    }
}
