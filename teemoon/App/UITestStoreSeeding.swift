//
//  UITestStoreSeeding.swift
//  teemoon
//
//  DEBUG-only fixture seeding for UI tests and capture runs, called from the
//  in-memory --uitesting branch of TeemoonApp.sharedModelContainer. Moved out
//  of teemoonApp.swift unchanged.
//

import Foundation
import SwiftData

#if DEBUG
enum UITestStoreSeeding {
    /// Deterministic conversation fixtures for capture runs, into TeemoonApp's
    /// in-memory `--uitesting` store and nowhere else.
    ///
    /// The Mac design baseline needs a chat window that LOOKS like a chat window
    /// — a populated sidebar, a real exchange, wrapped paragraphs — and the only
    /// previous source of that was the developer's own history, which cannot be
    /// published. Fixed text and fixed timestamps so a capture diff shows design
    /// drift rather than today's date.
    ///
    /// Set `UITEST_SEED_THREADS=1`. Off by default, because most tests want the
    /// empty state.
    static func seedFixtureThreadsIfRequested(into container: ModelContainer) {
        // `UITEST_SEED_LONG_THREAD=<n>` seeds ONE thread of n turns and nothing
        // else — the fixture for the scroll-performance work, where the whole
        // question is what a transcript costs at length. Kept separate from the
        // design fixtures below because those are chosen for how they LOOK and
        // this one is chosen for how much of it there is.
        if let raw = ProcessInfo.processInfo.environment["UITEST_SEED_LONG_THREAD"],
           let count = Int(raw), count > 0 {
            seedLongThread(turns: count, into: container)
            return
        }
        // `UITEST_SEED_SHAPED_THREAD` rebuilds threads from real threads'
        // measured STRUCTURE (char/markdown counts only — no content; the
        // numbers ship in the bundle, the env var is just the switch, because
        // a large launch-env payload never survives the device transport).
        // Structure is the fidelity that hand-guessed fixtures lacked.
        if ProcessInfo.processInfo.environment["UITEST_SEED_SHAPED_THREAD"] == "bundled",
           let url = Bundle.main.url(forResource: "thread_shapes", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            seedShapedThreads(data, into: container)
            return
        }
        guard ProcessInfo.processInfo.environment["UITEST_SEED_THREADS"] == "1" else { return }
        let context = ModelContext(container)

        // Fixed reference date, so captures are byte-comparable across days.
        let base = Date(timeIntervalSince1970: 1_770_000_000)

        func thread(_ title: String, daysAgo: Int, turns: [(Role, String)]) {
            let thread = Thread()
            thread.title = title
            thread.timestamp = base.addingTimeInterval(TimeInterval(-daysAgo * 86_400))
            context.insert(thread)
            for (offset, turn) in turns.enumerated() {
                let message = Message(role: turn.0, content: turn.1, thread: thread)
                message.timestamp = thread.timestamp.addingTimeInterval(TimeInterval(offset * 30))
                context.insert(message)
            }
        }

        thread("what attestation actually proves", daysAgo: 0, turns: [
            (.user, "if the server is attested, what exactly am I trusting?"),
            (.assistant, """
             You're trusting three things, and it's worth separating them.

             The hardware vendor, that the TEE does what it claims. The measurement, \
             that the code hashed into the quote is the code you think it is. And the \
             chain from that measurement back to source you can read.

             Attestation proves the second one cleanly. The first is an assumption you \
             inherit. The third is only as good as the build being reproducible.
             """),
        ])

        // Deliberately long opening line: the window title is derived from it,
        // and an untruncated title is only visibly wrong past a certain length.
        thread("a long opening question", daysAgo: 1, turns: [
            (.user, "when a provider says the model runs in a secure enclave, which specific claims can I check myself and which ones am I taking on faith from the vendor?"),
            (.assistant, "Check the quote and the measurement. Take the silicon on faith."),
        ])

        thread("a shorter one", daysAgo: 2, turns: [
            (.user, "does this run offline?"),
            (.assistant, "On-device models do. Cloud providers don't, by definition."),
        ])

        thread("weekend reading", daysAgo: 9, turns: [
            (.user, "summarise the confidential computing landscape"),
            (.assistant, "The short version: three vendors, two threat models, and a lot of overloaded words."),
        ])

        try? context.save()
    }

