import Foundation
import Testing
@testable import teemoon

/// Regression coverage for the at-rest protection of the SwiftData conversation
/// store (privacy audit gap: chat history was stored unprotected and included in
/// device backups). Verifies `TeemoonApp.hardenConversationStore(at:)` excludes
/// the store and its SQLite sidecars from backup and, where the platform enforces
/// it, applies file protection.
@Suite("ConversationStore hardening")
struct ConversationStoreHardeningTests {

    @Test func hardensStoreAndSidecars() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("teemoon-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Simulate the store plus its -wal / -shm sidecars existing on disk.
        let storeURL = dir.appendingPathComponent("default.store")
        let sidecars = ["-wal", "-shm"].map { URL(fileURLWithPath: storeURL.path + $0) }
        for url in [storeURL] + sidecars {
            #expect(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
        }

        TeemoonApp.hardenConversationStore(at: storeURL)

        for url in [storeURL] + sidecars {
            // Backup exclusion round-trips on every platform and is the primary fix.
            let fresh = URL(fileURLWithPath: url.path)
            let values = try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(
                values.isExcludedFromBackup == true,
                "\(url.lastPathComponent) should be excluded from backup"
            )

            // File protection is only enforced on device; when present it must be
            // `.completeUnlessOpen` (never `.complete`, which would crash an open store).
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let protection = attrs[.protectionKey] as? FileProtectionType {
                #expect(protection == .completeUnlessOpen)
            }
        }
    }

    /// The FTS sidecar holds a full second copy of every message in plaintext,
    /// so it needs exactly the protection the store it shadows gets. Search that
    /// quietly undid this fix would be worse than no search.
    @Test @MainActor func hardensTheChatSearchSidecar() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("teemoon-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("default.store")

        let sidecar = try #require(
            ChatSearchIndex.sidecarURL(forStoreAt: storeURL, isStoredInMemoryOnly: false)
        )
        let all = [sidecar] + ["-wal", "-shm"].map { URL(fileURLWithPath: sidecar.path + $0) }
        for url in all {
            #expect(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
        }

        ChatSearchService(index: ChatSearchIndex(databaseURL: sidecar)).rehardenIfNeeded()

        for url in all {
            let fresh = URL(fileURLWithPath: url.path)
            let values = try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true,
                    "\(url.lastPathComponent) should be excluded from backup")
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let protection = attrs[.protectionKey] as? FileProtectionType {
                #expect(protection == .completeUnlessOpen)
            }
        }
    }

    /// An in-memory store must leave nothing on disk. `ModelConfiguration.url`
    /// still hands back a file URL for one, so a caller that trusts it blindly
    /// writes a real index of whatever store a `--uitesting` run opened.
    @Test @MainActor func inMemoryStoreCreatesNoSidecar() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("teemoon-mem-\(UUID().uuidString)", isDirectory: true)
        let storeURL = dir.appendingPathComponent("default.store")

        let service = ChatSearchService()
        service.configure(storeURL: storeURL, isStoredInMemoryOnly: true)

        #expect(service.index == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func missingStoreIsNoOp() {
        // Sidecars often don't exist yet at container-creation time; hardening must
        // silently skip absent files rather than throw/crash.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("teemoon-absent-\(UUID().uuidString).store")
        TeemoonApp.hardenConversationStore(at: missing)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
