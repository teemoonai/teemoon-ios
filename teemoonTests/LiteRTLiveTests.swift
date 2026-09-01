//
//  LiteRTLiveTests.swift
//  teemoonTests
//
//  Does LiteRT-LM actually deliver what Google claims, on THIS phone?
//
//  The claim is 56 tok/s decode for Gemma 4 E2B on iOS Metal. Measured here
//  against what MLX does on the same device:
//
//      MLX + Qwen3-0.6B    prefill 1304 tok/s · decode 70 tok/s (43 throttled)
//      MLX + Qwen3.5-4B    prefill 64→21 tok/s · decode 14→4 tok/s
//
//  If LiteRT runs Gemma 4 E2B — a far better model than Qwen3-0.6B, and one MLX
//  cannot load at all — at anything near 56 tok/s, that settles the runtime
//  question. If it lands at 4B-like speeds, it does not.
//
//  REAL DEVICE ONLY, and downloads ~2.5 GB on first run. Off by default:
//
//      TEST_RUNNER_LITERT_LIVE=1 xcodebuild test … \
//        -only-testing:teemoonTests/LiteRTLiveTests
//

import Foundation
import Testing
import ModelBackend
import LiteRTLM
@testable import teemoon

/// Importing LiteRTLM puts a second `Tool` in scope — the same collision
/// `LiteRTToolBridge` exists to manage. Qualified here for the same reason.
private typealias LMTool = AnyLanguageModel.Tool

/// Returns a planted search result with no network involved.
///
/// The caller supplies the WHOLE result text, and that matters more than it
/// looks. A result has to read as a plausible answer to the question asked:
/// teemoon's persona says "Never invent or improvise information; if you don't
/// know something, say so clearly", and a model handed a nonsense token where a
/// price belongs correctly refuses to repeat it. Measured — the tool ran, and
/// the reply was still "I do not have real-time access to live commodity
/// prices." That is the persona working, not the bridge failing.
private struct BridgePlantedTool: LMTool {
    let name = "web_search"
    let description = "Search the web for current, real-time information."
    /// Exactly what the model gets back.
    let result: String
    let ran: LockedBox<Bool>

    @Generable struct Arguments: Sendable {
        @Guide(description: "The search query.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        ran.value = true
        return result
    }
}

/// Records that a tool was CALLED, whatever it then returns.
///
/// Measuring `onSourcesFound` instead conflates "the model never called" with
/// "the model called and Brave returned nothing" — two completely different
/// bugs that produce the same number.
private struct CallRecordingTool<Inner: LMTool>: LMTool where Inner.Output == String {
    let inner: Inner
    let ran: LockedBox<Bool>
    var name: String { inner.name }
    var description: String { inner.description }
    /// Forwarded, not re-derived: the wrapper has to be invisible to the model,
    /// or it would be measuring its own schema instead of the real tool's.
    var parameters: GenerationSchema { inner.parameters }
    typealias Arguments = Inner.Arguments
    typealias Output = String
    func call(arguments: Inner.Arguments) async throws -> String {
        ran.value = true
        let out = try await inner.call(arguments: arguments)
        print("[why]   tool ran, returned \(out.count) chars: \(out.prefix(120))")
        return out
    }
}

/// The real search, behind a MINIMAL schema: one required field, short
/// descriptions. Arm C differs from arm A only in what the model is shown.
private struct TrimmedSearchTool: LMTool {
    let name = "web_search"
    let description = "Search the web for current, real-time information."
    let apiKey: String

    @Generable struct Arguments: Sendable {
        @Guide(description: "The search query.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await BraveWebSearchTool(apiKey: apiKey, onDevice: true)
            .call(arguments: .init(query: arguments.query, freshness: nil,
                                   contextThresholdMode: nil, count: nil))
    }
}

@Suite("LiteRT-LM (live — downloads a .litertlm bundle)", .serialized)
struct LiteRTLiveTests {

    /// Google's own comparison point: the model AI Edge Gallery ships.
    static let repoID = "litert-community/gemma-4-E2B-it-litert-lm"
    static let fileName = "gemma-4-E2B-it.litertlm"
    static let sizeMB = 2468
    static let weatherPrompt = "What's the weather in New York NY today?"

    /// The multi-trial investigations are a separate opt-in.
    ///
    /// They are diagnostic scaffolding, not regression tests: each runs 8-16
    /// generations (some hitting the live Brave API), which is minutes of
    /// sustained GPU and enough heat to drop the phone off Wi-Fi. Valuable when
    /// a tool-calling result needs explaining, pure cost otherwise.
    static var diagnosticsEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return enabled && (env["LITERT_DIAGNOSTICS"] != nil
                           || env["TEST_RUNNER_LITERT_DIAGNOSTICS"] != nil)
    }

    static var enabled: Bool {
        #if targetEnvironment(simulator)
        // Unlike MLX (which aborts), LiteRT ships an ios-arm64-simulator slice,
        // so this MIGHT work in the sim. Untested — kept device-only until
        // someone verifies it rather than assuming.
        return false
        #else
        let env = ProcessInfo.processInfo.environment
        return env["LITERT_LIVE"] != nil || env["TEST_RUNNER_LITERT_LIVE"] != nil
        #endif
    }

    /// The catalog entry these tests exercise. Using the catalog rather than
    /// hardcoded constants is what keeps the tests and the app pointed at the
    /// same file — see `modelPath`.
    static var catalogModel: LocalModel {
        LocalModelCatalog.all.first { $0.id == repoID }
            ?? LocalModelCatalog.all[0]
    }

    /// Where the bundle lands — **the location the app itself uses**.
    ///
    /// It used to be a flat `litert/<file>` path of this suite's own invention,
    /// which quietly meant the tests and the app disagreed about where a model
    /// lives: `LocalModelStorage.isInstalled(model)` answered "no" for a bundle
    /// these tests had just generated from. That surfaced as a tool-support
    /// sweep reporting every model NOT INSTALLED minutes after this suite ran
    /// six passing tests against one — and, on a real phone, would have meant
    /// downloading the same 2.5 GB twice into two places.
    static var modelPath: URL {
        LocalModelStorage.file(for: catalogModel)
    }

    /// The pre-catalog location. Kept only to migrate off it.
    private static var legacyModelPath: URL {
        LocalModelStorage.baseDirectory
            .appending(component: "litert")
            .appending(component: fileName)
    }

