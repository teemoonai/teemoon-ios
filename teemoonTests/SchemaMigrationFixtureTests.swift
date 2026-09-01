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
                for: Schema([Thread.self, Message.self]),
                configurations: ModelConfiguration(url: url))
            let context = container.mainContext
            let thread = ChatThread()
            context.insert(thread)
            context.insert(Message(role: .user, content: "pre-plan message",
                                   thread: thread))
            try context.save()
        }

        // 2. The world after: same store, opened through the versioned plan —
        //    exactly what every existing install does on first launch after
        //    adoption.
        let container = try ModelContainer(
            for: Schema(versionedSchema: TeemoonSchemaV1.self),
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
                for: Schema(versionedSchema: TeemoonSchemaV1.self),
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
            for: Schema(versionedSchema: TeemoonSchemaV1.self),
            migrationPlan: TeemoonMigrationPlan.self,
            configurations: ModelConfiguration(url: url))
        #expect(try container.mainContext.fetch(FetchDescriptor<Message>())
            .first?.content == "steady state")
    }
}
