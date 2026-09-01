//
//  LocalEngineSmokeTests.swift
//  teemoonTests
//
//  End-to-end smoke for LOCAL models across all three engines teemoon supports:
//  Ollama, llama.cpp and LM Studio.
//
//  Driven by a host-side smoke driver, which is where the engine switching lives —
//  these tests run in the simulator and cannot start or stop host processes. The
//  script brings up exactly ONE engine (16 GB won't hold two, and an evicted
//  model costs ~19 s to reload) and then runs this suite against it.
//
//  Every check goes through the same objects the app uses — `EndpointModelCatalog`
//  for the probe, `ConfidentialLanguageModel` + `LanguageModelSession` for
//  generation — so a pass here means the user-facing path works, not that a
//  mock does.
//
//  Success is judged by `LocalInferenceOracle`, never by "the reply was
//  non-empty". See that file for why.
//
//  OPT-IN — nothing here runs in a plain `xcodebuild test`. See
//  `localSmokeEnabled` below for why that had to change.
//

import Foundation
import Testing
import ModelBackend
@testable import teemoon

/// OPT-IN, like `LiteRTLiveTests` and the grounding judge — every other suite in
/// this target is hermetic.
///
/// It used to be gated on REACHABILITY instead: unset meant "whichever engines
/// happen to be running", which is green in CI and wrong on the machine that
/// actually develops teemoon. The dev Mac keeps Ollama, llama.cpp and LM Studio up
/// as LaunchAgents, so a plain `xcodebuild test` quietly turned into live
/// generations against a 14B model — seconds per test in a suite that otherwise
/// runs in 18, and `toolRoundTripUsesTheToolResult` betting the build on one
/// model's tool-call decision, which is a judgement and not a constant. The last
/// full run needed `-skip-testing:` to get a clean answer, and a suite you have to
/// remember to exclude is a suite that is opted-in the wrong way round.
///
/// The smoke driver sets `LOCAL_SMOKE_ENGINE` per pass, so it still runs
/// everything with no change; `LOCAL_SMOKE=1` runs against whatever is up.
private var localSmokeEnabled: Bool {
    let env = ProcessInfo.processInfo.environment
    // Both spellings, per this target's convention: `xcodebuild` maps
    // `TEST_RUNNER_FOO` to `FOO` inside the test process, and the prefixed name
    // survives in some configurations.
    return ["LOCAL_SMOKE", "LOCAL_SMOKE_ENGINE"].contains {
        env[$0] != nil || env["TEST_RUNNER_" + $0] != nil
    }
}

@Suite("Local engine smoke", .serialized,
       .enabled(if: localSmokeEnabled,
                "set LOCAL_SMOKE=1, or LOCAL_SMOKE_ENGINE=<ollama|llamacpp|lmstudio> to require one"))
struct LocalEngineSmokeTests {

    // MARK: Engines

    enum Engine: String, CaseIterable {
        case ollama, llamacpp, lmstudio

        var endpoint: String {
            switch self {
            case .ollama:   return "http://127.0.0.1:11434/v1"
            case .llamacpp: return "http://127.0.0.1:8080/v1"
            case .lmstudio: return "http://127.0.0.1:1234/v1"
            }
        }
        var host: String { URL(string: endpoint)!.host! + ":" + String(URL(string: endpoint)!.port!) }
    }

    /// The engine under test. The smoke driver sets this per pass. When it
    /// is set the engine MUST be up — a smoke run that silently tests nothing is
    /// the failure mode this suite exists to avoid.
    ///
    /// Unset with `LOCAL_SMOKE=1` means "whichever engines happen to be running",
    /// which is a deliberate second mode: it is how you check three engines in one
    /// pass without the script. Unset with NEITHER set doesn't reach here at all —
    /// the suite is skipped (see `localSmokeEnabled`).
    static var requestedEngine: Engine? {
        let env = ProcessInfo.processInfo.environment
        let raw = env["LOCAL_SMOKE_ENGINE"] ?? env["TEST_RUNNER_LOCAL_SMOKE_ENGINE"]
        return raw.flatMap(Engine.init(rawValue:))
    }

