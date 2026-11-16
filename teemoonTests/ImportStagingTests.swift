//
//  ImportStagingTests.swift
//  teemoonTests
//
//  Plan B for shared exports (S17). iOS copies a shared file into Documents/Inbox, which Apple documents as
//  read/delete-only for the app: plan A's isExcludedFromBackup + completeUnlessOpen on that copy may be refused
//  on a device, and the copy (chat text and images) could then reach a backup while the import is open. So the
//  flow moves the copy into Library/Caches/ImportStaging on arrival and runs on that.
//
//  The simulator reads the protection class back as nil, so it is asserted only where it reads back.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@MainActor
@Suite("Import — staging a shared copy", .serialized)
struct ImportStagingTests {

    static let sample = ImportCorpusTests.folder.appendingPathComponent("sample/near-export-sample.json")

    /// Real Documents/Inbox (that is the path the app checks), a private staging root per test.
    private func fixture(_ source: URL? = nil) throws -> (inboxCopy: URL, staging: ImportStaging) {
        let docs = try #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let copy = inbox.appendingPathComponent("near-export-\(UUID().uuidString).json")
        if let source { try FileManager.default.copyItem(at: source, to: copy) } else { try Data("not an export".utf8).write(to: copy) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        return (copy, ImportStaging(root: root, documents: docs))
    }

    private func stagedFiles(_ staging: ImportStaging) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: staging.root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        return walk.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func theAppStagesUnderCachesNotDocuments() throws {
        let caches = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        #expect(ImportStaging.app.root.standardizedFileURL.path == caches.appendingPathComponent("ImportStaging").standardizedFileURL.path)
    }

    /// (a) and (b): on arrival the Inbox copy is gone, and the staged copy and its folders are out of backups.
    @Test func onArrivalNothingStaysInTheInboxAndTheStagedCopyIsOutOfBackups() async throws {
        let (copy, staging) = try fixture()
        defer { try? FileManager.default.removeItem(at: copy); staging.sweep() }
        let model = ChatImportModel(staging: staging)
        model.check(url: copy, container: try ImportCorpusTests.context().container, fromOutside: true)
        #expect(!FileManager.default.fileExists(atPath: copy.path), "the shared copy is still in Documents/Inbox")

        let staged = stagedFiles(staging)
        #expect(staged.count == 1, "one staged copy, found \(staged.map(\.lastPathComponent))")
        let file = try #require(staged.first)
        #expect(file.lastPathComponent == copy.lastPathComponent, "the file card shows the export's own name")
        for url in [file, file.deletingLastPathComponent(), staging.root] {
            let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true, "\(url.lastPathComponent) is in backups")
            if let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType {
                #expect(protection == .completeUnlessOpen, "\(url.lastPathComponent) is \(protection.rawValue)")
            }
        }
        await settle { !model.isBusy }
        model.dismissResult()
    }

    /// (c) and (d): the shared sample imports exactly what the file itself does, no delete offer follows,
    /// and the staged copy goes when the flow ends.
    @Test func aSharedExportImportsTheSameAndItsStagedCopyGoesWhenTheFlowEnds() async throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let (copy, staging) = try fixture(Self.sample)
        defer { try? FileManager.default.removeItem(at: copy); staging.sweep() }
        let direct = try ChatImporter.run(Data(contentsOf: Self.sample), into: try ImportCorpusTests.context())
        #expect(direct.chatsImported == 5 && direct.messagesImported == 28, "the corpus changed: \(direct)")

        let context = try ImportCorpusTests.context()
        let model = ChatImportModel(staging: staging)
        model.check(url: copy, container: context.container, fromOutside: true)
        await settle { if case .confirm = model.state { true } else { false } }
        guard case .confirm(let preview) = model.state else { Issue.record("no confirm step: \(model.state)"); return }
        #expect(preview == direct)
        #expect(model.file?.name == copy.lastPathComponent)
        model.confirm(container: context.container, mainContext: context)
        await settle { if case .finished = model.state { true } else { false } }
        guard case .finished(let summary) = model.state else { Issue.record("no finish: \(model.state)"); return }
        #expect(summary == direct, "shared: \(summary), the file itself: \(direct)")
        #expect(try context.fetchCount(FetchDescriptor<ChatThread>()) == 5)
        #expect(try context.fetchCount(FetchDescriptor<Message>()) == 28)
        #expect(stagedFiles(staging).count == 1, "the staged copy went before the flow ended")

        model.leave(showingChats: false)
        #expect(model.deleteOffer == nil, "a shared copy was teemoon's own: no offer")
        #expect(stagedFiles(staging).isEmpty, "the staged copy outlived the flow")
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    /// (d): a flow closed before it finishes takes its staged copy with it too.
    @Test func closingTheFlowEarlyRemovesTheStagedCopy() async throws {
        let (copy, staging) = try fixture()
        defer { try? FileManager.default.removeItem(at: copy); staging.sweep() }
        let model = ChatImportModel(staging: staging)
        model.check(url: copy, container: try ImportCorpusTests.context().container, fromOutside: true)
        #expect(stagedFiles(staging).count == 1)
        model.dismissResult()
        #expect(stagedFiles(staging).isEmpty)
    }

    /// (d): a crash leaves a staged copy behind; the launch sweep removes it.
    @Test func theLaunchSweepRemovesACopyACrashLeftBehind() throws {
        let (copy, staging) = try fixture()
        defer { try? FileManager.default.removeItem(at: copy) }
        let left = staging.stage(copy)
        #expect(staging.isStaged(left) && FileManager.default.fileExists(atPath: left.path))
        staging.sweep()
        #expect(!FileManager.default.fileExists(atPath: left.path))
        #expect(!FileManager.default.fileExists(atPath: staging.root.path))
    }

    /// (e): a file opened in place is the user's: it is read where it is, never moved, and still gets the offer.
    @Test func anOpenInPlaceOriginalIsUntouchedAndStillGetsTheOffer() async throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let (inboxCopy, staging) = try fixture()
        try? FileManager.default.removeItem(at: inboxCopy)
        defer { staging.sweep() }
        let original = FileManager.default.temporaryDirectory.appendingPathComponent("in-place-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: Self.sample, to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        let bytes = try Data(contentsOf: original)

        let context = try ImportCorpusTests.context()
        let model = ChatImportModel(staging: staging)
        model.check(url: original, container: context.container, fromOutside: true)
        #expect(stagedFiles(staging).isEmpty, "an in-place original was staged")
        await settle { if case .confirm = model.state { true } else { false } }
        model.confirm(container: context.container, mainContext: context)
        await settle { if case .finished = model.state { true } else { false } }
        model.leave(showingChats: false)
        #expect(try Data(contentsOf: original) == bytes, "the original changed")
        #expect(model.deleteOffer == ChatImportModel.ExportFile(url: original, name: original.lastPathComponent,
                                                                fromOutside: true))
        model.keepExport()
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func aStagedCopyNeverGetsTheDeleteOffer() {
        let staging = ImportStaging(root: URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/Library/Caches/ImportStaging"),
                                    documents: URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/Documents"))
        let wrote = ImportSummary(chatsImported: 2, messagesImported: 5)
        let writable = ChatImportModel.FileFacts(name: "export.json", writable: true)
        #expect(!ChatImportModel.offersDelete(after: wrote, file: writable,
                                              url: staging.root.appendingPathComponent("A/export.json"), staging: staging))
        #expect(ChatImportModel.offersDelete(after: wrote, file: writable,
                                             url: URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/export.json"),
                                             staging: staging))
        #expect(!staging.isStaged(URL(fileURLWithPath: staging.root.path + "Not/export.json")))
    }
}
