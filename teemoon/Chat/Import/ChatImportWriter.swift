//
//  ChatImportWriter.swift
//  teemoon
//
//  Turns ImportedChats into Thread/Message rows (docs/IMPORT_NEAR.md §0, §2, §3.5–3.10).
//  It knows nothing about any source: keys are `<source>:<chat>` and
//  `<source>:<chat>:<message>`, stored as name-based UUIDs, so a re-import finds what
//  is already here and a deleted chat comes back with the same ids.
//
//  One save per chat: an interrupted import leaves whole chats or nothing.
//

import CryptoKit
import Foundation
import SwiftData

struct ChatImportWriter {

    static let placeholderImage = "[image not imported]"
    static let placeholderFile = "[file not imported]"
    /// Images per imported message; the rest are placeholders (IMAGES.md §2). Equal to
    /// `ChatViewModel.cloudImagesPerSend`; a test pins it, the import layer must not import the view model.
    static let maxImagesPerMessage = 10

    let source: String
    let context: ModelContext
    /// Tests stop an import after a given number of chats are saved.
    var afterSave: ((Int) throws -> Void)? = nil
    /// Count what would be written and write nothing: the import page's confirm step.
    var dryRun = false

    private(set) var summary = ImportSummary()
    private var saved = 0
    /// What a dry run has counted, so a chat twice in one file counts the way the import treats it.
    private var counted = Set<UUID>()

    init(source: String, context: ModelContext) {
        self.source = source
        self.context = context
    }

    mutating func write(_ chat: ImportedChat) throws {
        let key = "\(source):\(chat.sourceId)"
        let threadID = ImportKey.uuid(key)
        if try exists(threadID) || (dryRun && counted.contains(threadID)) {
            summary.chatsAlreadyHere += 1                       // nothing read from it is counted
            return
        }
        summary.itemsSkipped += chat.itemsSkipped
        summary.mayBeIncomplete = summary.mayBeIncomplete || chat.mayBeIncomplete

        var rows: [(ImportedMessage, String, Date, String?, [(Int, ImageIntake.Image)])] = []
        var last: Int64 = 0
        var imagesImported = 0, imagesSkipped = 0
        for m in chat.messages {
            var lines: [String] = []
            var images: [(Int, ImageIntake.Image)] = []
            var imageIndex = 0
            for part in m.parts {
                if case .placeholder(let p) = part, p.kind == .image {
                    defer { imageIndex += 1 }
                    if imageIndex < Self.maxImagesPerMessage, let url = p.dataURL,
                       case .success(let image) = ImageIntake.fromDataURL(url) {
                        images.append((imageIndex, image))
                        continue
                    }
                    imagesSkipped += 1
                }
                lines.append(Self.line(part))
            }
            let text = lines.joined(separator: "\n\n")
            guard !text.isEmpty || !images.isEmpty else { summary.itemsSkipped += 1; continue }
            let ms = m.createdAt > last ? m.createdAt : last + 1
            last = ms
            imagesImported += images.count
            rows.append((m, text, Date(timeIntervalSince1970: Double(ms) / 1000), Self.sourcesJSON(m.sources), images))
        }
        guard let lastRow = rows.last else { summary.itemsSkipped += 1; return }
        if dryRun {
            counted.insert(threadID)
            summary.chatsImported += 1
            summary.messagesImported += rows.count
            summary.imagesImported += imagesImported
            summary.imagesSkipped += imagesSkipped
            return
        }

        let thread = Thread()
        thread.id = threadID
        thread.title = chat.title
        thread.timestamp = lastRow.2
        context.insert(thread)
        for (m, text, date, sources, images) in rows {
            let messageKey = "\(key):\(m.sourceId)"
            let message = Message(role: m.role, content: text, thread: thread, sourcesJSON: sources)
            message.id = ImportKey.uuid(messageKey)
            message.timestamp = date
            context.insert(message)
            for (index, image) in images {
                context.insert(ImageAttachment(id: ImportKey.uuid("\(messageKey)#\(index)"), messageID: message.id,
                                               index: index, mimeType: image.mimeType, width: image.width,
                                               height: image.height, data: image.data, thumbnail: image.thumbnail))
            }
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        summary.chatsImported += 1
        summary.messagesImported += rows.count
        summary.imagesImported += imagesImported
        summary.imagesSkipped += imagesSkipped
        saved += 1
        try afterSave?(saved)
    }

    mutating func countSkipped(_ n: Int) { summary.itemsSkipped += n }

    private func exists(_ id: UUID) throws -> Bool {
        var d = FetchDescriptor<Thread>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetchCount(d) > 0
    }

    static func line(_ part: ImportedMessage.Part) -> String {
        switch part {
        case .text(let t): return t
        case .placeholder(let p):
            let base = p.kind == .image ? placeholderImage : placeholderFile
            guard let name = p.name else { return base }
            return String(base.dropLast()) + ": \(name)]"
        }
    }

    /// Deduped by URL, first wins. Domain is the web-search path's host rule, case kept.
    static func sourcesJSON(_ sources: [ImportedMessage.Source]) -> String? {
        var seen = Set<String>()
        let list: [GroundingSource] = sources.compactMap { s in
            guard seen.insert(s.url).inserted else { return nil }
            let domain = URL(string: s.url)?.host ?? s.url
            return GroundingSource(url: s.url, domain: domain, title: s.title ?? domain, snippet: "")
        }
        return list.isEmpty ? nil : GroundingSource.encodedJSON(list)
    }
}

/// Name-based (v5) UUIDs of import keys. The key string is the cross-platform contract;
/// the UUID is iOS's storage form of it. The namespace never changes.
enum ImportKey {
    static let namespace = UUID(uuidString: "849A737B-2BA2-43F7-A24D-EE23A2C10D62")!

    static func uuid(_ key: String) -> UUID {
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes.append(contentsOf: Array(key.utf8))
        var hash = Array(Insecure.SHA1.hash(data: bytes)).prefix(16).map { $0 }
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }
}
