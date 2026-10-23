//
//  LiteRTReuseLiveTests.swift
//  teemoonTests
//
//  The kept LiteRT conversation on the phone: the follow-up's first token with
//  and without it, and that a stopped turn is never kept. Same switch and
//  model as LiteRTLiveTests (LITERT_LIVE=1, real device).
//

import Foundation
import Testing
@testable import teemoon

@Suite("LiteRT kept conversation (live)", .serialized)
struct LiteRTReuseLiveTests {

    static let system = "You are a helpful assistant. Answer in plain prose."
    /// About 1.5k tokens of prior chat, so the seed has something to prefill.
    static let history: [[String: Any]] = (1...3).flatMap { i -> [[String: Any]] in
        [["role": "user", "content": "Tell me about topic \(i): the history of bridges, part \(i)."],
         ["role": "assistant", "content": String(repeating: "Bridges carry roads and rails over rivers and valleys; engineers chose stone, iron and later steel as spans grew longer. ", count: 18)]]
    }

    struct Timed { let firstToken: Duration; let reply: String; let conversation: String }

    @MainActor
    static func turn(_ transport: LiteRTTransport, _ messages: [[String: Any]]) async throws -> Timed {
        let start = ContinuousClock.now
        let first = LockedBox<Duration?>(nil)
        let out = try await transport.runTurn(messages: messages, includeTools: false) { _ in
            if first.value == nil { first.value = start.duration(to: .now) }
        }
        return Timed(firstToken: first.value ?? start.duration(to: .now), reply: out.content,
                     conversation: out.report.requestHeaders?["conversation"] ?? "?")
    }

    @Test(.enabled(if: LiteRTLiveTests.enabled, "set LITERT_LIVE=1"), .timeLimit(.minutes(20)))
    @MainActor
    func followUpFirstTokenKeptVersusSeeded() async throws {
        try #require(FileManager.default.fileExists(atPath: LiteRTLiveTests.modelPath.path), "bundle missing")
        var lines: [String] = []
        defer {
            LiteRTTransport.reuseConversations = true
            try? lines.joined(separator: "\n").write(to: URL.documentsDirectory.appending(component: "reuse-bench.txt"),
                                                     atomically: true, encoding: .utf8)
        }
        for reuse in [false, true, false, true] {
            LiteRTTransport.reuseConversations = reuse
            let transport = LiteRTTransport(modelPath: LiteRTLiveTests.modelPath,
                                            estimatedSizeMB: LiteRTLiveTests.sizeMB, contextTokens: 8192)
            let base: [[String: Any]] = [["role": "system", "content": Self.system]] + Self.history
            let ask1 = base + [["role": "user", "content": "In one sentence, which material made the longest spans possible?"]]
            let a = try await Self.turn(transport, ask1)
            let ask2 = ask1 + [["role": "assistant", "content": a.reply],
                               ["role": "user", "content": "And in one sentence, why?"]]
            let b = try await Self.turn(transport, ask2)
            let line = "reuse=\(reuse) turn1 first=\(a.firstToken) [\(a.conversation)] · follow-up first=\(b.firstToken) [\(b.conversation)]"
            print("[litert-reuse] \(line)")
            lines.append(line)
            #expect(!b.reply.isEmpty)
            #expect(b.conversation.hasPrefix(reuse ? "reused" : "rebuilt"), "\(line)")
        }
    }

