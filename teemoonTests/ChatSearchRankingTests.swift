import Foundation
import Testing
@testable import teemoon

/// The "iran bug" (2026-08-30): a term buried deep in one LONG reply of an
/// old thread stopped appearing in search once the list started trusting the
/// index's ranked answer exclusively. Hypothesis under test: bm25's document-
/// length normalization ranks the long-document match below dozens of weak
/// short-message matches, and the thread-granularity limit then cuts it
/// entirely — behavior the old (accidental) full-store fallback scan masked.
@Suite("Chat search ranking under noise")
struct ChatSearchRankingTests {

    private func makeIndexURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ranking-\(UUID().uuidString).sqlite")
    }

    private func cleanUp(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    @Test func aLongBuriedMatchSurvivesManyShortWeakMatches() async throws {
        let url = makeIndexURL(); defer { cleanUp(url) }
        let index = ChatSearchIndex(databaseURL: url)

        // 120 noise threads: the term once, in a short message.
        var records: [ChatMessageRecord] = []
        for n in 0..<120 {
            records.append(ChatMessageRecord(
                messageID: UUID(), threadID: UUID(), role: .assistant,
                timestamp: Date().addingTimeInterval(Double(-n * 60)),
                content: "note \(n): zubrovka came up briefly in the meeting today."))
        }
        // The gold-shaped thread: ONE long reply, term buried deep.
        let goldThread = UUID()
        let filler = (0..<160)
            .map { "paragraph \($0) of dense market commentary with citations." }
            .joined(separator: " ")
        records.append(ChatMessageRecord(
            messageID: UUID(), threadID: goldThread, role: .assistant,
            timestamp: Date().addingTimeInterval(-86400 * 30),
            content: filler + " sanctions on zubrovka moved the price. " + filler))
        try await index.index(records)

        // At the list's OLD parameters (limit 100, overfetch cap 512) this
        // exact corpus dropped the gold thread entirely — the bug as shipped.
        // The pin below runs the list's CURRENT parameters.
        let hits = try await index.search("zubrovka", granularity: .threads, limit: 500)
        let position = hits.firstIndex { $0.threadID == goldThread }
        print("[ranking-verify] hits=\(hits.count) goldPosition=\(position.map(String.init) ?? "MISSING")")

        #expect(position != nil,
                "a buried long-document match must never vanish from the ranked answer")
    }

    @Test func fewMatches_theBuriedMatchIsStillRankedLast() async throws {
        // Same shape, only 5 noise threads — the realistic store. Presence is
        // the requirement; this records WHERE bm25 puts the long document.
        let url = makeIndexURL(); defer { cleanUp(url) }
        let index = ChatSearchIndex(databaseURL: url)

        var records: [ChatMessageRecord] = []
        for n in 0..<5 {
            records.append(ChatMessageRecord(
                messageID: UUID(), threadID: UUID(), role: .assistant,
                timestamp: Date(), content: "note \(n): zubrovka mentioned."))
        }
        let goldThread = UUID()
        let filler = (0..<160)
            .map { "paragraph \($0) of dense market commentary with citations." }
            .joined(separator: " ")
        records.append(ChatMessageRecord(
            messageID: UUID(), threadID: goldThread, role: .assistant,
            timestamp: Date().addingTimeInterval(-86400 * 30),
            content: filler + " sanctions on zubrovka moved the price. " + filler))
        try await index.index(records)

        let hits = try await index.search("zubrovka", granularity: .threads, limit: 100)
        let position = hits.firstIndex { $0.threadID == goldThread }
        print("[ranking-verify] small-corpus hits=\(hits.count) goldPosition=\(position.map(String.init) ?? "MISSING")")
        #expect(position != nil)
    }
}