    /// Engines to exercise this pass.
    static func targets() async -> [Engine] {
        if let requested = Self.requestedEngine { return [requested] }
        var up: [Engine] = []
        for e in Engine.allCases where await reachable(e) { up.append(e) }
        return up
    }

    private static func reachable(_ e: Engine) async -> Bool { await probeError(e) == nil }

    /// `nil` when reachable, else the URLError — so an ATS block (a real bug we
    /// must surface) is never confused with "no server running".
    private static func probeError(_ e: Engine) async -> URLError? {
        var req = URLRequest(url: URL(string: "http://\(e.host)/v1/models")!)
        req.timeoutInterval = 3
        do { _ = try await URLSession.shared.data(for: req); return nil }
        catch let err as URLError { return err }
        catch { return URLError(.unknown) }
    }

    /// Resolves the engine to a usable state or explains why not.
    /// Returns nil after recording the right kind of failure/skip.
    private func ready(_ e: Engine) async -> String? {
        if let err = await Self.probeError(e) {
            #expect(err.code != .appTransportSecurityRequiresSecureConnection,
                    "ATS blocked cleartext http://\(e.host) — add NSAllowsLocalNetworking to Info.plist")
            if Self.requestedEngine != nil {
                Issue.record("\(e.rawValue) was requested but is not reachable at \(e.endpoint) — start \(e.rawValue) on \(e.host) and re-run")
            } else {
                print("[smoke] \(e.rawValue) not running — skipping")
            }
            return nil
        }
        guard case .connected(let models) = await EndpointModelCatalog.probe(
                baseURL: URL(string: e.endpoint)!), let first = models.first else {
            Issue.record("\(e.rawValue) is up but served no models")
            return nil
        }
        return first.id
    }

    private func provider(_ e: Engine, model: String, maxTokens: String? = nil) -> Provider {
        Provider(name: "local \(e.rawValue)", endpoint: e.endpoint, model: model,
                 requiresAPIKey: false,
                 extraParams: maxTokens.map { ["max_tokens": $0] } ?? [:])
    }

    /// One generation through the real app path. Returns the final text plus the
    /// `RequestResult` so callers can assert on headers and tool calls.
    @MainActor
    private func generate(_ prompt: String, provider: Provider,
                          tools: [any Tool] = []) async throws -> (String, RequestResult?) {
        let results = LockedBox<[RequestResult]>([])
        let callbacks = StreamCallbacks(
            onSourcesFound: { _ in }, onQueriesFound: { _ in },
            onToolExecutionEnded: {},
            onSuccess: { r in results.value = results.value + [r] })
        let model = ConfidentialLanguageModel(
            provider: provider, apiKey: "", priorMessages: [], context: nil, events: callbacks)
        let session = LanguageModelSession(model: model, tools: tools)

        var text = ""
        for try await snapshot in session.streamResponse(to: prompt) { text = snapshot.content }
        return (text, results.value.first)
    }

    // MARK: 1 — the model list (the "test connection" the user presses)

    @Test @MainActor func probeReturnsModels() async throws {
        for e in await Self.targets() {
            guard let modelID = await ready(e) else { continue }
            #expect(!modelID.isEmpty)
            print("[smoke:\(e.rawValue)] model = \(modelID)")

            // A wrong port must classify as "nothing listening", not as a
            // generic failure — that distinction drives the add-provider error.
            let bad = await EndpointModelCatalog.probe(
                baseURL: URL(string: "http://127.0.0.1:8099/v1")!)
            if case .failed(let kind) = bad {
                #expect(kind == .nothingListening, "wrong port should read as nothingListening, got \(kind)")
            } else {
                Issue.record("probing a dead port should fail, got \(bad)")
            }
        }
    }

    // MARK: 2 — inference that answers THIS request

    @Test @MainActor func inferenceAnswersThisRequest() async throws {
        for e in await Self.targets() {
            guard let modelID = await ready(e) else { continue }
            let nonce = InferenceNonce.make()
            // Small cap: the answer is one token, and an uncapped local model
            // will happily narrate. Keeps the whole run inside its budget.
            let (text, result) = try await generate(
                nonce.prompt, provider: provider(e, model: modelID, maxTokens: "64"))

            let verdict = LocalInferenceOracle.judge(
                reply: text, prompt: nonce.prompt, nonce: nonce.token)
            #expect(verdict.passed, "[\(e.rawValue)] \(verdict) — reply: \(text.prefix(160))")

            // Local means local: no E2EE claimed, and no Authorization header
            // invented for a keyless provider.
            if let result {
                #expect(result.isE2EEActive == false,
                        "[\(e.rawValue)] E2EE must be inactive for a local endpoint")
                let auth = result.requestHeaders?.first {
                    $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }
                #expect(auth == nil, "[\(e.rawValue)] no Authorization header for a keyless provider")
            }
        }
    }

    // MARK: 3 — tool use, judged on whether the tool's OUTPUT reached the answer

    /// The tool returns a planted token that exists nowhere else. A model can
    /// only say it if the tool result actually came back and was read — which is
    /// a stronger check than live Brave could give, and costs nothing.
    @Test @MainActor func toolRoundTripUsesTheToolResult() async throws {
        for e in await Self.targets() {
            guard let modelID = await ready(e) else { continue }
            let planted = InferenceNonce.make().token
            let tool = PlantedSourceTool(planted: planted)
            // A question the model has no reason to refuse — see `PlantedSourceTool`.
            let question = "Which platform does the New York depot shuttle leave from? Use the search tool."

            // NO max_tokens here, deliberately. teemoon sends none in production,
            // and a cap distorts this check specifically: a model that opens with
            // a reasoning preamble ("Thinking Process:…") can be truncated before
            // it ever emits the tool call, which then reads as "never called the
            // tool". That is a harness artifact wearing the costume of a real bug.
            let (text, result) = try await generate(
                question, provider: provider(e, model: modelID), tools: [tool])

            let called = !(result?.toolCalls.isEmpty ?? true)
            let verdict = LocalInferenceOracle.judgeToolUse(.init(
                toolWasCalled: called,
                sourceTexts: [tool.sourceText],
                reply: text,
                prompt: question))
            #expect(verdict.passed, "[\(e.rawValue)] \(verdict) — reply: \(text.prefix(200))")

            // The specific, unfakeable assertion: the planted token came back.
            #expect(text.lowercased().contains(planted.lowercased()),
                    "[\(e.rawValue)] answer never used the tool's own content (planted \(planted))")
        }
    }
}