    @Test(.enabled(if: LiteRTLiveTests.enabled, "set LITERT_LIVE=1"), .timeLimit(.minutes(20)))
    @MainActor
    func aStoppedTurnIsNotKeptAndTheNextTurnStillAnswers() async throws {
        try #require(FileManager.default.fileExists(atPath: LiteRTLiveTests.modelPath.path), "bundle missing")
        LiteRTTransport.reuseConversations = true
        let transport = LiteRTTransport(modelPath: LiteRTLiveTests.modelPath,
                                        estimatedSizeMB: LiteRTLiveTests.sizeMB, contextTokens: 8192)
        let base: [[String: Any]] = [["role": "system", "content": Self.system]] + Self.history
        let ask1 = base + [["role": "user", "content": "Name one famous suspension bridge."]]
        let a = try await Self.turn(transport, ask1)
        // Stopped mid-answer.
        let ask2 = ask1 + [["role": "assistant", "content": a.reply],
                           ["role": "user", "content": "Write 400 words about its construction."]]
        let gotToken = LockedBox(false)
        let stopped = Task { @MainActor in
            try await transport.runTurn(messages: ask2, includeTools: false) { _ in gotToken.value = true }
        }
        while !gotToken.value { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(500))
        stopped.cancel()
        let partial = (try? await stopped.value)?.content ?? ""
        // The next turn replays the partial reply as the app stores it; it must be rebuilt, and answer.
        let ask3 = ask2 + [["role": "assistant", "content": partial],
                           ["role": "user", "content": "In one sentence, where is it?"]]
        let c = try await Self.turn(transport, ask3)
        print("[litert-reuse] after stop: first=\(c.firstToken) [\(c.conversation)] reply=\(c.reply.prefix(80))")
        #expect(c.conversation == "rebuilt")
        #expect(!c.reply.isEmpty)
        // And the turn after that one is kept again.
        let ask4 = ask3 + [["role": "assistant", "content": c.reply], ["role": "user", "content": "Thanks. One word: is it still open?"]]
        let d = try await Self.turn(transport, ask4)
        #expect(d.conversation.hasPrefix("reused"), "\(d.conversation)")
    }

    /// The audit's disk gate: a kept multi-turn session carrying a marker the
    /// harness then greps for in the runtime's cacheDir (tmp/) and the container.
    @Test(.enabled(if: LiteRTLiveTests.enabled, "set LITERT_LIVE=1"), .timeLimit(.minutes(20)))
    @MainActor
    func aKeptSessionWithAMarkerForTheDiskGrep() async throws {
        try #require(FileManager.default.fileExists(atPath: LiteRTLiveTests.modelPath.path), "bundle missing")
        LiteRTTransport.reuseConversations = true
        let marker = "QUILLFERN-58213-MARKER"
        let transport = LiteRTTransport(modelPath: LiteRTLiveTests.modelPath,
                                        estimatedSizeMB: LiteRTLiveTests.sizeMB, contextTokens: 8192)
        var messages: [[String: Any]] = [["role": "system", "content": Self.system]]
        var kinds: [String] = []
        for ask in ["My codeword is \(marker). Repeat it once.", "Say the codeword \(marker) again, then one fact about ferns.",
                    "Last time: spell \(marker) backwards is not needed, just say it."] {
            messages.append(["role": "user", "content": ask])
            let t = try await Self.turn(transport, messages)
            kinds.append(t.conversation)
            messages.append(["role": "assistant", "content": t.reply])
        }
        print("[litert-reuse] marker session: \(kinds)")
        #expect(kinds.dropFirst().allSatisfy { $0.hasPrefix("reused") }, "\(kinds)")
    }

    @Test(.enabled(if: LiteRTLiveTests.enabled, "set LITERT_LIVE=1"), .timeLimit(.minutes(20)))
    @MainActor
    func deletingAChatDropsTheKeptConversation() async throws {
        try #require(FileManager.default.fileExists(atPath: LiteRTLiveTests.modelPath.path), "bundle missing")
        LiteRTTransport.reuseConversations = true
        let transport = LiteRTTransport(modelPath: LiteRTLiveTests.modelPath,
                                        estimatedSizeMB: LiteRTLiveTests.sizeMB, contextTokens: 8192)
        var messages: [[String: Any]] = [["role": "system", "content": Self.system],
                                         ["role": "user", "content": "Name a colour."]]
        let a = try await Self.turn(transport, messages)
        messages += [["role": "assistant", "content": a.reply], ["role": "user", "content": "Another one."]]
        await LiteRTTransport.forgetKeptConversations()
        let b = try await Self.turn(transport, messages)
        #expect(b.conversation == "seeded", "the same history would have been kept: \(b.conversation)")
    }
}
