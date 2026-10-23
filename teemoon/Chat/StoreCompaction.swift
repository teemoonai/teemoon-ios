//
//  StoreCompaction.swift
//  teemoon
//
//  A deleted chat's text stays in the store's free pages and WAL until SQLite
//  happens to reuse them. After a delete, the next launch rewrites the file
//  BEFORE SwiftData opens it. Never run this with a container open on the
//  store; any failure leaves the file as it was and tries again next launch.
//

import Foundation
import OSLog
import SQLite3

enum StoreCompaction {
    static let pendingKey = "storeCompactionPending"

    enum Outcome: Equatable {
        case notPending, done, skippedForSpace
        case failed(String)
    }

    static func requestAfterDelete(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: pendingKey)
    }

    @discardableResult
    static func runIfPending(storeURL: URL, defaults: UserDefaults = .standard,
                             freeBytes: (URL) -> Int64? = availableBytes) -> Outcome {
        guard defaults.bool(forKey: pendingKey) else { return .notPending }
        let started = Date()
        let outcome = compact(storeURL: storeURL, freeBytes: freeBytes)
        if outcome == .done { defaults.removeObject(forKey: pendingKey) }
        Logger(subsystem: "ai.teemoon", category: "store")
            .notice("compaction \(String(describing: outcome), privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        return outcome
    }

    static func compact(storeURL: URL, freeBytes: (URL) -> Int64?) -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return .done }
        let size = ["", "-wal"].reduce(Int64(0)) { sum, suffix in
            let n = (try? fm.attributesOfItem(atPath: storeURL.path + suffix))?[.size] as? NSNumber
            return sum + (n?.int64Value ?? 0)
        }
        // VACUUM needs room for a second copy, plus the WAL it writes through.
        guard let free = freeBytes(storeURL.deletingLastPathComponent()), free >= 2 * size else {
            return .skippedForSpace
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = handle else {
            sqlite3_close_v2(handle)
            return .failed("open")
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 2000)

        guard text(db, "PRAGMA quick_check") == "ok" else { return .failed("quick_check") }
        // MEMORY: the rewrite's temporary copy holds every remaining chat and
        // must not land in tmp/ as a plain file.
        for (sql, step) in [("PRAGMA temp_store = MEMORY", "temp_store"),
                            ("PRAGMA secure_delete = ON", "secure_delete")] {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { return .failed(step) }
        }
        guard checkpoint(db) else { return .failed("checkpoint") }
        guard sqlite3_exec(db, "VACUUM", nil, nil, nil) == SQLITE_OK else { return .failed("vacuum") }
        guard checkpoint(db) else { return .failed("checkpoint after vacuum") }
        return .done
    }

    static func availableBytes(_ directory: URL) -> Int64? {
        try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// TRUNCATE empties the WAL file, which still holds the deleted rows' frames.
    private static func checkpoint(_ db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA wal_checkpoint(TRUNCATE)", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) == 0
    }

    private static func text(_ db: OpaquePointer, _ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }
}
