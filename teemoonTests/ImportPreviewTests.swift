//
//  ImportPreviewTests.swift
//  teemoonTests
//
//  The import page's confirm step (1.1.0 import redesign, b and c): a dry run counts exactly what the import
//  will write and writes nothing, and the chats it counts are the progress bar's total.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@MainActor
@Suite("Import — preview and progress", .serialized)
struct ImportPreviewTests {

    @Test func aDryRunCountsWhatTheImportWritesAndWritesNothing() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let data = try Data(contentsOf: ImportBehaviorTests.full)
        let context = try ImportCorpusTests.context()
        let preview = try ChatImporter.run(data, into: context, dryRun: true)
        #expect(try context.fetchCount(FetchDescriptor<ChatThread>()) == 0, "the dry run wrote chats")
        #expect(try context.fetchCount(FetchDescriptor<Message>()) == 0, "the dry run wrote messages")
        #expect(preview.chatsImported > 0)
        let real = try ChatImporter.run(data, into: context)
        #expect(preview == real, "the confirm step promised \(preview), the import wrote \(real)")
    }

    @Test func aDryRunAfterAnImportSaysEverythingIsAlreadyHere() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let data = try Data(contentsOf: ImportBehaviorTests.full)
        let context = try ImportCorpusTests.context()
        let first = try ChatImporter.run(data, into: context)
        let again = try ChatImporter.run(data, into: context, dryRun: true)
        #expect(again.chatsImported == 0)
        #expect(again.chatsAlreadyHere == first.chatsImported)
    }

    @Test func theElementCountIsTheLastProgressValue() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let data = try Data(contentsOf: ImportBehaviorTests.full)
        var last = 0
        let summary = try ChatImporter.run(data, into: try ImportCorpusTests.context(), dryRun: true) { last = $0 }
        #expect(summary.elementsRead == last && last > 0)
    }

    /// The page's steps: reading → confirm (nothing written) → importing → finished with what confirm promised;
    /// "show chats" leaves the page idle and asks the main screen for the list.
    @Test func thePageGoesFromConfirmToFinishedWithTheCountsItPromised() async throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let context = try ImportCorpusTests.context()
        let model = ChatImportModel()
        func settle(_ done: (ChatImportModel.State) -> Bool) async {
            for _ in 0..<200 where !done(model.state) { try? await Task.sleep(for: .milliseconds(25)) }
        }
        model.check(url: ImportBehaviorTests.full, container: context.container)
        await settle { if case .confirm = $0 { true } else { false } }
        guard case .confirm(let preview) = model.state else { Issue.record("no confirm step: \(model.state)"); return }
        #expect(try context.fetchCount(FetchDescriptor<ChatThread>()) == 0, "confirm wrote chats")
        #expect(model.file?.name == ImportBehaviorTests.full.lastPathComponent)
        #expect(model.file?.bytes ?? 0 > 0, "the card has no size")
        model.confirm(container: context.container, mainContext: context)
        await settle { if case .finished = $0 { true } else { false } }
        guard case .finished(let summary) = model.state else { Issue.record("no finish: \(model.state)"); return }
        #expect(summary == preview)
        // Never deleteExport() here: the file is the fixture in the source tree.
        model.leave(showingChats: true)
        #expect(model.state == .idle && model.file == nil)
        if model.deleteOffer != nil { model.keepExport() }   // the fixture is in the source tree: never delete it
        #expect(model.showChatsRequested)
    }

    /// A shared file is a copy in Documents/Inbox and goes when the flow ends; a file opened in place is the
    /// user's own and is never deleted.
    @Test func onlyAnInboxCopyIsCleanedUp() {
        let docs = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/Documents")
        #expect(ChatImportModel.isInboxCopy(docs.appendingPathComponent("Inbox/export.json"), documents: docs))
        #expect(!ChatImportModel.isInboxCopy(docs.appendingPathComponent("export.json"), documents: docs))
        #expect(!ChatImportModel.isInboxCopy(docs.appendingPathComponent("InboxNot/export.json"), documents: docs))
        #expect(!ChatImportModel.isInboxCopy(URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/export.json"),
                                             documents: docs))
    }

    /// The progress line says "N of M chats": the import reports chats written, and the last one is the dry run's count.
    @Test func progressCountsChatsWrittenUpToTheDryRunsCount() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let data = try Data(contentsOf: ImportBehaviorTests.full)
        let context = try ImportCorpusTests.context()
        let preview = try ChatImporter.run(data, into: context, dryRun: true)
        var written: [Int] = []
        _ = try ChatImporter.run(data, into: context, afterSave: { written.append($0) })
        #expect(written == Array(1...preview.chatsImported))
        #expect(ChatImportText.progress(read: 4, total: 6) == "4 of 6 chats")
        #expect(ChatImportText.progress(read: 0, total: 1) == "0 of 1 chat")
    }

    /// The delete offer (pm 11-01): only after an import that wrote chats, only for the user's own writable file.
    @Test func theDeleteOfferNeedsChatsWrittenAndTheUsersOwnWritableFile() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let own = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/export.json")
        let wrote = ImportSummary(chatsImported: 2, messagesImported: 5)
        let writable = ChatImportModel.FileFacts(name: "export.json", writable: true)
        #expect(ChatImportModel.offersDelete(after: wrote, file: writable, url: own))
        #expect(!ChatImportModel.offersDelete(after: ImportSummary(chatsAlreadyHere: 3), file: writable, url: own),
                "nothing new written")
        #expect(!ChatImportModel.offersDelete(after: wrote, file: .init(name: "export.json"), url: own), "read-only")
        #expect(!ChatImportModel.offersDelete(after: wrote, file: writable,
                                              url: docs.appendingPathComponent("Inbox/export.json")), "a share-sheet copy")
        #expect(!ChatImportModel.offersDelete(after: wrote, file: nil, url: own))
    }

    /// D4 (the maintainer 11-01): the offer waits until "done" or "show chats", never over the result, outlives the
    /// sheet's reset, and "show chats" waits for the answer. A copy of the fixture, so deleting it is safe.
    @Test func theDeleteOfferComesAfterLeavingAndShowChatsWaitsForTheAnswer() async throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("import-offer-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: ImportBehaviorTests.full, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let context = try ImportCorpusTests.context()
        let model = ChatImportModel()
        func settle(_ done: @escaping () -> Bool) async {
            for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(25)) }
        }
        model.check(url: copy, container: context.container)
        await settle { if case .confirm = model.state { true } else { false } }
        model.confirm(container: context.container, mainContext: context)
        await settle { if case .finished = model.state { true } else { false } }
        #expect(model.deleteOffer == nil, "the offer must not cover the result")

        model.leave(showingChats: true)
        model.dismissResult()   // the sheet's onDismiss
        #expect(model.deleteOffer == ChatImportModel.ExportFile(url: copy, name: copy.lastPathComponent))
        #expect(!model.showChatsRequested, "the chats list opens after the answer, not under the alert")
        model.deleteExport()
        await settle { model.showChatsRequested }
        #expect(model.showChatsRequested && model.deleteOffer == nil && model.deleteFailed == nil)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func doneWithoutAnOfferJustCloses() {
        let model = ChatImportModel()
        model.leave(showingChats: false)
        #expect(model.deleteOffer == nil && !model.showChatsRequested)
        model.leave(showingChats: true)
        #expect(model.showChatsRequested, "no offer: show chats goes straight to the list")
    }

    /// android 2026-11-06: "show chats" opened the list with the session's last search restored, which can
    /// hide the chats just imported. Both ways to it (no offer; after the offer's answer) start the list fresh.
    @Test func showChatsOpensTheListWithoutTheOldSearch() async throws {
        defer { ChatListSearchMemory.shared.query = "" }
        ChatListSearchMemory.shared.query = "tide pools"
        let direct = ChatImportModel()
        direct.leave(showingChats: true)
        #expect(direct.showChatsRequested)
        #expect(ChatListSearchMemory.shared.query.isEmpty, "the list would reopen filtered to an older search")

        guard TestFixture.sourceTreeAvailable() else { return }
        ChatListSearchMemory.shared.query = "tide pools"
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("import-fresh-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: ImportBehaviorTests.full, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let context = try ImportCorpusTests.context()
        let model = ChatImportModel()
        func settle(_ done: @escaping () -> Bool) async {
            for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(25)) }
        }
        model.check(url: copy, container: context.container)
        await settle { if case .confirm = model.state { true } else { false } }
        model.confirm(container: context.container, mainContext: context)
        await settle { if case .finished = model.state { true } else { false } }
        model.leave(showingChats: true)
        model.dismissResult()
        model.keepExport()
        await settle { model.showChatsRequested }
        #expect(model.showChatsRequested)
        #expect(ChatListSearchMemory.shared.query.isEmpty, "after the offer, too")
    }

    @Test func deletingTheExportRemovesItAndAMissingFileIsAFailure() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-delete-\(UUID().uuidString).json")
        try Data("[]".utf8).write(to: url)
        #expect(ChatImportModel.delete(url))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!ChatImportModel.delete(url), "a failed delete must be reported, not swallowed")
    }

    @Test func progressIsAFractionOfTheDryRunsCount() {
        #expect(ChatImportModel.fraction(read: 0, total: 0) == 0)
        #expect(ChatImportModel.fraction(read: 3, total: 12) == 0.25)
        #expect(ChatImportModel.fraction(read: 20, total: 12) == 1, "never past the end")
    }
}

