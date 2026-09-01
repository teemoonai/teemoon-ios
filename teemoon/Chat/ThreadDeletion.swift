//
//  ThreadDeletion.swift
//  teemoon
//
//  Delete means delete. `Thread.messages` carries no cascade rule — adding
//  one is a schema change on the type that holds every conversation, which
//  costs a new VersionedSchema and a stage — so the cascade
//  lives HERE, at the application layer, where it is testable and
//  migration-free. Before this type existed, deleting a thread nullified its
//  messages into invisible orphans: 915 of 8,124 messages (11.3%) on the
//  reference store. `DataModelTests` pins both the raw SwiftData behavior
//  (still .nullify — deliberately unchanged) and this type's contract.
//
//  Search-index hooks stay at the CALL SITES (`ChatSearchService` is
//  MainActor UI plumbing; this type is pure store mutation). When a model
//  gains references to Thread (the parked save-places feature had one),
//  clearing them belongs here too.
//

import Foundation
import SwiftData

enum ThreadDeletion {

    /// Deletes a thread AND its messages.
    static func delete(_ thread: Thread, in context: ModelContext) {
        for message in thread.messages {
            context.delete(message)
        }
        context.delete(thread)
    }

    /// The "delete all chats" cascade: every thread, every message — the
    /// second sweep exists because bulk thread deletion nullifies exactly
    /// like single deletion.
    static func deleteAll(in context: ModelContext) throws {
        try context.delete(model: Thread.self)
        try context.delete(model: Message.self)
    }
}
