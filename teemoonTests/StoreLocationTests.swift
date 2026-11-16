//
//  StoreLocationTests.swift
//  teemoonTests
//
//  docs/DATA_MODEL.md "Where the store lives (1.1.0)": the store is pinned to the app container. Build 61 let SwiftData
//  follow the new App Group, copy the chats there and leave the 1.0.6 file behind, out of reach of every delete (audit
//  LOW, 2026-11-15). A 61 install moves its group store back once. The table in that doc drives these tests: every
//  combination of files maps to the doc's action, and each row's work is killed at every step and relaunched.
//

import Foundation
import SQLite3
import SwiftData
import Testing
@testable import teemoon

@Suite("Store — where it lives")
struct StoreLocationTests {

    // MARK: fixtures

    struct Dirs {
        let base: URL
        var data: URL { base.appending(path: "app/Library/Application Support", directoryHint: .isDirectory) }
        var groupLibrary: URL { base.appending(path: "group/Library", directoryHint: .isDirectory) }
        var group: URL { groupLibrary.appending(path: "Application Support", directoryHint: .isDirectory) }
        func location(fault: ((String) -> Bool)? = nil) -> StoreLocation {
            StoreLocation(dataDir: data, groupDir: group, fault: fault)
        }
    }

    static func dirs() throws -> Dirs {
        let base = FileManager.default.temporaryDirectory.appending(path: "store-location-\(UUID().uuidString)",
                                                                    directoryHint: .isDirectory)
        let d = Dirs(base: base)
        try FileManager.default.createDirectory(at: d.data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d.groupLibrary, withIntermediateDirectories: true)
        return d
    }

    /// A store-shaped sqlite file with its set beside it: `threads` rows, two messages each, `images` attachments, a
    /// `.default_SUPPORT` file and a search index. `tag` lands in the support file so a test can tell sets apart.
    static func makeStore(in dir: URL, threads: Int, images: Int = 1, tag: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let url = dir.appending(path: "default.store")
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = "PRAGMA journal_mode=WAL; CREATE TABLE ZTHREAD (Z_PK INTEGER PRIMARY KEY, ZTAG TEXT);"
        sql += "CREATE TABLE ZMESSAGE (Z_PK INTEGER PRIMARY KEY, ZTHREAD INTEGER);"
        sql += "CREATE TABLE ZIMAGEATTACHMENT (Z_PK INTEGER PRIMARY KEY);"
        for t in 0..<threads {
            sql += "INSERT INTO ZTHREAD (ZTAG) VALUES ('\(tag)'); INSERT INTO ZMESSAGE (ZTHREAD) VALUES (\(t + 1)), (\(t + 1));"
        }
        for _ in 0..<images { sql += "INSERT INTO ZIMAGEATTACHMENT DEFAULT VALUES;" }
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        let support = dir.appending(path: ".default_SUPPORT/_EXTERNAL_DATA", directoryHint: .isDirectory)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(tag.utf8).write(to: support.appending(path: "image-bytes"))
        try Data("index \(tag)".utf8).write(to: dir.appending(path: "chat-search-index.sqlite"))
    }

    static func tag(in dir: URL) -> String? {
        (try? Data(contentsOf: dir.appending(path: ".default_SUPPORT/_EXTERNAL_DATA/image-bytes")))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Every `default.store*` file anywhere under `base`, as full paths.
    static func storeFiles(under base: URL) -> [String] {
        let all = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("default.store") }.map(\.path).sorted()
    }

    // MARK: the app's paths

    @Test func theAppsStoreIsInItsOwnContainerNotTheAppGroup() {
        let location = StoreLocation.app()
        #expect(location.dataStore == URL.applicationSupportDirectory.appending(path: "default.store"))
        #expect(!location.dataStore.path.contains("/AppGroup/"))
        #expect(location.groupStore?.path.contains("/AppGroup/") ?? true)
    }

    // MARK: the table, from the doc

    struct Row {
        let number: Int
        let cells: [String]
        let action: String
    }

