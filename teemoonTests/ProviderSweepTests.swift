//
//  ProviderSweepTests.swift
//  teemoonTests
//
//  A behavior sweep across EVERY provider, run through the real engine
//  (ConfidentialLanguageModel → GenerationEngine → SSEParser), because the bugs
//  that reach the phone are the ones a model *list* can't show:
//
//   • the answer carries provider markup (Brave's `<citation>`/`<usage>`)
//   • turn 2 loses the conversation, or errors
//   • the reply is empty because the model streamed `reasoning_content` only
//   • a tool is never attached, or is attached and never called
//   • a server error surfaces as something the user can't act on
//
//  It asserts SHAPE and TRANSPORT, never answer quality — the same script must
//  pass for a 2B local model and a frontier cloud one.
//
//  ── Running it ──────────────────────────────────────────────────────────────
//  The sweep runs in three tiers: local servers only (free); + near.ai / xAI /
//  Fireworks (~a cent); + Brave (≈5.5¢ per query, see below). Each tier is
//  opted into by exporting the matching keys/flags below.
//
//  Keys arrive as TEST_RUNNER_-prefixed environment variables (XCTest strips the
//  prefix for the test process), so nothing is written to disk. A provider whose
//  key is absent, or whose local server isn't running, SKIPS — a laptop with
//  nothing running still goes green.
//
//  ── Cost ────────────────────────────────────────────────────────────────────
//  Every turn is capped at `maxTokens` with a ~10-token prompt. Local servers
//  are free. near.ai / xAI / Fireworks land around $0.001 per turn. Brave
//  ANSWERS is the outlier: its `<usage>` block reported $0.0548 for ONE query
//  (2026-07-25), so it is opt-in and single-turn.
//
//  That figure is Answers only, and it is mostly INFERENCE, not search:
//    queries 0.004 + tokens-in 0.0499 (9,970 tok) + tokens-out 0.0010.
//  Brave *grounding* (`/res/v1/llm/context`, what `BraveWebSearchTool` calls)
//  runs no model and bills the query line alone — ~$5/1000, so ~$0.005. Don't
//  carry the 5.5¢ across to the grounding path; it's off by an order of
//  magnitude and makes cheap checks look unaffordable.
//

import Foundation
import Testing
import ModelBackend
@testable import teemoon

// MARK: - Sweep configuration

/// One provider under test, plus how to reach it.
struct SweepTarget {
    let name: String
    let provider: Provider
    /// Env var holding the key, or nil for a keyless local server.
    let keyEnvVar: String?
    /// Skip the multi-turn check for endpoints that document a single-turn API.
    let singleTurnOnly: Bool
    /// Whether the model LIST is gated by the key. near.ai's `/v1/models` is
    /// public, so a garbage key still returns the full catalogue — a key check
    /// against it proves nothing, and asserting otherwise reports a teemoon bug
    /// that isn't one. (It does mean "connected" on the add-provider screen
    /// doesn't validate a near.ai key: only the first message does.)
    var catalogueRequiresKey: Bool = true
    /// Cost tier — the sweep script decides which tiers run.
    enum Tier: String { case local, cloud, expensive }
    let tier: Tier

    var apiKey: String {
        guard let keyEnvVar else { return "" }
        return ProcessInfo.processInfo.environment[keyEnvVar] ?? ""
    }
    /// A keyed provider with no key is not a failure — it's not configured here.
    var isConfigured: Bool { keyEnvVar == nil || !apiKey.isEmpty }
}

/// Result of one check, collected into the report.
struct SweepFinding {
    let provider: String
    let check: String
    let passed: Bool
    let detail: String
}

@MainActor
final class SweepReport {
    static let shared = SweepReport()
    private(set) var findings: [SweepFinding] = []

