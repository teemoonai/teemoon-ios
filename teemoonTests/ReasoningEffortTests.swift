//
//  ReasoningEffortTests.swift
//  teemoonTests
//
//  Effort maps to each provider's own parameter, and only where it was seen
//  to work (live probes 2026-10-19). Chat sends low by default (the maintainer,
//  2026-10-19, via an internal eval v2: 5 models × 3 levels × 24 objective tasks).
//

import CryptoKit
import Foundation
import ModelBackend
import Testing
@testable import teemoon

@Suite("Reasoning effort", .serialized)
struct ReasoningEffortTests {

    init() { ReasoningEffort.forgetRefusals() }

    static func provider(_ endpoint: String) -> Provider {
        Provider(name: "p", endpoint: endpoint, model: "m", requiresAPIKey: true)
    }

    @Test func chatSendsLowByDefault() {
        #expect(ReasoningEffort.chatDefault == .fast)
    }

    @Test func fireworksNearAndXAIUseReasoningEffort() {
        for url in ["https://api.fireworks.ai/inference/v1/chat/completions", "https://cloud-api.near.ai/v1/chat/completions",
                    "https://api.x.ai/v1/chat/completions"] {
            let p = Self.provider(url)
            #expect(ReasoningEffort.fast.bodyFields(for: p)?["reasoning_effort"] as? String == "low", "\(url)")
            #expect(ReasoningEffort.thinkHarder.bodyFields(for: p)?["reasoning_effort"] as? String == "high", "\(url)")
        }
    }

    /// Only a model whose /models entry lists `reasoning` gets the field; the rest get nothing.
    @Test func openRouterNestsItWhereTheModelSaysItReasons() {
        let p = Self.provider("https://openrouter.ai/api/v1/chat/completions")
        ReasoningControl.note(ReasoningControl.resolve(provider: p, serverKind: nil, modelParameters: ["tools", "reasoning"]), for: p)
        let fields = ReasoningEffort.thinkHarder.bodyFields(for: p)
        #expect((fields?["reasoning"] as? [String: String])?["effort"] == "high")
        #expect(fields?["max_tokens"] == nil)
        ReasoningControl.note(ReasoningControl.resolve(provider: p, serverKind: nil, modelParameters: ["tools"]), for: p)
        #expect(ReasoningEffort.thinkHarder.bodyFields(for: p) == nil)
        #expect(!ReasoningEffort.canThinkHarder(ReasoningControl.current(for: p), provider: p))
    }

    /// Think Harder's answer is written on the request AFTER the search, so
    /// every round keeps the turn's level; it once dropped to low there.
    @Test(arguments: [(ReasoningEffort.thinkHarder, "high"), (.fast, "low")])
    func everyRoundOfASearchTurnSendsTheTurnsLevel(effort: ReasoningEffort, level: String) async throws {
        SearchTurnProtocol.bodies.value = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchTurnProtocol.self]
        let transport = HTTPTransport(
            provider: Self.provider("https://api.fireworks.ai/inference/v1"), apiKey: "k", teeContext: nil,
            tools: [OneSearch()], urlSession: URLSession(configuration: config), effort: effort)
        let result = LockedBox<RequestResult?>(nil)
        try await GenerationEngine(
            events: StreamCallbacks(onSourcesFound: { _ in }, onQueriesFound: { _ in },
                                    onToolExecutionEnded: {}, onSuccess: { r in if !r.effortLevels.isEmpty { result.value = r } }),
            tools: [OneSearch()], initialMessages: [], prompt: "q", transport: transport
        ).run { _ in }

