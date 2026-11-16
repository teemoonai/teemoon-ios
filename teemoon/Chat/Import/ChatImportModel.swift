//
//  ChatImportModel.swift
//  teemoon
//
//  Runs an import for the import page: a dry run reads the picked file and counts what it would write,
//  the user confirms, the import writes on a background context, then search indexes the new rows.
//  The views only show `state`.
//

import Foundation
import Observation
import SwiftData
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "import")

@MainActor
@Observable
final class ChatImportModel {

    enum Failure: Error, Equatable {
        /// No source reads it.
        case wrongFile
        /// Permission, or an iCloud file that isn't downloaded.
        case cantOpen
        /// A save failed part way; whole chats already written are kept.
        case stopped
    }

    /// What the file card shows, read when the dry run opens the file.
    struct FileFacts: Equatable, Sendable {
        var name: String
        var modified: Date?
        var bytes: Int?
        /// The file itself is writable: only then can the done step offer to delete it.
        var writable = false
    }

    enum State: Equatable {
        case idle
        /// The dry run is reading the file.
        case checking
        /// What the import will write; nothing is written yet.
        case confirm(ImportSummary)
        /// Chats written so far, of the new chats the dry run counted.
        case importing(read: Int, total: Int)
        case finished(ImportSummary)
        case failed(Failure)
    }

    private(set) var state: State = .idle
    /// Bumped when a flow is reset: a dry run or import from an earlier flow writes nothing.
    private var flow = 0
    private var fileURL: URL?
    private(set) var file: FileFacts?
    /// The export an import just read, while it can be deleted: the done step says nothing about it.
    private var deletable: ExportFile?
    /// Asked after "done" or "show chats", once the sheet has closed, never over the result (D4);
    /// it outlives `dismissResult`, and either answer clears it.
    private(set) var deleteOffer: ExportFile?
    /// "show chats" waits for the answer to the delete offer.
    private var chatsAfterOffer = false
    /// The delete failed: an alert says so.
    private(set) var deleteFailed: ExportFile?

    struct ExportFile: Equatable {
        var url: URL
        var name: String
        /// Opened from Files: the main screen asks, not Settings.
        var fromOutside = false
    }

    /// A file opened from Files or the share sheet: the main screen shows the flow in its own sheet.
    private(set) var openedFromOutside = false
    /// "show chats" on the done step: the main screen closes Settings (or its sheet) and opens the chats list.
    var showChatsRequested = false

    /// Where a shared export is moved out of Documents/Inbox for the flow.
    let staging: ImportStaging

    init(staging: ImportStaging = .app) {
        self.staging = staging
    }

    var isBusy: Bool {
        switch state {
        case .checking, .importing: true
        default: false
        }
    }

    /// The main screen's sheet: only a flow it started, and never for a failure (that is an alert).
    var showsSheet: Bool { openedFromOutside && state != .idle && failureAlert == nil }

    var failureAlert: ChatImportText.Alert? { ChatImportText.alert(for: state) }

    func dismissResult() {
        flow += 1
        if let fileURL { staging.discard(fileURL) }
        state = .idle
        fileURL = nil
        file = nil
        deletable = nil
        openedFromOutside = false
    }

    /// The Settings import sheet closed: resets only a flow Settings started, never one opened from outside.
    func closeSettingsFlow() {
        guard !isBusy, !openedFromOutside else { return }
        dismissResult()
    }

    /// Only after an import that wrote chats, and only for the user's own file: a share-sheet copy (in Inbox or
    /// staged) is ours and goes anyway, and a file we can't write can't be deleted.
    nonisolated static func offersDelete(after summary: ImportSummary, file: FileFacts?, url: URL?,
                                         staging: ImportStaging = .app) -> Bool {
        guard summary.chatsImported > 0, let file, file.writable, let url else { return false }
        return !staging.isInboxCopy(url) && !staging.isStaged(url)
    }

    /// "done" (false) or "show chats" (true) on the done step: the sheet closes, then the delete offer, if any.
    func leave(showingChats: Bool) {
        deleteOffer = deletable
        chatsAfterOffer = showingChats && deleteOffer != nil
        dismissResult()
        if showingChats && deleteOffer == nil { requestChats() }
    }

    /// The list opens fresh: an earlier search would hide the chats just imported.
    private func requestChats() {
        ChatListSearchMemory.shared.query = ""
        showChatsRequested = true
    }

    func keepExport() {
        guard deleteOffer != nil else { return }
        deleteOffer = nil
        afterOffer()
    }

