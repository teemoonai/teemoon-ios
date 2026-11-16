//
//  ChatImportText.swift
//  teemoon
//
//  What the import summary says (docs/IMPORT_NEAR.md §8). Proposals: the maintainer edits the
//  wording. Only the placeholder lines in ChatImportWriter are pinned by the corpus.
//

import Foundation

enum ChatImportText {

    struct Alert: Equatable {
        let title: String
        let message: String?
    }

    /// A failed import is a system alert (UI audit #8); a finished one is the summary sheet.
    static func alert(for state: ChatImportModel.State) -> Alert? {
        guard case .failed(let failure) = state else { return nil }
        switch failure {
        case .wrongFile:
            return Alert(title: "this file can't be imported", message: "it isn't a chat export teemoon can read.")
        case .cantOpen:
            return Alert(title: "couldn't open this file", message: nil)
        case .stopped:
            return Alert(title: "the import stopped",
                         message: "chats already imported are kept; import the same file again to finish.")
        }
    }

    static let alertButton = "ok"
    static let footerLead = "from near.ai private chat. it stays on this phone."

    // MARK: - The import sheet (1.1.0, Safari style). PLACEHOLDERS: review entry import-page-strings v2.

    static let pageTitle = "import from near.ai"
    static let intro = "bring your chats from near.ai private chat into teemoon. they're saved only on this phone."
    static let exportPath = "in near.ai private chat: settings → chats → export chats."
    static let chooseFile = "choose file…"
    static let chooseAnother = "choose another file…"
    static let importButton = "import"
    static let importingTitle = "importing…"
    static let importingBody = "keep teemoon open until it's done."
    static let finishedTitle = "import finished"
    static let nothingNewTitle = "nothing new to import"
    static let nothingNewBody = "every chat in this file is already in teemoon."
    static let emptyTitle = "nothing to import"
    static let emptyBody = "this file has no chats in it."
    static let showChats = "show chats"
    static let done = "done"
    static let cancel = "cancel"

    static let deleteTitle = "delete the export file?"
    static func deleteMessage(_ name: String) -> String {
        "\(name) holds your chats unencrypted. teemoon has its own copy now. this can't be undone."
    }
    static func deleteButton(_ name: String) -> String { "delete “\(name)”" }
    static let notNow = "not now"
    static let deleteFailedTitle = "couldn't delete the file"
    static let deleteFailedMessage = "it's still where it was. you can delete it in Files."

    /// The dry run found nothing to write: a result screen of its own, "done" at the bottom (v7 already here, v8 empty).
    static func isNothingNew(_ s: ImportSummary) -> Bool { s.chatsImported == 0 }

    static func title(for state: ChatImportModel.State) -> String {
        switch state {
        case .confirm(let s) where isNothingNew(s): s.chatsAlreadyHere > 0 ? nothingNewTitle : emptyTitle
        case .importing: importingTitle
        case .finished: finishedTitle
        default: pageTitle
        }
    }

    /// "6 chats, 25 messages and 1 image": what the file holds that isn't here yet.
    static func contents(_ s: ImportSummary) -> String {
        var parts = [count(s.chatsImported, "chat"), count(s.messagesImported, "message")]
        if s.imagesImported > 0 { parts.append(count(s.imagesImported, "image")) }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    /// The file card's counts line, from the dry run.
    /// nil for a file with no chats: "0 chats" would repeat the body.
    static func cardCounts(_ s: ImportSummary) -> String? {
        // Nothing new: the file's chat count only; the dry run counts no messages in chats already here.
        guard isNothingNew(s) else { return contents(s) }
        return s.chatsAlreadyHere > 0 ? count(s.chatsAlreadyHere, "chat") : nil
    }

    /// The card's small line under the divider: only the parts that apply, nil when none do or nothing is new.
    static func cardNote(_ s: ImportSummary) -> String? {
        guard s.chatsImported > 0 else { return nil }
        var out: [String] = []
        if s.chatsAlreadyHere > 0 {
            out.append(s.chatsAlreadyHere == 1 ? "1 chat already here stays as it is."
                                               : "\(s.chatsAlreadyHere) chats already here stay as they are.")
        }
        if s.itemsSkipped > 0 {
            out.append("\(count(s.itemsSkipped, "item")) can't be read and will be skipped.")
        }
        return out.isEmpty ? nil : out.joined(separator: " ")
    }

    /// "oct 15 · 24 KB"; either part may be missing.
    static func fileFacts(_ f: ChatImportModel.FileFacts, locale: Locale = .current) -> String? {
        let parts = [f.modified.map { $0.formatted(Date.FormatStyle(locale: locale).month(.abbreviated).day()).lowercased() },
                     f.bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Chats, not file elements: the total is the new chats the dry run counted.
    static func progress(read: Int, total: Int) -> String { "\(read) of \(count(total, "chat"))" }

    static func finishedBody(_ s: ImportSummary) -> String {
        s.chatsImported == 0 ? "there was nothing new to import." : "teemoon imported \(contents(s))."
    }

    /// The done step's grey lines under the body.
    static func finishedNotes(_ s: ImportSummary) -> [String] {
        var out: [String] = []
        if s.itemsSkipped > 0 {
            out.append("\(count(s.itemsSkipped, "item")) couldn't be read and \(s.itemsSkipped == 1 ? "was" : "were") skipped.")
        }
        if s.imagesSkipped > 0 {
            out.append("\(count(s.imagesSkipped, "image")) couldn't be imported.")
        }
        if s.mayBeIncomplete {
            out.append("part of this chat may be missing: the file was cut short or holds only its first 100 messages. if you have the full export, import that too.")
        }
        return out
    }

    private static func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
}