    func record(_ f: SweepFinding) {
        var f = f
        if f.detail.count > 240 {
            f = SweepFinding(provider: f.provider, check: f.check, passed: f.passed,
                             detail: String(f.detail.prefix(240)) + "…")
        }
        findings.append(f)
        let mark = f.passed ? "✓" : "✗"
        print("[sweep] \(mark) \(f.provider) · \(f.check)\(f.detail.isEmpty ? "" : " — \(f.detail)")")
    }

    /// Markdown matrix, written where the script can pick it up. Failures name
    /// the provider AND the check, so the output points at the fix.
    func write(to path: String) {
        let providers = findings.map(\.provider).reduced()
        let checks = findings.map(\.check).reduced()
        var md = "# provider sweep\n\n| provider | " + checks.joined(separator: " | ") + " |\n"
        md += "|---" + String(repeating: "|---", count: checks.count) + "|\n"
        for p in providers {
            var row = "| \(p) "
            for c in checks {
                let f = findings.first { $0.provider == p && $0.check == c }
                // A measured check reports its RATE in the cell — "2/5" is the
                // finding, and collapsing it to ✓ throws the measurement away.
                // Matched on the LEADING rate rather than the whole detail, so a
                // measured cell keeps showing "3/5" even once the miss evidence
                // is appended after it.
                let cell: String
                if let rate = f?.detail.firstMatch(of: #/^(\d+/\d+) called/#) {
                    cell = String(rate.1)
                } else {
                    cell = f.map { $0.passed ? "✓" : "✗" } ?? "–"
                }
                row += "| " + cell + " "
            }
            md += row + "|\n"
        }
        let failures = findings.filter { !$0.passed }
        if !failures.isEmpty {
            md += "\n## failures\n\n"
            for f in failures { md += "- **\(f.provider) · \(f.check)** — \(f.detail)\n" }
        }
        try? md.write(toFile: path, atomically: true, encoding: .utf8)
        print("[sweep] report written to \(path)")
    }
}

private extension Array where Element == String {
    /// Unique, in first-appearance order.
    func reduced() -> [String] {
        var seen = Set<String>(), out: [String] = []
        for e in self where seen.insert(e).inserted { out.append(e) }
        return out
    }
}

// MARK: - The sweep

@Suite("Provider sweep", .serialized)
struct ProviderSweepTests {

    /// Small enough that a full sweep costs cents, large enough that a model
    /// gets past a preamble and actually answers.
    static let maxTokens = "48"

    /// The tool check needs a bigger budget: a THINKING model spends its output
    /// on reasoning before it emits a tool call, so a tight cap truncates it
    /// mid-thought and reads as "refused to call the tool" — a false negative
    /// that would send you rewriting prompts for a bug that isn't there.
    static let toolMaxTokens = "512"