/// Settings and a file opened from Files share one importer. Opening a file from outside while the Settings
/// import sheet was up started the outside flow, and then the Settings sheet's close reset it.
@MainActor
@Suite("Import — shared importer", .serialized)
struct ImportSharedImporterTests {

    private func settle(_ done: () -> Bool) async {
        for _ in 0..<80 where !done() { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func closingTheSettingsSheetLeavesAFlowOpenedFromOutside() async throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let context = try ImportCorpusTests.context()
        let model = ChatImportModel()
        model.check(url: ImportBehaviorTests.full, container: context.container, fromOutside: true)
        await settle { if case .confirm = model.state { true } else { false } }
        guard case .confirm = model.state else { Issue.record("no confirm step: \(model.state)"); return }
        model.closeSettingsFlow()
        #expect(model.showsSheet, "the outside flow's sheet must survive Settings closing")
        if case .confirm = model.state {} else { Issue.record("the outside flow was reset: \(model.state)") }
    }

    @Test func aCheckForAResetFlowWritesNothing() async throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let context = try ImportCorpusTests.context()
        let model = ChatImportModel()
        model.check(url: ImportBehaviorTests.full, container: context.container)
        model.dismissResult()
        await settle { model.state != .idle }
        #expect(model.state == .idle, "a late dry run brought back a flow that was closed")
        #expect(model.file == nil)
    }
}
