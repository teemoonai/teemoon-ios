//
//  ModelTierGroundingTests.swift
//  teemoonTests
//
//  THE product question: does teemoon need to treat local models differently
//  from the large cloud models, or is one path correct for both?
//
//  An earlier design decision already answered "no branching" — but it answered it on
//  tool-CALL rates, i.e. does the model decide to search. That is now settled
//  (gemma4 calls 4/4 in every run). The unanswered half is what happens AFTER
//  the tool returns: can the model actually answer from several thousand tokens
//  of multi-source, partly-contradictory web context?
//
//  Design: ONE Brave fetch per query shape, that exact payload handed to every
//  model. Same persona, same engine, same tool. The ONLY variable is the model,
//  so a difference is attributable to model tier and nothing else.
//
//  Query shapes are varied too, because measuring only `weather 10001`
//  overfits: weather is close to a worst case (≈10 near-duplicate sources,
//  multi-day tables inside each page, 2/10 sources dated, and "right now" has a
//  minutes-level answer). A price lookup has one crisp number and no
//  time-series. If the local model copes everywhere except weather, the fix is
//  narrow — better source selection for time-series — not a local/cloud split.
//
//  Cost: one Brave query per shape (~$0.005) plus ~$0.001/turn for cloud.
//
//  Run this suite with SWEEP_GROUNDING_BUDGET=1 and BRAVE_API_KEY / NEAR_AI_API_KEY
//  set (TEST_RUNNER_-prefixed for xcodebuild); without them it skips, green.
//

import Foundation
import Testing
import ModelBackend
@testable import teemoon

@Suite("Model tier vs grounding (live)", .serialized)
struct ModelTierGroundingTests {

    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var braveKey: String? {
        guard env["SWEEP_GROUNDING_BUDGET"] == "1" else { return nil }
        let k = env["BRAVE_API_KEY"] ?? ""
        return k.isEmpty ? nil : k
    }

    struct Shape { let label, braveQuery, prompt: String }

    static let shapes: [Shape] = [
        .init(label: "weather", braveQuery: "weather 10001",
              prompt: "What is the weather in New York NY 10001 right now?"),
        .init(label: "price", braveQuery: "bitcoin price usd",
              prompt: "What is the current price of bitcoin in USD?"),
    ]

    @Test @MainActor func doLocalModelsNeedDifferentTreatment() async throws {
        guard let brave = Self.braveKey else { return }
        let trials = Int(Self.env["SWEEP_BUDGET_TRIALS"] ?? "3") ?? 3

        // Arms: two local sizes plus a cloud flagship. Local models skip when
        // Ollama isn't up; cloud skips without a key — so this stays runnable
        // on a laptop with nothing configured.
        var arms: [(String, Provider, String)] = []
        if await GroundingTestSupport.ollamaIsUp() {
            arms.append(("gemma4:e2b (local 2B)", GroundingTestSupport.ollama(model: "gemma4:e2b-it-qat"), ""))
            arms.append(("qwen3.5:4b (local 4B)", GroundingTestSupport.ollama(model: "qwen3.5:4b"), ""))
        }
        if let nearKey = Self.env["NEAR_AI_API_KEY"], !nearKey.isEmpty {
            arms.append(("\(Provider.nearAI.model) (cloud)", Provider.nearAI, nearKey))
        }
        guard !arms.isEmpty else { return }

        var summary: [(String, String, Int, Int)] = []   // shape, arm, cited, hedges
        var rows: [String] = []
        for shape in Self.shapes {
            let response = try await GroundingTestSupport.fetchGrounding(query: shape.braveQuery, key: brave)
            let payload = BraveWebSearchTool.contextXML(from: response)
            let dated = response.sources?.values.filter { $0.age?.isEmpty == false }.count ?? 0
            rows.append("\n### \(shape.label) — `\(shape.braveQuery)` · \(response.grounding.generic.count) sources, \(dated) dated\n")
            for (armLabel, provider, key) in arms {
                var cited = 0, hedges = 0
                for i in 1...trials {
                    let reply = await GroundingTestSupport.ask(
                        provider: provider, apiKey: key, payload: payload, prompt: shape.prompt)
                    if GroundingTestSupport.citesRetrievedFigure(
                        reply: reply, payload: payload, question: shape.prompt) { cited += 1 }
                    let h = GroundingTestSupport.hedgeCount(reply)
                    hedges += h
                    rows.append("- **\(armLabel) \(i)** · cited=\(GroundingTestSupport.citesRetrievedFigure(reply: reply, payload: payload, question: shape.prompt)) hedges=\(h)\n  > \(reply.replacingOccurrences(of: "\n", with: " ").prefix(200))")
                }
                summary.append((shape.label, armLabel, cited, hedges))
            }
        }
        Self.writeReport(trials: trials, summary: summary, rows: rows)
    }

    private static func writeReport(trials: Int, summary: [(String, String, Int, Int)], rows: [String]) {
        guard let dir = env["SWEEP_REPORT_DIR"], !dir.isEmpty else { return }
        var md = "# do local models need different treatment?\n\n"
        md += "\(trials) trials per cell · ONE Brave fetch per shape, that exact payload given to\n"
        md += "every model · same persona, same engine, same tool. Only the MODEL varies.\n\n"
        md += "scored objectively: does the reply state a multi-digit figure present in the\n"
        md += "payload and absent from the question?\n\n"
        md += "| query | model | cited retrieved data | hedges |\n|---|---|---|---|\n"
        for (shape, arm, cited, hedges) in summary {
            md += "| \(shape) | \(arm) | \(cited)/\(trials) | \(hedges) |\n"
        }
        md += "\n## every reply, verbatim\n" + rows.joined(separator: "\n") + "\n"
        try? md.write(toFile: dir + "/model_tier.md", atomically: true, encoding: .utf8)
    }
}