    /// Fetches the bundle through the app's own downloader.
    ///
    /// This suite used to hand-roll the download, on the stated grounds that
    /// `LocalModelDownloader` assumed MLX's snapshot-a-repo shape. It is
    /// format-aware now, so hand-rolling it would only re-open the gap between
    /// what the tests exercise and what a user gets.
    private func downloadIfNeeded() async throws {
        let destination = Self.modelPath
        if FileManager.default.fileExists(atPath: destination.path) { return }

        // One-time move off the old flat path, so an already-downloaded bundle
        // is not fetched a second time.
        if FileManager.default.fileExists(atPath: Self.legacyModelPath.path) {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: Self.legacyModelPath, to: destination)
            print("[litert-live] migrated bundle from the legacy flat path")
            return
        }

        print("[litert-live] downloading \(Self.sizeMB) MB via LocalModelDownloader …")
        let start = ContinuousClock.now
        let model = Self.catalogModel
        await MainActor.run { LocalModelDownloader.shared.start(model) }
        while await MainActor.run(body: { LocalModelDownloader.shared.isDownloading(model.id) }) {
            try await Task.sleep(for: .seconds(2))
        }
        if let failure = await MainActor.run(body: { LocalModelDownloader.shared.failures[model.id] }) {
            throw LocalInferenceError.loadFailed("download failed: \(failure)")
        }
        print("[litert-live] downloaded in \(start.duration(to: .now))")
    }

    @Test(.enabled(if: Self.enabled, "set LITERT_LIVE=1 (downloads ~2.5 GB)"),
          .timeLimit(.minutes(60)))
    @MainActor
    func runsGemma4AndReportsThroughput() async throws {
        try await downloadIfNeeded()
        #expect(FileManager.default.fileExists(atPath: Self.modelPath.path),
                "bundle missing after download")
        print("[litert-live] available memory: \(LocalMemory.availableMB()) MB")

        let transport = LiteRTTransport(
            modelPath: Self.modelPath, estimatedSizeMB: Self.sizeMB, contextTokens: 4096
        )
        let messages: [[String: Any]] = [
            ["role": "system", "content": "You are a helpful assistant."],
            ["role": "user", "content": "What is the capital of France? Answer in one word."],
        ]

        let start = ContinuousClock.now
        let turn = try await transport.runTurn(messages: messages, includeTools: false) { _ in }
        let elapsed = start.duration(to: .now)

