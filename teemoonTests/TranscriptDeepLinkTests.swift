import Foundation
import Testing
@testable import teemoon

@Suite("Transcript deep link")
struct TranscriptDeepLinkTests {

    @Test @MainActor func depositThenConsume_returnsTheMessageOnce() {
        let link = TranscriptDeepLink()
        let thread = UUID(), message = UUID()
        link.deposit(threadID: thread, messageID: message, fraction: 0.4)

        let target = link.consume(for: thread)
        #expect(target?.messageID == message)
        #expect(target?.fraction == 0.4)
        #expect(link.consume(for: thread) == nil, "one-shot — a second open must not jump")
    }

    @Test @MainActor func consumeForADifferentThread_discardsTheStaleTarget() {
        let link = TranscriptDeepLink()
        let tapped = UUID(), openedInstead = UUID()
        link.deposit(threadID: tapped, messageID: UUID())

        #expect(link.consume(for: openedInstead) == nil)
        #expect(link.consume(for: tapped) == nil,
                "a target the user navigated away from must not fire on a later visit")
    }

    @Test @MainActor func eachDeposit_bumpsTheStamp() {
        let link = TranscriptDeepLink()
        let before = link.stamp
        link.deposit(threadID: UUID(), messageID: UUID())
        link.deposit(threadID: UUID(), messageID: UUID())
        #expect(link.stamp == before + 2,
                "same-thread taps re-fire only because the stamp moves")
    }

    // MARK: - matchFraction: landing INSIDE a long message

    private let open = ChatSearchIndex.highlightOpen
    private let close = ChatSearchIndex.highlightClose

    @Test func matchDeepInALongMessage_locatesItsFraction() {
        // The reported shape: a multi-screen reply where the term sits pages
        // below the message top. ~75% in, the fraction must say so.
        let filler = String(repeating: "gold market commentary. ", count: 120)
        let tail = String(repeating: " more commentary.", count: 40)
        let content = filler + "sanctions on Iran shifted demand" + tail
        let snippet = "…sanctions on \(open)Iran\(close) shifted demand…"

        let fraction = TranscriptDeepLink.matchFraction(snippet: snippet, content: content)
        let expected = Double(filler.count) / Double(content.count)
        #expect(abs(fraction - expected) < 0.02,
                "the match sits at \(expected), got \(fraction)")
    }

    @Test func matchAtTheStart_isNearZero() {
        let content = "Iran question here" + String(repeating: " padding", count: 200)
        let snippet = "\(open)Iran\(close) question here…"
        #expect(TranscriptDeepLink.matchFraction(snippet: snippet, content: content) < 0.02)
    }

    @Test func snippetNotFoundInContent_fallsBackToTheTop() {
        // A location that cannot be trusted must land at the message top,
        // never at a wrong offset.
        let fraction = TranscriptDeepLink.matchFraction(
            snippet: "…\(open)iran\(close) something that is not in the message…",
            content: "entirely different text")
        #expect(fraction == 0)
    }

    @Test func emptyContent_isZeroNotNaN() {
        #expect(TranscriptDeepLink.matchFraction(snippet: "x", content: "") == 0)
    }

    @Test func aRealFTSSnippet_locatesTheMatch() async throws {
        // NOT a synthetic snippet: index a message through the real FTS5
        // pipeline and locate snippet()'s actual output. The four tests above
        // pin the arithmetic against an ASSUMED format; this one pins the
        // assumption itself (verbatim token-boundary spans, '…' ellipses,
        // U+0001/0002 delimiters).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deeplink-\(UUID().uuidString).sqlite")
        defer {
            for s in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + s)
            }
        }
        let index = ChatSearchIndex(databaseURL: url)

        let filler = (0..<150)
            .map { "paragraph \($0) about the gold market and demand cycles." }
            .joined(separator: " ")
        let content = filler
            + " Sanctions on Iran altered refinery flows that quarter. "
            + String(repeating: "closing commentary. ", count: 30)
        let record = ChatMessageRecord(messageID: UUID(), threadID: UUID(),
                                       role: .assistant, timestamp: Date(),
                                       content: content)
        try await index.index([record])

        let hits = try await index.search("iran", granularity: .messages, limit: 5)
        let snippet = try #require(hits.first?.snippet)
        print("[fraction-verify] real snippet: \(snippet.debugDescription)")

        let fraction = TranscriptDeepLink.matchFraction(snippet: snippet,
                                                        content: content)
        let expected = Double(filler.count) / Double(content.count)
        #expect(abs(fraction - expected) < 0.05,
                "real snippet located at \(fraction), expected ≈\(expected)")
    }
}
