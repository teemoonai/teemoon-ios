//
//  GroundingLiveTests.swift
//  teemoonTests
//
//  End-to-end grounding against the REAL Brave endpoint and a REAL local model.
//
//  Was `GroundingBudgetLiveTests`, which existed to prove `GroundingBudget`
//  worked: that `.compact` really did ask Brave for less, and that a small model
//  could still answer from what came back. Two of its three tests died with the
//  budget — comparing compact to full is not a question any more, and a live
//  test that re-litigates a settled decision costs money every run to tell you
//  something git already records.
//
//  What survives is the half that was never really about the budget: this is
//  the ONLY test that drives the real `BraveWebSearchTool` through the real
//  engine with a real local model. The sweep can't cover it — its
//  `SWEEP_TOOL_PAYLOAD=large` fakes a payload with a canned tool and never
//  constructs a `BraveWebSearchTool` — so without this, nothing checks that the
//  live tool, the live engine and a 4 B model actually compose.
//
//  ── Cost ────────────────────────────────────────────────────────────────────
//  ONE Brave grounding query, ~$0.005. Grounding bills per query and runs no
//  inference — `/res/v1/llm/context` returns no usage block at all. Do not
//  confuse this with Brave *Answers* ($0.0548, mostly tokens-in for the LLM
//  behind it): different endpoint, ~10x the cost per call.
//
//  Double-gated, so a plain `xcodebuild test` cannot spend anything:
//
//  run it with SWEEP_GROUNDING_BUDGET=1 and BRAVE_API_KEY set.
//
//  Without the flag or the key it SKIPS (green, not failed). Local inference is
//  free; if Ollama isn't listening this skips too.
//

import Foundation
import Testing
import ModelBackend
@testable import teemoon

@Suite("Grounding end-to-end (live)", .serialized)
struct GroundingLiveTests {

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Both gates: the opt-in flag AND a key. Costs money, so an accidental run
    /// is a bug in itself.
    private static var apiKey: String? {
        guard env["SWEEP_GROUNDING_BUDGET"] == "1" else { return nil }
        let key = env["BRAVE_API_KEY"] ?? ""
        return key.isEmpty ? nil : key
    }

    /// The reliable control. `gemma4:e2b` flips between calling the tool and
    /// greeting you on terse prompts — a model-capability coin flip that would
    /// make this test's verdict meaningless. Override to probe it deliberately.
    private static var ollamaModel: String {
        env["SWEEP_OLLAMA_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "qwen3.5:4b"
    }

    /// The real tool, the real engine, a real model — does the whole chain
    /// compose, and does the reply actually use what came back?
    ///
    /// Not "did it call the tool": the characteristic on-device failure is that
    /// the model calls `web_search` and *then* answers "I am ready to assist you
    /// with factual information…", ignoring the result entirely. A check that
    /// stops at the call scores that broken conversation as a pass.
    @Test @MainActor func localModelAnswersFromLiveGrounding() async throws {
        guard let key = Self.apiKey else { return }
        guard await Self.ollamaIsUp() else {
            print("[grounding] ollama not reachable — skipping")
            return
        }

        var provider = Provider(name: "ollama", endpoint: "http://127.0.0.1:11434/v1",
                                model: Self.ollamaModel, requiresAPIKey: false,
                                extraParams: ["max_tokens": "512"])
        provider.modelCapabilities = .tools
        // Production always sends the persona; a tool check without it is easier
        // than the real thing and misses what the phone hits.
        let persona = ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt)

        let results = LockedBox<[RequestResult]>([])
        let model = ConfidentialLanguageModel(
            provider: provider, apiKey: "",
            priorMessages: [WireMessage(role: "system", content: persona)],
            context: nil, events: StreamCallbacks(
                onSourcesFound: { _ in }, onQueriesFound: { _ in },
                onToolExecutionEnded: {},
                onSuccess: { r in results.value = results.value + [r] }))
        let session = LanguageModelSession(
            model: model, tools: [BraveWebSearchTool(apiKey: key)])

        var text = ""
        for try await snapshot in session.streamResponse(to: "What is the weather in New York NY 10001 right now?") {
            text = snapshot.content
        }
        try? await Task.sleep(for: .milliseconds(400))   // onSuccess lands detached

        print("[grounding] \(Self.ollamaModel) replied: \(text.prefix(400))")
        #expect(results.value.contains { !$0.toolCalls.isEmpty }, "model never called web_search")

        // Answered, rather than greeted or refused. The criterion is a
        // temperature FIGURE, which the question cannot supply — matching the
        // location instead would pass a refusal that echoes it back, the scorer
        // bug that voided a whole day's measurements once already.
        #expect(Self.usedTheGrounding(text),
                "reply didn't use the grounding: \(text.prefix(200))")
        // And the XML scaffolding must not leak into what the user reads.
        #expect(!text.contains("<source") && !text.contains("<content>"))
    }

    /// Did the reply actually USE the grounding?
    ///
    /// The check that was wrong the first time, and the error is worth naming:
    /// it accepted a reply mentioning "new york" or "10001" — both straight
    /// from the QUESTION. So
    ///
    ///   "I don't have current weather data for New York NY 10001."
    ///
    /// scored as a successful answer. A refusal counted as a pass, the same
    /// class of mistake as scoring "non-empty" as success: satisfiable without
    /// the tool result existing at all.
    private static func usedTheGrounding(_ text: String) -> Bool {
        let t = text.lowercased()
        guard t.count > 40 else { return false }
        // Reuse the sweep's detector rather than a second, weaker copy — it was
        // written for this exact on-device failure (tool called, greeting back).
        guard !ProviderSweepTests.looksGeneric(t) else { return false }
        guard !soundsLikeARefusal(t) else { return false }
        // A number attached to a temperature unit. The question supplies a town
        // and a ZIP; it cannot supply "72°".
        return t.contains(#/\d{1,3}\s*(°|degree|fahrenheit|celsius)/#)
    }

    /// Fluent "I can't do that" — non-empty, on-topic, worthless as an answer.
    /// It typically echoes the location back, which is exactly why
    /// location-matching was the wrong success signal.
    private static func soundsLikeARefusal(_ t: String) -> Bool {
        ["i don't have", "i do not have", "i cannot", "i can't", "unable to",
         "i'm sorry", "i am sorry", "no current", "not able to", "don't have access",
         "do not have access", "check a weather", "recommend checking", "you can check"]
            .contains { t.contains($0) }
    }

    private static func ollamaIsUp() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/v1/models")!)
        req.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
