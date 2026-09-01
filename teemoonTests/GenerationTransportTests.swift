//
//  GenerationTransportTests.swift
//  teemoonTests
//
//  Covers the shared generation loop through a STUB transport.
//
//  This is what the transport split buys: before it, every one of these
//  behaviours could only be exercised against a live server (or an SSE byte
//  fixture standing in for one), because the loop and the HTTP client were the
//  same object. Now the loop can be driven directly, and the assertions are
//  about *meaning* — did the tool round chain, did the follow-up messages take
//  the right shape, did the reasoning fallback fire — rather than about bytes.
//
//  These behaviours are exactly what must NOT differ between remote inference
//  and on-device inference, which is why they are tested once, here, and not
//  per transport.
//

import Foundation
import Testing
import ModelBackend
@testable import teemoon

// MARK: - Stub transport

/// Replays a scripted list of turns, recording what the loop sent it.
private final class StubTransport: GenerationTransport, @unchecked Sendable {
    private let turns: [TurnOutput]
    private let lock = NSLock()
    private var index = 0

    /// Every `messages` array the loop handed over, in order — this is how the
    /// follow-up construction is inspected.
    private(set) var sentMessages: [[[String: Any]]] = []
    private(set) var sentIncludeTools: [Bool] = []

    init(turns: [TurnOutput]) { self.turns = turns }

    func runTurn(
        messages: [[String: Any]],
        includeTools: Bool,
        onPartialContent: @escaping @Sendable (String) -> Void
    ) async throws -> TurnOutput {
        lock.lock()
        sentMessages.append(messages)
        sentIncludeTools.append(includeTools)
        let turn = index < turns.count ? turns[index] : TurnOutput(content: "")
        index += 1
        lock.unlock()
        // Mimic a real transport streaming its text before returning.
        if !turn.content.isEmpty { onPartialContent(turn.content) }
        return turn
    }
}

private struct EchoTool: Tool {
    let name = "web_search"
    let description = "Search the web."

    @Generable struct Arguments: Sendable {
        @Guide(description: "The search query.")
        var query: String
        @Guide(description: "How many results.")
        var count: Int
    }

    func call(arguments: Arguments) async throws -> String {
        "RESULT for \(arguments.query) x\(arguments.count)"
    }
}

private func callState(id: String, name: String, args: String) -> ToolCallState {
    var s = ToolCallState()
    s.id = id
    s.name = name
    s.arguments = args
    return s
}

private func makeEngine(
    transport: any GenerationTransport,
    tools: [any Tool] = [],
    prompt: String = "hello",
    prior: [WireMessage] = [],
    groundsItsOwnAnswers: Bool = false,
    onSuccess: @escaping @Sendable (RequestResult) -> Void = { _ in }
) -> GenerationEngine {
    GenerationEngine(
        events: StreamCallbacks(
            onSourcesFound: { _ in }, onQueriesFound: { _ in },
            onToolExecutionEnded: {}, onSuccess: onSuccess
        ),
        tools: tools,
        initialMessages: prior,
        prompt: prompt,
        transport: transport,
        groundsItsOwnAnswers: groundsItsOwnAnswers
    )
}

// MARK: - Tests

@Suite("Generation loop (transport-agnostic)")
struct GenerationTransportTests {

    @Test func plainAnswerStreamsAndFinishes() async throws {
        let stub = StubTransport(turns: [TurnOutput(content: "Paris.")])
        let seen = LockedBox<[String]>([])
        try await makeEngine(transport: stub).run { text in
            seen.value = seen.value + [text]
        }
        #expect(seen.value.last == "Paris.")
        // One turn only — no tools were offered, so no round to chain.
        #expect(stub.sentMessages.count == 1)
        #expect(stub.sentIncludeTools == [false])
    }

    @Test func promptAndPriorTurnsReachTheTransport() async throws {
        let stub = StubTransport(turns: [TurnOutput(content: "ok")])
        try await makeEngine(
            transport: stub,
            prompt: "and then?",
            prior: [WireMessage(role: "system", content: "be terse"),
                    WireMessage(role: "user", content: "first")]
        ).run { _ in }

        let sent = try #require(stub.sentMessages.first)
        #expect(sent.count == 3)
        #expect(sent[0]["role"] as? String == "system")
        #expect(sent[1]["content"] as? String == "first")
        #expect(sent[2]["role"] as? String == "user")
        #expect(sent[2]["content"] as? String == "and then?")
    }

