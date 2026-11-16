//
//  SentBeforeConfirmedTests.swift
//  teemoonTests
//
//  reply-machine.json sentBeforeConfirmedResolution: a sealed send that left before its record was confirmed keeps
//  "pending|<recordKey>" until that record's verdict settles; pass clears it, a hard fail turns it into "failed|".
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@Suite("sentBeforeConfirmed resolves per record")
@MainActor struct SentBeforeConfirmedTests {
    typealias Object = [String: Any]

    static func resolution() throws -> Object? {
        guard let kit = try ReplyMachineVectorsTests.kit() else { return nil }
        return try #require(kit["sentBeforeConfirmedResolution"] as? Object)
    }

    static func values(_ any: Any?) -> [String?] { (any as? [Any] ?? []).map { $0 as? String } }

    @Test func everyVectorResolves() throws {
        guard let r = try Self.resolution() else { return }
        let vectors = r["vectors"] as? [Object] ?? []
        #expect(vectors.count >= 3)
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let settle = try #require(vector["settle"] as? Object)
            let key = try #require(settle["recordKey"] as? String)
            let outcome = try #require(SentBeforeConfirmed.Outcome(rawValue: settle["outcome"] as? String ?? ""))
            let got = Self.values(vector["rows"]).map { SentBeforeConfirmed.resolved($0, recordKey: key, outcome: outcome) }
            #expect(got == Self.values(vector["expect"]), "\(name)")
            #expect(got.map { SentBeforeConfirmed.mark($0)?.rawValue } == Self.values(vector["marks"]), "\(name): marks")
            if let counts = vector["countsAsE2EE"] as? [Bool] {
                #expect(got.map(SentBeforeConfirmed.countsAsE2EE) == counts, "\(name): countsAsE2EE")
            }
        }
    }

    @Test func vocabularyMatchesTheKit() throws {
        guard let r = try Self.resolution() else { return }
        #expect(Set(r["outcomes"] as? [String] ?? []) == Set(SentBeforeConfirmed.Outcome.allCases.map(\.rawValue)))
        let marks = r["marks"] as? Object ?? [:]
        #expect(Set(marks.values.compactMap { $0 as? String }) == Set(SentBeforeConfirmed.Mark.allCases.map(\.rawValue)))
    }

    @Test func onlyANilRowCountsAsEndToEnd() {
        #expect(SentBeforeConfirmed.countsAsE2EE(nil))
        #expect(!SentBeforeConfirmed.countsAsE2EE("pending|1|n"))
        #expect(!SentBeforeConfirmed.countsAsE2EE("failed|1|n"))
    }

    @Test func recordKeyIsMillisecondsAndNonce() {
        let key = SentBeforeConfirmed.recordKey(fetchedAt: Date(timeIntervalSince1970: 1_730_851_200.0004), nonce: "n0")
        #expect(key == "1730851200000|n0")
    }

    /// The store pass: every row of the settled record, and only those, is rewritten.
    @Test func settlingRewritesEveryRowOfThatRecordInTheStore() throws {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let thread = ChatThread()
        context.insert(thread)
        let key = "1730851200000|n0", other = "1730851300000|n1"
        let rows = [("q", "pending|\(key)"), ("a", "pending|\(key)"), ("b", "pending|\(other)"), ("c", nil)]
            .map { content, value -> Message in
                let m = Message(role: content == "q" ? .user : .assistant, content: content, thread: thread)
                m.sentBeforeConfirmed = value
                context.insert(m)
                return m
            }
        try context.save()

        #expect(try SentBeforeConfirmed.settle(recordKey: key, outcome: .hardFail, in: context) == 2)
        #expect(rows.map(\.sentBeforeConfirmed) == ["failed|\(key)", "failed|\(key)", "pending|\(other)", nil])
        #expect(try SentBeforeConfirmed.settle(recordKey: other, outcome: .pass, in: context) == 1)
        #expect(rows.map(\.sentBeforeConfirmed) == ["failed|\(key)", "failed|\(key)", nil, nil])
        #expect(try SentBeforeConfirmed.settle(recordKey: key, outcome: .pass, in: context) == 0, "a failed row stays failed")
    }
}
