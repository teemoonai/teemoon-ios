//
//  SchemaVersioning.swift
//  teemoon
//
//  The migration ledger — SwiftData's Rails-migrations equivalent, adopted
//  2026-08-30. Every schema change from here on is a NEW VersionedSchema
//  snapshot plus an explicit MigrationStage between it and the previous one;
//  the container opens through the plan, so a planned change can never strand
//  the store on the fatalError cliff the schema rules fence off.
//
//  Rules of the ledger:
//  - A shipped version is FROZEN as nested copies of its models: never point it at the live
//    `Message`/`Thread`, or editing them silently edits every version and stores on disk stop
//    matching any of them. Only the newest version names the live classes.
//  - Prefer `.lightweight` stages; a `.custom` stage needs a device-verified
//    walk before it ships (SwiftData custom stages have OS-version quirks).
//  - A rename is a lightweight stage ONLY with `@Attribute(originalName:)`.
//  - Data backfills (e.g. a one-shot orphan sweep) belong in a stage's
//    didMigrate, not in app-launch code.
//
//  `SchemaMigrationFixtureTests` opens stores written by the 1.0.6 and V2 code under the plan.
//

import Foundation
import SwiftData

/// The store as 1.0.6 shipped it (Thread, Message).
enum TeemoonSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Thread.self, Message.self] }

    @Model final class Message {
        @Attribute(.unique) var id: UUID
        var role: Role
        var content: String
        var timestamp: Date
        var generatingTime: TimeInterval?
        var sourcesJSON: String? = nil
        var isE2EE: Bool = false
        @Relationship(inverse: \Thread.messages) var thread: Thread?
        init(id: UUID, role: Role, content: String, timestamp: Date) {
            self.id = id; self.role = role; self.content = content; self.timestamp = timestamp
        }
    }

    @Model final class Thread {
        @Attribute(.unique) var id: UUID
        var title: String?
        var timestamp: Date
        @Relationship var messages: [Message] = []
        init(id: UUID, timestamp: Date) { self.id = id; self.timestamp = timestamp }
    }
}

/// V1 + `ImageAttachment` (1.1.0, images; the maintainer approved 2026-10-25). Thread and Message are unchanged.
enum TeemoonSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [Thread.self, Message.self, ImageAttachment.self] }

    @Model final class Message {
        @Attribute(.unique) var id: UUID
        var role: Role
        var content: String
        var timestamp: Date
        var generatingTime: TimeInterval?
        var sourcesJSON: String? = nil
        var isE2EE: Bool = false
        @Relationship(inverse: \Thread.messages) var thread: Thread?
        init(id: UUID, role: Role, content: String, timestamp: Date) {
            self.id = id; self.role = role; self.content = content; self.timestamp = timestamp
        }
    }

    @Model final class Thread {
        @Attribute(.unique) var id: UUID
        var title: String?
        var timestamp: Date
        @Relationship var messages: [Message] = []
        init(id: UUID, timestamp: Date) { self.id = id; self.timestamp = timestamp }
    }

    @Model final class ImageAttachment {
        @Attribute(.unique) var id: UUID
        var messageID: UUID
        var index: Int
        var mimeType: String
        var width: Int
        var height: Int
        @Attribute(.externalStorage) var data: Data
        var thumbnail: Data
        init(id: UUID, messageID: UUID, index: Int, mimeType: String, width: Int, height: Int, data: Data, thumbnail: Data) {
            self.id = id; self.messageID = messageID; self.index = index; self.mimeType = mimeType
            self.width = width; self.height = height; self.data = data; self.thumbnail = thumbnail
        }
    }
}

/// V2 + two optional Message fields (1.1.0 reply machine; the maintainer's typed yes 2026-11-06): `statusRaw`
/// (nil = complete) and `sentBeforeConfirmed`. The live models.
enum TeemoonSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] { [teemoon.Thread.self, teemoon.Message.self, teemoon.ImageAttachment.self] }
}

enum TeemoonMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TeemoonSchemaV1.self, TeemoonSchemaV2.self, TeemoonSchemaV3.self] }
    /// A whole new model, then two optional columns: both lightweight, no backfill (nil reads as before).
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: TeemoonSchemaV1.self, toVersion: TeemoonSchemaV2.self),
         .lightweight(fromVersion: TeemoonSchemaV2.self, toVersion: TeemoonSchemaV3.self)]
    }
}
