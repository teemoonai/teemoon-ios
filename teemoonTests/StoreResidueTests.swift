//
//  StoreResidueTests.swift
//  teemoonTests
//
//  Android found a deleted chat's text still in its SQLite files (2026-10-19):
//  free pages and the WAL keep it until SQLite reuses them. The chats store
//  is rewritten at the next launch (StoreCompaction); the search index zeroes
//  freed pages and merges FTS segments at delete time.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@Suite("Deleted text residue", .serialized)
struct StoreResidueTests {

    static let gone = "GONEMARK-41907"
    static let kept = "KEPTMARK-22816"

    static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "residue-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Occurrences across the file and its -wal/-shm, as UTF-8, UTF-16LE and UTF-16BE.
    static func hits(_ marker: String, at url: URL) -> Int {
        let needles = [Data(marker.utf8), marker.data(using: .utf16LittleEndian)!, marker.data(using: .utf16BigEndian)!]
        return ["", "-wal", "-shm"].reduce(0) { sum, suffix in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: url.path + suffix)) else { return sum }
            var count = 0
            for needle in needles {
                var from = data.startIndex
                while let r = data.range(of: needle, in: from..<data.endIndex) { count += 1; from = r.upperBound }
            }
            return sum + count
        }
    }

    @MainActor static func container(_ url: URL) throws -> ModelContainer {
        try ModelContainer(for: Schema(versionedSchema: TeemoonSchemaV1.self),
                           migrationPlan: TeemoonMigrationPlan.self,
                           configurations: ModelConfiguration(url: url))
    }

    /// Two chats of 300 messages each; the first is deleted.
    @MainActor static func storeWithADeletedChat(_ url: URL) throws {
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 60)
        do {
            let container = try container(url)
            let context = container.mainContext
            for marker in [gone, kept] {
                let thread = ChatThread()
                context.insert(thread)
                for i in 0..<300 {
                    context.insert(Message(role: i.isMultiple(of: 2) ? .user : .assistant,
                                           content: "\(marker) \(i) \(filler)", thread: thread))
                }
            }
            try context.save()
        }
        do {
            let container = try container(url)
            let context = container.mainContext
            let doomed = try context.fetch(FetchDescriptor<ChatThread>())
                .first { $0.messages.contains { $0.content.hasPrefix(gone) } }
            ThreadDeletion.delete(try #require(doomed), in: context)
            try context.save()
        }
    }

    @Test @MainActor func theNextLaunchRewritesTheStoreWithoutTheDeletedChat() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "default.store")
        try Self.storeWithADeletedChat(url)
        #expect(Self.hits(Self.gone, at: url) > 0, "the premise: deleted text is still on disk")

        let defaults = try #require(UserDefaults(suiteName: "residue-\(UUID().uuidString)"))
        StoreCompaction.requestAfterDelete(defaults: defaults)
        let outcome = StoreCompaction.runIfPending(storeURL: url, defaults: defaults, freeBytes: { _ in .max })
        #expect(outcome == .done)
        #expect(!defaults.bool(forKey: StoreCompaction.pendingKey))
        #expect(Self.hits(Self.gone, at: url) == 0)
        #expect(Self.hits(Self.kept, at: url) >= 300)

        let reopened = try Self.container(url)
        let messages = try reopened.mainContext.fetch(FetchDescriptor<Message>())
        #expect(messages.count == 300)
        #expect(messages.allSatisfy { $0.content.hasPrefix(Self.kept) && $0.thread != nil })
    }

    /// Device gate on 49 (2026-10-21): the chat was deleted in the list, the app
    /// was killed seconds later, and the next launch still had every message.
    @Test @MainActor func aDeleteIsOnDiskBeforeAutosave() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "default.store")
        do {
            let container = try Self.container(url)
            let context = container.mainContext
            for _ in 0..<2 {
                let thread = ChatThread()
                context.insert(thread)
                context.insert(Message(role: .user, content: Self.gone, thread: thread))
            }
            try context.save()
        }
        do {
            let container = try Self.container(url)
            let threads = try container.mainContext.fetch(FetchDescriptor<ChatThread>())
            ThreadDeletion.delete(try #require(threads.first), in: container.mainContext)
        }
        do {
            let container = try Self.container(url)
            #expect(try container.mainContext.fetchCount(FetchDescriptor<ChatThread>()) == 1)
            #expect(try container.mainContext.fetchCount(FetchDescriptor<Message>()) == 1)
            try ThreadDeletion.deleteAll(in: container.mainContext)
        }
        let reopened = try Self.container(url)
        #expect(try reopened.mainContext.fetchCount(FetchDescriptor<ChatThread>()) == 0)
        #expect(try reopened.mainContext.fetchCount(FetchDescriptor<Message>()) == 0)
    }

    @Test @MainActor func tooLittleSpaceLeavesTheFileAndTheFlag() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "default.store")
        try Self.storeWithADeletedChat(url)
        let before = try Data(contentsOf: url)
        let defaults = try #require(UserDefaults(suiteName: "residue-\(UUID().uuidString)"))
        StoreCompaction.requestAfterDelete(defaults: defaults)
        let outcome = StoreCompaction.runIfPending(storeURL: url, defaults: defaults,
                                                   freeBytes: { _ in Int64(before.count) })
        #expect(outcome == .skippedForSpace)
        #expect(defaults.bool(forKey: StoreCompaction.pendingKey), "tried again next launch")
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aFileThatIsNotADatabaseIsLeftAlone() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "default.store")
        let junk = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try junk.write(to: url)
        let outcome = StoreCompaction.compact(storeURL: url, freeBytes: { _ in .max })
        guard case .failed = outcome else { Issue.record("got \(outcome)"); return }
        #expect(try Data(contentsOf: url) == junk)
    }

    @Test func nothingRunsWithoutADelete() throws {
        let defaults = try #require(UserDefaults(suiteName: "residue-\(UUID().uuidString)"))
        let missing = Self.tempDir().appending(path: "default.store")
        #expect(StoreCompaction.runIfPending(storeURL: missing, defaults: defaults) == .notPending)
    }

    @Test func theSearchIndexKeepsNoTextOfADeletedChat() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "chat-search-index.sqlite")
        let index = ChatSearchIndex(databaseURL: url)
        let goneThread = UUID(), keptThread = UUID()
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 60)
        var records: [ChatMessageRecord] = []
        for (marker, thread) in [(Self.gone, goneThread), (Self.kept, keptThread)] {
            for i in 0..<300 {
                records.append(ChatMessageRecord(messageID: UUID(), threadID: thread, role: .user,
                                                 timestamp: Date(), content: "\(marker) \(i) \(filler)"))
            }
        }
        try await index.index(records)
        try await index.remove(threadID: goneThread)
        #expect(Self.hits(Self.gone, at: url) > 0, "the premise: a plain delete leaves text behind")

        try await index.purgeDeleted()
        #expect(Self.hits(Self.gone, at: url) == 0)
        #expect(Self.hits(Self.kept, at: url) >= 300)
        let found = try await index.search(Self.kept, granularity: .messages, limit: 500)
        #expect(found.count == 300)

        try await index.removeAll()
        try await index.purgeDeleted()
        #expect(Self.hits(Self.kept, at: url) == 0, "delete all leaves nothing either")
        let after = try await index.search(Self.kept, granularity: .messages, limit: 500)
        #expect(after.isEmpty)
    }
}
