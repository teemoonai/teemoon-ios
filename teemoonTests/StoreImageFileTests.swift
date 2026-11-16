//
//  StoreImageFileTests.swift
//  teemoonTests
//
//  SwiftData writes a large ImageAttachment.data (@Attribute(.externalStorage)) as a file in a
//  hidden ".<store>_SUPPORT/_EXTERNAL_DATA/" folder beside the store. Hardening the store, -wal
//  and -shm alone left those image files in device/iCloud backups with the default protection
//  class, while the import copy promises chats are "saved only on this phone".
//
//  Real on-disk stores only: an in-memory store never writes the external file.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

/// An on-disk store in a fresh temp dir. Holds the container for the test's lifetime: a context
/// whose container was released traps inside SwiftData.
@MainActor
final class OnDiskChatStore {
    let dir: URL
    let url: URL
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("teemoon-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("default.store")
        container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                       configurations: ModelConfiguration(url: url))
        context = ModelContext(container)
    }

    /// ".default_SUPPORT", found on disk rather than assumed.
    var supportFolder: URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.first { $0.hasPrefix(".") && $0.hasSuffix("_SUPPORT") }.map { dir.appendingPathComponent($0) }
    }

    /// Every regular file under _EXTERNAL_DATA.
    var externalFiles: [URL] {
        guard let support = supportFolder else { return [] }
        let external = support.appendingPathComponent("_EXTERNAL_DATA")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: external.path)) ?? []
        return names.map { external.appendingPathComponent($0) }
    }

    /// Every file and folder under the support folder, the folder included.
    var supportTree: [URL] {
        guard let support = supportFolder else { return [] }
        var all = [support]
        if let walk = FileManager.default.enumerator(at: support, includingPropertiesForKeys: nil) {
            for case let url as URL in walk { all.append(url) }
        }
        return all
    }

    /// A chat whose question carries `images` attachments of 300 KB of noise each (well past the
    /// external-storage threshold).
    @discardableResult
    func chat(images: Int) throws -> (ChatThread, [Message]) {
        let thread = ChatThread()
        context.insert(thread)
        let question = Message(role: .user, content: "what is this?", thread: thread)
        let answer = Message(role: .assistant, content: "a cat", thread: thread)
        [question, answer].forEach(context.insert)
        for i in 0..<images {
            let bytes = Data((0..<300_000).map { _ in UInt8.random(in: 0...255) })
            context.insert(ImageAttachment(id: UUID(), messageID: question.id, index: i, mimeType: "image/jpeg",
                                           width: 4, height: 3, data: bytes, thumbnail: Data([2])))
        }
        try context.save()
        return (thread, [question, answer])
    }
}

@MainActor
@Suite("Store image files — backup and protection")
struct StoreImageFileTests {

    private func protection(_ url: URL) -> FileProtectionType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType
    }

    private func expectHardened(_ store: OnDiskChatStore) throws {
        let files = store.externalFiles
        #expect(!files.isEmpty, "a 300 KB image is stored as an external file")
        let tree = store.supportTree
        #expect(tree.count > files.count, "the support folder and its subfolders are walked too")
        // Protection is asserted where the platform reads it back on the store file itself.
        let storeProtection = protection(store.url)
        print("[StoreImageFileTests] store protection reads back as \(String(describing: storeProtection))")
        for url in tree {
            let excluded = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(excluded.isExcludedFromBackup == true, "\(url.path) is excluded from backup")
            print("[StoreImageFileTests] \(url.lastPathComponent) protection \(String(describing: protection(url)))")
            if storeProtection == .completeUnlessOpen {
                #expect(protection(url) == .completeUnlessOpen, "\(url.path) is protected like the store")
            }
        }
    }

    @Test func launchHardeningCoversImageFiles() throws {
        let store = try OnDiskChatStore()
        try store.chat(images: 1)
        TeemoonApp.hardenConversationStore(at: store.url)
        try expectHardened(store)
    }

    /// An image sent mid-session is hardened by its save, not at the next launch.
    @Test func savingAnImageHardensItsFile() throws {
        let store = try OnDiskChatStore()
        let observer = TeemoonApp.hardenAfterImageSaves(storeAt: store.url)
        defer { NotificationCenter.default.removeObserver(observer) }
        try store.chat(images: 1)
        try expectHardened(store)
    }
}

/// Delete means delete: an image's external file goes with its attachment row, on every path that
/// deletes one, and a surviving chat's file stays.
@MainActor
@Suite("Store image files — deletion")
struct StoreImageFileDeletionTests {

    /// The bytes of every external file on disk, as a set to compare with what the store still holds.
    private func onDisk(_ store: OnDiskChatStore) -> Set<Data> {
        Set(store.externalFiles.compactMap { try? Data(contentsOf: $0) })
    }

    private func held(_ store: OnDiskChatStore) throws -> Set<Data> {
        Set(try store.context.fetch(FetchDescriptor<ImageAttachment>()).map(\.data))
    }

    @Test func deletingAMessageDeletesItsImageFiles() throws {
        let store = try OnDiskChatStore()
        let (_, messages) = try store.chat(images: 2)
        try store.chat(images: 1)
        #expect(store.externalFiles.count == 3)
        MessageDeletion.delete([messages[0]], in: store.context)
        try store.context.save()
        #expect(store.externalFiles.count == 1, "only the other chat's image file remains")
        #expect(onDisk(store) == (try held(store)))
    }

    @Test func deletingAChatDeletesItsImageFiles() throws {
        let store = try OnDiskChatStore()
        let (thread, _) = try store.chat(images: 2)
        try store.chat(images: 1)
        #expect(store.externalFiles.count == 3)
        ThreadDeletion.delete(thread, in: store.context)
        #expect(store.externalFiles.count == 1, "only the other chat's image file remains")
        #expect(onDisk(store) == (try held(store)))
    }

    @Test func deletingAllChatsDeletesEveryImageFile() throws {
        let store = try OnDiskChatStore()
        try store.chat(images: 2)
        try store.chat(images: 1)
        #expect(store.externalFiles.count == 3)
        try ThreadDeletion.deleteAll(in: store.context)
        #expect(store.externalFiles.isEmpty)
    }
}