    /// A structured tool round must come back as OpenAI-shaped follow-up:
    /// an assistant turn carrying `tool_calls`, then one `tool` message per
    /// result, keyed by `tool_call_id`.
    @Test func structuredToolRoundChainsWithToolRole() async throws {
        let stub = StubTransport(turns: [
            TurnOutput(
                content: "",
                toolCalls: [0: callState(id: "call_a", name: "web_search",
                                         args: #"{"query": "swift", "count": 3}"#)],
                isTextBasedToolCall: false
            ),
            TurnOutput(content: "Swift is a language."),
        ])
        let final = LockedBox<String>("")
        try await makeEngine(transport: stub, tools: [EchoTool()]).run { final.value = $0 }

        #expect(final.value == "Swift is a language.")
        #expect(stub.sentMessages.count == 2)

        let followUp = try #require(stub.sentMessages.last)
        let assistant = try #require(followUp.first { $0["role"] as? String == "assistant" })
        #expect(assistant["tool_calls"] != nil)
        let toolMsg = try #require(followUp.first { $0["role"] as? String == "tool" })
        #expect(toolMsg["tool_call_id"] as? String == "call_a")
        #expect((toolMsg["content"] as? String)?.contains("RESULT for swift x3") == true)
    }

    /// A *text-recovered* tool round (Gemma ```tool_code, and the on-device
    /// path in general) cannot use the `tool` role — a model that emitted a
    /// call as prose may not accept a structured reply. It gets a user-role
    /// results message instead, and tools are withheld from the next round.
    @Test func textBasedToolRoundChainsAsUserMessageAndDisablesTools() async throws {
        let stub = StubTransport(turns: [
            TurnOutput(
                content: "Let me look.",
                toolCalls: [0: callState(id: "t0", name: "web_search",
                                         args: #"{"query": "swift", "count": 3}"#)],
                isTextBasedToolCall: true
            ),
            TurnOutput(content: " Done."),
        ])
        try await makeEngine(transport: stub, tools: [EchoTool()]).run { _ in }

        let followUp = try #require(stub.sentMessages.last)
        #expect(!followUp.contains { $0["role"] as? String == "tool" })
        let userResults = try #require(followUp.last)
        #expect(userResults["role"] as? String == "user")
        #expect((userResults["content"] as? String)?.contains("RESULT for swift x3") == true)

        // First round offered tools; the round after a text-based call must not.
        #expect(stub.sentIncludeTools == [true, false])
    }

    /// Arguments arriving as strings (`"count": "3"`) must be coerced against
    /// the tool's own schema before `@Generable` decoding, or the call fails
    /// with a typeMismatch and the tool never runs. Small on-device models do
    /// this constantly, so it is shared-loop behaviour, not a GLM special case.
    @Test func stringifiedScalarArgumentsAreCoercedBeforeTheToolRuns() async throws {
        let stub = StubTransport(turns: [
            TurnOutput(
                content: "",
                toolCalls: [0: callState(id: "c", name: "web_search",
                                         args: #"{"query": "swift", "count": "3"}"#)],
                isTextBasedToolCall: false
            ),
            TurnOutput(content: "done"),
        ])
        try await makeEngine(transport: stub, tools: [EchoTool()]).run { _ in }

        let toolMsg = try #require(stub.sentMessages.last?.first { $0["role"] as? String == "tool" })
        let content = try #require(toolMsg["content"] as? String)
        #expect(content.contains("RESULT for swift x3"), "coercion failed — got: \(content)")
    }

    /// Some models put their whole reply in the reasoning field and leave
    /// `content` empty. Without the fallback the user sees a blank message.
    @Test func reasoningOnlyReplyFallsBackToReasoningText() async throws {
        let stub = StubTransport(turns: [
            TurnOutput(content: "", reasoning: "The answer is 4."),
        ])
        let final = LockedBox<String>("")
        try await makeEngine(transport: stub).run { final.value = $0 }
        #expect(final.value == "The answer is 4.")
    }

    /// A reasoning-only reply that was CUT OFF must not be shown.
    ///
    /// The fallback above exists for models whose whole answer arrives as
    /// reasoning. A model that spiralled until it ran out of budget looks
    /// identical — empty content, full reasoning field — but its reasoning is a
    /// scratchpad stopped mid-thought, and displaying it is worse than showing
    /// nothing.
    ///
    /// Measured: Qwen3-0.6B on MLX, looping on the date teemoon injects, emitted
    /// 3,616 characters over exactly 1024 tokens ending "...asking about the
    /// 2026 F" — and teemoon put that on screen as the assistant's reply.
    @Test func truncatedReasoningIsWithheldRatherThanShownAsTheAnswer() async throws {
        let stub = StubTransport(turns: [
            TurnOutput(content: "",
                       reasoning: "Let me think. The date is 2026 but races are held in different years. But the",
                       completionTokens: 1024, wasTruncated: true),
        ])
        let final = LockedBox<String>("")
        try await makeEngine(transport: stub).run { final.value = $0 }
        #expect(final.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "a truncated scratchpad was shown as the answer: \(final.value)")
    }

    /// ...but a FINISHED reasoning-only reply still is. The truncation check
    /// must not break the case the fallback was written for.
    @Test func completeReasoningOnlyRepliesAreStillShown() async throws {
        let stub = StubTransport(turns: [
            TurnOutput(content: "", reasoning: "The answer is 4.",
                       completionTokens: 120, wasTruncated: false),
        ])
        let final = LockedBox<String>("")
        try await makeEngine(transport: stub).run { final.value = $0 }
        #expect(final.value == "The answer is 4.")
    }

    /// Reasoning must NOT override a real answer.
    @Test func reasoningIsIgnoredWhenContentExists() async throws {
        let stub = StubTransport(turns: [
            TurnOutput(content: "4", reasoning: "thinking out loud"),
        ])
        let final = LockedBox<String>("")
        try await makeEngine(transport: stub).run { final.value = $0 }
        #expect(final.value == "4")
    }

    /// Residual tool markup a recovery parser didn't consume must never reach
    /// the answer. The containment net is in the shared loop, so it protects
    /// on-device output too.
    @Test func residualToolMarkupIsStrippedFromTheAnswer() async throws {
        let stub = StubTransport(turns: [
            TurnOutput(content: "Here you go <tool_call>{\"name\":\"nope\"}</tool_call> done."),
        ])
        let result = LockedBox<RequestResult?>(nil)
        try await makeEngine(transport: stub, onSuccess: { result.value = $0 }).run { _ in }

        // onSuccess is delivered from a detached Task; give it a moment.
        for _ in 0..<40 where result.value == nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let body = try #require(result.value?.responseBody)
        #expect(!body.contains("<tool_call>"), "tool markup leaked into the answer: \(body)")
    }

    /// The round budget is finite: a model that only ever calls tools must be
    /// stopped rather than looping forever.
    ///
    /// REGRESSION: the budget originally gated only whether tools were *offered*,
    /// not whether the loop continued. Withholding tools does not stop a model
    /// emitting a tool call anyway — and teemoon's text recovery parses one out
    /// of raw output regardless — so a stubborn model looped forever, running
    /// real tool calls every round. This test is what caught it.
    @Test func toolRoundsAreBounded() async throws {
        let calling = TurnOutput(
            content: "",
            toolCalls: [0: callState(id: "c", name: "web_search",
                                     args: #"{"query": "x", "count": 1}"#)],
            isTextBasedToolCall: false
        )
        let stub = StubTransport(turns: Array(repeating: calling, count: 10))
        try await makeEngine(transport: stub, tools: [EchoTool()]).run { _ in }

        // 4 tool rounds allowed, then tools are withheld and the loop ends on
        // the next turn: 5 turns total, and only the first 4 offered tools.
        #expect(stub.sentIncludeTools.count == 5)
        #expect(stub.sentIncludeTools == [true, true, true, true, false])
    }

    /// When the budget runs out the tools vanish from the request — and the
    /// model must be TOLD, on that same turn.
    ///
    /// The test above asserts the loop stops. It never asserted the user gets
    /// anything, and for a tool-only chain `textSoFar` is "" — so the guard
    /// traded an infinite loop for a blank message.
    ///
    /// REGRESSION (246356b, the transport split): before it the tool-round
    /// branch was gated on `toolCallRoundDetected` alone and kept executing
    /// rounds past the budget. The split added `remainingToolRounds > 0` to the
    /// loop — correct, and it fixed a real hang — but the exhausted path falls
    /// straight through to "finished" with nothing accumulated.
    ///
    /// Measured on GLM-5.1 via near.ai against one captured exhausted history,
    /// final turn replayed 52 times: silence produced an empty answer 5 times in
    /// 18; the notice produced none in 34 (p = 0.0033, Fisher exact).
    @Test func anExhaustedBudgetTellsTheModelSearchesAreOver() async throws {
        let calling = TurnOutput(
            content: "",
            toolCalls: [0: callState(id: "c", name: "web_search",
                                     args: #"{"query": "x", "count": 1}"#)],
            isTextBasedToolCall: false
        )
        let stub = StubTransport(turns: Array(repeating: calling, count: 10))
        try await makeEngine(transport: stub, tools: [EchoTool()]).run { _ in }

        // Rounds 1-4 offer tools and must say nothing; the 5th withholds them
        // and must carry the notice as its final message.
        for (i, sent) in stub.sentMessages.enumerated() {
            let carriesNotice = sent.contains {
                ($0["content"] as? String) == GenerationEngine.searchesExhaustedNotice
            }
            #expect(carriesNotice == (i == 4),
                    "turn \(i + 1) \(carriesNotice ? "carried" : "omitted") the notice")
        }
        #expect(stub.sentIncludeTools == [true, true, true, true, false])
    }

    /// ...and a model that stops when told then produces a real answer, rather
    /// than the empty string. This is the behaviour the live measurement found:
    /// GLM answers on that turn once it knows the searches are over.
    @Test func aModelThatStopsWhenToldAnswersInsteadOfEmpty() async throws {
        /// Calls tools forever, exactly like the stubborn live case — until it
        /// is told searches are over, at which point it answers.
        final class StubbornUntilToldTransport: GenerationTransport, @unchecked Sendable {
            func runTurn(
                messages: [[String: Any]],
                includeTools: Bool,
                onPartialContent: @escaping @Sendable (String) -> Void
            ) async throws -> TurnOutput {
                let told = messages.contains {
                    ($0["content"] as? String) == GenerationEngine.searchesExhaustedNotice
                }
                guard told else {
                    return TurnOutput(
                        content: "",
                        toolCalls: [0: callState(id: "c", name: "web_search",
                                                 args: #"{"query": "x", "count": 1}"#)],
                        isTextBasedToolCall: false
                    )
                }
                onPartialContent("No CP car wash exists nearby; here is what I found.")
                return TurnOutput(content: "No CP car wash exists nearby; here is what I found.")
            }
        }

        let final = LockedBox<String>("")
        try await makeEngine(transport: StubbornUntilToldTransport(),
                             tools: [EchoTool()]).run { final.value = $0 }

        #expect(!final.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "the round budget ran out and the user got nothing at all")
        #expect(final.value.contains("No CP car wash"))
    }

    /// The TEXT-BASED path already ends its follow-up with "Please answer based
    /// on these results", so it must not also get the notice — two user
    /// messages in a row is a shape some servers reject, for no added
    /// instruction.
    @Test func theTextBasedPathIsNotGivenASecondUserMessage() async throws {
        let stub = StubTransport(turns: [
            TurnOutput(
                content: "Let me look.",
                toolCalls: [0: callState(id: "t0", name: "web_search",
                                         args: #"{"query": "swift", "count": 3}"#)],
                isTextBasedToolCall: true
            ),
            TurnOutput(content: " Done."),
        ])
        try await makeEngine(transport: stub, tools: [EchoTool()]).run { _ in }

        let followUp = try #require(stub.sentMessages.last)
        #expect(!followUp.contains {
            ($0["content"] as? String) == GenerationEngine.searchesExhaustedNotice
        })
        let roles = followUp.compactMap { $0["role"] as? String }
        #expect(!zip(roles, roles.dropFirst()).contains { $0 == "user" && $1 == "user" },
                "two consecutive user messages: \(roles)")
    }

    /// The LAST emitted text must be the clean, canonical answer — because
    /// `ChatGeneration` keeps the last snapshot and that is what gets persisted.
    ///
    /// This is the contract that lets `MLXTransport` stream RAW text (so the
    /// live view can render its "thinking…" block from the `<think>` tags)
    /// without those tags ending up in the stored message. A transport is
    /// allowed to stream anything it likes; the engine guarantees the final
    /// word.
    @Test func lastEmittedTextIsTheCleanAnswerNotTheRawPartial() async throws {
        // Streams raw text containing a think block, then returns clean content
        // — exactly what the MLX transport does.
        final class RawStreamingTransport: GenerationTransport, @unchecked Sendable {
            func runTurn(
                messages: [[String: Any]],
                includeTools: Bool,
                onPartialContent: @escaping @Sendable (String) -> Void
            ) async throws -> TurnOutput {
                onPartialContent("<think>let me consider</think>Paris.")
                return TurnOutput(content: "Paris.", reasoning: "let me consider")
            }
        }

        let seen = LockedBox<[String]>([])
        try await makeEngine(transport: RawStreamingTransport()).run { text in
            seen.value = seen.value + [text]
        }

        let last = try #require(seen.value.last)
        #expect(!last.contains("<think>"),
                "raw thinking markup would be persisted — last emission was: \(last)")
        #expect(last == "Paris.", "final emission should be the clean answer, got: \(last)")
        // The raw partial must still have been emitted, or the live "thinking…"
        // block has nothing to render.
        #expect(seen.value.contains { $0.contains("<think>") },
                "the raw partial was suppressed — the thinking UI would show nothing")
    }

    /// The engine must say when it is WAITING ON A TURN with nothing to show —
    /// the signal the activity chip needs and previously had to guess at with a
    /// 3-second stall timer.
    ///
    /// The gap that guess missed is the one after a tool round: the transcript
    /// already holds text, so the leading chip is gone, and nothing changes on
    /// screen while the follow-up request flies and its prompt prefills.
    /// Measured on DeepSeek V4 Flash via near.ai — which writes a 63-character
    /// preamble alongside its tool call, so its text is non-empty from 0.6s —
    /// that window was 3.0s per tool round.
    @Test func theEngineSaysWhenItIsWaitingWithNothingToShow() async throws {
        let stub = StubTransport(turns: [
            TurnOutput(
                content: "Let me look that up.",
                toolCalls: [0: callState(id: "c", name: "web_search",
                                         args: #"{"query": "x", "count": 1}"#)],
                isTextBasedToolCall: false
            ),
            TurnOutput(content: "Here you go."),
        ])
        let edges = LockedBox<[(Int, Bool)]>([])
        var callbacks = StreamCallbacks(
            onSourcesFound: { _ in }, onQueriesFound: { _ in },
            onToolExecutionEnded: {}, onSuccess: { _ in }
        )
        callbacks.onAwaitingModel = { turn, awaiting in
            edges.value = edges.value + [(turn, awaiting)]
        }
        try await GenerationEngine(
            events: callbacks, tools: [EchoTool()], initialMessages: [],
            prompt: "hi", transport: stub
        ).run { _ in }

        let seen = edges.value
        // Two turns ran, so both must have been announced...
        #expect(seen.contains { $0 == (1, true) }, "turn 1 never announced: \(seen)")
        #expect(seen.contains { $0 == (2, true) }, "turn 2 never announced: \(seen)")
        // ...and each cleared, or the chip would never go away.
        #expect(seen.contains { $0 == (1, false) })
        #expect(seen.contains { $0 == (2, false) })
        // Turn 2's wait must not be cleared before it is announced — that
        // ordering is the whole reason the edge carries a turn index.
        let start2 = try #require(seen.firstIndex { $0 == (2, true) })
        let end2 = try #require(seen.lastIndex { $0 == (2, false) })
        #expect(start2 < end2, "turn 2 was cleared before it started: \(seen)")
    }

    /// A turn that produces text must clear its own wait as soon as the FIRST
    /// character lands — not when the turn ends. Otherwise the chip sits on
    /// screen through the whole answer.
    @Test func theWaitClearsOnTheFirstVisibleCharacter() async throws {
        /// Streams two chunks, then returns; records the wait state seen at the
        /// moment each chunk was emitted.
        final class ChunkedTransport: GenerationTransport, @unchecked Sendable {
            let onChunk: @Sendable () -> Void
            init(onChunk: @escaping @Sendable () -> Void) { self.onChunk = onChunk }
            func runTurn(
                messages: [[String: Any]],
                includeTools: Bool,
                onPartialContent: @escaping @Sendable (String) -> Void
            ) async throws -> TurnOutput {
                onPartialContent("Hel")
                onChunk()
                onPartialContent("Hello.")
                onChunk()
                return TurnOutput(content: "Hello.")
            }
        }

        let edges = LockedBox<[(Int, Bool)]>([])
        let atChunk = LockedBox<[Int]>([])
        var callbacks = StreamCallbacks(
            onSourcesFound: { _ in }, onQueriesFound: { _ in },
            onToolExecutionEnded: {}, onSuccess: { _ in }
        )
        callbacks.onAwaitingModel = { turn, awaiting in
            edges.value = edges.value + [(turn, awaiting)]
        }
        let transport = ChunkedTransport { atChunk.value = atChunk.value + [edges.value.count] }
        try await GenerationEngine(
            events: callbacks, tools: [], initialMessages: [],
            prompt: "hi", transport: transport
        ).run { _ in }

        // By the first chunk's return the wait was already cleared: edges are
        // [(1,true), (1,false)] — the clear is not deferred to turn end.
        #expect(edges.value.prefix(2).map(\.1) == [true, false], "got \(edges.value)")
        // And it is emitted ONCE, not per chunk.
        #expect(edges.value.filter { $0 == (1, false) }.count <= 2,
                "the clear fired per-chunk: \(edges.value)")
    }

    /// A transport with no attestation story (on-device) reports no
    /// verification — which must read as "not applicable", not as a failure.
    @Test func absentVerificationIsNotAFailedVerification() async throws {
        let stub = StubTransport(turns: [TurnOutput(content: "hi")])
        let result = LockedBox<RequestResult?>(nil)
        try await makeEngine(transport: stub, onSuccess: { result.value = $0 }).run { _ in }
        for _ in 0..<40 where result.value == nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let r = try #require(result.value)
        #expect(r.teeVerification == nil)
        #expect(r.isE2EEActive == false)
    }
}

// MARK: - On-device context budget

@Suite("LiteRT context budget")
struct LiteRTContextBudgetTests {

    /// History must be trimmed to fit, oldest first.
    ///
    /// The KV cache covers input AND output, and the on-device grounding payload
    /// alone is ~4.2k tokens (5 sources, ~16,900 characters). With a 4,096
    /// ceiling the first follow-up in a grounded conversation died in the native
    /// layer — `Input token ids are too long: 4484 >= 4096` — which the user saw
    /// as a one-token non-answer, not as an error about length.
    @Test func historyIsTrimmedOldestFirstToFitTheBudget() {
        let messages: [[String: Any]] = (1...10).map {
            ["role": $0 % 2 == 0 ? "assistant" : "user",
             "content": String(repeating: "x", count: 400)]   // ~100 tokens each
        }
        let kept = LiteRTTransport.trimmedHistory(messages, budgetTokens: 350)

        #expect(kept.count == 3, "expected 3 turns to fit a 350-token budget, kept \(kept.count)")
        // The turns nearest the question are the ones a follow-up depends on:
        // "what about the rest of the week" is meaningless without its
        // predecessor, so eviction must take from the FRONT.
        let keptContents = kept.map { $0["content"] as? String ?? "" }
        let tail = messages.suffix(3).map { $0["content"] as? String ?? "" }
        #expect(keptContents == tail, "trimming dropped the most recent turns instead of the oldest")
    }

    /// A budget that leaves no room drops everything rather than overflowing.
    @Test func anExhaustedBudgetKeepsNoHistory() {
        let messages: [[String: Any]] = [["role": "user", "content": String(repeating: "x", count: 4000)]]
        #expect(LiteRTTransport.trimmedHistory(messages, budgetTokens: 0).isEmpty)
        #expect(LiteRTTransport.trimmedHistory(messages, budgetTokens: -50).isEmpty)
    }

    /// The estimate must OVER-count, never under.
    ///
    /// Gemma 4 averages ~6.3 characters per token; dividing by 4 deliberately
    /// over-estimates. Under-estimating would put the prompt over a hard ceiling
    /// that fails in the native layer rather than degrading.
    @Test func tokenEstimateIsPessimistic() {
        let text = String(repeating: "a", count: 630)      // ~100 real tokens
        #expect(LiteRTTransport.estimatedTokens(text) > 100)
        #expect(LiteRTTransport.estimatedTokens("") == 1)
    }

    /// The default context must fit a grounded turn WITH history — the case
    /// that was failing.
    @Test func defaultContextFitsAGroundedFollowUp() {
        let transport = LiteRTTransport(modelPath: URL(fileURLWithPath: "/tmp/x"), estimatedSizeMB: 1)
        // persona + history + 5 sources (~4.2k) + answer.
        #expect(transport.contextTokens >= 8192,
                "context of \(transport.contextTokens) cannot hold a grounded follow-up")
    }
}
