//
//  LiteRTTransport.swift
//  teemoon
//
//  On-device inference via Google's LiteRT-LM — the runtime behind AI Edge
//  Gallery, and the on-device `GenerationTransport`.
//
//  It exists for two measured reasons:
//    1. It runs **Gemma 4**, which mlx-swift-lm cannot load at all
//       (`unsupportedModelType("gemma4")`).
//    2. Google reports 56 tok/s decode for Gemma 4 E2B on iOS Metal. MLX gets
//       ~70 tok/s from *Qwen3-0.6B* — comparable throughput from a far smaller
//       model, on the same GPU backend.
//
//  First-class on-device transport. Tool calling is wired through
//  `LiteRTToolBridge` into the shared `GenerationEngine` loop.
//
//  Related: LiteRTToolBridge.swift, Packages/LiteRTLM.
//

import Foundation
import ModelBackend
import os

#if canImport(UIKit)
import UIKit
#endif

// The third `Tool` in this project — AnyLanguageModel's protocol, MLXLMCommon's
// struct, and now LiteRTLM's. Imported here only, never re-exported, so a bare
// `Tool` elsewhere stays unambiguous.
import LiteRTLM

private let logger = Logger(subsystem: "ai.teemoon", category: "inference.litert")

/// Generates one turn on-device with LiteRT-LM.
struct LiteRTTransport: GenerationTransport {
    /// Path to the `.litertlm` bundle. LiteRT uses a single packaged file, not
    /// the directory of safetensors + config MLX expects — which is why the
    /// catalog and downloader need a format dimension before this can ship.
    let modelPath: URL
    let estimatedSizeMB: Int

    /// KV-cache size: the ceiling on **input + output tokens together**.
    ///
    /// NOT the same thing as MLX's `maxTokens`, which caps only generation.
    /// Conflating them is a silent trap that only fires on long prompts:
    /// passing a generation budget of 1024 here caps the whole conversation at
    /// 1024 tokens, and a grounded query dies with
    ///
    ///     INVALID_ARGUMENT: Input token ids are too long.
    ///     Exceeding the maximum number of tokens allowed: 1123 >= 256
    ///
    /// Sized for a grounded prompt IN A CONVERSATION, which 4096 was not.
    ///
    /// The old figure assumed 5 sources ran ~1.2k tokens. Measured, they run
    /// ~16,900 characters — about 4.2k tokens, i.e. the entire budget on their
    /// own. A first grounded question therefore worked (no history yet) and the
    /// first FOLLOW-UP died in the native layer:
    ///
    ///     INVALID_ARGUMENT: Input token ids are too long: 4484 >= 4096
    ///
    /// which surfaces as a one-token non-answer. The budget has to hold persona
    /// + history + the grounding payload + the answer at once:
    ///
    ///     persona            ~200
    ///     history            ~500-1500
    ///     5 sources         ~4200
    ///     answer             ~500
    ///                       ------
    ///                       ~6400, so 8192 with headroom
    ///
    /// It still costs memory — this IS the KV cache — which is why it is not
    /// simply set to the model's 32k maximum, and why `trimmedHistory` below
    /// bounds the part that grows without limit.
    let contextTokens: Int
    /// teemoon's tools, bridged to LiteRT's protocol at conversation setup.
    let tools: [any AnyLanguageModel.Tool]
    /// Needed because this transport reports tool rounds itself: LiteRT runs the
    /// loop internally, so the engine never sees the calls and cannot fire the
    /// grounding callbacks on its behalf.
    let events: StreamCallbacks?

    /// Ceiling on one answer. A decoder looping on a single token otherwise
    /// runs to the KV cache — minutes of GPU for a reply nobody can read.
    let maxAnswerTokens: Int

    /// Test seam for the background-abandon path. Production is nil — the turn
    /// polls `UIApplication.applicationState`. A test can force the path (there
    /// is no real app state to background) by returning true from here.
    let backgroundedForTest: (@Sendable () -> Bool)?

    /// A delay that still delays when the current task is cancelled.
    static func uncancellableSleep(milliseconds: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }

    init(modelPath: URL, estimatedSizeMB: Int, contextTokens: Int = 8192,
         tools: [any AnyLanguageModel.Tool] = [], events: StreamCallbacks? = nil,
         maxAnswerTokens: Int = LiteRTTransport.answerReserveTokens,
         backgroundedForTest: (@Sendable () -> Bool)? = nil) {
        self.modelPath = modelPath
        self.estimatedSizeMB = estimatedSizeMB
        self.contextTokens = contextTokens
        self.tools = tools
        self.events = events
        self.maxAnswerTokens = maxAnswerTokens
        self.backgroundedForTest = backgroundedForTest
    }

    // MARK: - Engine cache

    /// Engines are expensive to build (gigabytes, seconds) and LiteRT's `Engine`
    /// is an actor, so one per model path is both correct and necessary.
    fileprivate actor EngineCache {
        static let shared = EngineCache()
        /// Keyed by path AND context size.
        ///
        /// Path alone was wrong: `contextTokens` sizes the KV cache at engine
        /// construction, so asking for a different context silently returned the
        /// engine built for the old one — the request would be honoured in name
        /// and ignored in fact.
        struct Key: Hashable { let path: URL; let contextTokens: Int }
        private var engines: [Key: LiteRTLM.Engine] = [:]
        /// Builds in flight. A warm-up and a turn asking for the same engine
        /// share one build; the actor suspends at `initialize()`, so without
        /// this the second caller found no engine and built another.
        private var building: [Key: Task<LiteRTLM.Engine, Error>] = [:]

        func evictAll() async {
            guard !engines.isEmpty else { return }
            logger.info("[litert] releasing \(self.engines.count, privacy: .public) engine(s)")
            engines.removeAll()
            await publish()
        }

        /// Test seam: how many engines are resident.
        var residentCount: Int { engines.count }

        /// Forgets an engine whose decode thread is DEAD (a drain that timed
        /// out). The next turn builds a fresh one; the caller releases the dead
        /// one off any thread a user is waiting on.
        func discard(_ path: URL, contextTokens: Int) async {
            engines[Key(path: path, contextTokens: contextTokens)] = nil
            await publish()
        }

        /// Pushes this cache's state to the observable the picker reads.
        ///
        /// `await MainActor.run`, not `Task { @MainActor in }`: unstructured
        /// tasks carry no ordering guarantee between them, so an eviction and
        /// the build that follows it could land in either order and leave the
        /// mirror claiming a model is resident when it isn't. Awaiting keeps the
        /// two in the order the cache performed them.
        private func publish() async {
            let paths = Set(engines.keys.map(\.path))
            await MainActor.run {
                LocalEngineResidency.shared.update(resident: paths)
            }
        }

        func engine(for path: URL, contextTokens: Int, sizeMB: Int) async throws -> LiteRTLM.Engine {
            let key = Key(path: path, contextTokens: contextTokens)
            if let existing = engines[key] { return existing }
            if let inFlight = building[key] { return try await inFlight.value }
            let task = Task { try await self.build(key: key, path: path, sizeMB: sizeMB) }
            building[key] = task
            defer { building[key] = nil }
            return try await task.value
        }

        private func build(key: Key, path: URL, sizeMB: Int) async throws -> LiteRTLM.Engine {
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw LocalInferenceError.modelNotDownloaded(path.lastPathComponent)
            }

            // ONE ENGINE RESIDENT AT A TIME, evicted BEFORE the memory gate
            // runs — otherwise the gate measures memory an engine nobody is
            // using still holds. Measured on the runtime this replaced: an
            // unbounded cache left a 2.9 GB model 55 MB short of loading.
            // `LocalGenerationGate` serializes generation, so a second engine is
            // by definition idle.
            for (other, _) in engines where other != key {
                logger.info("[litert] evicting \(other.path.lastPathComponent, privacy: .public) to make room")
                engines[other] = nil
            }
            // Published BEFORE the gate, which can throw: at this point the old
            // engine is gone and the new one doesn't exist, so nothing is warm
            // and a failed load must not leave the picker saying otherwise.
            await publish()
            try LocalMemory.check(needMB: sizeMB + LocalMemory.headroomMB)

            let config = try LiteRTLM.EngineConfig(
                modelPath: path.path,
                // Metal. The whole reason to evaluate this runtime is its GPU
                // path; measuring the CPU one would answer a different question.
                backend: .gpu,
                maxNumTokens: key.contextTokens,
                cacheDir: FileManager.default.temporaryDirectory.path
            )
            LiteRTTransport.enableExperimentalFeatures()
            // Read at engine creation, like every experimental flag. Gated on
            // the file: a bundle without a drafter has nothing to speculate with.
            let fileSupports = LiteRTLM.Capabilities(modelPath: path.path)?.hasSpeculativeDecodingSupport() ?? false
            let speculative = LiteRTSpeculativeDecoding.setting(
                disabled: LiteRTSpeculativeDecoding.disabledByEnvironment, fileSupports: fileSupports)
            LiteRTLM.ExperimentalFlags.enableSpeculativeDecoding = speculative
            logger.info("[litert] speculative decoding disabled=\(LiteRTSpeculativeDecoding.disabledByEnvironment, privacy: .public) fileSupports=\(fileSupports, privacy: .public) enabled=\(speculative.map(String.init) ?? "default", privacy: .public)")
            DiagLog.note("[litert] speculative disabled=\(LiteRTSpeculativeDecoding.disabledByEnvironment) fileSupports=\(fileSupports) enabled=\(speculative.map(String.init) ?? "default")")

            let engine = LiteRTLM.Engine(engineConfig: config)
            let start = ContinuousClock.now
            try await engine.initialize()
            let took = start.duration(to: .now)
            logger.info("[litert] engine ready in \(took.description, privacy: .public)")
            DiagLog.note("[litert] engine ready in \(took.description)")
            engines[key] = engine
            // The cost, not just the fact — this is what the developer-mode card
            // shows, and the log line was the only place it existed.
            await MainActor.run { LocalEngineResidency.shared.recordLoad(of: path, took: took) }
            await publish()
            return engine
        }
    }

    /// Releases every cached LiteRT engine.
    ///
    /// Called on memory pressure and when the app is backgrounded — a resident
    /// multi-gigabyte engine is the largest thing teemoon holds by orders of
    /// magnitude, and the first thing worth giving back. See
    /// `LocalMemoryPressure`.
    /// Builds the engine for an on-device provider ahead of its first turn —
    /// on selection and at launch, per LiteRT-LM's guidance to create the
    /// engine once, early and off the main thread. A turn that arrives while
    /// this runs shares the build (`EngineCache.building`). Skipped when a
    /// generation is in flight: that turn is loading it anyway. The memory
    /// gate inside `engine(for:)` still decides; a refusal is quiet.
    static func warmUp(for provider: Provider?) {
        guard let ref = LocalWarmUpPolicy.target(for: provider) else { return }
        Task.detached(priority: .utility) {
            guard await !LocalGenerationGate.shared.isBusy else { return }
            DiagLog.note("[litert] warm-up: \(ref.displayName)")
            _ = try? await EngineCache.shared.engine(
                for: ref.bundleFile, contextTokens: 8192, sizeMB: ref.sizeMB)
        }
    }

    static func evictEngines() async {
        await EngineCache.shared.evictAll()
    }

    /// Turns on the LiteRT behaviour teemoon depends on. Idempotent; every flag
    /// here is inert until `optIntoExperimentalAPIs()` has been called, and each
    /// is read only when a *new* `Conversation` is created.
    ///
    /// `enableConversationToolCallStreaming` is not an optimisation — it is what
    /// makes tool calling work at all on this path. Both it and
    /// `ConversationConfig.enableToolCallStreaming` default to false, and the
    /// native flag is the AND of the two, so a conversation built from the
    /// defaults is told *not* to stream tool calls. `sendMessageStream` then
    /// never sees a `tool_calls` chunk, `pendingToolCalls` stays empty, and the
    /// tool silently never runs — while the model's reply looks like an ordinary
    /// decision not to search. That is exactly how the first live run read
    /// `toolRan=false` and sent me looking at prompt wording.
    ///
    /// The non-streaming `sendMessage` has no such flag, which is why this is
    /// invisible until you use the streaming API.
    static func enableExperimentalFeatures() {
        LiteRTLM.ExperimentalFlags.optIntoExperimentalAPIs()
        // Without this `getBenchmarkInfo()` yields nothing — which is how the
        // first run produced only a wall clock. The prefill/decode split is the
        // whole point of comparing runtimes, so it is opted into rather than
        // estimated from character counts.
        LiteRTLM.ExperimentalFlags.enableBenchmark = true
        LiteRTLM.ExperimentalFlags.enableConversationToolCallStreaming = true
        // Constrained decoding is NOT set here: it is per conversation, see
        // `setConstrainedDecoding(toolsAttached:)`.
    }

    /// Constrained decoding, per conversation — OFF on this runtime.
    ///
    /// On LiteRT-LM v0.17 it neutralises the drafter, and every on-device
    /// turn carries the search tool, so "only when tools are attached" would
    /// be every turn. Tool calls still parse with it off. Re-measure before
    /// turning it back on. The flag is global but read at
    /// `createConversation`, which is why it is set right before each one.
    ///
    /// DEBUG bench override: `TEEMOON_BENCH_FLAGS` = `none` / `streaming` /
    /// `constrained` forces the pair, to re-measure what each costs.
    static func setConstrainedDecoding(toolsAttached: Bool) {
        var constrained = false
        #if DEBUG
        if let arm = ProcessInfo.processInfo.environment["TEEMOON_BENCH_FLAGS"] {
            constrained = arm == "constrained"
            LiteRTLM.ExperimentalFlags.enableConversationToolCallStreaming = arm == "streaming"
            DiagLog.note("[litert] bench flags: streaming=\(arm == "streaming") constrained=\(constrained)")
        }
        #endif
        LiteRTLM.ExperimentalFlags.enableConversationConstrainedDecoding = constrained
        DiagLog.note("[litert] conversation: toolsAttached=\(toolsAttached) constrained=\(constrained)")
    }

    /// Room left for the model's own answer, and for the grounding payload a
    /// tool round will inject on top of everything else.
    ///
    /// Generous because the thing it protects against is not a slow reply but a
    /// hard `INVALID_ARGUMENT` from the native layer, which the user sees as a
    /// one-token non-answer.
    static let answerReserveTokens = 4800

    /// Rough token count. Deliberately PESSIMISTIC: Gemma 4 averages ~6.3
    /// characters per token, so dividing by 4 over-estimates, and
    /// over-estimating is what keeps the prompt under a hard ceiling.
    static func estimatedTokens(_ text: String) -> Int { max(1, text.count / 4) }

    /// Keeps the most RECENT turns that fit the budget.
    ///
    /// Oldest-first eviction: the turns nearest the question are the ones a
    /// follow-up depends on ("what about the rest of the week" is meaningless
    /// without the message before it). Without this a conversation grows until
    /// it exceeds the KV cache and every further message fails.
    static func trimmedHistory(
        _ messages: [[String: Any]], budgetTokens: Int
    ) -> [[String: Any]] {
        guard budgetTokens > 0 else { return [] }
        var kept: [[String: Any]] = []
        var used = 0
        for message in messages.reversed() {
            let cost = estimatedTokens((message["content"] as? String) ?? "")
            guard used + cost <= budgetTokens else { break }
            used += cost
            kept.insert(message, at: 0)
        }
        if kept.count < messages.count {
            logger.info("[litert] trimmed history to \(kept.count, privacy: .public)/\(messages.count, privacy: .public) turns to fit the context")
        }
        return kept
    }

    /// The messages actually sent, as readable JSON — what the developer panel
    /// shows in place of an HTTP request body.
    static func prettyMessages(_ messages: [[String: Any]]) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: messages, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// OpenAI wire roles → LiteRT's.
    ///
    /// LiteRT follows Gemini's vocabulary: the assistant is **`.model`**, not
    /// `.assistant`. Getting this wrong does not fail loudly — the turn is just
    /// attributed to the wrong speaker and the model's own replies read back as
    /// the user's, which quietly poisons multi-turn context.
    static func role(for wireRole: String?) -> LiteRTLM.Role {
        switch wireRole {
        case "assistant": return .model
        case "system":    return .system
        case "tool":      return .tool
        default:          return .user
        }
    }

    /// What LiteRT will actually put in front of the model before the first
    /// turn — system instruction, tool schemas and all.
    ///
    /// Diagnostic, not part of generation. It exists because "the model did not
    /// call the tool" has two very different causes that produce identical
    /// replies: the model saw the schema and declined, or it never saw one. Only
    /// this distinguishes them, and the second is a bug no prompt would fix.
    func renderedPreface(tools overrideTools: [any AnyLanguageModel.Tool]? = nil) async throws -> String {
        let engine = try await EngineCache.shared.engine(
            for: modelPath, contextTokens: contextTokens, sizeMB: estimatedSizeMB
        )
        let shims = await LiteRTToolBridge.bridged(tools: overrideTools ?? tools) { _, _, _ in }
        Self.setConstrainedDecoding(toolsAttached: !shims.isEmpty)
        let conversation = try await engine.createConversation(
            with: LiteRTLM.ConversationConfig(tools: shims, enableToolCallStreaming: true)
        )
        return try conversation.renderPrefaceIntoString()
    }

    // MARK: - GenerationTransport

    func runTurn(
        messages: [[String: Any]],
        includeTools: Bool,
        onPartialContent: @escaping @Sendable (String) -> Void
    ) async throws -> TurnOutput {
        // Same process-wide gate as MLX: one on-device generation at a time.
        try await LocalGenerationGate.shared.acquire()
        defer { Task { await LocalGenerationGate.shared.release() } }

        // iOS revokes GPU access from a backgrounded app: Metal aborts the
        // in-flight command buffer ("Insufficient Permission to submit GPU work
        // from background") and LiteRT's decode thread never returns from it.
        // The stream then never yields and never finishes, so awaiting it — and
        // the gate above — would hang forever; that was the "thinking counts up
        // forever, and every later message hangs too" report (2026-09-04, device
        // log). POLL applicationState rather than trusting a notification: the
        // observer raced the cold engine load and was attached only AFTER the
        // background transition had already fired. A poll started here catches a
        // background at any point in the turn, including during the load.
        let backgrounded = LockedBox<Bool>(false)
        let bgForTest = backgroundedForTest
        let bgPoll = Task { @MainActor in
            while !Task.isCancelled {
                if let bgForTest {
                    if bgForTest() {
                        backgrounded.value = true
                        DiagLog.note("[litert] backgroundedForTest — abandoning the turn")
                        return
                    }
                } else {
                    #if canImport(UIKit) && !os(watchOS)
                    if UIApplication.shared.applicationState == .background {
                        backgrounded.value = true
                        DiagLog.note("[litert] applicationState == .background — abandoning the turn")
                        return
                    }
                    #endif
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { bgPoll.cancel() }

        DiagLog.note("[litert] turn: acquiring engine")
        let engine = try await EngineCache.shared.engine(
            for: modelPath, contextTokens: contextTokens, sizeMB: estimatedSizeMB
        )
        DiagLog.note("[litert] turn: engine ready, building conversation")
        // Tool wiring. LiteRT owns the tool loop for this transport — see
        // LiteRTToolBridge for why that exception exists and what teemoon keeps
        // in spite of it. Executed calls are captured here so the turn can still
        // report them, which is what feeds the grounding sources rail.
        // SEED the transcript, do not REPLAY it.
        //
        // This used to loop over the prior messages calling
        // `conversation.sendMessage(...)`. That call does not insert a message —
        // it GENERATES a full model response to it, tool loop and all. So every
        // prior turn in a thread produced a complete generation before the
        // user's actual question was even asked, and the system prompt produced
        // one too. Cost grew with conversation length: a fresh thread answered
        // in ~15 s while a few turns of history ran for minutes with the UI
        // showing nothing, which is exactly how it was reported —
        // "still thinking, 60s and rising".
        //
        // `systemMessage` and `initialMessages` populate the history WITHOUT
        // generating, which is what was wanted all along.
        let systemMessage = messages
            .first { ($0["role"] as? String) == "system" }
            .flatMap { $0["content"] as? String }
            .flatMap { $0.isEmpty ? nil : LiteRTLM.Message($0, role: .system) }

        let priorMessages = messages
            .dropLast()                                   // the live turn is sent below
            .filter { ($0["role"] as? String) != "system" } // carried separately
        let history: [LiteRTLM.Message] = Self.trimmedHistory(
            priorMessages,
            budgetTokens: contextTokens
                - Self.estimatedTokens(systemMessage?.toString ?? "")
                - Self.estimatedTokens((messages.last?["content"] as? String) ?? "")
                - Self.answerReserveTokens
        ).compactMap { message in
            guard let text = message["content"] as? String, !text.isEmpty else { return nil }
            return LiteRTLM.Message(text, role: Self.role(for: message["role"] as? String))
        }

        let executed = LockedBox<[ToolCallRecord]>([])
        let conversation: LiteRTLM.Conversation
        if includeTools, !tools.isEmpty {
            let events = self.events
            let shims = await LiteRTToolBridge.bridged(
                tools: tools,
                onStarted: { _, arguments in
                    // Flip the chip to "searching" while the search is actually
                    // running, matching what `GenerationEngine` does for remote
                    // providers. Reporting only at the END of the turn — which
                    // is what this did — meant a grounded on-device query showed
                    // "thinking" for its entire duration, tool rounds included.
                    if let query = arguments["query"] as? String, !query.isEmpty {
                        events?.onQueriesFound([query])
                    }
                },
                onExecuted: { name, args, result in
                    executed.value = executed.value + [
                        ToolCallRecord(name: name, arguments: args, result: result)
                    ]
                    // Report per ROUND, not once at the end: the sources rail
                    // should populate as they arrive, and the chip has to be
                    // told the search finished.
                    let sources = BraveWebSearchTool.parseSources(from: result)
                    if !sources.isEmpty { events?.onSourcesFound(sources) }
                    events?.onToolExecutionEnded()
                }
            )
            Self.setConstrainedDecoding(toolsAttached: true)
            conversation = try await engine.createConversation(
                with: LiteRTLM.ConversationConfig(
                    systemMessage: systemMessage, initialMessages: history,
                    tools: shims, samplerConfig: LiteRTSpeculativeDecoding.benchSampler,
                    enableToolCallStreaming: true)
            )
        } else {
            Self.setConstrainedDecoding(toolsAttached: false)
            conversation = try await engine.createConversation(
                with: LiteRTLM.ConversationConfig(
                    systemMessage: systemMessage, initialMessages: history,
                    samplerConfig: LiteRTSpeculativeDecoding.benchSampler)
            )
        }

        let lastText = (messages.last?["content"] as? String) ?? ""
        // A task cancelled during the engine build must not START a native
        // generation it will abandon at once; that orphan wedges the next turn
        // exactly as a cancelled decode does.
        try Task.checkCancellation()
        // Tool-call markup must never stream to the user — same machine as the
        // SSE path (ToolMarkupElider, driven by ToolCallFormat.markerPairs, so
        // a new format reaches both transports by construction). Always
        // enabled, unlike SSE's hasTools gate: a small local model may emit
        // tool syntax whether or not tools were offered this turn, and the
        // check this replaces was likewise unconditional.
        let elider = ToolMarkupElider()
        // The stream is consumed on a task the caller's cancellation does NOT
        // reach, so it drains to LiteRT's final callback. A cancel goes to the
        // NATIVE decode instead, and this function does not return — or release
        // the gate — until that decode has stopped. Merely leaving the Swift loop
        // leaves LiteRT decoding on its one worker thread, and the next turn
        // queues behind it (LiteRTLiveTests.answersAfterATurnWasAbandonedMidDecode).
        let cap = maxAnswerTokens
        // LiteRT ends a cancelled stream with an ERROR
        // (`invalidResponse("CANCELLED: Task cancelled")`). One we asked for is a
        // normal end of stream, and the partial answer is the turn's output.
        let stoppedByUs = LockedBox<Bool>(false)
        let drained = LockedBox<Bool>(false)
        /// Set when the native decode did not stop within the bound: its thread
        /// is dead (typically GPU access revoked in the background), and so is
        /// the engine it runs on.
        let dead = LockedBox<Bool>(false)
        let live = LockedBox<LiteRTLM.Conversation?>(conversation)
        let watchdog = LockedBox<Task<Void, Never>?>(nil)
        let consumerBox = LockedBox<Task<String, any Error>?>(nil)
        // What the user has already been shown, so an ABANDONED turn (below) can
        // return the partial answer without awaiting the stuck consumer.
        let shown = LockedBox<String>("")
        // Set the moment the turn is abandoned. The leaked decode may resume when
        // the app returns to the foreground and the GPU is restored; without this
        // its late `onPartialContent` writes land in a LATER turn's message — the
        // "I sent hello and got the potato essay" report. After abandon, drop them.
        let abandoned = LockedBox<Bool>(false)
        // Flips when the consumer task finishes, so the wait below can poll for
        // completion WITHOUT structurally awaiting it (a task group awaits its
        // children, and a wedged decode never returns — which is what made the
        // abandon take the full 10 s watchdog before).
        let finished = LockedBox<Bool>(false)
        /// Every way a turn ends early goes through here: a user stop, the
        /// answer cap, the app leaving the foreground. Asks the NATIVE decode to
        /// stop and bounds the drain, so the composer never waits on a decode
        /// that cannot answer.
        @Sendable func requestStop(_ reason: String) {
            guard !stoppedByUs.value else { return }
            stoppedByUs.value = true
            logger.error("[litert] \(reason, privacy: .public) — asking the native decode to stop")
            DiagLog.note("[litert] \(reason) — asking the native decode to stop")
            try? live.value?.cancel()
            DiagLog.note("[litert] cancel_process returned")
            watchdog.value = Task {
                try? await Task.sleep(for: .seconds(10))
                if !drained.value {
                    dead.value = true
                    logger.error("[litert] drain TIMED OUT — the native decode did not stop within 10 s; its engine is dead")
                    DiagLog.note("[litert] drain TIMED OUT — engine is dead")
                    // Unblocks the caller with the partial answer.
                    consumerBox.value?.cancel()
                }
            }
        }
        let consumer = Task { () throws -> String in
            defer { finished.value = true }
            var answer = ""
            var capped = false
            do {
            for try await chunk in conversation.sendMessageStream(LiteRTLM.Message(lastText, role: .user)) {
                let piece = chunk.contents.compactMap { content -> String? in
                    if case .text(let t) = content { return t }
                    return nil
                }.joined()
                guard !piece.isEmpty else { continue }
                answer += piece
                // Cancelled natively and DRAINED like any other cancel — never
                // `break`, which would orphan the decode this guard exists to end.
                if !capped, Self.estimatedTokens(answer) > cap {
                    capped = true
                    requestStop("answer passed \(cap) tokens")
                }
                // Stream the ELIDED accumulation, not the raw one. This used to be
                //
                //   if !ToolCallFormat.containsAnyMarker(answer) { onPartialContent(answer) }
                //
                // which LATCHED: `answer` is cumulative, so the marker never left it
                // and the first one froze partial updates for the rest of the turn —
                // the reply then landed in one batch at the end. Same sticky-
                // suppression defect the SSE path had (commit b364fad,
                // StreamSuppressionTests), in cruder form. The engine yields per-
                // chunk deltas (`piece`) even though this loop accumulates them, so
                // the shared delta-fed machine ports directly: feed it the piece,
                // show its cumulative `visibleContent` (monotonic — a snapshot once
                // shown is never retracted). Thinking markup still streams raw, as
                // before: the live view renders its own thinking block, and the
                // elider touches only tool-call regions. `answer` stays RAW — the
                // TurnOutput below parses thinking out of it, and the engine's
                // sanitize pass owns the final text; elide only what is SHOWN.
                if !elider.append(piece).isEmpty {
                    // Drop writes from a decode that outlived its turn.
                    guard !abandoned.value else { continue }
                    onPartialContent(elider.visibleContent)
                    shown.value = elider.visibleContent
                }
            }
            // End of stream: a suffix held back as a possible marker prefix is now
            // known to be plain prose — show it. (An UNTERMINATED markup region
            // stays suppressed instead; the engine's end-of-turn sanitize decides
            // what of it survives into the final text.)
            } catch {
                guard stoppedByUs.value else { throw error }
            }
            if !elider.finish().isEmpty, !abandoned.value {
                onPartialContent(elider.visibleContent)
            }
            return answer
        }
        consumerBox.value = consumer
        DiagLog.note("[litert] turn: streaming started")
        // Wait for completion by POLLING, not by awaiting the consumer: once the
        // app is backgrounded the decode is wedged in a GPU buffer that never
        // completes, and awaiting it — structurally or otherwise — is the hang.
        // Three exits, in priority order: the app went to the background (abandon
        // at once), the watchdog gave up on a drain (abandon), the consumer
        // finished (a clean end, a stop that drained, or a real error). A user
        // stop must reach `finished` and drain, not abort the loop and orphan
        // the decode it just cancelled — so the wait survives cancellation.
        let outcome: Result<String, any Error> = await withTaskCancellationHandler {
            defer { drained.value = true }
            while true {
                if backgrounded.value || dead.value {
                    abandoned.value = true               // silence the leaked decode
                    dead.value = true                    // its engine is poisoned; rebuild next turn
                    requestStop(backgrounded.value
                                ? "app is in the background — GPU work is barred"
                                : "drain timed out")
                    // Keep a partial answer if there is one; otherwise this is an
                    // interruption, surfaced as a cancellation so the UI shows a
                    // stopped turn, NOT an "empty response" error.
                    return shown.value.isEmpty ? .failure(CancellationError()) : .success(shown.value)
                }
                if finished.value {
                    do { return .success(try await consumer.value) }
                    catch {
                        return stoppedByUs.value ? .success(shown.value) : .failure(error)
                    }
                }
                // `Task.sleep` throws at entry once the turn is cancelled, so
                // after a stop this loop would spin until the drain lands;
                // the wait has to survive cancellation.
                await Self.uncancellableSleep(milliseconds: 100)
            }
        } onCancel: {
            requestStop("cancel requested")
        }
        watchdog.value?.cancel()
        live.value = nil
        if dead.value {
            // Forget the poisoned engine BEFORE returning — the gate releases on
            // return, and the next turn must not find it in the cache. Release it
            // off the user's path: `engine_delete` joins the (wedged) worker.
            await EngineCache.shared.discard(modelPath, contextTokens: contextTokens)
            DiagLog.note("[litert] dead engine discarded from the cache")
            let doomed = engine
            Task.detached(priority: .background) {
                try? await Task.sleep(for: .seconds(2))
                DiagLog.note("[litert] releasing the dead engine (engine_delete may block)")
                _ = doomed
                DiagLog.note("[litert] dead engine released")
            }
        }
        let answer: String
        switch outcome {
        case .success(let text): answer = text
        case .failure(let error): throw error
        }
        if stoppedByUs.value {
            logger.error("[litert] stopped turn drained; native stopped=\(!dead.value, privacy: .public)")
            DiagLog.note("[litert] stopped turn drained; native stopped=\(!dead.value) chars=\(answer.count)")
        }

        // LiteRT reports the prefill/decode split directly.
        var decodeTokens: Int?
        if let info = try? conversation.getBenchmarkInfo() {
            decodeTokens = info.lastDecodeTokenCount
            logger.info("""
                [litert] ttft=\(info.timeToFirstTokenInSecond, privacy: .public)s \
                prefill=\(info.lastPrefillTokenCount, privacy: .public)tok \
                (\(Int(info.lastPrefillTokensPerSecond), privacy: .public)tok/s) · \
                decode=\(info.lastDecodeTokenCount, privacy: .public)tok \
                (\(Int(info.lastDecodeTokensPerSecond), privacy: .public)tok/s)
                """)
            // Into native.log too: the unified log is not readable off a device.
            DiagLog.note("[litert] bench ttft=\(info.timeToFirstTokenInSecond)s prefill=\(info.lastPrefillTokenCount)tok (\(Int(info.lastPrefillTokensPerSecond))tok/s) decode=\(info.lastDecodeTokenCount)tok (\(Int(info.lastDecodeTokensPerSecond))tok/s)")
        }

        // Surface what the tools did. The calls have already run inside
        // LiteRT's loop, so these are a RECORD, not a request for the engine to
        // execute them — hence `toolCalls` stays empty and the records travel on
        // the report instead. Getting that backwards would run every search
        // twice.
        // Sources and completion are reported per round in `onExecuted` above,
        // as they happen — not here, where they would arrive only once the
        // whole turn (including every tool round) had finished.
        let records = executed.value
        if !records.isEmpty {
            logger.info("[litert] executed \(records.count, privacy: .public) tool call(s)")
        }

        let (thinking, visible) = ThinkingContentParser.parse(answer)
        return TurnOutput(
            content: visible ?? "",
            reasoning: thinking ?? "",
            // Deliberately empty, not unfinished: the calls already ran inside
            // LiteRT's loop, so handing them back would make the engine run each
            // one a second time.
            toolCalls: [:],
            isTextBasedToolCall: false,
            completionTokens: decodeTokens,
            // The developer panel's equivalent of a request, for a turn that
            // never made one. `url` stays nil — there is no endpoint — but the
            // messages actually sent and the runtime settings ARE the request
            // here, and showing nothing made an on-device chat look like it had
            // done nothing.
            report: TurnReport(
                url: nil,
                requestHeaders: [
                    "runtime": "LiteRT-LM",
                    "model": modelPath.lastPathComponent,
                    "backend": "gpu (Metal)",
                    "context-tokens": String(contextTokens),
                    "tools-offered": includeTools ? String(tools.count) : "0",
                ],
                requestBodyJSON: Self.prettyMessages(messages),
                isE2EEActive: false,
                // Calls LiteRT ran inside its own loop. The engine never saw
                // them, so without this the panel lists no tools for a turn that
                // visibly searched.
                executedToolCalls: records,
                verify: nil)
        )
    }
}
