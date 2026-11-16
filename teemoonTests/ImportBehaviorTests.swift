//
//  ImportBehaviorTests.swift
//  teemoonTests
//
//  The import's promises beyond the corpus (docs/IMPORT_NEAR.md §7 tests 1–9, §9):
//  pinned keys, no network and no image decoding, an interrupted import finished by
//  running it again, nothing stored beyond the conversation text, search picks the
//  rows up, and memory follows the largest chat, not the file.
//

import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import teemoon

@MainActor
@Suite("Import — behaviour", .serialized)
struct ImportBehaviorTests {

    static let full = ImportCorpusTests.folder.appendingPathComponent("near-export-v1.json")

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test func anImportedMessageKeepsAsManyImagesAsASentOne() {
        #expect(ChatImportWriter.maxImagesPerMessage == ChatViewModel.cloudImagesPerSend)
        #expect(ChatImportWriter.maxImagesPerMessage == 10)
    }

    @Test func theFixturesAreTheOnesTheSpecPins() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        #expect(Self.sha(try Data(contentsOf: Self.full))
                == "6b20405d85fb80d3d9106614b9a9146ebd0b2a10d03c445f508cc9c0fbe63e6f")
        #expect(Self.sha(try Data(contentsOf: ImportCorpusTests.folder.appendingPathComponent("near-chat-export-v1.json")))
                == "6d2f62d1185eaae15f089a63a5331e47d43816aadff2df9f8573407344d03a03")
    }

    /// The UUIDs are iOS's storage form of the key strings; changing the namespace orphans every import.
    @Test func keysArePinned() {
        #expect(ImportKey.uuid("near:conv_lisbon").uuidString == "66E8DED4-E3F0-5BE6-B010-20C2E139DE01")
        #expect(ImportKey.uuid("near:conv_prime:msg_u1").uuidString == "9F8E71F6-54A0-5043-8E98-BAEFBD82F00A")
        #expect(ImportKey.uuid("near:conv_damaged:msg_a1").uuidString == "EE4D83F2-76BD-5D54-8DB4-07EFB3F7355B")
        #expect(ImportKey.uuid("near:chat:resp_c1").uuidString == "CB5C8D26-FE36-59FE-B579-65929E4684E6")
        #expect(ImportKey.uuid("near:chat:resp_c1:msg_c1").uuidString == "D6916681-AB83-51FF-8DA1-432F8DD823EE")
        #expect(ImportKey.uuid("near:chat:resp_p1").uuidString == "39FABD04-F5B8-5035-8AC9-A859E6D54B12")
    }

    @Test func anInterruptedImportIsFinishedByRunningItAgain() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let data = try Data(contentsOf: Self.full)
        struct Stop: Error {}
        let clean = try ImportCorpusTests.context()
        _ = try ChatImporter.run(data, into: clean)

        let broken = try ImportCorpusTests.context()
        #expect(throws: Stop.self) {
            try ChatImporter.run(data, into: broken, afterSave: { if $0 == 2 { throw Stop() } })
        }
        #expect(try broken.fetchCount(FetchDescriptor<ChatThread>()) == 2, "whole chats or nothing")
        _ = try ChatImporter.run(data, into: broken)
        func rows(_ c: ModelContext) throws -> [[String]] {
            try c.fetch(FetchDescriptor<Message>()).map { [$0.id.uuidString, $0.content, "\($0.timestamp.timeIntervalSince1970)",
                                                          $0.thread?.id.uuidString ?? "-",
                                                          $0.groundingSources.map { "\($0.url)|\($0.domain)|\($0.title)" }.joined(separator: ",")] }
                .sorted { $0[0] < $1[0] }
        }
        #expect(try rows(broken) == rows(clean), "decoded sources, not sourcesJSON bytes: its key order is not stable")
        #expect(try broken.fetchCount(FetchDescriptor<ChatThread>()) == clean.fetchCount(FetchDescriptor<ChatThread>()))
    }

    @Test func nothingBeyondTheConversationTextIsStored() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let context = try ImportCorpusTests.context()
        _ = try ChatImporter.run(Data(contentsOf: Self.full), into: context)
        for m in try context.fetch(FetchDescriptor<Message>()) {
            for field in [m.content, m.sourcesJSON ?? "", m.thread?.title ?? ""] {
                #expect(!field.contains("Sample Person") && !field.contains("user_0001") && !field.contains("GLM"),
                        "author or model leaked into \(m.id)")
                #expect(!field.contains("data:image"), "an image's bytes were stored")
            }
            #expect(!m.isE2EE && m.generatingTime == nil)
        }
    }

    /// No request leaves during an import: every URLSession the app could reach is watched.
    @Test func anImportMakesNoRequest() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        NoNetwork.requests.value = 0
        URLProtocol.registerClass(NoNetwork.self)
        defer { URLProtocol.unregisterClass(NoNetwork.self) }
        let context = try ImportCorpusTests.context()
        _ = try ChatImporter.run(Data(contentsOf: Self.full), into: context)
        _ = try ChatImporter.run(Data(contentsOf: ImportCorpusTests.folder.appendingPathComponent("near-chat-export-v1.json")),
                                 into: context)
        #expect(NoNetwork.requests.value == 0)
    }

    /// The import code has no way to reach the network or decode an image.
    @Test func theImportCodeHasNoNetworkOrImageDecoding() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("teemoon/Chat/Import")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 5)
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
            // Images: the import hands data: URLs to ImageIntake, the one file that decodes base64 (IMAGES.md §3).
            for banned in ["URLSession", "URLRequest", "NWConnection", "base64Encoded", "UIImage", "CGImage",
                           "contentsOf: URL(string", "openURL"] {
                #expect(!code.contains(banned), "\(file.lastPathComponent) uses \(banned)")
            }
        }
    }

    @Test func searchIndexesTheImportedMessages() async throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        _ = try ChatImporter.run(Data(contentsOf: Self.full), into: container.mainContext)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        let index = ChatSearchIndex(databaseURL: url)
        let stats = try await ChatSearchReconciler(index: index).reconcile(in: container.mainContext)
        #expect(stats.inserted == 25)
        #expect(try await index.search("Alfama", granularity: .messages, limit: 10).count == 1)
    }

    /// 5,000 chats: resident memory follows one chat, not the file (§7 test 7).
    @Test func aLargeFileImportsWithFlatMemory() throws {
        guard let c = ImportCorpusTests.manifest.first(where: { $0["name"] as? String == "many-chats" }) else { return }
        let data = try ImportCorpusTests.bytes(c)
        let context = try ImportCorpusTests.context()
        let baseline = Self.footprint()
        var peak = baseline
        let summary = try ChatImporter.run(data, into: context, progress: { n in
            if n % 250 == 0 { peak = max(peak, Self.footprint()) }
        })
        #expect(summary.chatsImported == 5000 && summary.messagesImported == 10000)
        let grew = Double(peak - baseline) / 1_048_576
        #expect(grew < 100, "peak grew \(grew) MB during the import")
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

private final class NoNetwork: URLProtocol {
    static let requests = LockedBox<Int>(0)
    override class func canInit(with request: URLRequest) -> Bool { requests.value += 1; return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