        // The transport logs the prefill/decode split from LiteRT's own
        // benchmark API — that is the number to compare against MLX, not this
        // wall clock, which includes engine warm-up on the first run.
        print("[litert-live] \(elapsed) — reply: \(turn.content.prefix(120))")
        #expect(!turn.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "no text generated")
        #expect(turn.content.lowercased().contains("paris"),
                "ran but did not answer — reply: \(turn.content)")
    }

    /// Prefill at a REALISTIC prompt size.
    ///
    /// The short prompts above report 171-193 tok/s prefill against MLX's 1,304,
    /// which looks alarming — but they are 18-token prompts, so that figure is
    /// fixed overhead, not throughput. Prefill is precisely where a grounded
    /// query hurts (5 web sources ≈ 4k tokens, and on MLX that curve is
    /// superlinear: 12.98 s at 10 sources), so it has to be measured at the size
    /// that actually occurs before LiteRT can be compared to MLX on it.
    @Test(.enabled(if: Self.enabled, "set LITERT_LIVE=1 (downloads ~2.5 GB)"),
          .timeLimit(.minutes(30)))
    @MainActor
    func reportsPrefillAtGroundedPromptSizes() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.modelPath.path),
                     "run runsGemma4AndReportsThroughput first")
        // Same shape as the MLX prefill benchmark so the two are comparable.
        func sources(_ n: Int) -> String {
            (1...n).map { i in
                """
                <source index="\(i)"><url>https://example.com/\(i)</url><title>Report \(i)</title>
                <content>Brent crude traded at $98.49 per barrel on July 23, 2026. \
                \(String(repeating: "Further market detail followed through the session. ", count: 20))</content>
                </source>
                """
            }.joined(separator: "\n")
        }

        let transport = LiteRTTransport(
            modelPath: Self.modelPath, estimatedSizeMB: Self.sizeMB, contextTokens: 8192
        )
        for count in [1, 5, 10] {
            let payload = sources(count)
            let start = ContinuousClock.now
            _ = try await transport.runTurn(messages: [
                ["role": "system", "content": "You are a helpful assistant."],
                ["role": "user", "content": "Summarise these sources.\n\n\(payload)"],
            ], includeTools: false) { _ in }
            print("[litert-live] prefill sources=\(count) chars=\(payload.count) -> \(start.duration(to: .now))")
        }
    }

    /// Does LiteRT actually call teemoon's tool, through the bridge?
    ///
    /// This is the piece the spike deliberately skipped. It exercises the whole
    /// chain: teemoon's flattened schema reaches the model, the model emits a
    /// call, LiteRT's ToolManager routes it to `LiteRTWebSearchTool`, the bridge
    /// looks the real tool up in the static registry and runs it, and the result
    /// comes back as a `ToolCallRecord`.
    ///
    /// A local, network-free tool so a failure is teemoon's, not Brave's.
    @Test(.enabled(if: Self.enabled, "set LITERT_LIVE=1 (downloads ~2.5 GB)"),
          .timeLimit(.minutes(30)))
    @MainActor
    func callsTeemoonToolsThroughTheBridge() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.modelPath.path),
                     "run runsGemma4AndReportsThroughput first")

        let ran = LockedBox<Bool>(false)
        let planted = "ZX9-QUARTZ"
        let tool = BridgePlantedTool(result: "The depot access code is \(planted).", ran: ran)

        let sources = LockedBox<Int>(0)
        let events = StreamCallbacks(
            onSourcesFound: { s in sources.value += s.count },
            onQueriesFound: { _ in }, onToolExecutionEnded: {}, onSuccess: { _ in }
        )
        let transport = LiteRTTransport(
            modelPath: Self.modelPath, estimatedSizeMB: Self.sizeMB,
            contextTokens: 4096, tools: [tool], events: events
        )
        // The decisive diagnostic. A model that never sees the schema cannot
        // call the tool, and the reply is indistinguishable from one that saw it
        // and declined — the first run here printed `toolRan=false` with a
        // perfectly ordinary "I need more context", which says nothing about
        // which. `renderPrefaceIntoString()` is LiteRT rendering exactly what it
        // will send, so it separates the two without guessing.
        // Not fatal: `renderPrefaceIntoString` is a debug entry point that
        // returns null on some bundles, and a diagnostic that can fail the run
        // it exists to explain is worse than no diagnostic.
        if let preface = try? await transport.renderedPreface(tools: [tool]) {
            print("[litert-live] preface (\(preface.count) chars):\n\(preface.prefix(2000))")
            #expect(preface.contains("web_search"),
                    "the tool schema never reached the model — the bridge is not wired, and no prompt wording would fix it")
        } else {
            print("[litert-live] preface unavailable for this bundle")
        }

        let turn = try await transport.runTurn(messages: [
            ["role": "system", "content": "You are a helpful assistant. Use tools when they apply."],
            ["role": "user", "content": "What is the current depot access code? Use the web_search tool to look it up."],
        ], includeTools: true) { _ in }

        print("[litert-live] bridge: toolRan=\(ran.value) reply=\(turn.content.prefix(200))")
        // Whether a model DECIDES to call is a model question, and one small
        // models answer inconsistently — so it is reported, not asserted. The
        // chain itself is proved deterministically in LiteRTToolBridgeTests,
        // which needs no model at all. What IS asserted: if it did call, the
        // planted answer came back.
        if ran.value {
            #expect(turn.content.lowercased().contains(planted.lowercased()),
                    "tool ran but its result never reached the answer: \(turn.content.prefix(300))")
        }
    }

    /// The bundle on this phone must hash to the value the catalog pins.
    ///
    /// The unit test checks the pin against HuggingFace's *metadata*; this
    /// checks it against the 2.5 GB of bytes actually sitting on the device —
    /// the thing that gets memory-mapped and executed. It also exercises the
    /// chunked hasher at real size, where a whole-file read would allocate
    /// 2.5 GB on a device that is already gating model loads on free memory.
    @Test(.enabled(if: Self.enabled, "set LITERT_LIVE=1"),
          .timeLimit(.minutes(20)))
    @MainActor
    func theInstalledBundleMatchesItsPinnedChecksum() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.modelPath.path),
                     "run runsGemma4AndReportsThroughput first")
        let expected = try #require(Self.catalogModel.sha256,
                                    "the catalog entry has no pinned checksum")

        let before = LocalMemory.availableMB()
        let start = ContinuousClock.now
        let actual = try LocalModelDownloader.sha256OfFile(at: Self.modelPath)
        let elapsed = start.duration(to: .now)
        let after = LocalMemory.availableMB()

        print("""
            [litert-live] checksum \(elapsed) · memory \(before) -> \(after) MB
            [litert-live] expected \(expected)
            [litert-live] actual   \(actual)
            """)
        #expect(actual.caseInsensitiveCompare(expected) == .orderedSame,
                "the installed bundle does not match the pinned checksum")
        // Hashing must not cost memory proportional to the file. A whole-file
        // read would show up here as a multi-gigabyte drop.
        #expect(before - after < 500,
                "hashing consumed \(before - after) MB — it is not streaming")
    }

    /// The same tool round trip, but through the stack the APP actually runs.
    ///
    /// THIS IS THE TEST THAT MATTERS, and its absence is a mistake already made
    /// once on the MLX path: direct-transport tests called the tool 3/3 while
    /// the app failed four times running. The transport was never the problem —
    /// the app differs in three ways a transport test cannot see:
    ///
    ///   - the real persona (`AppSettings.defaultSystemPrompt`, datetime
    ///     resolved), not a one-line "use tools when asked"
    ///   - the real prompt shape a user types, not an instruction naming the tool
    ///   - `LocalLanguageModel`'s real defaults, including temperature 0.7 —
    ///     transport tests pinned 0, and at 0.7 the decision is a different
    ///     distribution
    ///
    /// So this goes through `LocalLanguageModel` + `LanguageModelSession` +
    /// `GenerationEngine`, exactly as `ChatGeneration` does, and changes nothing
    /// from their defaults.
    @Test(.enabled(if: Self.enabled, "set LITERT_LIVE=1 (downloads ~2.5 GB)"),
          .timeLimit(.minutes(30)))
    @MainActor
    func callsToolsThroughTheAppsOwnStack() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.modelPath.path),
                     "run runsGemma4AndReportsThroughput first")

        let ran = LockedBox<Bool>(false)
        // A plausible ANSWER, not a nonsense token — and a number specific
        // enough that it cannot have come from the weights. Handed
        // "the answer is ZX9-QUARTZ" where a price belongs, the model ran the
        // tool and then refused to repeat it ("I do not have real-time access to
        // live commodity prices"), which is the persona's "never invent or
        // improvise" clause working exactly as written.
        let planted = "$147.63"
        let tool = BridgePlantedTool(
            result: "Brent crude is trading at \(planted) per barrel as of this morning.",
            ran: ran
        )

        let ref = LocalModelRef(
            id: Self.repoID, directory: Self.modelPath.deletingLastPathComponent(),
            sizeMB: Self.sizeMB, bundleFile: Self.modelPath
        )
        // Exactly what ChatGeneration sends: the stored persona with its
        // templates resolved, as a system wire message.
        let persona = ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt)
        let lm = LocalLanguageModel(
            model: ref,
            priorMessages: [WireMessage(role: "system", content: persona)],
            events: StreamCallbacks(onSourcesFound: { _ in }, onQueriesFound: { _ in },
                                    onToolExecutionEnded: {}, onSuccess: { _ in })
            // temperature / maxTokens / enableThinking left at their defaults on
            // purpose — overriding them here would rebuild the gap this test
            // exists to close.
        )
        let session = LanguageModelSession(model: lm, tools: [tool])

        // A question a user would actually type: no tool named, and one where
        // searching is plainly the right move.
        //
        // The wording is load-bearing, and the first version of this test got it
        // wrong — it asked for an invented "depot access code", the model
        // sensibly asked what that meant, and `toolRan=false` looked like a
        // broken app path. `isolatesWhyTheAppStackDeclinesToCall` settled it:
        // 3/3 on this question, 0/3 on the invented one with the persona and the
        // temperature held constant. The question was the variable.
        var text = ""
        for try await snapshot in session.streamResponse(to: "What's the price of oil right now?") {
            text = snapshot.content
        }
        // On one line: replies here run to several paragraphs, and the planted
        // value tends to land in the LAST one — a truncated or line-filtered
        // dump reads as a model that ignored the tool result.
        print("[litert-live] app-stack toolRan=\(ran.value) contains=\(text.contains(planted)) "
              + "reply: \(text.replacingOccurrences(of: "\n", with: " ⏎ "))")

        #expect(ran.value, "the app stack never called the tool on a plainly search-shaped question")
        // The planted token exists nowhere but inside the tool, so finding it in
        // the answer proves the whole path — decision, bridge, execution, and
        // the result surviving back into the visible reply.
        #expect(text.contains(planted),
                "the tool ran but its result never reached the user-visible answer: \(text.prefix(300))")
    }

    /// Downloads any catalog model, so the sweep can measure it.
    ///
    /// `LocalToolSupportSweepTests` deliberately never downloads — it reports
    /// "NOT INSTALLED — unmeasured" rather than silently pulling gigabytes. This
    /// is the opt-in that puts a model on the device first:
    ///
    ///     TEST_RUNNER_LITERT_MODEL_ID=litert-community/gemma-4-E4B-it-litert-lm
    @Test(.enabled(if: Self.enabled, "set LITERT_LIVE=1 + LITERT_MODEL_ID"),
          .timeLimit(.minutes(60)))
    @MainActor
    func downloadsTheModelNamedInTheEnvironment() async throws {
        let env = ProcessInfo.processInfo.environment
        let id = try #require(env["LITERT_MODEL_ID"] ?? env["TEST_RUNNER_LITERT_MODEL_ID"],
                              "set TEST_RUNNER_LITERT_MODEL_ID to a catalog id")
        let model = try #require(LocalModelCatalog.model(id: id), "\(id) is not in the catalog")
        if LocalModelStorage.isInstalled(model) {
            print("[dl] \(model.displayName) already installed")
            return
        }
        print("[dl] downloading \(model.displayName) (\(model.sizeMB) MB) …")
        let start = ContinuousClock.now
        LocalModelDownloader.shared.start(model)
        while LocalModelDownloader.shared.isDownloading(model.id) {
            try await Task.sleep(for: .seconds(5))
        }
        if let failure = LocalModelDownloader.shared.failures[model.id] {
            Issue.record("download failed: \(failure)")
            return
        }
        print("[dl] done in \(start.duration(to: .now)) — installed=\(LocalModelStorage.isInstalled(model))")
        #expect(LocalModelStorage.isInstalled(model))
    }

    /// The REAL `BraveWebSearchTool`, not a stand-in.
    ///
    /// Every tool test so far used a simplified planted tool: one or two
    /// required fields, a one-line description. The real tool has THREE OPTIONAL
    /// fields (`freshness`, `contextThresholdMode`, `count`) and ~2 kB of
    /// descriptions — and this transport runs with constrained decoding on, so
    /// generation is constrained to whatever schema teemoon produces from that.
    ///
    /// A user reported "no tool calls on local" with grounding enabled and a
    /// valid key, on the model this suite measures at 12/12 with a planted tool.
    /// The difference between those two facts is this schema, so this is the
    /// test that can tell them apart.
    ///
    /// Needs a Brave key: `TEST_RUNNER_BRAVE_API_KEY=$BRAVE_API_KEY`.
    @Test(.enabled(if: Self.enabled, "set LITERT_LIVE=1"),
          .timeLimit(.minutes(30)))
    @MainActor
    func callsTheRealBraveToolNotAStandIn() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.modelPath.path),
                     "run runsGemma4AndReportsThroughput first")
        let env = ProcessInfo.processInfo.environment
        let key = try #require(env["BRAVE_API_KEY"] ?? env["TEST_RUNNER_BRAVE_API_KEY"],
                               "set TEST_RUNNER_BRAVE_API_KEY to exercise the real tool")

        // Exactly what ChatGeneration builds for an on-device provider.
        let tool = BraveWebSearchTool(apiKey: key, onDevice: true)

        // What the model is actually shown. Printed because a schema the
        // constrained decoder cannot follow is invisible from the reply alone.
        let schema = GenerationEngine.flattenedToolSchema(tool)
        let json = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        print("[real-tool] schema \(json.count) bytes: \(String(data: json, encoding: .utf8) ?? "")")

        let ref = LocalModelRef(
            id: Self.repoID, directory: Self.modelPath.deletingLastPathComponent(),
            sizeMB: Self.sizeMB, bundleFile: Self.modelPath
        )
        let sources = LockedBox<Int>(0)
        let lm = LocalLanguageModel(
            model: ref,
            priorMessages: [WireMessage(
                role: "system",
                content: ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt)
            )],
            events: StreamCallbacks(onSourcesFound: { sources.value += $0.count },
                                    onQueriesFound: { _ in },
                                    onToolExecutionEnded: {}, onSuccess: { _ in })
        )
        let session = LanguageModelSession(model: lm, tools: [tool])

        var text = ""
        for try await snapshot in session.streamResponse(to: "What's the weather in New York NY today?") {
            text = snapshot.content
        }
        print("[real-tool] sources=\(sources.value) reply: \(text.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(400))")

        #expect(sources.value > 0,
                "the real web_search tool was never called — grounding is enabled and the key is valid, so this is teemoon's bug, not the user's setup")
    }

    /// WHY the real tool is ignored when a planted one is called 12/12.
    ///
    /// Two things differ between them, and they are separable:
    ///   - the SCHEMA: 1,613 bytes with three optional fields, against ~200
    ///     bytes with none
    ///   - CONSTRAINED DECODING, which this transport turns on and which
    ///     constrains generation to exactly that schema
    ///
    /// A: real tool, constrained on   (what ships — reproduces the bug)
    /// B: real tool, constrained off  (indicts constrained decoding)
    /// C: trimmed tool, constrained on (indicts the schema's size/optionals)
    @Test(.enabled(if: Self.diagnosticsEnabled, "set LITERT_DIAGNOSTICS=1 (slow: many generations)"),
          .timeLimit(.minutes(30)))
    @MainActor
    func isolatesWhyTheRealToolIsIgnored() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = try #require(env["BRAVE_API_KEY"] ?? env["TEST_RUNNER_BRAVE_API_KEY"])
        let ref = LocalModelRef(
            id: Self.repoID, directory: Self.modelPath.deletingLastPathComponent(),
            sizeMB: Self.sizeMB, bundleFile: Self.modelPath
        )

        func trial<T: LMTool>(tool: T, constrained: Bool, prompt: String) async -> Bool where T.Output == String {
            let ran = LockedBox<Bool>(false)
            let recording = CallRecordingTool(inner: tool, ran: ran)
            LiteRTLM.ExperimentalFlags.optIntoExperimentalAPIs()
            LiteRTLM.ExperimentalFlags.enableConversationConstrainedDecoding = constrained
            let sources = LockedBox<Int>(0)
            let lm = LocalLanguageModel(
                model: ref,
                priorMessages: [WireMessage(
                    role: "system",
                    content: ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt)
                )],
                events: StreamCallbacks(onSourcesFound: { sources.value += $0.count },
                                        onQueriesFound: { _ in },
                                        onToolExecutionEnded: {}, onSuccess: { _ in })
            )
            let session = LanguageModelSession(model: lm, tools: [recording])
            do {
                for try await _ in session.streamResponse(to: prompt) {}
            } catch {
                print("[why] threw: \(error)")
            }
            if sources.value > 0 { print("[why]   sources=\(sources.value)") }
            return ran.value
        }

        let real = BraveWebSearchTool(apiKey: key, onDevice: true)
        for (label, constrained) in [("A real + constrained ON ", true),
                                     ("B real + constrained OFF", false)] {
            var called = 0
            for _ in 1...2 where await trial(tool: real, constrained: constrained,
                                             prompt: Self.weatherPrompt) { called += 1 }
            print("[why] \(label) · weather: CALLED \(called)/2")
        }
        var smallWeather = 0
        for _ in 1...2 where await trial(tool: TrimmedSearchTool(apiKey: key), constrained: true,
                                         prompt: Self.weatherPrompt) { smallWeather += 1 }
        print("[why] C small + constrained ON  · weather: CALLED \(smallWeather)/2")
        // The one remaining variable: the QUESTION. `callsToolsThroughTheAppsOwnStack`
        // passes 3/3 with a schema no richer than arm C — but it asks about the
        // price of oil, not the weather. If a model that ignores "weather"
        // searches for "oil", nothing above is the cause.
        var realOil = 0
        for _ in 1...2 where await trial(tool: real, constrained: true,
                                         prompt: "What is the price of oil right now?") { realOil += 1 }
        print("[why] real  · OIL:     CALLED \(realOil)/2")
        // Restore what ships, so a later test in this serialized suite is not
        // silently running a different configuration.
        LiteRTLM.ExperimentalFlags.enableConversationConstrainedDecoding = true
    }

    /// Why the app stack didn't call the tool when the transport test did.
    ///
    /// Three things change between them at once — persona, prompt wording, and
    /// temperature — so the first run tells you only that *something* differs.
    /// This varies them one at a time. Reports rates; asserts nothing, because
    /// the answer is a measurement, not a contract.
    ///
    ///   A  real persona  + a realistic grounded question
    ///   B  real persona  + the invented-term question the app test used
    ///   C  toy prompt    + the invented-term question  (≈ the transport test)
    ///   D  real persona  + invented term, temperature 0 (transport used 0)
    ///
    /// A high but B low means the invented term was simply an ambiguous
    /// question and there is no app bug. C high but B low indicts the persona.
    /// D high but B low indicts temperature. All low indicts the app path.
    @Test(.enabled(if: Self.diagnosticsEnabled, "set LITERT_DIAGNOSTICS=1 (slow: 12 generations)"),
          .timeLimit(.minutes(30)))
    @MainActor
    func isolatesWhyTheAppStackDeclinesToCall() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.modelPath.path),
                     "run runsGemma4AndReportsThroughput first")

        let ref = LocalModelRef(
            id: Self.repoID, directory: Self.modelPath.deletingLastPathComponent(),
            sizeMB: Self.sizeMB, bundleFile: Self.modelPath
        )
        let persona = ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt)
        let toy = "You are a helpful assistant. Use tools when they apply."
        let invented = "What's the current depot access code?"
        let realistic = "What's the price of oil right now?"

        func trial(systemPrompt: String, prompt: String, temperature: Float) async -> Bool {
            let ran = LockedBox<Bool>(false)
            let lm = LocalLanguageModel(
                model: ref,
                priorMessages: [WireMessage(role: "system", content: systemPrompt)],
                events: StreamCallbacks(onSourcesFound: { _ in }, onQueriesFound: { _ in },
                                        onToolExecutionEnded: {}, onSuccess: { _ in }),
                temperature: temperature
            )
            let session = LanguageModelSession(
                model: lm, tools: [BridgePlantedTool(result: "The depot access code is ZX9-QUARTZ.", ran: ran)]
            )
            // A generation that throws still answers the question this arm asks
            // — did it call? — so a failure is counted, not propagated.
            do {
                for try await _ in session.streamResponse(to: prompt) {}
            } catch {
                print("[litert-live] trial threw: \(error)")
            }
            return ran.value
        }

        // The decision is stochastic, so one sample per arm is indistinguishable
        // from noise — the mistake that produced the disproved persona theory on
        // the MLX path.
        let trials = 3
        let arms: [(String, String, String, Float)] = [
            ("A persona + realistic", persona, realistic, 0.7),
            ("B persona + invented ", persona, invented, 0.7),
            ("C toy     + invented ", toy, invented, 0.7),
            ("D persona + invented ", persona, invented, 0),
        ]
        for (label, systemPrompt, prompt, temperature) in arms {
            var called = 0
            for _ in 1...trials {
                if await trial(systemPrompt: systemPrompt, prompt: prompt, temperature: temperature) {
                    called += 1
                }
            }
            print("[litert-live] arm \(label) temp=\(temperature): called \(called)/\(trials)")
        }
    }

    /// Second call, engine already warm: this is the honest steady-state figure,
    /// with model load excluded.
    @Test(.enabled(if: Self.enabled, "set LITERT_LIVE=1 (downloads ~2.5 GB)"),
          .timeLimit(.minutes(30)))
    @MainActor
    func reportsWarmThroughput() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.modelPath.path),
                     "run runsGemma4AndReportsThroughput first")
        let transport = LiteRTTransport(
            modelPath: Self.modelPath, estimatedSizeMB: Self.sizeMB, contextTokens: 4096
        )
        for i in 1...2 {
            let start = ContinuousClock.now
            let turn = try await transport.runTurn(messages: [
                ["role": "system", "content": "You are a helpful assistant."],
                ["role": "user", "content": "Explain what an API is, in three sentences."],
            ], includeTools: false) { _ in }
            print("[litert-live] warm run \(i): \(start.duration(to: .now)) · \(turn.content.count) chars")
        }
    }
}

