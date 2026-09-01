//
//  ChatSearchService.swift
//  teemoon
//
//  The app's single entry point to the chat search index: owns it, hardens it,
//  reconciles it at launch, and takes the incremental hooks from the six sites
//  that mutate chat data.
//
//  HOOKS ARE BEST-EFFORT AND SILENT ON FAILURE, BY DESIGN. Every hook is a
//  detached task whose error is discarded, because `reconcile(in:)` at next
//  launch is what actually guarantees correctness (0.23 s for the whole
//  reference store). A hook that threw into the send path would risk a message
//  for the sake of an index that repairs itself.
//
//  `RequestLLMIntent` is why this is reachable as `shared`. Siri/Shortcuts
//  append messages from outside the view hierarchy, so there is no environment
//  to inject through — and that path is exactly the one a hook-only design
//  would silently lose.
//
//  NO INDEX MEANS NO SEARCH, NOT AN EMPTY SEARCH. `search(_:)` returns nil when
//  the index is unavailable so the caller can fall back to the in-memory filter.
//  Returning `[]` would state that the user's history does not contain the term,
//  which is a different — and false — claim.
//

import Foundation
import SwiftData
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "chat-search")

@MainActor
@Observable
final class ChatSearchService {
    static let shared = ChatSearchService()

    private(set) var index: (any ChatSearchIndexing)?
    /// True once a launch reconcile has finished, so the UI can tell "no
    /// matches" apart from "not indexed yet".
    private(set) var isReady = false

    init(index: (any ChatSearchIndexing)? = nil) {
        self.index = index
        self.isReady = index != nil
    }

    // MARK: - Lifecycle

    /// Creates the sidecar for a store, or deliberately does nothing.
    ///
    /// The hardening call is not optional. This file is a full second copy of
    /// every message in plaintext, so it needs the same backup exclusion and
    /// data-protection class as the store it shadows — otherwise adding search
    /// quietly undoes `hardenConversationStore`'s whole reason for existing.
    func configure(storeURL: URL, isStoredInMemoryOnly: Bool) {
        guard let url = ChatSearchIndex.sidecarURL(forStoreAt: storeURL,
                                                   isStoredInMemoryOnly: isStoredInMemoryOnly)
        else {
            index = nil
            isReady = false
            return
        }
        index = ChatSearchIndex(databaseURL: url)
        TeemoonApp.hardenConversationStore(at: url)
    }

    /// Converges the index onto the store. Safe to call on every launch.
    func reconcile(in context: ModelContext) async {
        guard let index else { return }
        do {
            let stats = try await ChatSearchReconciler(index: index).reconcile(in: context)
            isReady = true
            if !stats.isConverged {
                logger.info("chat index converged: +\(stats.inserted) -\(stats.removed)")
            }
        } catch {
            // Leave `isReady` false: the list falls back to the in-memory
            // filter rather than showing a confidently empty result.
            logger.error("chat index reconcile failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Re-hardens the sidecar. Called on the same launch path as the store's own
    /// re-harden, since the file may not have existed last time.
    func rehardenIfNeeded() {
        guard let index = index as? ChatSearchIndex else { return }
        TeemoonApp.hardenConversationStore(at: index.databaseURL)
    }

    // MARK: - Hooks (sites 1–6)

    /// Hooks run in the order they were called, one at a time.
    ///
    /// NOT a bare `Task {}` per hook, which was the first version and was wrong:
    /// unstructured tasks have no ordering guarantee, so a write immediately
    /// followed by a delete of the same message — exactly what retry truncation
    /// does — could apply in either order and leave a deleted message searchable
    /// until the next launch. Chaining costs nothing and removes the race.
    private var tail: Task<Void, Never> = Task {}

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task { @Sendable in
            await previous.value
            await work()
        }
    }

    /// Joins the hook queue. Tests only — production never needs to wait, which
    /// is the entire point of the queue being detached.
    func drainPendingWork() async { await tail.value }

    /// Sites 1, 2 and 5 — a message was written or grown. Upserts, so calling it
    /// repeatedly while a reply streams is correct and cheap.
    func didWrite(_ message: Message) {
        // `modelContext` gates out detached messages: Siri/Shortcuts (site 5)
        // builds its turn on a Thread that is never inserted, so indexing it
        // would write a "spoken and discarded" prompt into the persistent
        // sidecar under a thread id no row can open. Detached in, nothing out.
        guard let index, message.modelContext != nil,
              let threadID = message.thread?.id else { return }
        let record = ChatMessageRecord(messageID: message.id,
                                       threadID: threadID,
                                       role: message.role,
                                       timestamp: message.timestamp,
                                       content: message.content)
        enqueue { try? await index.index([record]) }
    }

    /// Site 3 — retry truncation deletes the messages after a given turn.
    func didDelete(messageIDs: [UUID]) {
        guard let index, !messageIDs.isEmpty else { return }
        enqueue { try? await index.remove(messageIDs: messageIDs) }
    }

    /// Site 4 — a thread was deleted. Its messages are nullified rather than
    /// cascaded, so they become orphans; the index must drop them either way.
    func didDeleteThread(_ threadID: UUID) {
        guard let index else { return }
        enqueue { try? await index.remove(threadID: threadID) }
    }

    /// Site 6 — "delete all chats". Empties the index outright: leaving it would
    /// keep a searchable plaintext copy of everything the user just deleted.
    func didDeleteAllChats() {
        guard let index else { return }
        enqueue { try? await index.removeAll() }
    }

    // MARK: - Query

    /// Ranked results, or nil when there is no usable index.
    ///
    /// nil is not "no matches" — see the note at the top of this file.
    func search(_ query: String,
                granularity: ChatSearchGranularity = .threads,
                limit: Int = 50) async -> [ChatSearchResult]? {
        guard let index, isReady else { return nil }
        do {
            return try await index.search(query, granularity: granularity, limit: limit)
        } catch {
            logger.error("chat search failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
