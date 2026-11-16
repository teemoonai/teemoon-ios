//
//  StoreLocation.swift
//  teemoon
//
//  Where the chat store is opened: always the app container's `Application Support/default.store`. A build-61 install
//  has its live store in the App Group and moves it back once. docs/DATA_MODEL.md "Where the store lives (1.1.0)" is
//  the state table; StoreLocationTests runs it. Never delete a store on doubt, and never open the 1.0.6 copy in place
//  of a live group store.
//

import Foundation
import os
import SQLite3

struct StoreLocation {
    enum Action: String { case rollBack, openGroupInPlace, resumeIncoming, resumeOld, move, finish, restoreOld, openData }

    struct State: Equatable, CustomStringConvertible {
        var data, group, old, incoming, rollback: Bool
        var description: String { "data \(data) group \(group) old \(old) incoming \(incoming) rollback \(rollback)" }
    }

    struct Counts: Codable, Equatable { var threads, messages, images: Int }
    /// Thrown only by `fault`, the tests' kill.
    struct Killed: Error {}
    private struct MoveFailed: Error {}

    let dataDir: URL
    let groupDir: URL?
    /// Tests: return true to stop before the named step, as a kill would.
    var fault: ((String) -> Bool)?

    var dataStore: URL { dataDir.appending(path: Self.main) }
    var groupStore: URL? { groupDir?.appending(path: Self.main) }
    private var moveDir: URL { dataDir.appending(path: "StoreMove", directoryHint: .isDirectory) }
    private var oldDir: URL { moveDir.appending(path: "old", directoryHint: .isDirectory) }
    private var incomingDir: URL { moveDir.appending(path: "incoming", directoryHint: .isDirectory) }
    private var marker: URL { moveDir.appending(path: "rollback") }
    private var expectedFile: URL { oldDir.appending(path: "expected.json") }

    private static let main = "default.store"
    /// A set, `default.store` last: moved in this order it is never complete without its `-wal`.
    private static let set = ["default.store-wal", "default.store-shm", ".default_SUPPORT", "chat-search-index.sqlite",
                              "chat-search-index.sqlite-wal", "chat-search-index.sqlite-shm", main]
    /// Rebuilt from the store when missing.
    private static let caches: Set = ["default.store-shm", "chat-search-index.sqlite", "chat-search-index.sqlite-wal",
                                      "chat-search-index.sqlite-shm"]
    private static let log = Logger(subsystem: "ai.teemoon", category: "store")

