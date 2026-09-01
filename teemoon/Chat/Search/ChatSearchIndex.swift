//
//  ChatSearchIndex.swift
//  teemoon
//
//  Full-text search over stored chat messages, backed by an FTS5 sidecar
//  database beside the SwiftData store.
//
//  Five traps this type exists to hold shut. Each one has a test.
//
//  - THE SIDECAR IS NEVER INSIDE `default.store`. SwiftData owns that schema
//    and drops entities it does not recognise — proven when a main build over
//    the wiki build dropped `ZWIKIPAGE`/`ZWIKISOURCE`. The index is a separate
//    file, derived from the same `ModelConfiguration.url`.
//  - NO SIDECAR FOR AN IN-MEMORY STORE. A `--uitesting` run must not leave a
//    persistent index of whatever store it opened behind on disk.
//  - USER TEXT IS NOT FTS5 SYNTAX. Raw `c++` throws `fts5: syntax error near
//    "+"`. Everything the user types goes through `matchExpression(for:)`.
//  - KEYS ARE `Message.id` / `Thread.id` UUID STRINGS, never `Z_PK`, which is
//    private to Core Data and unstable across migrations.
//  - THE SNIPPET DELIMITERS CANNOT COLLIDE, because indexing strips them from
//    the content first. They are not "characters unlikely to appear" — after
//    `sanitizeForStorage`, they cannot appear.
//
//  The caller owns the privacy consequence: this file holds a full second copy
//  of every message in plaintext, so whoever creates it must also call
//  `TeemoonApp.hardenConversationStore(at:)` on `databaseURL`.
//

import Foundation
import SQLite3
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "chat-search")

/// sqlite wants to know whether it may keep the pointer we bind. It may not —
/// Swift's `String` buffers do not outlive the call.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Values crossing the actor boundary

/// A message flattened into a `Sendable` value.
///
/// `Message` is a SwiftData `@Model`: not `Sendable`, and touching it off its
/// context faults the store on whatever thread asked. Snapshot on the main
/// actor, hand the values over.
struct ChatMessageRecord: Sendable, Equatable {
    let messageID: UUID
    let threadID: UUID
    let role: Role
    let timestamp: Date
    let content: String

    init(messageID: UUID, threadID: UUID, role: Role, timestamp: Date, content: String) {
        self.messageID = messageID
        self.threadID = threadID
        self.role = role
        self.timestamp = timestamp
        self.content = content
    }
}

/// What granularity a search answers at.
///
/// Both modes run the SAME match, ranking and snippet — only the terminal
/// grouping differs, and that grouping happens in Swift because FTS5 will not
/// allow it in SQL (see `threadOverFetch(for:)`). The list UI shows one card
/// per conversation; the model tool wants the passages themselves, because
/// "when did I decide X" is answered by a sentence and not by a conversation.
/// Do not fork the query builder to add a third.
enum ChatSearchGranularity: Sendable {
    /// One row per thread: its single best-matching message.
    case threads
    /// One row per matching message.
    case messages
}

/// How a query's tokens combine.
///
/// `.allTerms` is the list UI's mode: every token is a conjunct, so results
/// narrow as the user types. `.anyTerm` is the RECALL mode for the model
/// tool's second pass: every token prefixed and OR'd, ranked by bm25. A model
/// queries in concept words — measured live, GLM asked for "grocery list
/// recommendations store" — and under AND semantics each extra word is one
/// more reason to return nothing ("grocery" alone cannot even find
/// "groceries" without the prefix star).
enum ChatSearchMatchMode: Sendable {
    case allTerms
    case anyTerm
}

/// One hit. Carries full provenance even though the thread-list card renders
/// only the title and snippet — the model tool and the (parked) scroll-to-
/// message deep link both need the message identity, and backfilling it later
/// would mean rewriting every call site.
struct ChatSearchResult: Sendable, Equatable, Identifiable {
    let messageID: UUID
    let threadID: UUID
    let role: Role
    let timestamp: Date
    /// The matching passage, with `ChatSearchIndex.highlightOpen`/`highlightClose`
    /// wrapped around the matched terms.
    let snippet: String