        let sent = SearchTurnProtocol.bodies.value
        #expect(sent.count == SearchTurnProtocol.rounds)
        #expect(sent.allSatisfy { $0["reasoning_effort"] as? String == level }, "\(sent.map { $0["reasoning_effort"] ?? "-" })")
        #expect(sent.allSatisfy { $0["max_tokens"] == nil }, "Fireworks' own default is larger than any cap we'd set")
        for _ in 0..<40 where result.value == nil { try? await Task.sleep(for: .milliseconds(25)) }
        #expect(result.value?.effortLevels == Array(repeating: "effort \(level)", count: SearchTurnProtocol.rounds))
    }

    /// LM Studio, llama.cpp, any custom endpoint: a server that may ignore the field gets none,
    /// and Think Harder is not offered (it would only ask again).
    @Test func unverifiedServersAreLeftAloneAndOfferNoThinkHarder() {
        for (url, kind) in [("http://192.168.1.20:1234/v1/chat/completions", LocalServerKind.lmStudio),
                            ("http://192.168.1.20:8080/v1/chat/completions", nil),
                            ("https://api.example.com/v1/chat/completions", nil)] as [(String, LocalServerKind?)] {
            let p = Self.provider(url)
            let control = ReasoningControl.resolve(provider: p, serverKind: kind, modelParameters: nil)
            #expect(control == .none, "\(url)")
            ReasoningControl.note(control, for: p)
            #expect(ReasoningEffort.fast.bodyFields(for: p) == nil, "\(url)")
            #expect(!ReasoningEffort.canThinkHarder(control, provider: p), "\(url)")
        }
    }

    /// Ollama honours reasoning_effort (measured 2026-10-22, gemma4:e4b on 0.40.6: low 396 tokens, high 668).
    @Test func ollamaGetsEffortWithoutACap() {
        let p = Self.provider("http://192.168.1.20:11434/v1/chat/completions")
        let control = ReasoningControl.resolve(provider: p, serverKind: .ollama, modelParameters: nil)
        #expect(control == .effort(cap: nil))
        ReasoningControl.note(control, for: p)
        #expect(ReasoningEffort.fast.bodyFields(for: p)?["reasoning_effort"] as? String == "low")
        let high = ReasoningEffort.thinkHarder.bodyFields(for: p)
        #expect(high?["reasoning_effort"] as? String == "high")
        #expect(high?["max_tokens"] == nil)
        #expect(ReasoningEffort.canThinkHarder(control, provider: p))
    }

    /// A self-hosted server nothing classified is asked once, on the first send (the maintainer: "Include").
    @Test @MainActor func anUnclassifiedServerIsAskedOnceAndAnOllamaAnswerCounts() async {
        ReasoningControl.forgetProbesForTesting()
        let store = ProviderStore(inMemory: true)
        let p = Self.provider("http://192.168.1.21:11434/v1/chat/completions")
        var asked = 0
        await ReasoningControl.classifyIfNeeded(p, store: store) { _ in asked += 1; return true }
        await ReasoningControl.classifyIfNeeded(p, store: store) { _ in asked += 1; return true }
        #expect(asked == 1)
        #expect(ReasoningControl.resolve(provider: p, store: store) == .effort(cap: nil))
    }

    @Test @MainActor func aNoIsRememberedAndACloudHostIsNeverAsked() async {
        ReasoningControl.forgetProbesForTesting()
        let store = ProviderStore(inMemory: true)
        let lmStudio = Self.provider("http://192.168.1.22:1234/v1/chat/completions")
        var asked = 0
        await ReasoningControl.classifyIfNeeded(lmStudio, store: store) { _ in asked += 1; return false }
        await ReasoningControl.classifyIfNeeded(lmStudio, store: store) { _ in asked += 1; return false }
        #expect(asked == 1, "a no is not asked again this launch")
        #expect(ReasoningControl.resolve(provider: lmStudio, store: store) == .none)
        await ReasoningControl.classifyIfNeeded(Self.provider("https://api.fireworks.ai/inference/v1/chat/completions"),
                                                store: store) { _ in asked += 1; return true }
        #expect(asked == 1, "a cloud host is never probed")
    }

    /// NVIDIA ignores reasoning_effort; enable_thinking switches it (measured 2026-10-22 on three Nemotrons).
    @Test func nvidiaSwitchesThinkingOffThenOn() {
        let p = Self.provider("https://integrate.api.nvidia.com/v1/chat/completions")
        #expect(ReasoningControl.resolve(provider: p, serverKind: nil, modelParameters: nil) == .thinkingSwitch)
        #expect((ReasoningEffort.fast.bodyFields(for: p)?["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
        #expect((ReasoningEffort.thinkHarder.bodyFields(for: p)?["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == true)
        #expect(ReasoningEffort.thinkHarder.bodyFields(for: p)?["reasoning_effort"] == nil)
        #expect(ReasoningEffort.isRefusal(status: 400, body: Data(#"{"error":"unexpected field chat_template_kwargs"}"#.utf8)))
    }

    /// near.ai's default output was never measured, so its Think Harder keeps 8192; the others get none.
    @Test func onlyNearAICapsThinkHarder() {
        #expect(ReasoningEffort.thinkHarder.bodyFields(for: Self.provider("https://cloud-api.near.ai/v1/chat/completions"))?["max_tokens"] as? Int == 8192)
        for url in ["https://api.fireworks.ai/inference/v1/chat/completions", "https://api.x.ai/v1/chat/completions"] {
            #expect(ReasoningEffort.thinkHarder.bodyFields(for: Self.provider(url))?["max_tokens"] == nil, "\(url)")
        }
        #expect(ReasoningEffort.fast.bodyFields(for: Self.provider("https://cloud-api.near.ai/v1/chat/completions"))?["max_tokens"] == nil)
    }

    @Test func onDeviceAndBraveAnswers() {
        var local = Provider(name: "Gemma 4 E2B", endpoint: "on-device", model: "litert-community/gemma-4-E2B-it-litert-lm")
        local.localModelID = "litert-community/gemma-4-E2B-it-litert-lm"
        #expect(ReasoningControl.resolve(provider: local, serverKind: nil, modelParameters: nil) == .onDevice)
        #expect(ReasoningEffort.thinkHarder.bodyFields(for: local) == nil, "on-device thinking is the runtime's switch, not a body")
        #expect(ReasoningEffort.canThinkHarder(.onDevice, provider: local))
        let brave = Provider.braveAnswers
        #expect(ReasoningControl.resolve(provider: brave, serverKind: nil, modelParameters: nil) == .none)
        #expect(!ReasoningEffort.canThinkHarder(.none, provider: brave))
    }

    @Test func theCardReadsTheLevelTheBodySent() {
        #expect(ReasoningEffort.sentLevel(inBodyJSON: #"{"model":"m","reasoning_effort":"low"}"#) == "effort low")
        #expect(ReasoningEffort.sentLevel(inBodyJSON: #"{"reasoning":{"effort":"high"}}"#) == "effort high")
        #expect(ReasoningEffort.sentLevel(inBodyJSON: #"{"chat_template_kwargs":{"enable_thinking":false}}"#) == "thinking off")
        #expect(ReasoningEffort.sentLevel(inBodyJSON: #"{"chat_template_kwargs":{"enable_thinking":true}}"#) == "thinking on")
        #expect(ReasoningEffort.sentLevel(inBodyJSON: #"{"model":"m"}"#) == nil)
        #expect(ReasoningEffort.sentLevel(inBodyJSON: nil) == nil)
    }

    /// One word for the turn (the maintainer, review page 2026-10-20), whatever the round count.
    @Test func theCardNamesTheTurnsLevelInOneWord() {
        #expect(ReasoningEffort.cardLine(levels: ["effort low"]) == "effort low")
        #expect(ReasoningEffort.cardLine(levels: ["effort high", "effort high"]) == "effort high")
        #expect(ReasoningEffort.cardLine(levels: ["thinking on", "thinking on", "thinking on"]) == "thinking on")
        #expect(ReasoningEffort.cardLine(levels: [nil, "effort low"]) == "effort low")
        #expect(ReasoningEffort.cardLine(levels: [nil, nil]) == nil)
        #expect(ReasoningEffort.cardLine(levels: []) == nil)

        var info = LastRequestDebugInfo(providerName: "fireworks", url: nil, requestHeaders: nil,
                                        requestBodyJSON: #"{"reasoning_effort":"high"}"#, responseBody: nil,
                                        toolCalls: [], threadID: UUID(), totalDuration: nil, timeToFirstToken: nil,
                                        outputTokens: nil, isE2EEActive: false)
        #expect(info.effortLine == "effort high", "a turn with no recorded rounds reads the body")
        info.effortLevels = ["effort high", "effort high"]
        #expect(info.effortLine == "effort high")
        let onDevice = LastRequestDebugInfo(providerName: "Gemma 4 E2B", url: nil, requestHeaders: ["thinking": "on"],
                                            requestBodyJSON: "[]", responseBody: nil, toolCalls: [], threadID: UUID(),
                                            totalDuration: nil, timeToFirstToken: nil, outputTokens: nil, isE2EEActive: false)
        #expect(onDevice.effortLine == "thinking on")
    }

    @Test func neverNone() {
        for effort in ReasoningEffort.allCases {
            let fields = effort.bodyFields(for: Self.provider("https://api.x.ai/v1/chat/completions"))
            #expect(fields?["reasoning_effort"] as? String != "none")
        }
    }

    @Test func onlyA400NamingTheParameterIsARefusal() {
        #expect(ReasoningEffort.isRefusal(status: 400, body: Data(#"{"error":"Invalid reasoning effort."}"#.utf8)))
        #expect(ReasoningEffort.isRefusal(status: 400, body: Data(#"{"error":{"message":"Unknown field reasoning_effort"}}"#.utf8)))
        // xAI, grok-build-0.1 (2026-10-22): camel case. Missed in 58, so every send failed.
        #expect(ReasoningEffort.isRefusal(status: 400, body: Data(#"{"code":"invalid-argument","error":"Model grok-build-0.1 does not support parameter reasoningEffort."}"#.utf8)))
        #expect(ReasoningEffort.isRefusal(status: 400, body: Data(#"{"error":"unknown field enableThinking"}"#.utf8)))
        #expect(!ReasoningEffort.isRefusal(status: 400, body: Data(#"{"error":"context length exceeded"}"#.utf8)))
        #expect(!ReasoningEffort.isRefusal(status: 401, body: Data("reasoning_effort".utf8)))
        #expect(!ReasoningEffort.isRefusal(status: 400, body: Data(#"{"error":"invalid effort"}"#.utf8)))
        #expect(!ReasoningEffort.isRefusal(status: 400, body: Data(#"{"error":"reasoning tokens exceed max_tokens"}"#.utf8)))
    }

    @Test func aModelThatRefusesIsAskedAgainWithoutItAndRemembered() async throws {
        EffortRefusingProtocol.bodies.value = []
        let transport = Self.transport("https://api.x.ai/v1", extra: [:])
        let out = try await transport.runTurn(messages: [["role": "user", "content": "hi"]], includeTools: false,
                                              onPartialContent: { _ in })
        #expect(out.content == "ok")
        let sent = EffortRefusingProtocol.bodies.value
        #expect(sent.count == 2)
        #expect(sent.first?["reasoning_effort"] as? String == "low")
        #expect(sent.last?["reasoning_effort"] == nil)
        // The next turn on that model does not try again.
        _ = try await transport.runTurn(messages: [["role": "user", "content": "hi"]], includeTools: false,
                                        onPartialContent: { _ in })
        #expect(EffortRefusingProtocol.bodies.value.count == 3)
        #expect(ReasoningEffort.fast.bodyFields(for: Self.provider("https://api.x.ai/v1/chat/completions")) != nil,
                "another model on the host is unaffected")
    }

    /// near.ai: the retry is sealed again from plaintext, never the first request's bytes re-sent.
    @Test func anE2EERetryIsSealedAfresh() async throws {
        EffortRefusingProtocol.bodies.value = []
        let modelKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let peer = try E2EEPeer(modelEd25519PubKey: modelKey)
        let record = AttestationRecord(
            composeHash: "test", mrtd: "test", osImageHash: "test", intelQuote: "",
            composeManifest: nil, gpuArch: nil, gpuNodeComposeHash: nil, modelFileHash: nil,
            signingAddress: nil, gpuSigningAddress: nil, modelEd25519PubKey: modelKey,
            quoteVerification: nil, gpuQuoteVerification: nil, modelQuoteVerification: nil,
            fetchedAt: Date(), providerID: UUID())
        let provider = Provider(name: "near.ai", endpoint: "https://cloud-api.near.ai/v1", model: "zai-org/GLM-5.3-Flash")
        let context = TEEContext(baseURL: try #require(provider.openAIBaseURL), model: provider.model, apiKey: "k",
                                 attestation: record, gpuNodeURL: nil, e2eePeer: peer)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EffortRefusingProtocol.self]
        let transport = HTTPTransport(provider: provider, apiKey: "k", teeContext: context, tools: [],
                                      urlSession: URLSession(configuration: config), effort: .fast)
        // The second answer is plaintext, which the E2EE decoder rejects; only the requests matter here.
        _ = try? await transport.runTurn(messages: [["role": "user", "content": "my private words"]],
                                         includeTools: false, onPartialContent: { _ in })
        let sent = EffortRefusingProtocol.bodies.value
        #expect(sent.count == 2)
        let first = (sent.first?["messages"] as? [[String: Any]])?.first?["content"] as? String
        let retry = (sent.last?["messages"] as? [[String: Any]])?.first?["content"] as? String
        #expect(first != nil && retry != nil)
        #expect(first != retry, "fresh ephemeral key per seal")
        #expect(first != "my private words" && retry != "my private words")
        #expect(sent.last?["reasoning_effort"] == nil)
    }

    @Test func aKeyThePersonSetInExtraParametersWins() async throws {
        EffortRefusingProtocol.bodies.value = []
        let transport = Self.transport("https://api.fireworks.ai/inference/v1", extra: ["reasoning_effort": "medium"])
        _ = try await transport.runTurn(messages: [["role": "user", "content": "hi"]], includeTools: false,
                                        onPartialContent: { _ in })
        #expect(EffortRefusingProtocol.bodies.value.first?["reasoning_effort"] as? String == "medium")
    }

    static func transport(_ endpoint: String, extra: [String: String]) -> HTTPTransport {
        var p = Provider(name: "p", endpoint: endpoint, model: "grok-x", requiresAPIKey: true)
        p.extraParams = extra
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EffortRefusingProtocol.self]
        return HTTPTransport(provider: p, apiKey: "k", teeContext: nil, tools: [],
                             urlSession: URLSession(configuration: config), effort: .fast)
    }
}