    static var targets: [SweepTarget] {
        var t: [SweepTarget] = []
        let env = ProcessInfo.processInfo.environment

        // ── local (free) ────────────────────────────────────────────────────
        if let ollamaModel = env["SWEEP_OLLAMA_MODEL"]?.trimmingCharacters(in: .whitespaces), !ollamaModel.isEmpty {
            t.append(SweepTarget(
                name: "ollama/\(ollamaModel)",
                provider: Provider(name: "ollama", endpoint: "http://127.0.0.1:11434/v1",
                                   model: ollamaModel, requiresAPIKey: false,
                                   extraParams: ["max_tokens": maxTokens]),
                keyEnvVar: nil, singleTurnOnly: false, tier: .local))
        }
        if let llamaModel = env["SWEEP_LLAMACPP_MODEL"]?.trimmingCharacters(in: .whitespaces), !llamaModel.isEmpty {
            t.append(SweepTarget(
                name: "llama.cpp/\(llamaModel)",
                provider: Provider(name: "llama.cpp", endpoint: "http://127.0.0.1:8080/v1",
                                   model: llamaModel, requiresAPIKey: false,
                                   extraParams: ["max_tokens": maxTokens]),
                keyEnvVar: nil, singleTurnOnly: false, tier: .local))
        }
        if let lmModel = env["SWEEP_LMSTUDIO_MODEL"]?.trimmingCharacters(in: .whitespaces), !lmModel.isEmpty {
            t.append(SweepTarget(
                name: "lmstudio/\(lmModel)",
                provider: Provider(name: "lm studio", endpoint: "http://127.0.0.1:1234/v1",
                                   model: lmModel, requiresAPIKey: false,
                                   extraParams: ["max_tokens": maxTokens]),
                keyEnvVar: nil, singleTurnOnly: false, tier: .local))
        }

        // ── cloud (≈$0.001 per turn) ────────────────────────────────────────
        guard env["SWEEP_TIER"] != "local" else { return t }
        var nearAI = Provider.nearAI
        nearAI.extraParams = ["max_tokens": maxTokens]
        t.append(SweepTarget(name: "near.ai", provider: nearAI,
                             keyEnvVar: "NEAR_AI_API_KEY", singleTurnOnly: false,
                             catalogueRequiresKey: false, tier: .cloud))
        var grok = Provider.grok
        grok.extraParams = ["max_tokens": maxTokens]
        t.append(SweepTarget(name: "grok", provider: grok,
                             keyEnvVar: "XAI_API_KEY", singleTurnOnly: false, tier: .cloud))
        var fireworks = Provider.fireworks
        fireworks.extraParams = ["max_tokens": maxTokens]
        t.append(SweepTarget(name: "fireworks", provider: fireworks,
                             keyEnvVar: "FIREWORKS_API_KEY", singleTurnOnly: false, tier: .cloud))

        // ── expensive (Brave: ≈5.5¢ a query) ────────────────────────────────
        guard env["SWEEP_TIER"] == "all" else { return t }
        t.append(SweepTarget(name: "brave", provider: .braveAnswers,
                             keyEnvVar: "BRAVE_ANSWERS_API_KEY", singleTurnOnly: true, tier: .expensive))
        return t
    }


    /// Assistant boilerplate — the reply a model gives when it has lost the
    /// thread: "I am ready to assist you with factual information…", "How can I
    /// help?". It is non-empty, so a check that only tests for emptiness scores
    /// it as a PASS. That is exactly the failure seen on-device (tool called,
    /// generic greeting returned), so it has to be named and failed.
    static func looksGeneric(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["i am ready to assist", "i'm ready to assist", "how can i help",
                "how may i assist", "what would you like", "let me know what topic",
                "i'm here to help", "i am here to help", "please let me know"]
            .contains { t.contains($0) }
    }

    // MARK: Checks

    /// Turn 1 answers, and the answer is CLEAN: no provider markup, not empty.
    @Test @MainActor func firstTurnAnswersCleanly() async throws {
        for target in Self.targets where target.isConfigured {
            guard await Self.reachable(target) else { continue }
            let (text, error) = await Self.send("Reply with exactly one word: pong", to: target)
            guard error == nil else {
                SweepReport.shared.record(.init(provider: target.name, check: "answers",
                                                passed: false, detail: error!))
                continue
            }
            // The prompt asks for one specific word, so the reply is checkable —
            // "non-empty" was never the assertion worth making. A reasoning-only
            // model answers in prose, so the word only has to APPEAR.
            let saidPong = text.lowercased().contains("pong")
            let generic = Self.looksGeneric(text)
            SweepReport.shared.record(.init(
                provider: target.name, check: "answers",
                passed: saidPong && !generic,
                detail: saidPong && !generic ? ""
                      : (generic ? "generic assistant boilerplate — \(text.prefix(100))"
                                 : "never said \"pong\" — \(text.prefix(100))")))

            // Markup that must never survive into a displayed answer.
            let leaks = ["<citation>", "<usage>", "<tool_call>", "<think>", "[DONE]", "<|"]
                .filter { text.contains($0) }
            SweepReport.shared.record(.init(
                provider: target.name, check: "no markup leak",
                passed: leaks.isEmpty, detail: leaks.joined(separator: " ")))
        }
    }

