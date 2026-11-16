//
//  ImportCorpusTests.swift
//  teemoonTests
//
//  Every case in conformance/import/near/cases.json, through the real scanner, source and
//  writer into an in-memory store: totals on the first and second run, thread keys, and
//  every stored field where the manifest lists them. The expected values come from
//  conformance/import/tools/reference_import.py; Android runs the same manifest.
//  Skips when the source tree is not reachable (a device run, or the public tree).
//

import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import teemoon

@MainActor
@Suite("Import — near corpus", .serialized)
struct ImportCorpusTests {

    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("conformance/import/near")

    static var manifest: [[String: Any]] {
        guard TestFixture.sourceTreeAvailable(),
              let data = try? Data(contentsOf: folder.appendingPathComponent("cases.json")),
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return m["cases"] as? [[String: Any]] ?? []
    }

    static func context() throws -> ModelContext {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// The case's bytes: its committed file, or its recipe expanded. Checked against the manifest's sha256.
    static func bytes(_ c: [String: Any]) throws -> Data {
        let data: Data
        if let file = c["file"] as? String {
            data = try Data(contentsOf: folder.appendingPathComponent(file))
        } else {
            var out = Data()
            for part in try #require(c["recipe"] as? [Any]) {
                if let s = part as? String { out.append(Data(s.utf8)); continue }
                let p = try #require(part as? [String: Any])
                let count = try #require(p["count"] as? Int)
                if let r = p["repeat"] as? String {
                    out.append(Data(String(repeating: r, count: count).utf8))
                } else {
                    let each = try #require(p["each"] as? String)
                    let joined = (0..<count).map { each.replacingOccurrences(of: "{i}", with: String($0)) }
                        .joined(separator: p["joiner"] as? String ?? "")
                    out.append(Data(joined.utf8))
                }
            }
            data = out
        }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(sha == c["sha256"] as? String, "\(c["name"] ?? "?"): bytes differ from the manifest")
        return data
    }

    static func totals(_ s: ImportSummary) -> [String: AnyHashable] {
        ["chatsImported": s.chatsImported, "messagesImported": s.messagesImported,
         "chatsAlreadyHere": s.chatsAlreadyHere, "itemsSkipped": s.itemsSkipped, "mayBeIncomplete": s.mayBeIncomplete,
         "imagesImported": s.imagesImported, "imagesSkipped": s.imagesSkipped]
    }

    static func expectedTotals(_ any: Any?) -> [String: AnyHashable] {
        let d = any as? [String: Any] ?? [:]
        var out: [String: AnyHashable] = [:]
        for key in ["chatsImported", "messagesImported", "chatsAlreadyHere", "itemsSkipped", "imagesImported", "imagesSkipped"] {
            if let n = d[key] as? Int { out[key] = n }
        }
        if let b = d["mayBeIncomplete"] as? Bool { out["mayBeIncomplete"] = b }
        return out
    }

    static func threads(_ context: ModelContext) throws -> [ChatThread] {
        try context.fetch(FetchDescriptor<ChatThread>())
    }

