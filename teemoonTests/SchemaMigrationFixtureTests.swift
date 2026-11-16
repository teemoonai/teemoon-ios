import Foundation
import SwiftData
import Testing
@testable import teemoon

/// Adopting the migration plan must be invisible: a store created the way
/// every existing install created it — bare Schema, no plan — has to open
/// under the plan with its rows intact. This is the one risk in adoption
/// (a V1 that mismatches the live schema would read as a migration), so it
/// is pinned against an actual on-disk store, not an in-memory one.
@Suite("Schema migration plan adoption")
struct SchemaMigrationFixtureTests {

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-fixture-\(UUID().uuidString).store")
    }

    private func cleanUp(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    @Test @MainActor func aPrePlanStoreOpensUnderThePlanWithDataIntact() throws {
        let url = tempStoreURL(); defer { cleanUp(url) }

        // 1. The world before the plan: bare Schema, on disk.
        do {
            let container = try ModelContainer(
                for: Schema([TeemoonSchemaV1.Thread.self, TeemoonSchemaV1.Message.self]),
                configurations: ModelConfiguration(url: url))
            let context = container.mainContext
            let thread = TeemoonSchemaV1.Thread(id: UUID(), timestamp: Date())
            context.insert(thread)
            let message = TeemoonSchemaV1.Message(id: UUID(), role: .user, content: "pre-plan message", timestamp: Date())
            message.thread = thread
            context.insert(message)
            try context.save()
        }

        // 2. The world after: same store, opened through the versioned plan —
        //    exactly what every existing install does on first launch after
        //    adoption.
        let container = try ModelContainer(
            for: Schema(versionedSchema: TeemoonSchemaV3.self),
            migrationPlan: TeemoonMigrationPlan.self,
            configurations: ModelConfiguration(url: url))
        let context = container.mainContext

        let threads = try context.fetch(FetchDescriptor<ChatThread>())
        let messages = try context.fetch(FetchDescriptor<Message>())
        #expect(threads.count == 1)
        #expect(messages.count == 1)
        #expect(messages.first?.content == "pre-plan message")
        #expect(messages.first?.thread?.id == threads.first?.id)
    }

    @Test @MainActor func thePlanRoundTripsItsOwnStore() throws {
        // Create WITH the plan, reopen WITH the plan — the steady state.
        let url = tempStoreURL(); defer { cleanUp(url) }

        do {
            let container = try ModelContainer(
                for: Schema(versionedSchema: TeemoonSchemaV3.self),
                migrationPlan: TeemoonMigrationPlan.self,
                configurations: ModelConfiguration(url: url))
            let context = container.mainContext
            let thread = ChatThread()
            context.insert(thread)
            context.insert(Message(role: .assistant, content: "steady state",
                                   thread: thread))
            try context.save()
        }

        let container = try ModelContainer(
            for: Schema(versionedSchema: TeemoonSchemaV3.self),
            migrationPlan: TeemoonMigrationPlan.self,
            configurations: ModelConfiguration(url: url))
        #expect(try container.mainContext.fetch(FetchDescriptor<Message>())
            .first?.content == "steady state")
    }

    /// A V1 store made from the frozen V1 models opens under the live plan intact (the file-based twin is
    /// SchemaV3MigrationTests, which opens stores written by the 1.0.6 and V2 code themselves).
    @Test @MainActor func aV1StoreOpensUnderTheLivePlanIntact() throws {
        let url = tempStoreURL(); defer { cleanUp(url) }
        let messageID = UUID()
        do {
            let container = try ModelContainer(
                for: Schema(versionedSchema: TeemoonSchemaV1.self),
                configurations: ModelConfiguration(url: url))
            let context = container.mainContext
            let thread = TeemoonSchemaV1.Thread(id: UUID(), timestamp: Date())
            thread.title = "kept title"
            context.insert(thread)
            let message = TeemoonSchemaV1.Message(id: messageID, role: .user, content: "written by 1.0.6", timestamp: Date())
            message.thread = thread
            message.isE2EE = true
            context.insert(message)
            try context.save()
        }
        let container = try ModelContainer(
            for: Schema(versionedSchema: TeemoonSchemaV3.self),
            migrationPlan: TeemoonMigrationPlan.self,
            configurations: ModelConfiguration(url: url))
        let message = try #require(try container.mainContext.fetch(FetchDescriptor<Message>()).first)
        #expect(message.id == messageID && message.content == "written by 1.0.6" && message.isE2EE)
        #expect(message.thread?.title == "kept title" && message.statusRaw == nil)
    }
}