    /// Turn 2 must answer too, and must SEE turn 1 — except where the endpoint
    /// documents a single-turn API, in which case the truncation must be exact
    /// (Brave 422s if a second message reaches it).
    @Test @MainActor func secondTurnKeepsTheConversation() async throws {
        for target in Self.targets where target.isConfigured {
            guard await Self.reachable(target) else { continue }
            let prior = [
                WireMessage(role: "user", content: "My favorite color is teal. Remember it."),
                WireMessage(role: "assistant", content: "Got it — teal."),
            ]
            let wire = ChatGeneration.buildWireMessages(
                from: [
                    Message(role: .user, content: prior[0].content),
                    Message(role: .assistant, content: prior[1].content),
                    Message(role: .user, content: "What is my favorite color? One word."),
                ],
                systemPrompt: "You are a helpful assistant.",
                maxMessages: target.provider.effectiveMaxMessages,
                omitSystemPrompt: target.provider.effectiveOmitSystemPrompt)

            if target.singleTurnOnly {
                // The constraint IS the behavior: nothing may reach the wire but
                // the current question, or the request is rejected outright.
                SweepReport.shared.record(.init(
                    provider: target.name, check: "turn 2",
                    passed: wire.isEmpty,
                    detail: wire.isEmpty ? "single-turn API — history correctly dropped"
                                         : "\(wire.count) prior message(s) would 422"))
                continue
            }
            let (text, error) = await Self.send("What is my favorite color? One word.",
                                                to: target, prior: prior)
            let generic2 = Self.looksGeneric(text)
            SweepReport.shared.record(.init(
                provider: target.name, check: "turn 2",
                passed: error == nil && !text.isEmpty && !generic2,
                detail: error ?? (text.isEmpty ? "empty reply"
                      : generic2 ? "generic assistant boilerplate — \(text.prefix(100))" : "")))
            // The model saw the history if it can name the color.
            SweepReport.shared.record(.init(
                provider: target.name, check: "sees history",
                passed: text.lowercased().contains("teal"),
                detail: text.isEmpty ? "no reply" : String(text.prefix(60))))
        }
    }