// MARK: - Context budget cost

extension LiteRTLiveTests {

    /// What a larger context actually COSTS, on this device.
    ///
    /// `contextTokens` sizes the KV cache, and the question it answers is "why
    /// not just use the model's maximum?" Gemma 4 E2B advertises
    /// `max_position_embeddings: 131072`, so the ceiling is not the model — it is
    /// this phone's memory, and the cache is allocated when the engine is built
    /// whether or not the tokens are ever used.
    ///
    /// Theory, from the published config (35 layers, 1 KV head, head_dim 256,
    /// fp16 → 35 KB/token; 28 of 35 layers use a 512-token sliding window):
    ///
    ///      ctx   4096:  42 MB with sliding windows, 140 MB without
    ///      ctx   8192:  70 MB              /  280 MB
    ///      ctx  32768: 238 MB              / 1120 MB
    ///      ctx 131072: 910 MB              / 4480 MB
    ///
    /// Whether LiteRT exploits the sliding windows is not something to assume —
    /// the difference is 4x. This measures it.
    @Test(.enabled(if: Self.diagnosticsEnabled, "set LITERT_DIAGNOSTICS=1 (loads the model repeatedly)"),
          .timeLimit(.minutes(30)))
    @MainActor
    func measuresWhatContextSizeCostsInMemory() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.modelPath.path))

        for context in [4096, 8192, 16384, 32768] {
            await LiteRTTransport.evictEngines()
            try await Task.sleep(for: .milliseconds(500))
            let before = LocalMemory.availableMB()

            let transport = LiteRTTransport(
                modelPath: Self.modelPath, estimatedSizeMB: Self.sizeMB, contextTokens: context
            )
            let start = ContinuousClock.now
            let turn = try await transport.runTurn(messages: [
                ["role": "system", "content": "You are a helpful assistant."],
                ["role": "user", "content": "Name one colour."],
            ], includeTools: false) { _ in }
            let elapsed = start.duration(to: .now)
            let after = LocalMemory.availableMB()

            print("[ctx] \(context): memory \(before) -> \(after) MB (cost \(before - after) MB) "
                  + "· load+gen \(String(format: "%.1f", Double(elapsed.components.seconds)))s "
                  + "· reply \(turn.content.prefix(30))")
        }
        await LiteRTTransport.evictEngines()
    }
}