// MARK: - Stub tool

/// A `web_search` stand-in whose result contains a token invented for this run.
/// Deterministic, free, and impossible to satisfy from parametric memory.
///
/// The planted fact is a DULL one — a shuttle's platform — and that is the second
/// harness artifact this test had to shed, after `max_tokens`. It used to plant an
/// "access code", and a safety-tuned model does not search for one: measured
/// 2026-07-30 against `gemma4:e2b`, it answered "I cannot provide you with an
/// access code… these types of security codes are private information", never
/// called the tool, and the oracle reported exactly that. A refusal is the model
/// working; the test was asking a question whose subject matter it should refuse,
/// and then calling the refusal a tool-calling failure. Nothing about "did the
/// tool's output reach the answer" needs a secret to carry it.
private struct PlantedSourceTool: Tool {
    let name = "web_search"
    let description = "Search the web for current, real-time information such as schedules, weather, recent events, or anything past your training cutoff."
    let planted: String

    var sourceText: String {
        "The New York depot shuttle departs from platform \(planted). The change took effect this morning."
    }

    @Generable struct Arguments: Sendable {
        @Guide(description: "The search query.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        "<source index=\"1\"><url>https://depot.example/codes</url><title>Depot access</title><content>\(sourceText)</content></source>"
    }
}
