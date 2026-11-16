//
//  ImportStaging.swift
//  teemoon
//
//  A shared export lands in Documents/Inbox, which the app may only read and delete. The flow runs on a copy
//  moved into Library/Caches/ImportStaging instead: never backed up, writable, so the protection class holds.
//

import Foundation

struct ImportStaging: Sendable {
    /// Each staged export sits in its own folder here, under its own name (the file card shows it).
    let root: URL
    let documents: URL?

    static let app = ImportStaging(
        root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportStaging", isDirectory: true),
        documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)

    func isInboxCopy(_ url: URL) -> Bool { ChatImportModel.isInboxCopy(url, documents: documents) }

    func isStaged(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    /// An Inbox copy moves here and the Inbox copy is gone; anything else comes back as it is. If the move
    /// is refused, the Inbox copy is hardened in place and still goes when the flow ends.
    func stage(_ url: URL) -> URL {
        guard isInboxCopy(url) else { return url }
        let fm = FileManager.default
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staged = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            TeemoonApp.hardenFile(at: root)
            TeemoonApp.hardenFile(at: folder)
            do {
                try fm.moveItem(at: url, to: staged)
            } catch {
                try fm.copyItem(at: url, to: staged)
                try? fm.removeItem(at: url)
            }
            TeemoonApp.hardenFile(at: staged)
            return staged
        } catch {
            try? fm.removeItem(at: folder)
            TeemoonApp.hardenFile(at: url.deletingLastPathComponent())
            TeemoonApp.hardenFile(at: url)
            return url
        }
    }

    /// The flow ended: teemoon's own copy goes (a staged one with its folder). The user's file is never touched.
    func discard(_ url: URL) {
        if isStaged(url) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        } else if isInboxCopy(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// At launch no flow is open, so anything here was left by a crash.
    func sweep() {
        try? FileManager.default.removeItem(at: root)
    }
}