// MARK: - Speed tuning

extension LiteRTLiveTests {

    /// What actually costs the seconds, per knob.
    ///
    /// Gemma 4 E2B measured **39-43 tok/s decode with ttft ~0.14 s** early in
    /// this work. Later, in the app, it was showing **25-32 tok/s with ttft
    /// 5-14 s** — a regression, and every candidate cause is a setting teemoon
    /// chose since:
    ///
    ///   - `contextTokens` 4096 -> 8192 (a bigger KV cache to fit a grounded
    ///     follow-up)
    ///   - `enableConversationConstrainedDecoding = true` (constrains sampling
    ///     to the tool schema)
    ///   - `enableBenchmark = true` (instrumentation)
    ///
    /// Google reports 56 tok/s for this model on an iPhone 17 Pro, so there is
    /// known headroom on top. This is not a pass/fail test; it prints a table.
    @Test(.enabled(if: Self.diagnosticsEnabled, "set LITERT_DIAGNOSTICS=1 (loads the model repeatedly)"),
          .timeLimit(.minutes(45)))
    @MainActor
    func measuresWhatEachSpeedKnobCosts() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.modelPath.path))

        // A prompt long enough to measure decode rather than overhead.
        let prompt = "Explain how a bicycle derailleur shifts gears, in about eight sentences."

        func run(_ label: String, context: Int, constrained: Bool, benchmark: Bool) async {
            await LiteRTTransport.evictEngines()
            try? await Task.sleep(for: .milliseconds(400))
            LiteRTLM.ExperimentalFlags.optIntoExperimentalAPIs()
            LiteRTLM.ExperimentalFlags.enableConversationConstrainedDecoding = constrained
            LiteRTLM.ExperimentalFlags.enableBenchmark = benchmark

            let transport = LiteRTTransport(
                modelPath: Self.modelPath, estimatedSizeMB: Self.sizeMB, contextTokens: context
            )
            // Warm the engine first so load time is not counted as latency.
            _ = try? await transport.runTurn(messages: [
                ["role": "user", "content": "Hi"],
            ], includeTools: false) { _ in }

            var firstTokenAt: Duration?
            let start = ContinuousClock.now
            let turn = try? await transport.runTurn(messages: [
                ["role": "system", "content": "You are a helpful assistant."],
                ["role": "user", "content": prompt],
            ], includeTools: false) { _ in
                if firstTokenAt == nil { firstTokenAt = start.duration(to: .now) }
            }
            let total = start.duration(to: .now)
            let secs = Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
            let ttft = firstTokenAt.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } ?? 0
            let tokens = turn?.completionTokens ?? 0
            let decodeSecs = max(0.001, secs - ttft)
            print(String(format: "[tune] %@ ctx=%-5d constrained=%@ bench=%@ -> %.1fs total, ttft %.2fs, %d tok, %.1f tok/s",
                         label, context, constrained ? "Y" : "N", benchmark ? "Y" : "N",
                         secs, ttft, tokens, Double(tokens) / decodeSecs))
        }

        await run("baseline-as-shipped", context: 8192, constrained: true,  benchmark: true)
        await run("no-constrained     ", context: 8192, constrained: false, benchmark: true)
        await run("no-benchmark       ", context: 8192, constrained: true,  benchmark: false)
        await run("ctx-4096           ", context: 4096, constrained: true,  benchmark: true)
        await run("ctx-16384          ", context: 16384, constrained: true, benchmark: true)
        await run("lean (none of them)", context: 4096, constrained: false, benchmark: false)

        // Restore what ships.
        LiteRTLM.ExperimentalFlags.enableConversationConstrainedDecoding = true
        LiteRTLM.ExperimentalFlags.enableBenchmark = true
        await LiteRTTransport.evictEngines()
    }
}

