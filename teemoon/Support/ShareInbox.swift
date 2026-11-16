//
//  ShareInbox.swift
//  teemoon
//
//  What the share extension hands teemoon (docs/SHARE_IN.md): `Inbox/<uuid>/` in the App Group. The extension compiles
//  this file too, so it imports Foundation only; do not reach for an app type here.
//

import Foundation

struct ShareInbox {
    static let maxImages = 10
    /// ImageIntake.maxEncodedBytes, mirrored: ImageIntake links Wuffs, which the extension does not.
    static let maxImageBytes = 20 * 1024 * 1024
    static let maxTextCharacters = 100_000
    /// An entry, staging folder or unread taken folder older than this is purged when the app or extension starts.
    static let expiry: TimeInterval = 7 * 86_400

    enum Item: Equatable, Sendable {
        case image(URL)
        case text(String)
        case link(URL)
    }

    enum Refusal: Error, Equatable, Sendable {
        case overCap
        case textOverCap
        case unreadable
    }

    struct Entry: Equatable, Sendable {
        let id: UUID
        /// The shared files, in share order, out of the inbox but unread: `readImages` reads them.
        let imageFiles: [URL]
        let text: String
        /// Images the extension could not read; the composer says so.
        var unreadable = 0

        /// The bytes, unread by the intake (a file it cannot open is empty); the taken folder goes after.
        /// Never on the main thread: ten photos are up to 200 MB.
        func readImages() -> [Data] {
            let images = imageFiles.map { (try? Data(contentsOf: $0)) ?? Data() }
            if let folder = imageFiles.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) }
            return images
        }
    }

    let root: URL

    private var inbox: URL { root.appending(path: "Inbox", directoryHint: .isDirectory) }
    /// A taken entry with photos waits here for its read.
    private var taken: URL { root.appending(path: "Taken", directoryHint: .isDirectory) }
    private static let textFile = "text.txt"
    private static let unreadableFile = "unreadable.txt"
    private static let imagePrefix = "image-"
    /// Entries are built under this prefix and renamed into place, so `take` never sees half an entry.
    private static let stagingPrefix = "."

    /// Every cap is checked before a byte is copied; any refusal leaves nothing on disk.
    func write(_ items: [Item], unreadable: Int = 0) -> Result<UUID, Refusal> {
        purgeExpired()
        var images: [URL] = [], texts: [String] = []
        for item in items {
            switch item {
            case .image(let url): images.append(url)
            case .text(let text): texts.append(text)
            case .link(let url): texts.append(url.absoluteString)
            }
        }
        let text = texts.joined(separator: "\n")
        guard !images.isEmpty || !text.isEmpty else { return .failure(.unreadable) }
        guard images.count <= Self.maxImages else { return .failure(.overCap) }
        guard text.count <= Self.maxTextCharacters else { return .failure(.textOverCap) }
        for url in images {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard let size = values?.fileSize, values?.isRegularFile == true else { return .failure(.unreadable) }
            guard size <= Self.maxImageBytes else { return .failure(.overCap) }
        }

        let id = UUID()
        let fm = FileManager.default
        let staging = inbox.appending(path: Self.stagingPrefix + id.uuidString, directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            Self.harden(inbox)
            Self.harden(staging)
            for (n, url) in images.enumerated() {
                let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
                let name = Self.imagePrefix + String(format: "%02d", n) + "." + ext
                try fm.copyItem(at: url, to: staging.appending(path: name))
                Self.harden(staging.appending(path: name))
            }
            if !text.isEmpty { try Self.writeHardened(Data(text.utf8), to: staging.appending(path: Self.textFile)) }
            if unreadable > 0 {
                try Self.writeHardened(Data(String(unreadable).utf8), to: staging.appending(path: Self.unreadableFile))
            }
            try fm.moveItem(at: staging, to: inbox.appending(path: id.uuidString, directoryHint: .isDirectory))
        } catch {
            try? fm.removeItem(at: staging)
            return .failure(.unreadable)
        }
        return .success(id)
    }

    /// The newest entry inside `expiry`; it and every older entry leave the inbox at once. Its photos are moved out,
    /// not read: `Entry.readImages` reads them off the main thread.
    func take() -> Entry? {
        purgeExpired()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let folders = try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: keys) else { return nil }
        let entries = folders.compactMap { url -> (UUID, URL, Date)? in
            guard let id = UUID(uuidString: url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true else { return nil }
            return (id, url, values.contentModificationDate ?? .distantPast)
        }
        guard let newest = entries.max(by: { $0.2 < $1.2 }) else { return nil }
        let files = (try? fm.contentsOfDirectory(atPath: newest.1.path)) ?? []
        let names = files.filter { $0.hasPrefix(Self.imagePrefix) }.sorted()
        let text = (try? Data(contentsOf: newest.1.appending(path: Self.textFile))).map { String(decoding: $0, as: UTF8.self) }
        let unreadable = (try? Data(contentsOf: newest.1.appending(path: Self.unreadableFile)))
            .flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        // A read the app never finished (it was killed) leaves its folder here; only the newest share is wanted.
        try? fm.removeItem(at: taken)
        var folder = newest.1
        if !names.isEmpty {
            let moved = taken.appending(path: newest.0.uuidString, directoryHint: .isDirectory)
            if (try? fm.createDirectory(at: taken, withIntermediateDirectories: true)) != nil,
               (try? fm.moveItem(at: newest.1, to: moved)) != nil {
                folder = moved
                Self.harden(taken)
                // Its age restarts: a purge must not take a folder whose read is under way.
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: moved.path)
            }
        }
        for entry in entries where entry.1 != folder { try? fm.removeItem(at: entry.1) }
        if names.isEmpty { try? fm.removeItem(at: folder) }
        return Entry(id: newest.0, imageFiles: names.map { folder.appending(path: $0) }, text: text ?? "",
                     unreadable: unreadable)
    }

    /// Removes inbox entries, staging folders and taken folders older than `expiry`. Never touches anything newer.
    func purgeExpired(now: Date = Date()) {
        let fm = FileManager.default
        for dir in [inbox, taken] {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for item in items {
                guard let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate, now.timeIntervalSince(modified) > Self.expiry else { continue }
                try? fm.removeItem(at: item)
            }
        }
    }

    /// Out of backups and `.completeUnlessOpen`, like the chat store: a share made just before the phone locks still
    /// finishes writing, and teemoon reads it once the phone is unlocked.
    private static func harden(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
    }

    private static func writeHardened(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .completeFileProtectionUnlessOpen)
        harden(url)
    }

    func contains(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: inbox.appending(path: id.uuidString).path)
    }

    /// The bundle id as given, `.dev` kept: a dev build never shares a group with the store app.
    static func appGroupID(bundleID: String) -> String { "group." + bundleID }

    /// The extension is `<app bundle id>.share`.
    static func appBundleID(extensionBundleID: String) -> String? {
        let suffix = ".share"
        guard extensionBundleID.hasSuffix(suffix) else { return nil }
        return String(extensionBundleID.dropLast(suffix.count))
    }

    static func link(for id: UUID, bundleID: String) -> URL? { URL(string: "\(bundleID)://share/\(id.uuidString)") }

    static func entryID(from url: URL, bundleID: String) -> UUID? {
        guard url.scheme?.lowercased() == bundleID.lowercased(), url.host() == "share" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    /// The app's inbox: nil until the App Group entitlement exists.
    static func inApp(bundle: Bundle = .main) -> ShareInbox? {
        bundle.bundleIdentifier.flatMap { forApp(bundleID: $0) }
    }

    /// The share extension's view of the same inbox.
    static func inExtension(bundle: Bundle = .main) -> ShareInbox? {
        bundle.bundleIdentifier.flatMap { appBundleID(extensionBundleID: $0) }.flatMap { forApp(bundleID: $0) }
    }

    private static func forApp(bundleID: String) -> ShareInbox? {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID(bundleID: bundleID))
        else { return nil }
        return ShareInbox(root: root)
    }
}
