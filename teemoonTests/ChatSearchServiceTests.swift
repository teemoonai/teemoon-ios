import Foundation
import SwiftData
import Testing
@testable import teemoon

/// Covers the six mutation-site hooks and the fail-open contract. The hooks are
/// an optimisation over the reconciler, but "optimisation" does not mean
/// "allowed to be wrong" — a stale index between launches is what the user
/// actually sees.
@Suite("Chat search service")
struct ChatSearchServiceTests {

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: ChatThread.self, Message.self, configurations: config)
    }

    private func makeIndexURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("service-\(UUID().uuidString).sqlite")
    }

    private func cleanUp(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    @MainActor
    private func makeService(_ url: URL) -> (ChatSearchService, ChatSearchIndex) {
        let index = ChatSearchIndex(databaseURL: url)
        return (ChatSearchService(index: index), index)
    }

    // MARK: - Hooks

    @Test @MainActor func didWrite_makesAMessageFindable() async throws {
        let url = makeIndexURL(); defer { cleanUp(url) }
        let (service, index) = makeService(url)
        let container = try makeContainer()
        let thread = ChatThread()
        container.mainContext.insert(thread)
        let message = Message(role: .user, content: "the kettle broke", thread: thread)
        container.mainContext.insert(message)

        service.didWrite(message)
        await service.drainPendingWork()

        #expect(try await index.search("kettle", granularity: .messages, limit: 10).count == 1)
    }

    @Test @MainActor func didWrite_ignoresAnOrphanedMessage() async throws {
        // No thread means no way to open the result, so it must never be indexed.
        let url = makeIndexURL(); defer { cleanUp(url) }
        let (service, index) = makeService(url)

        service.didWrite(Message(role: .user, content: "orphan kettle"))
        await service.drainPendingWork()

        #expect(try await index.indexedMessageIDs().isEmpty)
    }

    @Test @MainActor func didWrite_ignoresADetachedMessage() async throws {
        // The Siri/Shortcuts shape (site 5): a Thread never inserted into any
        // context, a Message riding on it. "Spoken and discarded" must mean
        // discarded — indexing it would persist the prompt under a thread id
        // no row can ever open.
        let url = makeIndexURL(); defer { cleanUp(url) }
        let (service, index) = makeService(url)

        let thread = ChatThread()
        service.didWrite(Message(role: .user, content: "detached kettle", thread: thread))
        await service.drainPendingWork()

        #expect(try await index.indexedMessageIDs().isEmpty)
    }

    @Test @MainActor func rehardenAfterFirstWrite_excludesTheSidecarFromBackup() async throws {
        // The sqlite is created lazily by the first index write, so a reharden
        // that runs BEFORE any write finds no file and no-ops — which is why
        // ContentView rehardens after reconcile, not before. This pins the
        // after-a-write path actually taking effect.
        let url = makeIndexURL(); defer { cleanUp(url) }
        let (service, index) = makeService(url)
        let container = try makeContainer()
        let thread = ChatThread()
        container.mainContext.insert(thread)
        let message = Message(role: .user, content: "hardened kettle", thread: thread)
        container.mainContext.insert(message)
        service.didWrite(message)
        await service.drainPendingWork() // the file exists only after this

        service.rehardenIfNeeded()

        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        withExtendedLifetime(index) {}
    }

    @Test @MainActor func hooksApplyInTheOrderTheyWereCalled() async throws {
        // THE RACE THIS QUEUE EXISTS FOR. Retry truncation writes a message and
        // then deletes it moments later; two unstructured tasks could apply
        // those in either order and leave deleted text searchable.
        let url = makeIndexURL(); defer { cleanUp(url) }
        let (service, index) = makeService(url)
        let container = try makeContainer()
        let thread = ChatThread()
        container.mainContext.insert(thread)
        let message = Message(role: .assistant, content: "retracted kettle answer", thread: thread)
        container.mainContext.insert(message)

        service.didWrite(message)
        service.didDelete(messageIDs: [message.id])
        await service.drainPendingWork()

        #expect(try await index.search("kettle", granularity: .messages, limit: 10).isEmpty)
        #expect(try await index.indexedMessageIDs().isEmpty)
    }

    @Test @MainActor func didDeleteThread_dropsThatThreadOnly() async throws {
        let url = makeIndexURL(); defer { cleanUp(url) }
        let (service, index) = makeService(url)
        let container = try makeContainer()
        let doomed = ChatThread(), kept = ChatThread()
        container.mainContext.insert(doomed)
        container.mainContext.insert(kept)
        let a = Message(role: .user, content: "kettle one", thread: doomed)
        let b = Message(role: .user, content: "kettle two", thread: kept)
        container.mainContext.insert(a)
        container.mainContext.insert(b)

        service.didWrite(a)
        service.didWrite(b)
        service.didDeleteThread(doomed.id)
        await service.drainPendingWork()

        let hits = try await index.search("kettle", granularity: .messages, limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.threadID == kept.id)
    }

    @Test @MainActor func didDeleteAllChats_leavesNothingSearchable() async throws {
        // Site 6. An index left behind here is a searchable plaintext copy of
        // everything the user just asked to be deleted.
        let url = makeIndexURL(); defer { cleanUp(url) }
        let (service, index) = makeService(url)
        let container = try makeContainer()
        let thread = ChatThread()
        container.mainContext.insert(thread)
        for text in ["one kettle", "two kettle", "three kettle"] {
            let message = Message(role: .user, content: text, thread: thread)
            container.mainContext.insert(message)
            service.didWrite(message)
        }

        service.didDeleteAllChats()
        await service.drainPendingWork()

        #expect(try await index.indexedMessageIDs().isEmpty)
        #expect(try await index.search("kettle", granularity: .messages, limit: 10).isEmpty)
    }

    // MARK: - Fail open

    @Test @MainActor func search_returnsNilWithoutAnIndex() async {
        // nil means "fall back to the in-memory filter", NOT "no matches".
        let service = ChatSearchService()
        #expect(await service.search("kettle") == nil)
    }

    @Test @MainActor func search_returnsNilBeforeTheFirstReconcile() async throws {
        // A half-built index must not answer: it would report a confidently
        // empty history while the launch reconcile is still running.
        let url = makeIndexURL(); defer { cleanUp(url) }
        let service = ChatSearchService()
        service.configure(storeURL: url.deletingLastPathComponent()
            .appendingPathComponent("default.store"), isStoredInMemoryOnly: false)
        defer { if let live = service.index as? ChatSearchIndex { cleanUp(live.databaseURL) } }

        #expect(service.index != nil)
        #expect(await service.search("kettle") == nil)
    }

    @Test @MainActor func hooksAreNoOpsWithoutAnIndex() async {
        // The --uitesting / in-memory path: every hook must be inert, not crash.
        let service = ChatSearchService()
        service.didWrite(Message(role: .user, content: "x"))
        service.didDelete(messageIDs: [UUID()])
        service.didDeleteThread(UUID())
        service.didDeleteAllChats()
        await service.drainPendingWork()
        #expect(service.index == nil)
    }

    // MARK: - Reconcile

    @Test @MainActor func reconcile_marksTheServiceReadyAndAnswersAfterwards() async throws {
        let url = makeIndexURL(); defer { cleanUp(url) }
        let (service, _) = makeService(url)
        let container = try makeContainer()
        let thread = ChatThread()
        container.mainContext.insert(thread)
        container.mainContext.insert(Message(role: .user, content: "reconciled kettle", thread: thread))
        try container.mainContext.save()

        await service.reconcile(in: container.mainContext)

        #expect(service.isReady)
        let hits = await service.search("kettle", granularity: .messages, limit: 10)
        #expect(hits?.count == 1)
    }
}
