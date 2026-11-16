//
//  ImportedChat.swift
//  teemoon
//
//  The source-neutral middle of an import (docs/IMPORT_NEAR.md §0): a source turns
//  its file into these, and ChatImportWriter turns these into rows without knowing
//  where they came from. A new source adds a ChatImportSource and a fixture folder.
//

import Foundation

struct ImportedChat: Equatable, Sendable {
    /// Unique within the source; the thread key is `<source>:<sourceId>`.
    var sourceId: String
    var title: String?
    /// Epoch ms, when the source has one.
    var createdAt: Int64?
    var messages: [ImportedMessage]
    /// Items the source could not read; counted only if the chat is written.
    var itemsSkipped: Int
    var mayBeIncomplete: Bool
}

struct ImportedMessage: Equatable, Sendable {
    enum Part: Equatable, Sendable {
        case text(String)
        case placeholder(Placeholder)
    }
    struct Placeholder: Equatable, Sendable {
        enum Kind: String, Sendable { case image, file }
        var kind: Kind
        var name: String?
        /// An image's inline `data:` URL, as the source gave it: untrusted, never fetched. The writer
        /// passes it to ImageIntake; any other URL is not carried.
        var dataURL: String? = nil
    }
    struct Source: Equatable, Sendable {
        var url: String
        var title: String?
    }

    /// Unique within the chat; the message key is `<source>:<chat sourceId>:<sourceId>`.
    var sourceId: String
    var role: Role
    var parts: [Part]
    /// Epoch ms as the source gives it; the writer makes each later than the last.
    var createdAt: Int64
    /// In order, not deduped.
    var sources: [Source]

    /// The placeholder parts in order, for a later pass that fills attachments by message key.
    var placeholders: [Placeholder] {
        parts.compactMap { if case .placeholder(let p) = $0 { p } else { nil } }
    }
}

/// One app's export format. Detect looks at the first element only (Android streams).
protocol ChatImportSource: Sendable {
    /// The key prefix, e.g. "near".
    var name: String { get }
    /// Which of this source's file kinds the first element starts, or nil.
    func detect(first: Any) -> ImportFileKind?
    /// A file whose elements are each one chat: one element within the caps, nil when it is skipped (counts 1).
    func chat(element: Data, depth: Int) -> ImportedChat?
    /// A file that is one chat: its items within the caps. `cutOff` when the scanner hit a broken
    /// element. Not called when an item is over a cap: the file is then over a cap and gives no chat.
    /// nil when the file gives no chat (counts 1).
    func chat(items: [(data: Data, depth: Int)], cutOff: Bool, fileBytes: Int) -> ImportedChat?
}

enum ImportFileKind: Sendable {
    /// Each top-level element is a chat; the importer streams them.
    case chatPerElement
    /// The file is one chat's items.
    case singleChat
}

struct ImportSummary: Equatable, Sendable {
    var chatsImported = 0
    var messagesImported = 0
    var chatsAlreadyHere = 0
    var itemsSkipped = 0
    var mayBeIncomplete = false
    var imagesImported = 0
    var imagesSkipped = 0
    /// Elements the scan read: the progress total for the import that follows a dry run.
    var elementsRead = 0
}