// MARK: - Where the seconds go

extension LiteRTLiveTests {

    /// Decomposes a REAL grounded turn, because the knobs are not where the
    /// time is.
    ///
    /// A/B'ing contextTokens, constrained decoding and the benchmark flag moved
    /// nothing: 28-30 tok/s and ttft ~0.9 s in every arm. Yet the app reports
    /// ttft of 5-14 s on grounded questions. The difference is not the engine —
    /// it is everything a grounded answer does around it:
    ///
    ///   1. the DECISION generation (short, but a full generation)
    ///   2. the live Brave request (network)
    ///   3. re-prefill of persona + history + ~2k tokens of sources
    ///   4. the ANSWER generation
    ///
    /// Prints each phase so the next optimisation targets the largest one
    /// rather than the most obvious one.
    @Test(.enabled(if: Self.diagnosticsEnabled, "set LITERT_DIAGNOSTICS=1"),
          .timeLimit(.minutes(30)))
    @MainActor
    func decomposesAGroundedTurn() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = try #require(env["BRAVE_API_KEY"] ?? env["TEST_RUNNER_BRAVE_API_KEY"])

        let ref = LocalModelRef(
            id: Self.repoID, directory: Self.modelPath.deletingLastPathComponent(),
            sizeMB: Self.sizeMB, bundleFile: Self.modelPath
        )
        let persona = ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt)

        // Warm the engine so model load is not attributed to the answer.
        let warm = LiteRTTransport(modelPath: Self.modelPath, estimatedSizeMB: Self.sizeMB)
        _ = try? await warm.runTurn(messages: [["role": "user", "content": "Hi"]],
                                    includeTools: false) { _ in }

        // 1+2+3+4 together, through the app's stack.
        let searchStart = LockedBox<ContinuousClock.Instant?>(nil)
        let searchEnd = LockedBox<ContinuousClock.Instant?>(nil)
        let payloadChars = LockedBox<Int>(0)
        let tool = TimedSearchTool(apiKey: key, started: searchStart, ended: searchEnd, chars: payloadChars)

        var firstToken: ContinuousClock.Instant?
        let lm = LocalLanguageModel(
            model: ref,
            priorMessages: [WireMessage(role: "system", content: persona)],
            events: StreamCallbacks(onSourcesFound: { _ in }, onQueriesFound: { _ in },
                                    onToolExecutionEnded: {}, onSuccess: { _ in })
        )
        let session = LanguageModelSession(model: lm, tools: [tool])
        let t0 = ContinuousClock.now
        var reply = ""
        for try await snapshot in session.streamResponse(to: "What's the weather in New York NY today?") {
            if firstToken == nil, !snapshot.content.isEmpty { firstToken = ContinuousClock.now }
            reply = snapshot.content
        }
        let total = t0.duration(to: .now)

        func secs(_ d: Duration) -> Double {
            Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let searchSecs = (searchStart.value.flatMap { s in searchEnd.value.map { secs(s.duration(to: $0)) } }) ?? 0
        let toDecision = searchStart.value.map { secs(t0.duration(to: $0)) } ?? 0
        let afterSearch = searchEnd.value.map { secs($0.duration(to: .now)) } ?? 0

        print(String(format: """
            [phases] total %.1fs
            [phases]   1. decision generation : %.1fs
            [phases]   2. brave search        : %.1fs  (%d chars of sources)
            [phases]   3+4. prefill + answer  : %.1fs  (%d chars out)
            """, secs(total), toDecision, searchSecs, payloadChars.value, afterSearch, reply.count))
    }
}