    func deleteExport() {
        guard let offer = deleteOffer else { return }
        deleteOffer = nil
        Task {
            let deleted = await Task.detached(priority: .userInitiated) { Self.delete(offer.url) }.value
            if deleted { afterOffer() } else { deleteFailed = offer }
        }
    }

    func dismissDeleteFailure() {
        deleteFailed = nil
        afterOffer()
    }

    private func afterOffer() {
        if chatsAfterOffer { requestChats() }
        chatsAfterOffer = false
    }

    /// A coordinated delete, so iCloud and other providers see it as the user's own.
    nonisolated static func delete(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var deleted = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [.forDeleting], error: &coordinationError) { at in
            do {
                try FileManager.default.removeItem(at: at)
                deleted = true
            } catch {
                logger.error("import: couldn't delete the export: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        return deleted
    }

    /// A file shared to teemoon is copied into Documents/Inbox; that copy goes when the flow ends, so no copy
    /// of the export stays behind. A file opened in place (Files) is never touched.
    nonisolated static func isInboxCopy(_ url: URL,
                                        documents: URL? = FileManager.default.urls(for: .documentDirectory,
                                                                                   in: .userDomainMask).first) -> Bool {
        guard let documents, url.isFileURL else { return false }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(inbox)
    }

    /// Reads `url` without writing and moves to `.confirm` with the counts, or to `.failed`.
    func check(url: URL, container: ModelContainer, fromOutside: Bool = false) {
        guard !isBusy else { return }
        deleteOffer = nil
        chatsAfterOffer = false
        if let fileURL, fileURL != url { staging.discard(fileURL) }
        let url = staging.stage(url)
        fileURL = url
        file = FileFacts(name: url.lastPathComponent)
        openedFromOutside = fromOutside
        state = .checking
        let mine = flow
        Task {
            let result = await Self.run(url: url, container: container, dryRun: true, saved: { _ in })
            guard mine == flow else { return }
            switch result {
            case .success(let (preview, facts)):
                file = facts
                state = .confirm(preview)
            case .failure(let failure): state = .failed(failure)
            }
        }
    }

    /// Writes what `.confirm` counted.
    func confirm(container: ModelContainer, mainContext: ModelContext) {
        guard case .confirm(let preview) = state, let url = fileURL else { return }
        state = .importing(read: 0, total: preview.chatsImported)
        let mine = flow
        Task {
            let result = await Self.run(url: url, container: container, dryRun: false) { [weak self] n in
                Task { @MainActor in
                    if case .importing(_, let total) = self?.state { self?.state = .importing(read: n, total: total) }
                }
            }
            switch result {
            case .success(let (summary, _)):
                if mine == flow {
                    state = .finished(summary)
                    if Self.offersDelete(after: summary, file: file, url: url, staging: staging), let file {
                        deletable = ExportFile(url: url, name: file.name, fromOutside: openedFromOutside)
                    }
                }
                // The chats are written either way, so search still indexes them.
                if summary.chatsImported > 0 { await ChatSearchService.shared.reconcile(in: mainContext) }
            case .failure(let failure):
                if mine == flow { state = .failed(failure) }
            }
        }
    }

    /// The progress bar's fill: chats written over the dry run's count, never past the end.
    nonisolated static func fraction(read: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, Double(read) / Double(total))
    }

    private nonisolated static func run(url: URL, container: ModelContainer, dryRun: Bool,
                                        saved: @escaping @Sendable (Int) -> Void) async -> Result<(ImportSummary, FileFacts), Failure> {
        await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Coordinated, so an iCloud file that isn't on the phone yet is downloaded before it is read.
            var read: Data?
            var facts = FileFacts(name: url.lastPathComponent)
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { at in
                read = try? Data(contentsOf: at, options: .mappedIfSafe)
                let values = try? at.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isWritableKey])
                facts.modified = values?.contentModificationDate
                facts.bytes = values?.fileSize ?? read?.count
                facts.writable = values?.isWritable ?? false
            }
            guard let data = read else {
                logger.error("import: can't open the file")
                return .failure(.cantOpen)
            }
            let context = ModelContext(container)
            context.autosaveEnabled = false
            do {
                let summary = try ChatImporter.run(data, into: context, dryRun: dryRun, afterSave: { saved($0) })
                logger.info("import\(dryRun ? " (dry run)" : ""): \(summary.chatsImported) chats, \(summary.messagesImported) messages, \(summary.chatsAlreadyHere) already here, \(summary.itemsSkipped) skipped")
                return .success((summary, facts))
            } catch is ChatImporter.WrongFile {
                return .failure(.wrongFile)
            } catch {
                logger.error("import stopped: \(String(describing: type(of: error)), privacy: .public)")
                return .failure(.stopped)
            }
        }.value
    }
}