    var id: UUID { messageID }
}

/// What a reconcile changed. Returned rather than logged so a test can assert
/// convergence instead of asserting on log output.
struct ChatSearchReconcileStats: Sendable, Equatable {
    var inserted: Int = 0
    var removed: Int = 0
    var unchanged: Int = 0

    var isConverged: Bool { inserted == 0 && removed == 0 }
}

enum ChatSearchIndexError: Error, CustomStringConvertible {
    case cannotOpen(path: String, code: Int32, message: String)
    case sqlite(operation: String, code: Int32, message: String)

    var description: String {
        switch self {
        case let .cannotOpen(path, code, message):
            return "could not open chat index at \(path): sqlite \(code) — \(message)"
        case let .sqlite(operation, code, message):
            return "chat index \(operation) failed: sqlite \(code) — \(message)"
        }
    }
}

// MARK: - Seam

/// The seam tests stub. Production is `ChatSearchIndex`.
protocol ChatSearchIndexing: Sendable {
    func index(_ records: [ChatMessageRecord]) async throws
    func remove(messageIDs: [UUID]) async throws
    func remove(threadID: UUID) async throws
    func removeAll() async throws
    func indexedMessageIDs() async throws -> Set<UUID>
    /// `since` and `excludingThread` are applied IN SQL, before `limit`.
    /// Filtering rank-ordered rows after an over-fetch is not equivalent: a
    /// common term with a deep history fills any fixed window with rows the
    /// filter then discards, and the caller reads that as "no matches".
    func search(_ query: String,
                granularity: ChatSearchGranularity,
                limit: Int,
                since: Date?,
                excludingThread: UUID?,
                mode: ChatSearchMatchMode) async throws -> [ChatSearchResult]
    /// The stored message directly after `timestamp` in a thread, or nil at
    /// the thread's end. Exists because bm25 finds the message that SHARES the
    /// query's words — usually the question — while the answer beside it
    /// rarely repeats them (measured: a grocery list matched on nothing).
    func following(threadID: UUID, after timestamp: Date) async throws -> ChatSearchResult?
    /// Content-led rows around `timestamp` in a thread, ascending: the row AT
    /// `timestamp`, up to `before` messages preceding it and `after` following.
    /// `(0,0)` is "this message, whole". Rows carry FULL stored content in
    /// `snippet` (callers cap) — the 18-token FTS snippet is the list UI's;
    /// a model reconstructing a discussion needs the words, and measured live
    /// the words it needed (a comparison table) never fit the window.
    func window(threadID: UUID, around timestamp: Date,
                before: Int, after: Int) async throws -> [ChatSearchResult]
}

extension ChatSearchIndexing {
    func search(_ query: String,
                granularity: ChatSearchGranularity,
                limit: Int) async throws -> [ChatSearchResult] {
        try await search(query, granularity: granularity, limit: limit,
                         since: nil, excludingThread: nil, mode: .allTerms)
    }

    func search(_ query: String,
                granularity: ChatSearchGranularity,
                limit: Int,
                since: Date?,
                excludingThread: UUID?) async throws -> [ChatSearchResult] {
        try await search(query, granularity: granularity, limit: limit,
                         since: since, excludingThread: excludingThread, mode: .allTerms)
    }
}

// MARK: - The index

