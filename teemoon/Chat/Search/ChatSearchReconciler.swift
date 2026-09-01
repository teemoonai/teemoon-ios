//
//  ChatSearchReconciler.swift
//  teemoon
//
//  Brings the FTS5 sidecar back in line with the SwiftData store.
//
//  THE RECONCILER IS AUTHORITATIVE AND HOOKS ARE ONLY AN OPTIMISATION. There
//  are six places that mutate chat data, and a hook-only design silently rots
//  on at least two of them:
//
//    1. ChatViewModel — insert Thread
//    2. ChatViewModel — insert Message
//    3. ChatViewModel — delete Messages (retry truncation)
//    4. ChatsListView.deleteThread — delete Thread
//    5. RequestLLMIntent — appends Messages from Siri/Shortcuts, and never
//       goes through `sendMessage`
//    6. ChatsSettingsView.deleteChats — bulk delete; must empty the index
//
//  A full rebuild of the reference store (7,209 indexable messages) measured
//  0.23 s cold. Correctness is that cheap — never trade it for cleverness.
//
//  ORPHANS ARE NEVER INDEXED. Deleting a Thread nullifies its messages rather
//  than cascading (pinned by `DataModelTests.threadDelete_leavesMessagesBehind‐
//  AsOrphans`), so the store accumulates messages with no thread. They stay on
//  disk and stay unsearchable: a result that cannot be opened is not a result.
//

import Foundation
import SwiftData
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "chat-search")

/// Diffs the store against the index and applies the difference.
///
/// `@MainActor` because `ModelContext` is not `Sendable` and must be touched on
/// the actor that owns it. Only values cross to the index.
@MainActor
struct ChatSearchReconciler {
    let index: any ChatSearchIndexing

    init(index: any ChatSearchIndexing) {
        self.index = index
    }

    /// Converges the index onto the store, and returns what it took.
    ///
    /// Three passes, in this order for a reason: identifiers first (cheap),
    /// then the set difference, then content for the missing rows ONLY. Fetching
    /// every message with its text would fault ~12 MB through SwiftData on
    /// launch to discover that nothing changed.
    @discardableResult
    func reconcile(in context: ModelContext) async throws -> ChatSearchReconcileStats {
        let liveIDs = try indexableMessageIDs(in: context)
        let indexedIDs = try await index.indexedMessageIDs()

        let missing = liveIDs.subtracting(indexedIDs)
        let stale = indexedIDs.subtracting(liveIDs)

        if !stale.isEmpty {
            try await index.remove(messageIDs: Array(stale))
        }
        if !missing.isEmpty {
            try await index.index(records(for: missing, in: context))
        }

        let stats = ChatSearchReconcileStats(inserted: missing.count,
                                             removed: stale.count,
                                             unchanged: liveIDs.count - missing.count)
        if !stats.isConverged {
            logger.info("chat index reconciled: +\(stats.inserted) -\(stats.removed)")
        }
        return stats
    }

    /// Ids of every message that still belongs to a thread.
    ///
    /// `propertiesToFetch` keeps `content` unfaulted — the whole point of doing
    /// identity first. The orphan filter is a predicate rather than a Swift
    /// `filter` so the store does the work.
    private func indexableMessageIDs(in context: ModelContext) throws -> Set<UUID> {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.thread != nil }
        )
        descriptor.propertiesToFetch = [\.id]
        return Set(try context.fetch(descriptor).map(\.id))
    }

    /// Snapshots the given messages into `Sendable` values.
    ///
    /// Drops anything whose thread vanished between the two fetches — that
    /// window is real (a delete can land mid-reconcile) and an orphan must not
    /// slip into the index through it.
    private func records(for ids: Set<UUID>, in context: ModelContext) throws -> [ChatMessageRecord] {
        let wanted = Array(ids)
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { wanted.contains($0.id) }
        )
        return try context.fetch(descriptor).compactMap { message in
            guard let threadID = message.thread?.id else { return nil }
            return ChatMessageRecord(messageID: message.id,
                                     threadID: threadID,
                                     role: message.role,
                                     timestamp: message.timestamp,
                                     content: message.content)
        }
    }
}