    static func docTable() throws -> [Row] {
        let doc = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/DATA_MODEL.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        let section = try #require(text.components(separatedBy: "## Where the store lives (1.1.0)").last)
        return section.split(separator: "\n").compactMap { line -> Row? in
            let cols = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count == 7, let number = Int(cols[0]) else { return nil }
            return Row(number: number, cells: Array(cols[1...5]), action: cols[6])
        }
    }

    @Test func everyCombinationOfFilesTakesTheDocsAction() throws {
        let rows = try Self.docTable()
        #expect(rows.count == 9)
        for bits in 0..<32 {
            let flags = (0..<5).map { bits & (1 << $0) != 0 }
            let state = StoreLocation.State(data: flags[0], group: flags[1], old: flags[2], incoming: flags[3],
                                            rollback: flags[4])
            let row = try #require(rows.first { row in
                zip(row.cells, flags).allSatisfy { cell, flag in cell == "any" || (cell == "yes") == flag }
            }, "no row matches \(state)")
            #expect(StoreLocation.action(for: state).rawValue == row.action, "row \(row.number) for \(state)")
        }
    }

    // MARK: rows, end to end

    @Test func aStoreFromTheOldBuildStaysWhereItIsAndNothingMoves() throws {
        let d = try Self.dirs()
        try Self.makeStore(in: d.data, threads: 2, tag: "1.0.6")
        let url = try d.location().run()
        #expect(url == d.data.appending(path: "default.store"))
        #expect(Self.tag(in: d.data) == "1.0.6")
        #expect(!Self.exists(d.group.appending(path: "default.store")))
        #expect(!Self.exists(d.data.appending(path: "StoreMove")))
    }

    @Test func aFreshInstallOpensTheAppContainer() throws {
        let d = try Self.dirs()
        #expect(try d.location().run() == d.data.appending(path: "default.store"))
        #expect(Self.storeFiles(under: d.base).isEmpty, "the table creates nothing; SwiftData makes the store")
    }

    /// Build 61: the live chats are in the group; the 1.0.6 file is a stale copy that still holds a chat deleted in 61.
    @Test func aBuild61InstallMovesItsLiveStoreBackOnceAndTheStaleCopyGoes() throws {
        let d = try Self.dirs()
        try Self.makeStore(in: d.data, threads: 3, tag: "1.0.6")
        try Self.makeStore(in: d.group, threads: 2, tag: "61")
        let url = try #require(try d.location().run())
        #expect(url == d.data.appending(path: "default.store"))
        #expect(Self.tag(in: d.data) == "61", "the live store, image bytes included")
        #expect(StoreLocation.counts(of: url) == StoreLocation.Counts(threads: 2, messages: 4, images: 1))
        #expect(String(decoding: try Data(contentsOf: d.data.appending(path: "chat-search-index.sqlite")), as: UTF8.self)
                == "index 61")
        let files = Self.storeFiles(under: d.base)
        #expect(files.contains(url.path))
        #expect(files.allSatisfy { URL(filePath: $0).deletingLastPathComponent().path == d.data.path },
                "one store on disk, in the app container: \(files)")
        #expect(!Self.exists(d.data.appending(path: "StoreMove")))
        #expect(!Self.exists(d.group))
        #expect(try d.location().run() == url, "the next launch is an ordinary one")
    }

    @Test func aBuild61InstallWithNoOldStoreMovesToo() throws {
        let d = try Self.dirs()
        try Self.makeStore(in: d.group, threads: 1, tag: "61")
        #expect(try d.location().run() == d.data.appending(path: "default.store"))
        #expect(Self.tag(in: d.data) == "61")
        #expect(!Self.exists(d.data.appending(path: "StoreMove")))
    }

    // MARK: doubt

    @Test func anUnreadableGroupStoreOpensInPlaceAndNothingMoves() throws {
        let d = try Self.dirs()
        try Self.makeStore(in: d.data, threads: 3, tag: "1.0.6")
        try FileManager.default.createDirectory(at: d.group, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: d.group.appending(path: "default.store"))
        #expect(try d.location().run() == d.group.appending(path: "default.store"))
        #expect(Self.tag(in: d.data) == "1.0.6")
        #expect(Self.exists(d.group.appending(path: "default.store")))
        #expect(!Self.exists(d.data.appending(path: "StoreMove")))
    }

    @Test func countsThatDifferAfterTheMoveRollBackAndOpenTheGroupStoreNeverTheOldOne() throws {
        let d = try Self.dirs()
        try Self.makeStore(in: d.data, threads: 3, tag: "1.0.6")
        try Self.makeStore(in: d.group, threads: 2, tag: "61")
        // Killed after the move, before finish; then the expectation is made false.
        #expect(throws: StoreLocation.Killed.self) { try d.location(fault: { $0 == "deleteOld" }).run() }
        let expected = d.data.appending(path: "StoreMove/old/expected.json")
        try JSONEncoder().encode(StoreLocation.Counts(threads: 9, messages: 9, images: 9)).write(to: expected)
        let url = try d.location().run()
        #expect(url == d.group.appending(path: "default.store"), "a 61 phone never shows the 1.0.6 chats")
        #expect(Self.tag(in: d.group) == "61")
        #expect(Self.tag(in: d.data) == "1.0.6", "the 1.0.6 file is back, untouched, for the retry")
        #expect(!Self.exists(d.data.appending(path: "StoreMove")))
    }

    // MARK: kills

    /// Every step of a 61 move, killed, then launched again until it settles: the live store always wins, the 1.0.6
    /// copy is gone at the end, and no launch ever opens the 1.0.6 chats.
    @Test func aKillAtEveryStepOfTheMoveResumesToTheLiveStore() throws {
        var steps: [String] = []
        do {
            let d = try Self.dirs()
            try Self.makeStore(in: d.data, threads: 3, tag: "1.0.6")
            try Self.makeStore(in: d.group, threads: 2, tag: "61")
            _ = try d.location(fault: { steps.append($0); return false }).run()
        }
        #expect(steps.count >= 8, "\(steps)")
        for (n, step) in steps.enumerated() {
            let d = try Self.dirs()
            try Self.makeStore(in: d.data, threads: 3, tag: "1.0.6")
            try Self.makeStore(in: d.group, threads: 2, tag: "61")
            var seen = 0
            #expect(throws: StoreLocation.Killed.self, "step \(step)") {
                try d.location(fault: { _ in defer { seen += 1 }; return seen == n }).run()
            }
            var opened: URL? = nil
            for _ in 0..<3 {
                let url = try #require(try d.location().run())
                let tag = Self.tag(in: url.deletingLastPathComponent())
                #expect(tag == "61", "after a kill at \(step) a launch opened \(tag ?? "nothing")")
                opened = url
            }
            #expect(opened == d.data.appending(path: "default.store"), "killed at \(step)")
            #expect(!Self.exists(d.data.appending(path: "StoreMove")), "killed at \(step)")
            #expect(!Self.exists(d.group.appending(path: "default.store")), "killed at \(step)")
        }
    }

    @Test func aKillAtEveryStepOfARollBackStillOpensTheGroupStore() throws {
        var steps: [String] = []
        func prepared() throws -> Dirs {
            let d = try Self.dirs()
            try Self.makeStore(in: d.data, threads: 3, tag: "1.0.6")
            try Self.makeStore(in: d.group, threads: 2, tag: "61")
            #expect(throws: StoreLocation.Killed.self) { try d.location(fault: { $0 == "deleteOld" }).run() }
            try JSONEncoder().encode(StoreLocation.Counts(threads: 9, messages: 9, images: 9))
                .write(to: d.data.appending(path: "StoreMove/old/expected.json"))
            return d
        }
        do { _ = try prepared().location(fault: { steps.append($0); return false }).run() }
        #expect(steps.count >= 5, "\(steps)")
        for n in steps.indices {
            let d = try prepared()
            var seen = 0
            #expect(throws: StoreLocation.Killed.self) {
                try d.location(fault: { _ in defer { seen += 1 }; return seen == n }).run()
            }
            let url = try d.location().run()
            #expect(url == d.group.appending(path: "default.store"), "rollback killed at \(steps[n])")
            #expect(Self.tag(in: d.group) == "61", "rollback killed at \(steps[n])")
            #expect(Self.tag(in: d.data) == "1.0.6", "rollback killed at \(steps[n])")
            #expect(!Self.exists(d.data.appending(path: "StoreMove")), "rollback killed at \(steps[n])")
        }
    }

    @Test func onlyAnOldFolderLeftIsRestoredNeverDeleted() throws {
        let d = try Self.dirs()
        try Self.makeStore(in: d.data.appending(path: "StoreMove/old"), threads: 1, tag: "1.0.6")
        #expect(try d.location().run() == d.data.appending(path: "default.store"))
        #expect(Self.tag(in: d.data) == "1.0.6")
    }

    @Test func groupSidecarsWithNoStoreAreSwept() throws {
        let d = try Self.dirs()
        try Self.makeStore(in: d.data, threads: 1, tag: "1.0.6")
        try FileManager.default.createDirectory(at: d.group, withIntermediateDirectories: true)
        try Data().write(to: d.group.appending(path: "default.store-shm"))
        try Data().write(to: d.group.appending(path: "chat-search-index.sqlite"))
        _ = try d.location().run()
        #expect(!Self.exists(d.group.appending(path: "default.store-shm")))
        #expect(!Self.exists(d.group.appending(path: "chat-search-index.sqlite")))
        #expect(Self.tag(in: d.data) == "1.0.6")
    }

    // MARK: strays and partial failures (review, 2026-11-15)

    @Test func aStraySearchIndexOrShmInTheWayIsACacheAndDoesNotBlockTheMove() throws {
        let d = try Self.dirs()
        try Self.makeStore(in: d.group, threads: 2, tag: "61")
        // No 1.0.6 store, but a stray index and -shm where the moved set lands.
        try Data("stray".utf8).write(to: d.data.appending(path: "chat-search-index.sqlite"))
        try Data().write(to: d.data.appending(path: "default.store-shm"))
        #expect(try d.location().run() == d.data.appending(path: "default.store"))
        #expect(Self.tag(in: d.data) == "61")
        #expect(!Self.exists(d.data.appending(path: "StoreMove")))
    }

    @Test func aRestoreThatCannotMoveOpensTheOldSetWhereItIsAndCreatesNothing() throws {
        let d = try Self.dirs()
        let old = d.data.appending(path: "StoreMove/old")
        try Self.makeStore(in: old, threads: 1, tag: "1.0.6")
        try Data("wal".utf8).write(to: old.appending(path: "default.store-wal"))
        try Data("stray wal".utf8).write(to: d.data.appending(path: "default.store-wal"))
        #expect(try d.location().run() == old.appending(path: "default.store"))
        #expect(Self.tag(in: old) == "1.0.6")
        #expect(!Self.exists(d.data.appending(path: "default.store")), "no empty store may appear beside the real one")
    }

    @Test func finishWithNoExpectationKeepsBothAndRollsNothingBack() throws {
        let d = try Self.dirs()
        try Self.makeStore(in: d.data, threads: 2, tag: "61")
        try Self.makeStore(in: d.data.appending(path: "StoreMove/old"), threads: 3, tag: "1.0.6")
        #expect(try d.location().run() == d.data.appending(path: "default.store"))
        #expect(Self.tag(in: d.data) == "61")
        #expect(Self.tag(in: d.data.appending(path: "StoreMove/old")) == "1.0.6", "nothing is deleted on doubt")
        #expect(!Self.exists(d.group.appending(path: "default.store")), "doubt is not a reason to roll back")
    }

    @Test func aRollBackThatFailsHalfwayOpensNothingFromDisk() throws {
        let d = try Self.dirs()
        try Self.makeStore(in: d.data, threads: 3, tag: "1.0.6")
        try Self.makeStore(in: d.group, threads: 2, tag: "61")
        #expect(throws: StoreLocation.Killed.self) { try d.location(fault: { $0 == "deleteOld" }).run() }
        try JSONEncoder().encode(StoreLocation.Counts(threads: 9, messages: 9, images: 9))
            .write(to: d.data.appending(path: "StoreMove/old/expected.json"))
        // The live set has a -wal; a stray one already sits where the rollback must put it.
        try Data("live wal".utf8).write(to: d.data.appending(path: "default.store-wal"))
        let incoming = d.data.appending(path: "StoreMove/incoming")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("stray wal".utf8).write(to: incoming.appending(path: "default.store-wal"))
        #expect(try d.location().run() == nil, "a store without its own -wal is never opened")
        #expect(Self.exists(d.data.appending(path: "StoreMove/old/default.store")), "nothing is deleted")
    }

    @Test func aResumedMoveCountsTheGroupStoreAgain() throws {
        let d = try Self.dirs()
        try Self.makeStore(in: d.data, threads: 3, tag: "1.0.6")
        try Self.makeStore(in: d.group, threads: 2, tag: "61")
        #expect(throws: StoreLocation.Killed.self) { try d.location(fault: { $0 == "incoming" }).run() }
        // The session that followed changed the group store; the old expectation is stale.
        try JSONEncoder().encode(StoreLocation.Counts(threads: 9, messages: 9, images: 9))
            .write(to: d.data.appending(path: "StoreMove/old/expected.json"))
        #expect(try d.location().run() == d.data.appending(path: "default.store"))
        #expect(Self.tag(in: d.data) == "61")
        #expect(!Self.exists(d.data.appending(path: "StoreMove")), "the move finished instead of rolling back")
    }

    // MARK: a real store

    /// SwiftData's own files: a 61-shaped group store with a chat deleted in 61 moves back and opens with that chat
    /// still gone, its image intact, and no copy of the deleted chat anywhere on disk.
    @Test @MainActor func aRealSwiftDataStoreMovesBackWithADeletionKept() throws {
        let d = try Self.dirs()
        let schema = Schema(versionedSchema: TeemoonSchemaV3.self)
        let kept = UUID(), gone = UUID()
        func seed(at dir: URL, deleteGone: Bool) throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let container = try ModelContainer(for: schema, migrationPlan: TeemoonMigrationPlan.self,
                                               configurations: ModelConfiguration(schema: schema, url: dir.appending(path: "default.store")))
            let context = container.mainContext
            for id in [kept, gone] {
                let thread = teemoon.Thread()
                thread.id = id
                context.insert(thread)
                let message = Message(role: .user, content: "about \(id == kept ? "kept" : "gone")", thread: thread)
                context.insert(message)
                context.insert(ImageAttachment(id: UUID(), messageID: message.id, index: 0, mimeType: "image/png",
                                               width: 1, height: 1, data: Data(repeating: 7, count: 200_000),
                                               thumbnail: Data([1])))
            }
            try context.save()
            if deleteGone, let thread = try context.fetch(FetchDescriptor<teemoon.Thread>()).first(where: { $0.id == gone }) {
                ThreadDeletion.delete(thread, in: context)
            }
        }
        try seed(at: d.data, deleteGone: false)
        try seed(at: d.group, deleteGone: true)
        let url = try #require(try d.location().run())
        #expect(url == d.data.appending(path: "default.store"))
        let container = try ModelContainer(for: schema, migrationPlan: TeemoonMigrationPlan.self,
                                           configurations: ModelConfiguration(schema: schema, url: url))
        let threads = try container.mainContext.fetch(FetchDescriptor<teemoon.Thread>())
        #expect(threads.map(\.id) == [kept])
        #expect(try container.mainContext.fetch(FetchDescriptor<ImageAttachment>()).count == 1)
        #expect(!Self.exists(d.data.appending(path: "StoreMove")), "the 1.0.6 copy with the deleted chat is gone")
        #expect(!Self.exists(d.group.appending(path: "default.store")))
    }
}