    /// A tool is ATTACHED (the gating decision) and CALLED (the model's
    /// decision). Small local models fail the second half for prompt/schema
    /// reasons, which is exactly the signal this check exists to give.
    @Test @MainActor func toolIsAttachedAndCalled() async throws {
        for target in Self.targets where target.isConfigured {
            guard await Self.reachable(target) else { continue }
            guard !target.provider.capabilities.contains(.builtInGrounding) else {
                SweepReport.shared.record(.init(provider: target.name, check: "tool call",
                                                passed: true, detail: "built-in grounding — no tool attached"))
                continue
            }
            // Gating first: teemoon withholds tools from a model it KNOWS can't
            // call them. A false negative here is a silent "search does nothing".
            guard target.provider.modelSupportsTools else {
                SweepReport.shared.record(.init(provider: target.name, check: "tool call",
                                                passed: false, detail: "tool withheld — modelCapabilities says no tools"))
                continue
            }
            let results = LockedBox<[RequestResult]>([])
            let callbacks = StreamCallbacks(
                onSourcesFound: { _ in }, onQueriesFound: { _ in },
                onToolExecutionEnded: {},
                onSuccess: { r in results.value = results.value + [r] })
            var provider = target.provider
            provider.extraParams["max_tokens"] = Self.toolMaxTokens
            // Production ALWAYS sends the persona; a tool check without it is
            // easier than the real thing and misses what the phone hit.
            let persona = ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt)
            let model = ConfidentialLanguageModel(
                provider: provider, apiKey: target.apiKey,
                priorMessages: [WireMessage(role: "system", content: persona)],
                context: nil, events: callbacks)
            let session = LanguageModelSession(model: model, tools: [SweepSearchTool()])
            var text = ""
            do {
                // `??` is NOT enough here, and the difference cost a whole sweep:
                // the sweep driver always exports SWEEP_AB_PROMPT, passing an
                // EMPTY STRING when the user didn't set one. An empty string is
                // not nil, so `??` accepted it and this check streamed a
                // zero-length prompt to every provider. They replied "I see you
                // sent an empty message" / "You haven't provided a question",
                // no tool was called, and all four providers recorded a red
                // "tool call" cell — a harness artifact that looks exactly like
                // the product bug this check exists to detect.
                let prompt = Self.envPrompt("SWEEP_AB_PROMPT")
                    ?? "What is the weather in Paris right now?"
                for try await snapshot in session.streamResponse(to: prompt) {
                    text = snapshot.content
                }
            } catch {
                SweepReport.shared.record(.init(provider: target.name, check: "tool call",
                                                passed: false, detail: error.localizedDescription))
                continue
            }
            // The callback lands from a detached task; give it a moment.
            try? await Task.sleep(for: .milliseconds(400))
            let called = results.value.contains { !$0.toolCalls.isEmpty }
            SweepReport.shared.record(.init(
                provider: target.name, check: "tool call",
                passed: called,
                detail: called ? "" : "model did not call the tool — reply: \(text.prefix(80))"))

            // Calling the tool is only half of it. The SECOND round — where the
            // tool result is fed back — is its own failure mode: observed on
            // gemma4:e2b, the model called web_search and then answered "I am
            // ready to assist you with factual information…", a generic greeting
            // that ignores the result entirely. A check that stops at "did it
            // call the tool" reports that broken conversation as a pass.
            guard called else { continue }
            let usedResult = !Self.looksGeneric(text)
                && (text.lowercased().contains("18")
                    || text.lowercased().contains("sunny")
                    || text.lowercased().contains("paris"))
            SweepReport.shared.record(.init(
                provider: target.name, check: "uses tool result",
                passed: usedResult,
                detail: usedResult ? "" : "answer ignores the tool result — \(text.prefix(120))"))
        }
    }

    /// A rejected key must classify as unauthorized rather than a generic
    /// failure, or the add-provider screen sends the user hunting.
    @Test @MainActor func rejectedKeyIsClassified() async throws {
        for target in Self.targets
        where target.keyEnvVar != nil && target.isConfigured && target.catalogueRequiresKey {
            guard let base = target.provider.openAIBaseURL else { continue }
            let result = await EndpointModelCatalog.probe(
                baseURL: base,
                authHeaderName: target.provider.authHeaderName,
                apiKey: "sk-definitely-not-a-real-key")
            let classified: Bool
            if case .failed(let kind) = result { classified = (kind == .unauthorized) } else { classified = false }
            SweepReport.shared.record(.init(
                provider: target.name, check: "bad key → unauthorized",
                passed: classified, detail: classified ? "" : "got \(result)"))
        }
    }

    /// The stanza teemoon used to append to the persona whenever a tool was
    /// attached, deleted in `aa27f0e` because the local A/B said it did nothing.
    ///
    /// It lives HERE, in the test, precisely because it is gone from production:
    /// "does re-adding it help?" is a question you can only keep answering if
    /// you keep the thing you removed. Verbatim from `ChatGeneration` at the
    /// commit that deleted it — if you edit it, the arm stops measuring the
    /// decision that was actually made.
    static let deletedToolUseGuidance = """
    You have tools available. When answering requires current, local, or real-time \
    information — such as weather, news, prices, sports scores, or anything that may \
    have changed recently — call the appropriate tool (for example web_search) rather \
    than asking the user for clarification or saying you cannot help.
    """

    /// An environment override that treats "set but empty" as absent.
    ///
    /// Every one of these scripts exports its optional knobs unconditionally
    /// (`FOO="${FOO:-}"`), so "unset" arrives as an empty string. Reading them
    /// with `??` silently accepts that empty value as a deliberate choice —
    /// which is how the sweep spent a run sending empty prompts. One helper, so
    /// the next knob added can't reintroduce it.
    static func envPrompt(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The prompt shapes the ± study turns on. Each names a DIFFERENT failure,
    /// and a study that runs only one of them answers only half the question —
    /// which is exactly how §4a ended up with a local-only reversal.
    struct ABShape { let label, prompt: String }
    static let abShapes: [ABShape] = [
        // The local failure: terse and under-specified, so a small model asks
        // for clarification rather than searching. §3b was written for this.
        .init(label: "terse", prompt: "weather 10001"),
        // The CLOUD failure, and the sharpest single finding in §4: a big model
        // has a fluent, confident, STALE answer sitting in its weights, so it
        // never reaches for the tool at all. `gemma-4-31B` answered this one
        // from parametric memory without the nudge. A terse-only study cannot
        // see this — the model isn't confused here, it's certain and wrong.
        .init(label: "stale-memory", prompt: "Who is the current Prime Minister of the United Kingdom?"),
    ]

    /// A/B: does teemoon's PERSONA suppress tool use, and would the deleted
    /// nudge recover it? The theory was that the persona's "if you don't know
    /// something, say so clearly" reads, to a model holding a tool, as licence
    /// to decline instead of search. That was argued from one anecdote; the
    /// local re-measurement said no prompt, persona, and persona+guidance all
    /// call the tool alike, and the stanza was deleted on that basis.
    ///
    /// §4a recorded the honest limit of that reversal: it was measured on LOCAL
    /// models only, so §4's cloud rows — including the stale-memory finding
    /// above — were never re-run. This runs all three variants on both shapes,
    /// on whatever tier the script selected, so the cloud half can finally be
    /// answered with numbers instead of an older study's memory.
    ///
    /// Reported as rates, never a verdict. A single trial proves nothing:
    /// sampling makes tool use probabilistic, which is why an anecdote misleads.
    ///
    ///   Opt in with SWEEP_AB=1 (SWEEP_AB_TRIALS=5 by default); add the cloud
    ///   keys for the cloud arm (the guidance gap, ~$0.03).
    @Test @MainActor func guidanceABTest() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SWEEP_AB"] == "1" else { return }
        let trials = Int(env["SWEEP_AB_TRIALS"] ?? "5") ?? 5
        let persona = ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt)
        let allVariants: [(String, String?)] = [
            ("no prompt", nil),
            ("persona", persona),
            // The ± arm. Present only in the test; production ships without it.
            ("persona+nudge", persona + "\n\n" + Self.deletedToolUseGuidance),
        ]
        // `SWEEP_AB_VARIANTS=persona,persona+nudge` narrows to the arms a given
        // question turns on. Confirming a suspected persona-suppression signal
        // needs n≈20 on TWO arms, not n=5 on three — same wall clock, an answer
        // instead of a hint. "no prompt" is a control for whether the persona
        // matters at all, so it is the one to drop once that's established.
        let variants: [(String, String?)]
        if let picked = Self.envPrompt("SWEEP_AB_VARIANTS")?
            .split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            variants = allVariants.filter { picked.contains($0.0) }
        } else {
            variants = allVariants
        }
        // Two ways to narrow this, because the full grid is expensive and most
        // re-runs are chasing ONE cell. A verbatim prompt override wins outright;
        // otherwise `SWEEP_AB_SHAPE=terse` keeps the named shape only. Being able
        // to re-run a single cell at high n is the difference between confirming
        // a signal and re-paying for the grid to look at one column of it.
        let shapes: [ABShape]
        if let custom = Self.envPrompt("SWEEP_AB_PROMPT") {
            shapes = [ABShape(label: "custom", prompt: custom)]
        } else if let only = Self.envPrompt("SWEEP_AB_SHAPE") {
            shapes = Self.abShapes.filter { $0.label == only }
        } else {
            shapes = Self.abShapes
        }

        // `.expensive` is excluded on purpose: 3 variants × 2 shapes × 5 trials
        // against Brave Answers is 30 queries at ≈5.5¢, i.e. $1.65 for an arm
        // that measures nothing — Brave answers from its own retrieval and is
        // never handed a teemoon tool.
        for target in Self.targets where target.isConfigured && target.tier != .expensive {
            guard await Self.reachable(target) else { continue }
            for shape in shapes {
                for (label, prompt) in variants {
                    var called = 0
                    var notSearched: [String] = []
                    for _ in 0..<trials {
                        let (didCall, reply) = await Self.callsTool(
                            target, systemPrompt: prompt, userPrompt: shape.prompt)
                        if didCall { called += 1 }
                        else if !reply.isEmpty { notSearched.append(reply) }
                    }
                    // When a variant DIDN'T search, the reply is the evidence —
                    // "answered Keir Starmer from memory" is the finding, and a
                    // bare 3/5 throws away the only part you can act on.
                    var detail = "\(called)/\(trials) called"
                    if let miss = notSearched.first {
                        detail += " · answered instead: \(miss.replacingOccurrences(of: "\n", with: " ").prefix(100))"
                    }
                    SweepReport.shared.record(.init(
                        provider: target.name, check: "tool · \(shape.label) · \(label)",
                        passed: called > 0, detail: detail))
                }
            }
        }
    }

    /// One tool-attached generation: did the model call the tool, and what did
    /// it say? The TEXT matters on a miss — a model that answers a current-events
    /// question from its weights instead of searching looks identical to one that
    /// asked for clarification, until you read it.
    @MainActor
    private static func callsTool(
        _ target: SweepTarget, systemPrompt: String?,
        userPrompt: String = "What is the weather in Paris right now?"
    ) async -> (Bool, String) {
        var provider = target.provider
        provider.extraParams["max_tokens"] = toolMaxTokens
        let results = LockedBox<[RequestResult]>([])
        let model = ConfidentialLanguageModel(
            provider: provider, apiKey: target.apiKey,
            priorMessages: systemPrompt.map { [WireMessage(role: "system", content: $0)] } ?? [],
            context: nil, events: StreamCallbacks(
                onSourcesFound: { _ in }, onQueriesFound: { _ in },
                onToolExecutionEnded: {},
                onSuccess: { r in results.value = results.value + [r] }))
        let session = LanguageModelSession(model: model, tools: [SweepSearchTool()])
        var text = ""
        do {
            for try await snapshot in session.streamResponse(to: userPrompt) {
                text = snapshot.content
            }
        } catch {
            return (false, "error: \(error.localizedDescription)")
        }
        try? await Task.sleep(for: .milliseconds(400))
        return (results.value.contains { !$0.toolCalls.isEmpty }, text)
    }

    /// Diagnostic: hit the endpoint with plain URLSession, no teemoon code, so a
    /// failure upstream of the engine (unreachable from the simulator, refused
    /// request, non-SSE response) is told apart from a parsing bug in teemoon.
    @Test @MainActor func rawTransportWorks() async throws {
        for target in Self.targets where target.tier == .local && target.isConfigured {
            guard let base = target.provider.openAIBaseURL else { continue }
            guard await Self.reachable(target) else { continue }
            var req = URLRequest(url: base.appendingPathComponent("chat/completions"))
            req.httpMethod = "POST"
            req.timeoutInterval = 90
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": target.provider.model,
                "messages": [["role": "user", "content": "Reply with exactly one word: pong"]],
                "stream": true,
                "stream_options": ["include_usage": true],
                "max_tokens": 48,
            ])
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                let http = response as? HTTPURLResponse
                var body = ""
                for try await line in bytes.lines { body += line + "\n"; if body.count > 400 { break } }
                let ok = (http?.statusCode == 200) && body.contains("content")
                SweepReport.shared.record(.init(
                    provider: target.name, check: "raw transport", passed: ok,
                    detail: ok ? "" : "HTTP \(http?.statusCode ?? 0) ct=\(http?.value(forHTTPHeaderField: "Content-Type") ?? "?") body=\(body.prefix(160))"))
            } catch {
                SweepReport.shared.record(.init(
                    provider: target.name, check: "raw transport", passed: false,
                    detail: "transport error: \(error.localizedDescription)"))
            }
        }
    }

    /// Writes the matrix. Ordered last by the suite's `.serialized` trait.
    @Test @MainActor func zz_writeReport() {
        let dir = ProcessInfo.processInfo.environment["SWEEP_REPORT_DIR"] ?? NSTemporaryDirectory()
        SweepReport.shared.write(to: dir + "/provider_sweep.md")
    }

    // MARK: Helpers

    /// One generation through the production engine. Returns (text, error).
    ///
    /// On an empty reply it reports what the SERVER actually sent, because
    /// "empty" has three very different causes — the model said nothing, it
    /// streamed only `reasoning_content`, or teemoon dropped what arrived — and
    /// a report that can't tell them apart sends you debugging the wrong layer.
    @MainActor
    private static func send(
        _ prompt: String, to target: SweepTarget, prior: [WireMessage] = []
    ) async -> (String, String?) {
        let results = LockedBox<[RequestResult]>([])
        let model = ConfidentialLanguageModel(
            provider: target.provider, apiKey: target.apiKey, priorMessages: prior,
            context: nil, events: StreamCallbacks(
                onSourcesFound: { _ in }, onQueriesFound: { _ in },
                onToolExecutionEnded: {},
                onSuccess: { r in results.value = results.value + [r] }))
        let session = LanguageModelSession(model: model)
        var text = ""
        do {
            for try await snapshot in session.streamResponse(to: prompt) { text = snapshot.content }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? await Task.sleep(for: .milliseconds(400))   // onSuccess is detached
                let r = results.value.first
                let body = r?.responseBody ?? "(nil — engine produced no text)"
                let sent = r?.requestBodyJSON?.replacingOccurrences(of: "\n", with: " ") ?? "(no request captured)"
                return ("", "empty reply — url=\(r?.url?.absoluteString ?? "?") sent=\(sent.prefix(200)) got=\(body.prefix(200))")
            }
            return (text, nil)
        } catch {
            return (text, error.localizedDescription)
        }
    }

    /// Local servers come and go; a target that isn't listening is skipped, not
    /// failed, so the sweep is safe to run anywhere.
    private static func reachable(_ target: SweepTarget) async -> Bool {
        guard target.tier == .local, let base = target.provider.openAIBaseURL else { return true }
        var req = URLRequest(url: base.appendingPathComponent("models"))
        req.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            print("[sweep] – \(target.name) not reachable — skipping")
            return false
        }
        return true
    }
}

