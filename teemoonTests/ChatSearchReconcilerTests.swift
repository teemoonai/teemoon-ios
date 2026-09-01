import Foundation
import SwiftData
import Testing
@testable import teemoon

/// The reconciler is what makes hooks optional, so these tests are the ones
/// that matter most: it must converge from empty, from stale, and from
/// over-full, and it must never index a message whose thread is gone.
@Suite("Chat search reconciler")
struct ChatSearchReconcilerTests {

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: ChatThread.self, Message.self, configurations: config)
    }

    private func makeIndex() -> (ChatSearchIndex, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconcile-\(UUID().uuidString).sqlite")
        return (ChatSearchIndex(databaseURL: url), url)
    }

    private func cleanUp(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    @MainActor
    @discardableResult
    private func seedThread(_ context: ModelContext, messages: [String]) -> ChatThread {
        let thread = ChatThread()
        context.insert(thread)
        for text in messages {
            context.insert(Message(role: .user, content: text, thread: thread))
        }
        try? context.save()
        return thread
    }

    // MARK: - Convergence

    @Test @MainActor func reconcile_fromEmptyIndexesEverything() async throws {
        let container = try makeContainer()
        let (index, url) = makeIndex()
        defer { cleanUp(url) }
        seedThread(container.mainContext, messages: ["alpha kettle", "beta kettle", "gamma"])

        let stats = try await ChatSearchReconciler(index: index).reconcile(in: container.mainContext)

        #expect(stats.inserted == 3)
        #expect(stats.removed == 0)
        #expect(try await index.search("kettle", granularity: .messages, limit: 10).count == 2)
    }

    @Test @MainActor func reconcile_isIdempotent() async throws {
        let container = try makeContainer()
        let (index, url) = makeIndex()
        defer { cleanUp(url) }
        seedThread(container.mainContext, messages: ["alpha", "beta"])
        let reconciler = ChatSearchReconciler(index: index)

        try await reconciler.reconcile(in: container.mainContext)
        let second = try await reconciler.reconcile(in: container.mainContext)

        // A launch that changed nothing must do nothing.
        #expect(second.isConverged)
        #expect(second.unchanged == 2)
    }

    @Test @MainActor func reconcile_dropsRowsThatAreNoLongerInTheStore() async throws {
        let container = try makeContainer()
        let (index, url) = makeIndex()
        defer { cleanUp(url) }
        let reconciler = ChatSearchReconciler(index: index)

        // An index left over-full — the shape a missed delete hook produces.
        try await index.index([
            ChatMessageRecord(messageID: UUID(), threadID: UUID(), role: .user,
                              timestamp: Date(), content: "ghost message"),
            ChatMessageRecord(messageID: UUID(), threadID: UUID(), role: .user,
                              timestamp: Date(), content: "another ghost"),
        ])
        seedThread(container.mainContext, messages: ["real message"])

        let stats = try await reconciler.reconcile(in: container.mainContext)

        #expect(stats.removed == 2)
        #expect(stats.inserted == 1)
        #expect(try await index.search("ghost", granularity: .messages, limit: 10).isEmpty)
        #expect(try await index.search("real", granularity: .messages, limit: 10).count == 1)
    }

    // MARK: - Orphans

    @Test @MainActor func reconcile_neverIndexesOrphanedMessages() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (index, url) = makeIndex()
        defer { cleanUp(url) }

        let doomed = seedThread(context, messages: ["orphan kettle"])
        seedThread(context, messages: ["kept kettle"])
        // Deleting a Thread nullifies its messages rather than cascading, so
        // "orphan kettle" is still on disk with no thread.
        context.delete(doomed)
        try context.save()

        let stats = try await ChatSearchReconciler(index: index).reconcile(in: context)

        #expect(stats.inserted == 1)
        let hits = try await index.search("kettle", granularity: .messages, limit: 10)
        #expect(hits.count == 1)
        #expect(!hits[0].snippet.contains("orphan"))
    }

    @Test @MainActor func reconcile_removesRowsForAThreadDeletedSinceLastLaunch() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (index, url) = makeIndex()
        defer { cleanUp(url) }
        let reconciler = ChatSearchReconciler(index: index)

        let doomed = seedThread(context, messages: ["first", "second"])
        try await reconciler.reconcile(in: context)
        #expect(try await index.indexedMessageIDs().count == 2)

        // The delete hook never ran — a crash, a Siri path, an older build.
        context.delete(doomed)
        try context.save()
        let stats = try await reconciler.reconcile(in: context)

        #expect(stats.removed == 2)
        #expect(try await index.indexedMessageIDs().isEmpty)
    }

    // MARK: - Content changes

    @Test @MainActor func reconcile_leavesEditedContentAloneByDesign() async throws {
        // Identity-only diffing is the deliberate trade: it cannot see an edit
        // to an existing message. Nothing in teemoon edits a stored message
        // in place — a retry DELETES the messages after it (site 3) and writes
        // new ones with new ids — so the streaming path is served by hooks, and
        // this documents the boundary rather than pretending it does not exist.
        let container = try makeContainer()
        let context = container.mainContext
        let (index, url) = makeIndex()
        defer { cleanUp(url) }
        let reconciler = ChatSearchReconciler(index: index)

        let thread = ChatThread()
        context.insert(thread)
        let message = Message(role: .assistant, content: "original wording", thread: thread)
        context.insert(message)
        try context.save()
        try await reconciler.reconcile(in: context)

        message.content = "revised wording"
        try context.save()
        let stats = try await reconciler.reconcile(in: context)

        #expect(stats.isConverged)
        #expect(try await index.search("revised", granularity: .messages, limit: 10).isEmpty)
        // The hook path (index(_:) upsert) is what covers this; see
        // ChatSearchIndexTests.index_isIdempotentForTheSameMessageID.
    }
}
