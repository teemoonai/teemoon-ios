import Foundation
import Testing
@testable import teemoon

/// The property a search box actually promises: **every result contains what
/// you typed, and the snippet shows you where.**
///
/// Built on a synthetic corpus, deliberately. Reported symptom was results whose
/// keyword appears nowhere in the thread and whose snippet carries no highlight;
/// reproducing that against real chat history would mean reading it, and the
/// corpus below reproduces the shapes that matter without any private text.
@Suite("Chat search correctness")
struct ChatSearchCorrectnessTests {

    private func makeIndex() -> (ChatSearchIndex, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("correctness-\(UUID().uuidString).sqlite")
        return (ChatSearchIndex(databaseURL: url), url)
    }

    private func cleanUp(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// A chat-shaped corpus: short questions, long replies, shared vocabulary
    /// across threads, and words that are prefixes of other words.
    private func corpus() -> [(thread: UUID, messages: [(Role, String)])] {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        return [
            (a, [(.user, "how do I descale the kettle"),
                 (.assistant, "Run a cycle of white vinegar and water through the kettle, then rinse twice. Limescale builds up fastest in hard water areas and the element is what suffers first.")]),
            (b, [(.user, "what appliances need servicing this year"),
                 (.assistant, "The boiler is due in March. Your appliances under warranty are the dishwasher and the washing machine; the extractor fan is not covered."),
                 (.user, "book the boiler one")]),
            (c, [(.user, "recipe for sourdough"),
                 (.assistant, "Feed the starter twelve hours ahead. Autolyse the flour and water for an hour before adding salt. Bulk ferment until it has risen by half.")]),
            (d, [(.user, "cat vaccination schedule"),
                 (.assistant, "Kittens need a first course at nine weeks and a booster at twelve. After that it is annual. The catalogue from the vet lists which ones are legally required.")]),
        ]
    }

    private func records() -> [ChatMessageRecord] {
        corpus().flatMap { entry in
            entry.messages.enumerated().map { offset, message in
                ChatMessageRecord(messageID: UUID(),
                                  threadID: entry.thread,
                                  role: message.0,
                                  timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset)),
                                  content: message.1)
            }
        }
    }

    /// Does any message of this thread contain a token starting with `term`?
    /// Prefix semantics, because the last query token gets `*`.
    private func threadContainsPrefix(_ term: String, threadID: UUID, in records: [ChatMessageRecord]) -> Bool {
        records
            .filter { $0.threadID == threadID }
            .contains { record in
                record.content
                    .lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .contains { $0.hasPrefix(term.lowercased()) }
            }
    }

    // MARK: - The promise

    @Test func everyThreadResultActuallyContainsTheTerm() async throws {
        let (index, url) = makeIndex(); defer { cleanUp(url) }
        let all = records()
        try await index.index(all)

        for term in ["kettle", "boiler", "sourdough", "cat", "applianc", "vinegar", "limescale"] {
            let hits = try await index.search(term, granularity: .threads, limit: 50)
            for hit in hits {
                #expect(threadContainsPrefix(term, threadID: hit.threadID, in: all),
                        "\"\(term)\" returned a thread that does not contain it")
            }
        }
    }

    @Test func everyResultSnippetShowsWhereItMatched() async throws {
        // The reported symptom: a row with no highlight at all. If a result is
        // real, `snippet()` must mark the term inside it.
        let (index, url) = makeIndex(); defer { cleanUp(url) }
        try await index.index(records())

        for term in ["kettle", "boiler", "sourdough", "cat", "applianc"] {
            let hits = try await index.search(term, granularity: .threads, limit: 50)
            #expect(!hits.isEmpty, "\"\(term)\" should match something")
            for hit in hits {
                #expect(hit.snippet.contains(ChatSearchIndex.highlightOpen),
                        "\"\(term)\" produced an unhighlighted snippet: \(hit.snippet.debugDescription)")
            }
        }
    }

    /// A prefix query matches longer words — that is intended — but the result
    /// must still be a genuine match, and it must be shown as one.
    @Test func prefixMatchesAreRealMatchesNotAccidents() async throws {
        let (index, url) = makeIndex(); defer { cleanUp(url) }
        try await index.index(records())

        // "cat" prefixes "catalogue"; both live in thread d.
        let hits = try await index.search("cat", granularity: .messages, limit: 50)
        #expect(!hits.isEmpty)
        for hit in hits {
            let plain = ChatSearchHighlight.plainText(hit.snippet).lowercased()
            #expect(plain.contains("cat"), "snippet without the term: \(plain)")
        }
    }

    @Test func aTermInNoThreadReturnsNothing() async throws {
        let (index, url) = makeIndex(); defer { cleanUp(url) }
        try await index.index(records())
        #expect(try await index.search("helicopter", granularity: .threads, limit: 50).isEmpty)
    }

    /// Multi-word queries are implicit AND, so a thread must contain BOTH terms.
    /// This is where an OR-by-accident would show up as "keyword not in chat".
    @Test func multiWordQueriesRequireEveryTerm() async throws {
        let (index, url) = makeIndex(); defer { cleanUp(url) }
        let all = records()
        try await index.index(all)

        // "kettle" is in thread a; "sourdough" is in thread c. Nothing has both.
        #expect(try await index.search("kettle sourdough", granularity: .threads, limit: 50).isEmpty)

        // Both of these are in thread a.
        let both = try await index.search("kettle vinegar", granularity: .threads, limit: 50)
        #expect(both.count == 1)
        for hit in both {
            #expect(threadContainsPrefix("kettle", threadID: hit.threadID, in: all))
            #expect(threadContainsPrefix("vinegar", threadID: hit.threadID, in: all))
        }
    }

    /// Stale rows are the other way a result can point at a thread that no
    /// longer says what the index thinks it says.
    @Test func anEditedMessageDoesNotKeepMatchingItsOldText() async throws {
        let (index, url) = makeIndex(); defer { cleanUp(url) }
        let thread = UUID()
        let original = ChatMessageRecord(messageID: UUID(), threadID: thread, role: .user,
                                         timestamp: Date(), content: "the kettle is broken")
        try await index.index([original])

        let revised = ChatMessageRecord(messageID: original.messageID, threadID: thread,
                                        role: original.role, timestamp: original.timestamp,
                                        content: "the toaster is broken")
        try await index.index([revised])

        #expect(try await index.search("kettle", granularity: .threads, limit: 50).isEmpty)
        #expect(try await index.search("toaster", granularity: .threads, limit: 50).count == 1)
    }

    // MARK: - Long documents (the untested axis)

    /// `thread_shapes.json` records real messages of 2,882 characters, 13
    /// paragraphs, 34 list items — and the plan cites replies of 7,150. The
    /// corpus above is all short, clean prose, so `snippet()` never had to
    /// CHOOSE a window. These do.

    private func longDocument(termAt position: String, term: String = "kettle") -> String {
        let filler = (1...200).map { "paragraph \($0) discusses unrelated household maintenance topics at length" }
        switch position {
        case "start":  return ([term + " appears first here"] + filler).joined(separator: ". ")
        case "middle": return (filler.prefix(100) + [term + " appears in the middle"] + filler.suffix(100)).joined(separator: ". ")
        default:       return (filler + [term + " appears last of all"]).joined(separator: ". ")
        }
    }

    @Test func snippetHighlightsAMatchWhereverItSitsInALongDocument() async throws {
        for position in ["start", "middle", "end"] {
            let (index, url) = makeIndex(); defer { cleanUp(url) }
            let thread = UUID()
            try await index.index([
                ChatMessageRecord(messageID: UUID(), threadID: thread, role: .assistant,
                                  timestamp: Date(), content: longDocument(termAt: position))
            ])
            let hits = try await index.search("kettle", granularity: .threads, limit: 10)
            #expect(hits.count == 1, "no hit for a term at the \(position)")
            guard let hit = hits.first else { continue }
            #expect(hit.snippet.contains(ChatSearchIndex.highlightOpen),
                    "term at the \(position) of a long document produced NO highlight: \(hit.snippet.prefix(120).debugDescription)")
        }
    }

    @Test func multiWordMatchesFarApartStillShowAHighlight() async throws {
        // Implicit AND matches the ROW; the 18-token snippet window can only
        // cover one region. It must still mark something.
        let (index, url) = makeIndex(); defer { cleanUp(url) }
        let thread = UUID()
        let filler = (1...200).map { "filler line \($0) about nothing in particular" }.joined(separator: ". ")
        try await index.index([
            ChatMessageRecord(messageID: UUID(), threadID: thread, role: .assistant,
                              timestamp: Date(),
                              content: "kettle at the very beginning. \(filler). vinegar at the very end")
        ])
        let hits = try await index.search("kettle vinegar", granularity: .threads, limit: 10)
        #expect(hits.count == 1)
        guard let hit = hits.first else { return }
        #expect(hit.snippet.contains(ChatSearchIndex.highlightOpen),
                "two terms far apart produced no highlight: \(hit.snippet.prefix(120).debugDescription)")
    }
}