/// 400s any body carrying `reasoning_effort` when the value is "low", the way
/// grok-4.7 answers "none"; answers "ok" otherwise.
private final class EffortRefusingProtocol: URLProtocol {
    static let bodies = LockedBox<[[String: Any]]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        } else if let body = request.httpBody { data = body }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.bodies.value.append(body)
        let refuse = body["reasoning_effort"] as? String == "low"
        let response = HTTPURLResponse(url: request.url!, statusCode: refuse ? 400 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": refuse ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let text = refuse ? #"{"error":"Invalid reasoning effort."}"#
            : #"data: {"choices":[{"delta":{"content":"ok"}}]}"# + "\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct OneSearch: Tool {
    let name = "web_search"
    let description = "Search the web."
    @Generable struct Arguments: Sendable {
        @Guide(description: "The search query.")
        var query: String
    }
    func call(arguments: Arguments) async throws -> String { "<source><url>https://a.example</url><title>A</title></source>" }
}

/// Answers with a web_search call until the last round, then with text.
private final class SearchTurnProtocol: URLProtocol {
    static let rounds = 3
    static let bodies = LockedBox<[[String: Any]]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        } else if let body = request.httpBody { data = body }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.bodies.value.append(body)
        let round = Self.bodies.value.count
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let call = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c\#(round)","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"q\#(round)\"}"}}]},"finish_reason":null}]}"#
            + "\n\n" + #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"# + "\n\n"
        let text = #"data: {"choices":[{"delta":{"content":"Answer."},"finish_reason":"stop"}]}"# + "\n\n"
        client?.urlProtocol(self, didLoad: Data(((round < Self.rounds ? call : text) + "data: [DONE]\n\n").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