/// The same `web_search` shape teemoon sends, answering from canned data so the
/// check measures the CALL, not the network.
private struct SweepSearchTool: Tool {
    let name = "web_search"
    let description = "Search the web for current, real-time information such as weather, recent events, live prices, or anything past your training cutoff."

    @Generable struct Arguments: Sendable {
        @Guide(description: "The search query.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        // A one-line result is not what Brave returns. Real grounding is several
        // thousand tokens of multi-source XML, which for a 2B model is the bulk
        // of what it has to reason over — SWEEP_TOOL_PAYLOAD=large reproduces
        // that, because a tool call that succeeds on a one-liner can still
        // produce a generic non-answer on the real thing.
        guard ProcessInfo.processInfo.environment["SWEEP_TOOL_PAYLOAD"] == "large" else {
            return "<source index=\"1\"><url>https://weather.example/paris</url><title>Paris weather</title><content>Paris: sunny, 18°C.</content></source>"
        }
        let filler = String(repeating: "Conditions have been variable across the region this week, with local stations reporting differing figures. ", count: 6)
        return (1...5).map { i in
            """
            <source index="\(i)"><url>https://weather.example/report-\(i)</url>            <title>Forecast for \(arguments.query) — report \(i)</title>            <content>Weather for \(arguments.query): currently sunny, 18°C, light breeze from the northwest.             Humidity 44%. \(filler)</content></source>
            """
        }.joined(separator: "\n")
    }
}