    /// One long conversation, deterministic, with the content mix that decides
    /// what a transcript costs: mostly inline markdown (MessageView's fast
    /// path), every fifth reply carrying a fenced code block so Textual's
    /// block renderer — the expensive one — is represented at roughly the rate
    /// real chats hit it, and one reasoning block per ten turns.
    ///
    /// No randomness: two runs of the same `n` produce byte-identical text, so
    /// a before/after scroll comparison is comparing the same transcript.
    /// See the call site: rebuilds threads whose messages match measured
    /// structural shapes. Deterministic, content-free.
    static func seedShapedThreads(_ json: Data, into container: ModelContainer) {
        struct Shape: Decodable {
            let role: String?, chars: Int, paragraphs: Int, tableRows: Int
            let headings: Int, links: Int, codeFences: Int, listItems: Int, boldRuns: Int
        }
        struct ThreadShape: Decodable { let messages: [Shape] }
        let context = ModelContext(container)
        guard let shapes = try? JSONDecoder().decode([ThreadShape].self, from: json) else {
            // LOUD failure: a silently-empty seed reads as "thread not found"
            // in the test, which diagnoses as anything but the real cause.
            let marker = Thread()
            marker.title = "SHAPE DECODE FAILED"
            context.insert(marker)
            try? context.save()
            return
        }
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        let words = ["attestation", "marinade", "quantisation", "simmer", "provenance",
                     "cardamom", "verifier", "skillet", "manifest", "reduction",
                     "registry", "tempering", "custody", "coriander", "envelope"]
        var w = 0
        func word() -> String { defer { w += 1 }; return words[w % words.count] + "-\(w)" }
        func sentence(_ n: Int) -> String { (0..<n).map { _ in word() }.joined(separator: " ") + "." }

        for (t, threadShape) in shapes.enumerated() {
            let thread = Thread()
            thread.title = "shaped thread \(t)"
            thread.timestamp = base.addingTimeInterval(TimeInterval(-t * 3600))
            context.insert(thread)
            for (i, s) in threadShape.messages.enumerated() {
                var blocks: [String] = []
                // The chat list shows message previews, not titles — give the
                // first message a deterministic marker a test can match.
                if i == 0 { blocks.append("shaped-\(t) opening") }
                for h in 0..<s.headings { blocks.append("## \(word()) heading \(t)-\(i)-\(h)") }
                if s.tableRows > 0 {
                    var rows = ["| \(word()) | \(word()) | \(word()) |", "|---|---|---|"]
                    for _ in 0..<max(0, s.tableRows - 2) { rows.append("| \(word()) | \(word()) | \(word()) |") }
                    blocks.append(rows.joined(separator: "\n"))
                }
                for _ in 0..<s.codeFences { blocks.append("```swift\nlet \(word()) = \(word())\n```") }
                if s.listItems > 0 {
                    blocks.append((0..<s.listItems).map { _ in "- \(word()) \(sentence(4))" }.joined(separator: "\n"))
                }
                for l in 0..<s.links { blocks.append("\(sentence(5)) [\(word())](https://example.com/\(t)/\(i)/\(l)) \(sentence(3))") }
                for _ in 0..<s.boldRuns { blocks.append("\(sentence(3)) **\(word())** \(sentence(3))") }
                while blocks.count < s.paragraphs { blocks.append(sentence(10)) }
                var content = blocks.joined(separator: "\n\n")
                while content.count < s.chars { content += "\n\n" + sentence(12) }
                let role: Role = (s.role?.lowercased().contains("user") == true || i.isMultiple(of: 2)) ? .user : .assistant
                let message = Message(role: role, content: String(content.prefix(max(s.chars, content.count))), thread: thread)
                message.timestamp = thread.timestamp.addingTimeInterval(TimeInterval(i * 30))
                context.insert(message)
            }
        }
        try? context.save()
    }

    static func seedLongThread(turns: Int, into container: ModelContainer) {
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_770_000_000)

        // A second, trivial thread exists so a test can measure OPENING the long
        // one repeatedly: selecting the thread already on screen is a no-op, so
        // a cold re-open needs somewhere else to go first. Seeded older than the
        // long thread so it never takes the first row.
        let scratch = Thread()
        scratch.title = "scratch"
        scratch.timestamp = base.addingTimeInterval(-86_400)
        context.insert(scratch)
        for (offset, turn) in [(Role.user, "scratch"), (.assistant, "scratch reply")].enumerated() {
            let message = Message(role: turn.0, content: turn.1, thread: scratch)
            message.timestamp = scratch.timestamp.addingTimeInterval(TimeInterval(offset * 30))
            context.insert(message)
        }

        let thread = Thread()
        thread.title = "long thread (\(turns) turns)"
        thread.timestamp = base
        context.insert(thread)

        for i in 0..<turns {
            let content: String
            if i.isMultiple(of: 2) {
                content = "question \(i): what does this actually prove, and how would I check it myself?"
            } else if i % 10 == 1 {
                content = """
                <think>
                Turn \(i). The user is asking about verification, so the useful split is \
                what the quote covers versus what it does not.
                </think>
                Reply \(i). \(String(repeating: "The measurement binds the code, not the intent behind it. ", count: 6))
                """
            } else if i % 5 == 1 {
                content = """
                Reply \(i), with a block that needs the structured renderer:

                ```swift
                let quote = try TDXQuote(parsing: report)
                guard quote.mrConfigID == expected else { throw Err.mismatch }
                ```

                \(String(repeating: "Followed by prose that wraps across several lines. ", count: 5))
                """
            } else if i % 7 == 3 {
                // TABLES, deliberately. The 2026-08-06 device freeze was upward
                // realization of table-bearing history while a reply streamed:
                // Textual's TableLayout re-measures through TextKit on every
                // ScrollView size re-estimate, and a history with no tables —
                // which this seeder was — cannot reproduce it.
                // Keeps the `reply \(i):` prefix — the scroll tests anchor on
                // it (`label BEGINSWITH "reply "`), and the last seeded turn
                // can land on this branch.
                content = """
                reply \(i): comparing the options:

                ## Options \(i)

                | provider | boundary | hardware | verdict \(i) |
                |---|---|---|---|
                | one | model enclave | TDX | keep-\(i)0 |
                | two | gateway | SEV-SNP | reject-\(i)1 |
                | three | router | TDX | lower tier-\(i)2 |
                | four | model worker | H100 CC | blocked-\(i)3 |

                \(String(repeating: "Prose after the table so the row is tall. ", count: 4))
                """
            } else {
                content = "reply \(i): "
                    + String(repeating: "some **markdown** with `code` and ordinary text. ", count: 10)
            }
            let message = Message(role: i.isMultiple(of: 2) ? .user : .assistant,
                                  content: content, thread: thread)
            message.timestamp = base.addingTimeInterval(TimeInterval(i * 30))
            context.insert(message)
        }
        try? context.save()
    }
}
#endif