    static func app(bundle: Bundle = .main) -> StoreLocation {
        let group = bundle.bundleIdentifier
            .flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareInbox.appGroupID(bundleID: $0)) }
        return StoreLocation(dataDir: URL.applicationSupportDirectory,
                             groupDir: group?.appending(path: "Library/Application Support", directoryHint: .isDirectory))
    }

    /// docs/DATA_MODEL.md's table, first matching row.
    static func action(for s: State) -> Action {
        if s.rollback { return .rollBack }
        if s.incoming { return s.group ? .openGroupInPlace : .resumeIncoming }
        if s.group { return s.old ? .resumeOld : .move }
        if s.old { return s.data ? .finish : .restoreOld }
        return .openData
    }

    /// The store to open; nil when none can be opened whole (the app runs in memory, files kept). Only `fault` throws.
    func resolve() -> URL? { (try? run()) ?? nil }

    func run() throws -> URL? {
        let fm = FileManager.default
        let state = State(data: fm.fileExists(atPath: dataStore.path),
                          group: groupStore.map { fm.fileExists(atPath: $0.path) } ?? false,
                          old: fm.fileExists(atPath: oldDir.path), incoming: fm.fileExists(atPath: incomingDir.path),
                          rollback: fm.fileExists(atPath: marker.path))
        let action = Self.action(for: state)
        if action != .openData { Self.log.notice("store location: \(state.description, privacy: .public) → \(action.rawValue, privacy: .public)") }
        switch action {
        case .openData:
            sweepGroupSidecars()
            return dataStore
        case .openGroupInPlace:
            return groupStore ?? dataStore
        case .move, .resumeOld:
            return try moveBack()
        case .resumeIncoming:
            return try takeIncoming()
        case .finish:
            return try finish()
        case .rollBack:
            return try rollBack()
        case .restoreOld:
            do {
                try moveSet(from: oldDir, to: dataDir, mainLast: true, label: "restore")
            } catch is Killed {
                throw Killed()
            } catch {
                return oldDir.appending(path: Self.main)
            }
            try? fm.removeItem(at: expectedFile)
            try? fm.removeItem(at: oldDir)
            try? fm.removeItem(at: moveDir)
            return dataStore
        }
    }

    // MARK: rows

    private func moveBack() throws -> URL? {
        guard let groupDir, let groupStore, let counts = Self.counts(of: groupStore) else {
            Self.log.error("store location: group store unreadable, opened in place")
            return groupStore ?? dataStore
        }
        let fm = FileManager.default
        do {
            try step("old")
            try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
            Self.excludeFromBackup(moveDir)
            // Rewritten on a resume too: the group store, still in place, is the truth.
            try step("expected")
            try JSONEncoder().encode(counts).write(to: expectedFile, options: .completeFileProtectionUnlessOpen)
            try moveSet(from: dataDir, to: oldDir, mainLast: true, label: "old")
            try step("incoming")
            try fm.moveItem(at: groupDir, to: incomingDir)
        } catch is Killed {
            throw Killed()
        } catch {
            // The group store is untouched: open it; the next launch resumes.
            Self.log.error("store location: move failed before the group store moved: \(String(describing: error), privacy: .public)")
            return groupStore
        }
        return try takeIncoming()
    }

    private func takeIncoming() throws -> URL? {
        do {
            try moveSet(from: incomingDir, to: dataDir, mainLast: true, label: "in")
            try step("removeIncoming")
            try FileManager.default.removeItem(at: incomingDir)
        } catch is Killed {
            throw Killed()
        } catch {
            return try rollBack()
        }
        return try finish()
    }

    private func finish() throws -> URL? {
        let expected = (try? Data(contentsOf: expectedFile)).flatMap { try? JSONDecoder().decode(Counts.self, from: $0) }
        guard let expected, let counts = Self.counts(of: dataStore) else {
            // Unreadable is doubt, not a mismatch: keep both and try again next launch.
            Self.log.error("store location: cannot compare after the move, kept both")
            return dataStore
        }
        guard counts == expected else {
            Self.log.error("store location: counts differ after the move, rolling back")
            return try rollBack()
        }
        try step("deleteOld")
        try? FileManager.default.removeItem(at: moveDir)
        return dataStore
    }

    /// Puts the live store back in the group and the 1.0.6 set back in the app container, then opens the group store.
    private func rollBack() throws -> URL? {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: marker.path) {
                try step("marker")
                try fm.createDirectory(at: moveDir, withIntermediateDirectories: true)
                try Data().write(to: marker)
            }
            if let groupDir, !fm.fileExists(atPath: groupDir.appending(path: Self.main).path) {
                // Until the group store is back, data's main is the live one: the 1.0.6 set is restored after.
                try fm.createDirectory(at: incomingDir, withIntermediateDirectories: true)
                try moveSet(from: dataDir, to: incomingDir, mainLast: false, label: "back")
                try step("renameBack")
                if fm.fileExists(atPath: groupDir.path) {
                    try moveSet(from: incomingDir, to: groupDir, mainLast: true, label: "group")
                    try fm.removeItem(at: incomingDir)
                } else {
                    try fm.moveItem(at: incomingDir, to: groupDir)
                }
            }
            if fm.fileExists(atPath: oldDir.path) {
                try moveSet(from: oldDir, to: dataDir, mainLast: true, label: "restoreOld")
                try step("removeOld")
                try fm.removeItem(at: oldDir)
            }
            try step("removeMarker")
            try fm.removeItem(at: moveDir)
        } catch is Killed {
            throw Killed()
        } catch {
            Self.log.error("store location: roll back failed: \(String(describing: error), privacy: .public)")
        }
        // Half a rollback is never opened: a store away from its -wal would read as fewer chats.
        if let groupStore, fm.fileExists(atPath: groupStore.path) { return groupStore }
        return nil
    }

    // MARK: files

    private func step(_ name: String) throws {
        if fault?(name) == true { throw Killed() }
    }

    /// Moves what is present of a set; a file already at the destination with none at the source is done. A `-shm` or
    /// search-index file in the way is a cache and goes; any other conflict fails before anything moves.
    private func moveSet(from: URL, to: URL, mainLast: Bool, label: String) throws {
        let fm = FileManager.default
        let names = (mainLast ? Self.set : Self.set.reversed()).filter { fm.fileExists(atPath: from.appending(path: $0).path) }
        if names.contains(where: { !Self.caches.contains($0) && fm.fileExists(atPath: to.appending(path: $0).path) }) {
            throw MoveFailed()
        }
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in names {
            let dst = to.appending(path: name)
            try step("\(label):\(name)")
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: from.appending(path: name), to: dst)
        }
    }

    /// Search-index and `-shm` files with no group store beside them belong to a store that has moved.
    private func sweepGroupSidecars() {
        guard let groupDir, let groupStore, !FileManager.default.fileExists(atPath: groupStore.path) else { return }
        for name in Self.set where name != Self.main {
            try? FileManager.default.removeItem(at: groupDir.appending(path: name))
        }
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Threads, messages and image attachments, read without writing; nil when the file is not a readable store. No
    /// integrity check: it reads the whole file at launch.
    static func counts(of store: URL) -> Counts? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        func scalar(_ sql: String) -> String? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: text)
        }
        func count(_ table: String) -> Int? {
            guard let present = scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='\(table)'") else { return nil }
            guard present == "1" else { return 0 }
            return scalar("SELECT count(*) FROM \(table)").flatMap(Int.init)
        }
        guard let threads = count("ZTHREAD"), let messages = count("ZMESSAGE"), let images = count("ZIMAGEATTACHMENT")
        else { return nil }
        return Counts(threads: threads, messages: messages, images: images)
    }
}