/// Wraps the real search and records when it started and finished.
private struct TimedSearchTool: LMTool {
    let name = "web_search"
    let description = "Search the web for current, real-time information."
    let apiKey: String
    let started: LockedBox<ContinuousClock.Instant?>
    let ended: LockedBox<ContinuousClock.Instant?>
    let chars: LockedBox<Int>

    @Generable struct Arguments: Sendable {
        @Guide(description: "The search query.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        started.value = ContinuousClock.now
        let out = try await BraveWebSearchTool(apiKey: apiKey, onDevice: true)
            .call(arguments: .init(query: arguments.query, freshness: nil,
                                   contextThresholdMode: nil, count: nil))
        ended.value = ContinuousClock.now
        chars.value = out.count
        return out
    }
}

// MARK: - Brevity: does a shorter answer cost accuracy?

extension LiteRTLiveTests {

    /// Decode is 72% of a grounded turn and it is serial, so the biggest lever
    /// is simply generating fewer tokens. The question is what that costs.
    ///
    /// Measures BOTH sides rather than just the speed win: the planted sources
    /// carry five specific facts, and the metric is how many survive into the
    /// answer. A brevity nudge that drops the numbers is not a win, it is a
    /// worse answer delivered sooner.
    ///
    /// The fixture returns real-shaped source XML with facts that cannot come
    /// from the weights, so "did it keep the facts" is answerable.
    @Test(.enabled(if: Self.diagnosticsEnabled, "set LITERT_DIAGNOSTICS=1"),
          .timeLimit(.minutes(30)))
    @MainActor
    func measuresWhatBrevityCostsInFactRetention() async throws {
        let ref = LocalModelRef(
            id: Self.repoID, directory: Self.modelPath.deletingLastPathComponent(),
            sizeMB: Self.sizeMB, bundleFile: Self.modelPath
        )
        let persona = ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt)
        let facts = ["84", "64", "thunderstorm", "5 mph", "Tuesday"]

        func trial(_ label: String, systemPrompt: String) async {
            let t0 = ContinuousClock.now
            let lm = LocalLanguageModel(
                model: ref,
                priorMessages: [WireMessage(role: "system", content: systemPrompt)],
                events: StreamCallbacks(onSourcesFound: { _ in }, onQueriesFound: { _ in },
                                        onToolExecutionEnded: {}, onSuccess: { _ in })
            )
            let session = LanguageModelSession(model: lm, tools: [PlantedWeatherTool()])
            var reply = ""
            do {
                for try await s in session.streamResponse(to: "What's the weather in New York NY today?") {
                    reply = s.content
                }
            } catch { reply = "<threw: \(error)>" }
            let d = t0.duration(to: .now)
            let secs = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            let kept = facts.filter { reply.localizedCaseInsensitiveContains($0) }
            print(String(format: "[brevity] %@ -> %.1fs, %d chars, facts %d/%d (%@)",
                         label, secs, reply.count, kept.count, facts.count, kept.joined(separator: ",")))
        }