/// Owns the sqlite handle for the FTS5 sidecar.
///
/// An actor because two callers race for it by construction: the launch
/// reconcile walks the whole store while the search field queries on every
/// keystroke. Queries cost ~1 ms on the reference store (8,124 messages), so
/// the serialisation is about keeping SwiftData and the main thread out of
/// sqlite, not about contention.
actor ChatSearchIndex: ChatSearchIndexing {

    /// Wrapped around matched terms by `snippet()`.
    ///
    /// U+0001/U+0002 rather than anything printable: the same string is parsed
    /// into `AttributedString` ranges for the list card AND embedded in the XML
    /// envelope handed to a model, and any delimiter that survives in message
    /// text breaks one or the other. `sanitizeForStorage` removes them from
    /// content on the way in, so a collision is impossible rather than unlikely.
    static let highlightOpen = "\u{1}"
    static let highlightClose = "\u{2}"

    /// Bumping this DROPS and recreates the tables on next open — the sidecar
    /// is derived data, so a tokenizer change is a rebuild, never a migration;
    /// the launch reconcile refills it. v2: porter stemming.
    private static let schemaVersion: Int32 = 2

    /// `nonisolated` because the hardening call needs the path from the main
    /// actor, and an immutable `Sendable` constant has nothing to protect.
    nonisolated let databaseURL: URL
    private var db: OpaquePointer?

    /// The sidecar that belongs to `storeURL`, or nil when there must not be one.
    ///
    /// Returns nil for an in-memory store: `ModelConfiguration.url` still hands
    /// back a file URL for one, so a caller that trusts it blindly writes a
    /// real index for a store that does not exist.
    static func sidecarURL(forStoreAt storeURL: URL, isStoredInMemoryOnly: Bool) -> URL? {
        guard !isStoredInMemoryOnly else { return nil }
        return storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("chat-search-index.sqlite")
    }

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Open / schema

    private func handle() throws -> OpaquePointer {
        if let db { return db }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard code == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw ChatSearchIndexError.cannotOpen(path: databaseURL.path, code: code, message: message)
        }
        db = opened
        try createSchema(opened)
        return opened
    }

    private func createSchema(_ db: OpaquePointer) throws {
        // A sidecar built by an older schema is DROPPED, not migrated: the
        // tables carry a tokenizer, `IF NOT EXISTS` would silently keep the
        // old one, and this file is derived data the reconcile refills.
        // Finalized IMMEDIATELY, not deferred: a stepped statement holds an
        // implicit read transaction, and `journal_mode = WAL` below refuses to
        // run inside one ("cannot change into wal mode from within a
        // transaction" — which took the whole schema with it, measured as 39
        // failing tests that were briefly misattributed to the tokenizer).
        var current: Int32 = 0
        let versionStmt = try prepare(db, "PRAGMA user_version")
        if sqlite3_step(versionStmt) == SQLITE_ROW { current = sqlite3_column_int(versionStmt, 0) }
        sqlite3_finalize(versionStmt)
        if current != 0, current != Self.schemaVersion {
            try exec(db, "DROP TABLE IF EXISTS messages; DROP TABLE IF EXISTS docs;",
                     operation: "schema rebuild")
        }

        // `porter unicode61 remove_diacritics 2`: porter measured its way in —
        // GLM live queried "grocery items" against a history that says
        // "groceries" and got nothing, twice, because "grocery" is not a
        // PREFIX of "groceries" (y→ies); stemming folds both to "groceri".
        // Not trigram: trigram costs 50 MB against 5 MB on the reference
        // store — 6× — to serve the 189 messages that contain CJK. Revisit
        // only with a measurement, not a hunch.
        //
        // Regular FTS5, not contentless: contentless cannot do snippet(), and
        // the snippet IS the feature. The price is ~12 MB of duplicated text.
        try exec(db, """
            PRAGMA journal_mode = WAL;
            CREATE VIRTUAL TABLE IF NOT EXISTS messages USING fts5(
                content,
                message_id UNINDEXED,
                thread_id UNINDEXED,
                role UNINDEXED,
                ts UNINDEXED,
                tokenize = 'porter unicode61 remove_diacritics 2'
            );
            CREATE TABLE IF NOT EXISTS docs(
                message_id TEXT PRIMARY KEY,
                rowid_ref INTEGER NOT NULL,
                thread_id TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS docs_thread ON docs(thread_id);
            """, operation: "create schema")
        sqlite3_exec(db, "PRAGMA user_version = \(Self.schemaVersion)", nil, nil, nil)
    }

    // MARK: Writes

    func index(_ records: [ChatMessageRecord]) async throws {
        guard !records.isEmpty else { return }
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE", operation: "begin")
        do {
            for record in records { try upsert(record, db: db) }
            try exec(db, "COMMIT", operation: "commit")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func upsert(_ record: ChatMessageRecord, db: OpaquePointer) throws {
        try deleteRows(messageIDs: [record.messageID], db: db)

        let insert = try prepare(db, """
            INSERT INTO messages(content, message_id, thread_id, role, ts)
            VALUES(?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(insert) }
        bind(insert, 1, Self.sanitizeForStorage(record.content))
        bind(insert, 2, record.messageID.uuidString)
        bind(insert, 3, record.threadID.uuidString)
        bind(insert, 4, record.role.rawValue)
        sqlite3_bind_double(insert, 5, record.timestamp.timeIntervalSince1970)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw sqliteError(db, "insert message") }

        let rowid = sqlite3_last_insert_rowid(db)
        let map = try prepare(db, "INSERT INTO docs(message_id, rowid_ref, thread_id) VALUES(?, ?, ?)")
        defer { sqlite3_finalize(map) }
        bind(map, 1, record.messageID.uuidString)
        sqlite3_bind_int64(map, 2, rowid)
        bind(map, 3, record.threadID.uuidString)
        guard sqlite3_step(map) == SQLITE_DONE else { throw sqliteError(db, "insert doc") }
    }

    func remove(messageIDs: [UUID]) async throws {
        guard !messageIDs.isEmpty else { return }
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE", operation: "begin")
        do {
            try deleteRows(messageIDs: messageIDs, db: db)
            try exec(db, "COMMIT", operation: "commit")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func deleteRows(messageIDs: [UUID], db: OpaquePointer) throws {
        for id in messageIDs {
            let lookup = try prepare(db, "SELECT rowid_ref FROM docs WHERE message_id = ?")
            defer { sqlite3_finalize(lookup) }
            bind(lookup, 1, id.uuidString)
            guard sqlite3_step(lookup) == SQLITE_ROW else { continue }
            let rowid = sqlite3_column_int64(lookup, 0)

            let drop = try prepare(db, "DELETE FROM messages WHERE rowid = ?")
            defer { sqlite3_finalize(drop) }
            sqlite3_bind_int64(drop, 1, rowid)
            guard sqlite3_step(drop) == SQLITE_DONE else { throw sqliteError(db, "delete message") }

            let unmap = try prepare(db, "DELETE FROM docs WHERE message_id = ?")
            defer { sqlite3_finalize(unmap) }
            bind(unmap, 1, id.uuidString)
            guard sqlite3_step(unmap) == SQLITE_DONE else { throw sqliteError(db, "delete doc") }
        }
    }

    /// Drops every row for a thread. Indexed by `docs_thread`, so this stays
    /// cheap on the delete path where the user is watching a row animate away.
    func remove(threadID: UUID) async throws {
        let db = try handle()
        let lookup = try prepare(db, "SELECT message_id FROM docs WHERE thread_id = ?")
        defer { sqlite3_finalize(lookup) }
        bind(lookup, 1, threadID.uuidString)
        var ids: [UUID] = []
        while sqlite3_step(lookup) == SQLITE_ROW {
            if let raw = sqlite3_column_text(lookup, 0),
               let id = UUID(uuidString: String(cString: raw)) {
                ids.append(id)
            }
        }
        try await remove(messageIDs: ids)
    }

    /// Empties the index. `ChatsSettingsView.deleteChats()` must reach this, or
    /// "delete all chats" leaves a searchable plaintext copy of every one.
    func removeAll() async throws {
        let db = try handle()
        try exec(db, "DELETE FROM messages; DELETE FROM docs;", operation: "remove all")
    }

    // MARK: Reads

    func indexedMessageIDs() async throws -> Set<UUID> {
        let db = try handle()
        let statement = try prepare(db, "SELECT message_id FROM docs")
        defer { sqlite3_finalize(statement) }
        var ids: Set<UUID> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0),
               let id = UUID(uuidString: String(cString: raw)) {
                ids.insert(id)
            }
        }
        return ids
    }

    func search(_ query: String,
                granularity: ChatSearchGranularity = .threads,
                limit: Int = 50,
                since: Date? = nil,
                excludingThread: UUID? = nil,
                mode: ChatSearchMatchMode = .allTerms) async throws -> [ChatSearchResult] {
        guard let match = Self.matchExpression(for: query, mode: mode), limit > 0 else { return [] }
        let ranked = try rankedRows(match: match,
                                    limit: granularity == .threads
                                        ? Self.threadOverFetch(for: limit)
                                        : limit,
                                    since: since,
                                    excludingThread: excludingThread)
        switch granularity {
        case .messages:
            return Array(ranked.prefix(limit))
        case .threads:
            // Rows arrive in rank order, so a thread's first appearance IS its
            // best message — the same row `min(bm25)` would have chosen.
            var seen: Set<UUID> = []
            var best: [ChatSearchResult] = []
            for row in ranked where seen.insert(row.threadID).inserted {
                best.append(row)
                if best.count == limit { break }
            }
            return best
        }
    }

    /// How many message rows to pull before collapsing to threads.
    ///
    /// The collapse cannot happen in SQL: FTS5 refuses its auxiliary functions
    /// outside a direct query on the table — `SELECT …, min(rank) FROM (SELECT
    /// …, bm25(messages) AS rank …) GROUP BY thread_id` fails at step with
    /// "unable to use function bm25 in the requested context". So the grouping
    /// is done here, and this over-fetch is what pays for it: one very chatty
    /// thread could otherwise fill the window and hide the others. Bounded so a
    /// one-word query cannot walk the whole index.
    /// The cap is a RECALL cliff, not a tuning knob (the "iran bug",
    /// 2026-08-30): bm25's length normalization ranks a term buried in one
    /// long reply below dozens of short passing mentions, so any match ranked
    /// past this cap never reaches the thread collapse at all — the thread
    /// silently vanishes from search. 4096 keeps the one-word-query bound
    /// while making the cliff unreachable for a store this app's size.
    /// ChatSearchRankingTests pins the buried-match case.
    private static func threadOverFetch(for limit: Int) -> Int { min(limit * 8, 4096) }

    /// The one ranked query both granularities share. `since` and
    /// `excludingThread` live in the WHERE — `ts`/`thread_id` are ordinary
    /// stored columns of the FTS table — so LIMIT counts surviving rows.
    private func rankedRows(match: String, limit: Int,
                            since: Date? = nil,
                            excludingThread: UUID? = nil) throws -> [ChatSearchResult] {
        let db = try handle()
        var conditions = "messages MATCH ?"
        if since != nil { conditions += " AND ts >= ?" }
        if excludingThread != nil { conditions += " AND thread_id <> ?" }
        // bm25() is lower-is-better, so ORDER BY is ascending.
        let statement = try prepare(db, """
            SELECT message_id, thread_id, role, ts,
                   snippet(messages, 0, ?, ?, '…', 18) AS snip,
                   bm25(messages) AS rank
            FROM messages
            WHERE \(conditions)
            ORDER BY rank
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, Self.highlightOpen)
        bind(statement, 2, Self.highlightClose)
        bind(statement, 3, match)
        var slot: Int32 = 4
        if let since {
            sqlite3_bind_double(statement, slot, since.timeIntervalSince1970)
            slot += 1
        }
        if let excludingThread {
            bind(statement, slot, excludingThread.uuidString)
            slot += 1
        }
        sqlite3_bind_int(statement, slot, Int32(max(0, limit)))

        var results: [ChatSearchResult] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            defer { code = sqlite3_step(statement) }
            guard let rawMessage = sqlite3_column_text(statement, 0),
                  let messageID = UUID(uuidString: String(cString: rawMessage)),
                  let rawThread = sqlite3_column_text(statement, 1),
                  let threadID = UUID(uuidString: String(cString: rawThread))
            else { continue }
            let role = sqlite3_column_text(statement, 2)
                .flatMap { Role(rawValue: String(cString: $0)) } ?? .user
            let ts = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let snippet = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            results.append(ChatSearchResult(messageID: messageID, threadID: threadID,
                                            role: role, timestamp: ts, snippet: snippet))
        }
        // NEVER let a failed step read as "no matches". A malformed query used
        // to return zero rows here, which is indistinguishable from a working
        // search of a history that does not contain the term — and that is a
        // false claim about the user's data.
        guard code == SQLITE_DONE else { throw sqliteError(db, "search") }
        return results
    }

    func following(threadID: UUID, after timestamp: Date) async throws -> ChatSearchResult? {
        let db = try handle()
        let statement = try prepare(db, """
            SELECT message_id, thread_id, role, ts, content
            FROM messages
            WHERE thread_id = ? AND ts > ?
            ORDER BY ts ASC
            LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, threadID.uuidString)
        sqlite3_bind_double(statement, 2, timestamp.timeIntervalSince1970)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw sqliteError(db, "following") }
        guard let rawMessage = sqlite3_column_text(statement, 0),
              let messageID = UUID(uuidString: String(cString: rawMessage)),
              let rawThread = sqlite3_column_text(statement, 1),
              let tid = UUID(uuidString: String(cString: rawThread))
        else { return nil }
        let role = sqlite3_column_text(statement, 2)
            .flatMap { Role(rawValue: String(cString: $0)) } ?? .user
        let ts = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        let content = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
        // FULL content, not an FTS snippet — this row didn't match anything,
        // so there is no window to centre. Callers own the cap.
        return ChatSearchResult(messageID: messageID, threadID: tid, role: role,
                                timestamp: ts, snippet: content)
    }

    func window(threadID: UUID, around timestamp: Date,
                before: Int, after: Int) async throws -> [ChatSearchResult] {
        let db = try handle()
        var rows: [ChatSearchResult] = []
        // Two bounded queries rather than one clever one: at-or-before
        // descending (the target row rides in here), then strictly-after
        // ascending. Merged in time order below.
        let backward = try prepare(db, """
            SELECT message_id, thread_id, role, ts, content
            FROM messages
            WHERE thread_id = ? AND ts <= ?
            ORDER BY ts DESC
            LIMIT ?
            """)
        defer { sqlite3_finalize(backward) }
        bind(backward, 1, threadID.uuidString)
        sqlite3_bind_double(backward, 2, timestamp.timeIntervalSince1970)
        sqlite3_bind_int(backward, 3, Int32(max(0, before) + 1))
        var code = sqlite3_step(backward)
        while code == SQLITE_ROW {
            defer { code = sqlite3_step(backward) }
            if let row = Self.contentRow(backward) { rows.append(row) }
        }
        guard code == SQLITE_DONE else { throw sqliteError(db, "window backward") }
        rows.reverse()

        if after > 0 {
            let forward = try prepare(db, """
                SELECT message_id, thread_id, role, ts, content
                FROM messages
                WHERE thread_id = ? AND ts > ?
                ORDER BY ts ASC
                LIMIT ?
                """)
            defer { sqlite3_finalize(forward) }
            bind(forward, 1, threadID.uuidString)
            sqlite3_bind_double(forward, 2, timestamp.timeIntervalSince1970)
            sqlite3_bind_int(forward, 3, Int32(after))
            var fcode = sqlite3_step(forward)
            while fcode == SQLITE_ROW {
                defer { fcode = sqlite3_step(forward) }
                if let row = Self.contentRow(forward) { rows.append(row) }
            }
            guard fcode == SQLITE_DONE else { throw sqliteError(db, "window forward") }
        }
        return rows
    }

    /// One content-led row from a `SELECT message_id, thread_id, role, ts,
    /// content` statement positioned on a row.
    private static func contentRow(_ statement: OpaquePointer?) -> ChatSearchResult? {
        guard let rawMessage = sqlite3_column_text(statement, 0),
              let messageID = UUID(uuidString: String(cString: rawMessage)),
              let rawThread = sqlite3_column_text(statement, 1),
              let tid = UUID(uuidString: String(cString: rawThread))
        else { return nil }
        let role = sqlite3_column_text(statement, 2)
            .flatMap { Role(rawValue: String(cString: $0)) } ?? .user
        let ts = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        let content = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
        return ChatSearchResult(messageID: messageID, threadID: tid, role: role,
                                timestamp: ts, snippet: content)
    }

    // MARK: - Query building

    /// Turns what the user typed into an FTS5 MATCH expression, or nil when
    /// there is nothing to search for.
    ///
    /// FTS5's query language is not a search box. `c++` raises `fts5: syntax
    /// error near "+"`, `AND`/`OR`/`NOT`/`NEAR` are operators, and an unbalanced
    /// `"` is a parse error — all of which a user types by accident. Every token
    /// is quoted, which makes each one a literal phrase, and the last gets `*`
    /// so results narrow as you type. That trailing `*` is also what produces
    /// the partial-word highlight: the bold covers the matched prefix only.
    ///
    /// nil (rather than `""`) for "nothing to search": an empty MATCH is legal
    /// and returns zero rows, and zero rows is a claim about the user's history
    /// that a blank search box has not earned.
    static func matchExpression(for query: String,
                                mode: ChatSearchMatchMode = .allTerms) -> String? {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        switch mode {
        case .allTerms:
            return tokens.enumerated()
                .map { index, token in
                    index == tokens.count - 1 ? "\"\(token)\"*" : "\"\(token)\""
                }
                .joined(separator: " ")
        case .anyTerm:
            // Recall over precision: every token prefixed and OR'd, with bm25
            // still ranking multi-term matches first. The per-token `*` is
            // what lets a query say "grocery" and find "groceries".
            return tokens.map { "\"\($0)\"*" }.joined(separator: " OR ")
        }
    }

    /// Removes the highlight delimiters from text on its way into the index, so
    /// that a delimiter found in a snippet is always one `snippet()` put there.
    ///
    /// Replaced with a SPACE, not with nothing. Deleting them welds the
    /// neighbouring words into one token — `a\u{1}b\u{2}c` became the single
    /// term `abc`, so searching for `b` found nothing. Both delimiters are
    /// already token separators to `unicode61`, so a space is what the original
    /// text tokenized as anyway.
    static func sanitizeForStorage(_ content: String) -> String {
        guard content.contains(highlightOpen) || content.contains(highlightClose) else { return content }
        return content
            .replacingOccurrences(of: highlightOpen, with: " ")
            .replacingOccurrences(of: highlightClose, with: " ")
    }

    // MARK: - sqlite plumbing

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(db, "prepare")
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func exec(_ db: OpaquePointer, _ sql: String, operation: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            if let error { sqlite3_free(error) }
            logger.error("chat index \(operation, privacy: .public) failed: \(message, privacy: .public)")
            throw ChatSearchIndexError.sqlite(operation: operation,
                                              code: sqlite3_errcode(db),
                                              message: message)
        }
    }

    private func sqliteError(_ db: OpaquePointer, _ operation: String) -> ChatSearchIndexError {
        .sqlite(operation: operation, code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db)))
    }
}
