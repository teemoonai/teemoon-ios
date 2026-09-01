//
//  PublishedDateABTests.swift
//  teemoonTests
//
//  Does telling the model each source's DATE make a small model answer better?
//
//  The question comes from real replies, not a hunch. gemma4:e2b calls
//  web_search reliably (4/4 in every run measured) and then hedges instead of
//  answering, and it says why in its own output:
//
//    "The current weather varies significantly depending on the source …
//     several different readings occurring on different dates"
//
//  and in the worst observed case answered "highs in the mid-80s" from a
//  historical snapshot when the current reading in the same payload was 42°F.
//  Brave returns snapshots spanning different dates; the model cannot tell
//  which one is now. `<published>` (from Brave's top-level `sources` map) is
//  the intervention. This measures whether it works.
//
//  ── Design ──────────────────────────────────────────────────────────────────
//  ONE Brave fetch, rendered TWO ways. Both arms therefore see byte-identical
//  grounding and the ONLY difference is the presence of <published>. Re-fetching
//  per arm would let Brave's own result churn masquerade as an effect — and it
//  would cost a query per trial instead of one for the whole run.
//
//  ── Scoring ─────────────────────────────────────────────────────────────────
//  Scored against the DATA, never against vocabulary. Three prose-matching
//  scorers were tried and all three were wrong: matching the location accepted
//  refusals that echoed the question, and a refusal-phrase list rejected correct
//  answers that added a hedge afterwards. The only honest question is whether
//  the reply states a figure that actually appears in the payload the model was
//  given — which it cannot do by guessing.
//
//  run it with SWEEP_GROUNDING_BUDGET=1 and BRAVE_API_KEY set.
//

import Foundation
import Testing
import ModelBackend
@testable import teemoon

@Suite("Published-date A/B (live)", .serialized)
struct PublishedDateABTests {

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    private static var apiKey: String? {
        guard env["SWEEP_GROUNDING_BUDGET"] == "1" else { return nil }
        let key = env["BRAVE_API_KEY"] ?? ""
        return key.isEmpty ? nil : key
    }

    private static let query = "weather 10001"
    private static let prompt = "What is the weather in New York NY 10001 right now?"

    // Scoring and plumbing live in `GroundingTestSupport` — one scorer, shared,
    // because three separate prose-matching versions were written during this
    // investigation and all three were wrong.

    // MARK: - The measurement

    @Test @MainActor func publishedDatesChangeAnswerQuality() async throws {
        guard let key = Self.apiKey else { return }
        guard await GroundingTestSupport.ollamaIsUp() else { return }
        let model = Self.env["SWEEP_BUDGET_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "gemma4:e2b-it-qat"
        let trials = Int(Self.env["SWEEP_BUDGET_TRIALS"] ?? "5") ?? 5

        // One fetch, two renderings — the single-variable guarantee.
        let response = try await GroundingTestSupport.fetchGrounding(query: Self.query, key: key)
        let withDates = BraveWebSearchTool.contextXML(from: response, includePublished: true)
        let without   = BraveWebSearchTool.contextXML(from: response, includePublished: false)
        #expect(withDates.contains("<published>"), "no dates in this payload — the A/B would be vacuous")
        #expect(!without.contains("<published>"))

        let available = GroundingTestSupport.distinctiveFigures(in: withDates, excluding: Self.prompt)
        #expect(!available.isEmpty, "payload carries no temperature figures — nothing objective to score against")

        var rows: [String] = []
        var summary: [(String, Int, Int)] = []   // arm, cited, total hedges
        for (label, payload) in [("with <published>", withDates), ("without", without)] {
            var cited = 0, hedges = 0
            for i in 1...trials {
                let reply = await GroundingTestSupport.ask(provider: GroundingTestSupport.ollama(model: model), apiKey: "", payload: payload, prompt: Self.prompt)
                let ok = GroundingTestSupport.citesRetrievedFigure(reply: reply, payload: payload, question: Self.prompt)
                if ok { cited += 1 }
                let h = GroundingTestSupport.hedgeCount(reply)
                hedges += h
                rows.append("- **\(label) \(i)** · cited=\(ok) hedges=\(h) · figures=\(GroundingTestSupport.distinctiveFigures(in: reply, excluding: Self.prompt).sorted())\n  > \(reply.replacingOccurrences(of: "\n", with: " ").prefix(240))")
            }
            summary.append((label, cited, hedges))
        }
        Self.writeReport(model: model, trials: trials, available: available,
                         summary: summary, rows: rows)
    }

    private static func writeReport(model: String, trials: Int, available: Set<String>,
                                    summary: [(String, Int, Int)], rows: [String]) {
        guard let dir = env["SWEEP_REPORT_DIR"], !dir.isEmpty else { return }
        var md = "# `<published>` A/B\n\n"
        md += "model: `\(model)` · \(trials) trials per arm · ONE Brave fetch rendered two ways,\n"
        md += "so the payloads are byte-identical apart from `<published>`.\n\n"
        md += "scored against the DATA: does the reply state a temperature figure that\n"
        md += "appears in the payload? figures available: \(available.sorted())\n\n"
        md += "| arm | cited a retrieved figure | total hedges |\n|---|---|---|\n"
        for (label, cited, hedges) in summary {
            md += "| \(label) | \(cited)/\(trials) | \(hedges) |\n"
        }
        md += "\n## every reply, verbatim\n\n" + rows.joined(separator: "\n") + "\n"
        try? md.write(toFile: dir + "/published_date_ab.md", atomically: true, encoding: .utf8)
    }
}