        for run in 1...2 {
            await trial("run\(run) plain  ", systemPrompt: persona)
            await trial("run\(run) brief  ", systemPrompt: persona + "\n\n" + Self.brevityNudge)
        }
    }

    /// Deliberately about SHAPE, not omission: "lead with the answer" and "no
    /// preamble" cut tokens that carry no information, where "be brief" invites
    /// dropping the facts themselves.
    static let brevityNudge = """
        You are answering on a phone, where every word costs the user time. \
        Lead with the direct answer in the first sentence. Keep the whole reply \
        under four sentences. Do not restate the question, do not explain what \
        you are about to do, and do not add closing advice about checking other \
        sources. Keep every specific number, name and date from your sources — \
        brevity means fewer words, never fewer facts.
        """
}

/// Real-shaped source XML carrying facts that cannot come from the weights.
private struct PlantedWeatherTool: LMTool {
    let name = "web_search"
    let description = "Search the web for current, real-time information."

    @Generable struct Arguments: Sendable {
        @Guide(description: "The search query.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        """
        <source index="1"><url>https://weather.gov/okx/new-york</url>
        <title>New York NY Forecast</title>
        <content>Today: sunny, high near 84. Tonight: low around 64. \
        A chance of thunderstorms after 3pm Tuesday. Winds 5 mph becoming calm.</content>
        </source>
        """
    }
}

// MARK: - The one-source regression

extension LiteRTLiveTests {

    /// The exact query that came back with ONE source must now return several.
    ///
    /// Cause was Brave's `maximum_number_of_tokens`, which bounds the WHOLE
    /// payload and is filled highest-ranked-page-first: for "Iran war news" the
    /// top result was a single 17,716-character page that consumed the entire
    /// 4096-token budget teemoon was asking for. Non-monotonic — 2048 returned
    /// five entries and 8192 returned five, but 4096 returned one.
    ///
    /// Runs the REAL tool exactly as the app configures it (`onDevice: true`),
    /// so it fails if the on-device budget ever drifts back up.
    @Test(.enabled(if: Self.enabled, "set LITERT_LIVE=1 + BRAVE_API_KEY"),
          .timeLimit(.minutes(10)))
    @MainActor
    func theQueryThatReturnedOneSourceNowReturnsSeveral() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = try #require(env["BRAVE_API_KEY"] ?? env["TEST_RUNNER_BRAVE_API_KEY"])

        let tool = BraveWebSearchTool(apiKey: key, onDevice: true)
        let result = try await tool.call(arguments: .init(
            query: "Iran war news", freshness: nil, contextThresholdMode: nil, count: nil))
        let sources = BraveWebSearchTool.parseSources(from: result)

        print("[one-source] \(sources.count) sources, \(result.count) chars — "
              + sources.map(\.domain).joined(separator: ", "))
        #expect(sources.count > 1,
                "still one source: the on-device token budget has drifted back to a value Brave fills with a single long page")
    }
}

// MARK: - What a cold start costs

extension LiteRTLiveTests {

    /// How long a COLD on-device start takes, isolated from generation.
    ///
    /// This exists to answer a product question, not a perf one: the where sheet
    /// prints `warm`/`cold` on home models, and whether a PHONE model deserves
    /// the same word depends entirely on what cold actually costs. `EngineCache`
    /// says engines are "expensive to build (gigabytes, seconds)" and the runtime
    /// logs `engine ready in …`, but nothing measured it — and a warning worth
    /// showing at 8 s is noise at 0.5 s.
    ///
    /// Nothing here isolated it before. `measuresWhatContextSizeCostsInMemory`
    /// prints "load+gen" — one number covering both — and every other timing test
    /// deliberately warms the engine FIRST so that load time is excluded. That is
    /// right for measuring throughput and useless for measuring the load.
    ///
    /// Method: time-to-first-token on the same trivial prompt, cold then warm.
    /// Warm ttft is the engine already resident; cold ttft is that plus the build,
    /// so the DELTA is the build and the prompt cancels out. Two rounds, because a
    /// single cold read could be the filesystem cache rather than the engine.
    @Test(.enabled(if: Self.diagnosticsEnabled, "set LITERT_DIAGNOSTICS=1 (loads a 2.5 GB model twice)"),
          .timeLimit(.minutes(20)))
    @MainActor
    func measuresWhatAColdStartCosts() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.modelPath.path),
                     "no model on this device — download Gemma 4 E2B in the app first")

        // As shipped: the context the app actually uses, since the KV cache is
        // allocated during the build and is therefore part of what cold costs.
        let transport = LiteRTTransport(
            modelPath: Self.modelPath, estimatedSizeMB: Self.sizeMB, contextTokens: 8192
        )

        func seconds(_ d: Duration) -> Double {
            Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }

        /// Returns (ttft, total) for one generation.
        func run() async throws -> (Double, Double) {
            var firstTokenAt: Duration?
            let start = ContinuousClock.now
            _ = try await transport.runTurn(messages: [
                ["role": "system", "content": "You are a helpful assistant."],
                ["role": "user", "content": "Name one colour."],
            ], includeTools: false) { _ in
                if firstTokenAt == nil { firstTokenAt = start.duration(to: .now) }
            }
            return (seconds(firstTokenAt ?? .zero), seconds(start.duration(to: .now)))
        }

        for round in 1...2 {
            await LiteRTTransport.evictEngines()
            // Let the eviction actually land before measuring against it.
            try await Task.sleep(for: .milliseconds(500))
            let availableBefore = LocalMemory.availableMB()

            let (coldTTFT, coldTotal) = try await run()
            let (warmTTFT, warmTotal) = try await run()

            print(String(
                format: "[cold-start] round %d: cold ttft %.2fs (total %.2fs) · "
                      + "warm ttft %.2fs (total %.2fs) · ENGINE BUILD ≈ %.2fs · %d MB free before",
                round, coldTTFT, coldTotal, warmTTFT, warmTotal,
                coldTTFT - warmTTFT, availableBefore))
        }

        await LiteRTTransport.evictEngines()
    }
}