    /// One stored thread against the manifest's `threadsDetail` entry.
    static func compare(_ t: ChatThread, _ e: [String: Any], case name: String, context: ModelContext) {
        #expect(t.title == e["title"] as? String, "\(name): title")
        #expect(Int64((t.timestamp.timeIntervalSince1970 * 1000).rounded()) == (e["updatedMs"] as? NSNumber)?.int64Value,
                "\(name): thread timestamp")
        let want = e["messages"] as? [[String: Any]] ?? []
        let got = t.sortedMessages
        #expect(got.count == want.count, "\(name): message count")
        for (m, w) in zip(got, want) {
            #expect(m.id == ImportKey.uuid(w["key"] as? String ?? ""), "\(name): key of \(w["key"] ?? "")")
            #expect(m.role.rawValue == w["role"] as? String)
            #expect(m.content == w["text"] as? String, "\(name): text of \(w["key"] ?? "")")
            #expect(Int64((m.timestamp.timeIntervalSince1970 * 1000).rounded()) == (w["ms"] as? NSNumber)?.int64Value,
                    "\(name): ms of \(w["key"] ?? "")")
            #expect(!m.isE2EE && m.generatingTime == nil)
            let sources = (w["sources"] as? [[String: String]] ?? []).map {
                [$0["url"] ?? "", $0["domain"] ?? "", $0["title"] ?? "", $0["snippet"] ?? ""]
            }
            #expect(m.groundingSources.map { [$0.url, $0.domain, $0.title, $0.snippet] } == sources,
                    "\(name): sources of \(w["key"] ?? "")")
            let id = m.id
            let stored = ((try? context.fetch(FetchDescriptor<ImageAttachment>(predicate: #Predicate { $0.messageID == id }))) ?? [])
                .sorted { $0.index < $1.index }
            let wantImages = w["images"] as? [[String: Any]] ?? []
            #expect(stored.count == wantImages.count, "\(name): image count of \(w["key"] ?? "")")
            for (a, i) in zip(stored, wantImages) {
                #expect(a.id == ImportKey.uuid(i["key"] as? String ?? ""), "\(name): image key \(i["key"] ?? "")")
                #expect(a.index == i["index"] as? Int && a.width == i["width"] as? Int && a.height == i["height"] as? Int,
                        "\(name): image \(i["key"] ?? "") is \(a.width)×\(a.height)")
                #expect(a.mimeType == i["mime"] as? String, "\(name): image type of \(i["key"] ?? "")")
            }
        }
    }

    @Test func theManifestIsPresentAndPinned() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let data = try Data(contentsOf: Self.folder.appendingPathComponent("cases.json"))
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                == "3ccff1db629d1aaa8961119c8d7f08a553a51a2b18c5fb79cd7a2e6f2583ed62")
        #expect(Self.manifest.count == 37)
    }

    @Test func everyFileCase() throws {
        for c in Self.manifest where c["steps"] == nil {
            let name = c["name"] as? String ?? "?"
            let data = try Self.bytes(c)
            let expected = try #require(c["expected"] as? [String: Any])
            let context = try Self.context()
            if expected["rejected"] as? Bool == true {
                #expect(throws: ChatImporter.WrongFile.self, "\(name) should be rejected") {
                    try ChatImporter.run(data, into: context)
                }
                continue
            }
            let first = try ChatImporter.run(data, into: context)
            #expect(Self.totals(first) == Self.expectedTotals(expected["first"]), "\(name): first run")
            let stored = try Self.threads(context)
            if let keys = expected["threads"] as? [String] {
                #expect(Set(stored.map(\.id)) == Set(keys.map(ImportKey.uuid)), "\(name): thread keys")
            } else {
                #expect(stored.count == expected["threads"] as? Int, "\(name): thread count")
            }
            for e in expected["threadsDetail"] as? [[String: Any]] ?? [] {
                let id = ImportKey.uuid(e["key"] as? String ?? "")
                guard let t = stored.first(where: { $0.id == id }) else {
                    Issue.record("\(name): missing thread \(e["key"] ?? "")"); continue
                }
                Self.compare(t, e, case: name, context: context)
            }
            if expected["second"] != nil {
                let messagesBefore = try context.fetchCount(FetchDescriptor<Message>())
                let second = try ChatImporter.run(data, into: context)
                #expect(Self.totals(second) == Self.expectedTotals(expected["second"]), "\(name): second run")
                #expect(try context.fetchCount(FetchDescriptor<Message>()) == messagesBefore, "\(name): re-import added rows")
            }
        }
    }

    @Test func aDeletedChatComesBack() throws {
        guard let c = Self.manifest.first(where: { $0["name"] as? String == "deleted-chat-returns" }) else { return }
        let data = try Data(contentsOf: Self.folder.appendingPathComponent("near-export-v1.json"))
        let context = try Self.context()
        _ = try ChatImporter.run(data, into: context)
        let key = ImportKey.uuid("near:conv_prime")
        let before = try #require(try Self.threads(context).first { $0.id == key })
        let snapshot = before.sortedMessages.map { [$0.id.uuidString, $0.content, "\($0.timestamp.timeIntervalSince1970)"] }
        ThreadDeletion.delete(before, in: context)
        #expect(try Self.threads(context).contains { $0.id == key } == false)
        let third = try ChatImporter.run(data, into: context)
        let expected = try #require(c["expected"] as? [String: Any])
        #expect(Self.totals(third) == Self.expectedTotals(expected["third"]))
        let after = try #require(try Self.threads(context).first { $0.id == key })
        #expect(after.sortedMessages.map { [$0.id.uuidString, $0.content, "\($0.timestamp.timeIntervalSince1970)"] } == snapshot)
    }

    @Test func theSameChatFromBothFilesIsTwoThreads() throws {
        guard let c = Self.manifest.first(where: { $0["name"] as? String == "same-chat-twice" }) else { return }
        let context = try Self.context()
        _ = try ChatImporter.run(Data(contentsOf: Self.folder.appendingPathComponent("near-export-v1.json")), into: context)
        let second = try ChatImporter.run(Data(contentsOf: Self.folder.appendingPathComponent("derived/prime-as-chat-file.json")),
                                          into: context)
        let expected = try #require(c["expected"] as? [String: Any])
        #expect(Self.totals(second) == Self.expectedTotals(expected["second"]))
        let ids = Set(try Self.threads(context).map(\.id))
        for key in expected["threads"] as? [String] ?? [] { #expect(ids.contains(ImportKey.uuid(key)), "missing \(key)") }
    }
}
