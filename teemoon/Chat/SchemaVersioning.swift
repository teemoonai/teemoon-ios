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
//  - V1 is FROZEN. It must describe the store as it shipped on 2026-08-30
//    (Thread, Message — SavedPlace already excised). Never edit a shipped
//    version; add V2 and a stage.
//  - Prefer `.lightweight` stages; a `.custom` stage needs a device-verified
//    walk before it ships (SwiftData custom stages have OS-version quirks).
//  - A rename is a lightweight stage ONLY with `@Attribute(originalName:)`.
//  - Data backfills (e.g. a one-shot orphan sweep) belong in a stage's
//    didMigrate, not in app-launch code.
//
//  `SchemaMigrationFixtureTests` pins that a store created WITHOUT the plan
//  opens under it — the adoption itself must be a no-op.
//

import Foundation
import SwiftData

enum TeemoonSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Thread.self, Message.self] }
}

enum TeemoonMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TeemoonSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
