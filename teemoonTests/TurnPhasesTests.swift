//
//  TurnPhasesTests.swift
//  teemoonTests
//
//  The developer card's phase line: offsets from the tap, the tool round's
//  size, and the prompt-cache share read from usage. Before 1.0.6 the card's
//  ttft started after the attestation gate, so a slow gate was invisible.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Turn phases")
struct TurnPhasesTests {

    @Test func offsetsAreFromTheTapInOrder() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let phases = TurnPhases(origin: t0, events: [
            PhaseEvent(kind: .done, at: t0 + 7.3),
            PhaseEvent(kind: .gate, at: t0 + 0.8),
            PhaseEvent(kind: .sent, at: t0 + 0.81),
            PhaseEvent(kind: .response, at: t0 + 1.2),
            PhaseEvent(kind: .firstToken, at: t0 + 1.31),
            PhaseEvent(kind: .tool, at: t0 + 2.6, durationMs: 1200, bytes: 14_500, tokens: 3_625),
            PhaseEvent(kind: .firstAnswer, at: t0 + 5.9),
            PhaseEvent(kind: .verified, at: t0 + 9.5),
        ], promptTokens: 4_000, cachedTokens: 3_680)
        #expect(abs((phases.first(.gate) ?? 0) - 0.8) < 1e-6)
        #expect(phases.cachePercent == 92)
        #expect(phases.line == "gate 0.80 · sent 0.81 · resp 1.20 · first 1.31 · tool 1.2s 14KB ~3.6k tok · answer 5.90 · done 7.30 · signed 9.50 · cache 92%")
    }

    @Test func noUsageMeansNoCacheFigure() {
        let t0 = Date()
        let phases = TurnPhases(origin: t0, events: [PhaseEvent(kind: .done, at: t0 + 1)], promptTokens: 100)
        #expect(phases.cachePercent == nil)
        #expect(phases.line == "done 1.00")
        #expect(phases.cacheLine == nil)
    }

    /// The maintainer's 0% was a chat's first message, which has nothing to reuse yet.
    @Test func theCardsCacheLineSaysWhyAFirstMessageHasNone() {
        let t0 = Date()
        var phases = TurnPhases(origin: t0, events: [], promptTokens: 4_000, cachedTokens: 3_680)
        #expect(phases.cacheLine == "cache 92%")
        phases.cachedTokens = 0
        #expect(phases.cacheLine == "cache 0%", "a later message at 0% is a real miss")
        phases.firstMessage = true
        #expect(phases.cacheLine == "cache — first message")
        phases.cachedTokens = 2_000
        #expect(phases.cacheLine == "cache 50%", "a first message's search follow-up can reuse its own first request")
    }

    /// near.ai sends `prompt_tokens_details: null` on a miss, so a first near.ai
    /// message showed no cache line at all (the maintainer, GLM-5.3-Flash).
    @Test func aMissingFigureReadsByHost() {
        func phases(_ host: String?, onDevice: Bool = false, cached: Int? = nil, prompt: Int? = 4_000) -> TurnPhases {
            var p = TurnPhases(origin: Date(), events: [], promptTokens: prompt, cachedTokens: cached)
            p.cacheReporting = TurnPhases.cacheReporting(host: host, onDevice: onDevice)
            return p
        }
        for host in ["cloud-api.near.ai", "api.fireworks.ai", "api.x.ai", "openrouter.ai"] {
            var p = phases(host)
            #expect(p.cacheLine == "cache 0%", "\(host)")
            p.firstMessage = true
            #expect(p.cacheLine == "cache — first message", "\(host)")
            #expect(phases(host, cached: 3_680).cacheLine == "cache 92%", "\(host)")
        }
        for host in ["integrate.api.nvidia.com", "192.168.1.2"] {
            #expect(phases(host).cacheLine == "cache — not reported", "\(host)")
            #expect(phases(host, cached: 2_000).cacheLine == "cache 50%", "a figure still shows")
        }
        #expect(phases("cloud-api.near.ai", prompt: nil).cacheLine == "cache — not reported", "no usage at all")
        var sealed = TurnPhases(origin: Date(), events: [], promptTokens: 5_769)
        sealed.cacheReporting = TurnPhases.cacheReporting(host: "cloud-api.near.ai", onDevice: false, isE2EE: true)
        #expect(sealed.cacheLine == "cache — not reported", "E2EE near.ai sent null on a repeated prompt")
        #expect(phases(nil, onDevice: true).cacheLine == nil, "on-device has no provider cache")
        #expect(phases("api.fireworks.ai", onDevice: true).cacheLine == nil)
    }

    /// The maintainer: effort and cache go on the timing row; the copied text keeps its own lines.
    @Test func theCardsTimingRowEndsWithEffortAndCache() {
        var phases = TurnPhases(origin: Date(), events: [], promptTokens: 4_000, cachedTokens: 3_680)
        phases.cacheReporting = .missingIsZero
        let info = LastRequestDebugInfo(
            providerName: "fireworks", url: URL(string: "https://api.fireworks.ai/inference/v1/chat/completions"),
            requestHeaders: nil, requestBodyJSON: #"{"reasoning_effort":"low"}"#, responseBody: nil,
            toolCalls: [], threadID: UUID(), totalDuration: 6.9, timeToFirstToken: 1.4,
            outputTokens: 412, phases: phases, isE2EEActive: false)
        #expect(info.cardTimingLine == "6.9s · ttft 1.4s · gen 5.5s · 412tok · 75tok/s · effort low · cache 92%")
        #expect(info.timingLine == "6.9s · ttft 1.4s · gen 5.5s · 412tok · 75tok/s")
        #expect(info.effortLine == "effort low")
    }

    @Test func parserReadsCachedTokensOpenAIStyle() {
        let parser = SSEStreamParser(hasTools: false)
        let chunk = #"""
            data: {"id":"x","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":3968,"completion_tokens":12,"prompt_tokens_details":{"cached_tokens":3840}}}
            """# + "\n\n"
        _ = parser.consume(Data(chunk.utf8))
        #expect(parser.promptTokens == 3968)
        #expect(parser.cachedTokens == 3840)
    }

    @Test func parserReadsCachedTokensDeepSeekStyle() {
        let parser = SSEStreamParser(hasTools: false)
        let chunk = #"""
            data: {"id":"x","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":3718,"completion_tokens":9,"prompt_cache_hit_tokens":3712,"prompt_cache_miss_tokens":6}}
            """# + "\n\n"
        _ = parser.consume(Data(chunk.utf8))
        #expect(parser.cachedTokens == 3712)
    }
}
