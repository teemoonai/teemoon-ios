import Foundation
import SwiftData
import Testing
@testable import teemoon

/// V3 adds `Message.statusRaw` and `Message.sentBeforeConfirmed` (the maintainer's typed yes, 2026-11-06). The fixtures
/// `schema-v1.store` and `schema-v2.store` were written by the code before V3 — the 1.0.6 bare-Schema open and
/// the V2 plan open — so these tests open real on-disk stores, not ones the new schema wrote for itself.
@Suite("Schema V3: two optional Message fields, lightweight")
struct SchemaV3MigrationTests {
    private func copyFixture(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).store")
        try FileManager.default.copyItem(at: try TestFixture.url("\(name).store"), to: url)
        return url
    }

    private func openV3(_ url: URL) throws -> ModelContainer {
        try ModelContainer(for: Schema(versionedSchema: TeemoonSchemaV3.self), migrationPlan: TeemoonMigrationPlan.self,
                           configurations: ModelConfiguration(url: url))
    }

    @Test @MainActor func a106StoreOpensUnderV3WithEveryFieldIntact() throws {
        let url = try copyFixture("schema-v1")
        let container = try openV3(url)   // held: a context outlives a released container only as a trap
        let context = container.mainContext
        let messages = try context.fetch(FetchDescriptor<Message>(sortBy: [SortDescriptor(\.content)]))
        #expect(messages.map(\.content) == ["reply from 1.0.6", "written by 1.0.6"])
        let reply = try #require(messages.first)
        #expect(reply.id == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(reply.role == .assistant && reply.isE2EE && reply.generatingTime == 1.5)
        #expect(reply.sourcesJSON == #"[{"url":"https://example.com","title":"e"}]"#)
        #expect(reply.thread?.id == UUID(uuidString: "33333333-3333-3333-3333-333333333333") && reply.thread?.title == "kept title")
        #expect(messages.allSatisfy { $0.statusRaw == nil && $0.sentBeforeConfirmed == nil }, "old rows read as complete, unmarked")
        #expect(try context.fetchCount(FetchDescriptor<ImageAttachment>()) == 0)
    }

    @Test @MainActor func aV2StoreOpensUnderV3WithItsImage() throws {
        let url = try copyFixture("schema-v2")
        let container = try openV3(url)   // held: a context outlives a released container only as a trap
        let context = container.mainContext
        let messages = try context.fetch(FetchDescriptor<Message>(sortBy: [SortDescriptor(\.content)]))
        #expect(messages.map(\.content) == ["V2 reply", "written by a V2 build"])
        #expect(messages.first?.isE2EE == true && messages.first?.thread?.title == "near.ai import")
        #expect(messages.allSatisfy { $0.statusRaw == nil && $0.sentBeforeConfirmed == nil })
        let image = try #require(try context.fetch(FetchDescriptor<ImageAttachment>()).first)
        #expect(image.messageID == UUID(uuidString: "55555555-5555-5555-5555-555555555555") && image.data.count == 2_000)
    }

    @Test @MainActor func theNewFieldsPersistAcrossReopen() throws {
        let url = try copyFixture("schema-v2")
        do {
            let container = try openV3(url)   // held: a context outlives a released container only as a trap
        let context = container.mainContext
            let reply = try #require(try context.fetch(FetchDescriptor<Message>()).first { $0.role == .assistant })
            reply.statusRaw = "interrupted"
            reply.sentBeforeConfirmed = "pending|1762450000000|abc"
            try context.save()
        }
        let reopened = try openV3(url)
        let reply = try #require(try reopened.mainContext.fetch(FetchDescriptor<Message>()).first { $0.role == .assistant })
        #expect(reply.statusRaw == "interrupted" && reply.sentBeforeConfirmed == "pending|1762450000000|abc")
    }

    /// Rollback = the previous build: a V2-only app can't open a V3 store, and the failed open leaves the
    /// file untouched, so the V3 build opens it again with the rows intact.
    @Test @MainActor func aV2BuildFailsOnAV3StoreWithoutHarmingIt() throws {
        let url = try copyFixture("schema-v2")
        do {
            let container = try openV3(url)   // held: a context outlives a released container only as a trap
        let context = container.mainContext
            try #require(try context.fetch(FetchDescriptor<Message>()).first).statusRaw = "stopped"
            try context.save()
        }
        enum V2Only: SchemaMigrationPlan {
            static var schemas: [any VersionedSchema.Type] { [TeemoonSchemaV1.self, TeemoonSchemaV2.self] }
            static var stages: [MigrationStage] { [.lightweight(fromVersion: TeemoonSchemaV1.self, toVersion: TeemoonSchemaV2.self)] }
        }
        #expect(throws: (any Error).self) {
            let c = try ModelContainer(for: Schema(versionedSchema: TeemoonSchemaV2.self), migrationPlan: V2Only.self,
                                       configurations: ModelConfiguration(url: url))
            _ = try c.mainContext.fetch(FetchDescriptor<TeemoonSchemaV2.Message>())
        }
        let reopened = try openV3(url)
        let messages = try reopened.mainContext.fetch(FetchDescriptor<Message>())
        #expect(messages.count == 2 && messages.contains { $0.statusRaw == "stopped" })
    }
}
