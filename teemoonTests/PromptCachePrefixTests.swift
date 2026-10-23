//
//  PromptCachePrefixTests.swift
//  teemoonTests
//
//  The maintainer, TestFlight 57: Fireworks GLM 5.3 Flash showed "cache 0%" on a chat's second
//  send. The body was serialized from Swift dictionaries without sorted keys, so the
//  tools' key order changed between requests and the prompt the server rendered no
//  longer shared a prefix. Live, two sends through ChatViewModel: 0 cached of ~870
//  twice unsorted, 768 cached of ~860 twice sorted (2026-10-22).
//

import Foundation
import CryptoKit
import SwiftData
import Testing
@testable import teemoon

@Suite("Prompt cache prefix", .serialized)
struct PromptCachePrefixTests {

    @Test func aRequestBodyIsTheSameBytesEveryTime() async throws {
        RawBodyProtocol.bodies.value = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RawBodyProtocol.self]
        let provider = Provider(name: "Fireworks", endpoint: "https://api.fireworks.ai/inference/v1",
                                model: "accounts/fireworks/models/glm-5p3-flash", requiresAPIKey: true)
        let messages: [[String: Any]] = [["role": "system", "content": "persona"],
                                         ["role": "user", "content": "What is a tide pool?"]]
        for _ in 0..<3 {
            let transport = HTTPTransport(provider: provider, apiKey: "k", teeContext: nil,
                                          tools: [BraveWebSearchTool(apiKey: "b")],
                                          urlSession: URLSession(configuration: config), effort: .fast)
            _ = try? await transport.runTurn(messages: messages, includeTools: true, onPartialContent: { _ in })
        }
        let bodies = RawBodyProtocol.bodies.value
        #expect(bodies.count == 3)
        #expect(Set(bodies).count == 1, "the same turn must serialize to the same bytes")
        let first = try #require(bodies.first)
        let parsed = try JSONSerialization.jsonObject(with: first)
        #expect(first == (try JSONSerialization.data(withJSONObject: parsed, options: .sortedKeys)),
                "keys are sorted, so a dictionary's order never reaches the wire")
    }

    /// Only object keys sort: messages, tools, tool_calls and content parts keep their order.
    @Test func sortingNeverReordersAnArray() async throws {
        RawBodyProtocol.bodies.value = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RawBodyProtocol.self]
        let provider = Provider(name: "Fireworks", endpoint: "https://api.fireworks.ai/inference/v1",
                                model: "accounts/fireworks/models/glm-5p3-flash", requiresAPIKey: true)
        let messages: [[String: Any]] = [
            ["role": "system", "content": "zeta persona"],
            ["role": "user", "content": [["type": "text", "text": "zz first part"], ["type": "text", "text": "aa second part"]]],
            ["role": "assistant", "content": "", "tool_calls": [
                ["id": "z-call", "type": "function", "function": ["name": "web_search", "arguments": "{\"query\":\"z\"}"]],
                ["id": "a-call", "type": "function", "function": ["name": "web_search", "arguments": "{\"query\":\"a\"}"]]]],
            ["role": "tool", "tool_call_id": "z-call", "content": "z result"],
            ["role": "tool", "tool_call_id": "a-call", "content": "a result"],
            ["role": "user", "content": "and then?"],
        ]
        let transport = HTTPTransport(provider: provider, apiKey: "k", teeContext: nil,
                                      tools: [BraveWebSearchTool(apiKey: "b"), BraveWebSearchTool(apiKey: "b2")],
                                      urlSession: URLSession(configuration: config), effort: .fast)
        _ = try? await transport.runTurn(messages: messages, includeTools: true, onPartialContent: { _ in })
        let body = try #require(RawBodyProtocol.bodies.value.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try #require(json["messages"] as? [[String: Any]])
        #expect(sent.map { $0["role"] as? String } == ["system", "user", "assistant", "tool", "tool", "user"])
        let parts = try #require(sent[1]["content"] as? [[String: Any]])
        #expect(parts.map { $0["text"] as? String } == ["zz first part", "aa second part"])
        let calls = try #require(sent[2]["tool_calls"] as? [[String: Any]])
        #expect(calls.map { $0["id"] as? String } == ["z-call", "a-call"])
        #expect(sent[3...4].map { $0["tool_call_id"] as? String } == ["z-call", "a-call"])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 2)
        let schema = try #require((tools[0]["function"] as? [String: Any])?["parameters"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["query"])
    }

    /// The sort is on the plaintext, before E2EE sealing; sealed fields go out as plain
    /// ciphertext strings, in the same message order, whatever the sort did.
    @Test func sealingTakesTheSortedPlaintextAndLeavesStrings() async throws {
        RawBodyProtocol.bodies.value = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RawBodyProtocol.self]
        let provider = Provider(name: "near.ai", endpoint: "https://cloud-api.near.ai/v1", model: "z-ai/glm-5.3-flash")
        let transport = HTTPTransport(provider: provider, apiKey: "k", teeContext: nil,
                                      tools: [BraveWebSearchTool(apiKey: "b")],
                                      urlSession: URLSession(configuration: config), effort: .fast)
        _ = try? await transport.runTurn(messages: [["role": "system", "content": "persona"],
                                                    ["role": "user", "content": "my private question"]],
                                         includeTools: true, onPartialContent: { _ in })
        let plaintext = try #require(RawBodyProtocol.bodies.value.first)
        let peer = try E2EEPeer(modelEd25519PubKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let sealed = try #require(try E2EEStreamCodec(peer: peer).encryptedBodyIfChanged(plaintext))
        let json = try #require(try JSONSerialization.jsonObject(with: sealed) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        for m in messages {
            let content = try #require(m["content"] as? String, "a sealed content is one ciphertext string")
            #expect(!content.contains("private"))
        }
        let fn = try #require((json["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
        #expect(fn["parameters"] is String, "the schema is sealed whole, as a string")
        #expect(!String(decoding: sealed, as: UTF8.self).contains("my private question"))
    }
}

private final class RawBodyProtocol: URLProtocol {
    static let bodies = LockedBox<[Data]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        }
        Self.bodies.value.append(data)
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// pm, 2026-10-22 (Android writes the same fixture): for each case, the sorted-key JSON of
/// request N's `messages`, minus its closing `]`, is a byte prefix of request N+1's.
/// Every request goes through ChatViewModel, ConfidentialLanguageModel and HTTPTransport;
/// only the server is a stub.
@Suite("Prompt cache prefix across turns", .serialized)
@MainActor struct PromptCachePrefixAcrossTurnsTests {

    struct Prefix: CustomStringConvertible {
        let holds: Bool
        let offset: Int
        let messageIndex: Int?
        let role: String?
        var description: String {
            holds ? "prefix holds" : "differs at byte \(offset), message \(messageIndex ?? -1) (\(role ?? "-"))"
        }
    }

    static func messages(_ body: Data) throws -> [[String: Any]] {
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require(json["messages"] as? [[String: Any]])
    }

    static func prefix(_ n: Data, _ next: Data) throws -> Prefix {
        let a = try JSONSerialization.data(withJSONObject: messages(n), options: .sortedKeys).dropLast()
        let b = try JSONSerialization.data(withJSONObject: messages(next), options: .sortedKeys)
        let offset = zip(a, b).prefix { $0 == $1 }.count
        if offset == a.count { return Prefix(holds: true, offset: offset, messageIndex: nil, role: nil) }
        // The message of N+1 the first differing byte falls in.
        var end = 1
        let sent = try messages(next)
        for (i, m) in sent.enumerated() {
            end += try JSONSerialization.data(withJSONObject: m, options: .sortedKeys).count + 1
            if offset < end { return Prefix(holds: false, offset: offset, messageIndex: i, role: m["role"] as? String) }
        }
        return Prefix(holds: false, offset: offset, messageIndex: nil, role: nil)
    }

    @MainActor final class Rig {
        let container: ModelContainer
        var thread: ChatThread?
        let vm = ChatViewModel()
        let llm = ChatGeneration()
        let store = ProviderStore(inMemory: true)
        let settings = AppSettings()
        let grounding: Bool

        init(_ script: [Data], provider: Provider = Provider(name: "Fireworks", endpoint: "https://api.fireworks.ai/inference/v1",
                                                               model: "accounts/fireworks/models/glm-5p3-flash", requiresAPIKey: false)) throws {
            container = try ModelContainer(for: ChatThread.self, Message.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            ScriptedServer.reset(script)
            grounding = settings.braveGroundingEnabled
            settings.braveGroundingEnabled = false   // keyless search: the tool runs, nothing leaves
            store.addProvider(provider)
            store.currentProviderID = provider.id.uuidString
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ScriptedServer.self]
            let session = URLSession(configuration: config)
            let effort = LockedBox<ReasoningEffort?>(ReasoningEffort.chatDefault)
            self.effort = effort
            llm.makeLanguageModel = { provider, key, prior, tee, events in
                ConfidentialLanguageModel(provider: provider, apiKey: key, priorMessages: prior, context: tee,
                                          events: events, urlSession: session, effort: effort.value)
            }
        }
        let effort: LockedBox<ReasoningEffort?>

        func send(_ text: String) async {
            effort.value = ReasoningEffort.chatDefault
            vm.prompt = text
            vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: settings,
                        providers: store, session: ConfidentialSession(providers: store), llm: llm)
            await finish()
        }

        func thinkHarder() async throws {
            effort.value = .thinkHarder
            let question = try #require(thread?.sortedMessages.last { $0.role == .user })
            vm.retry(from: question, currentThread: &thread, modelContext: container.mainContext,
                     settings: settings, providers: store, session: ConfidentialSession(providers: store),
                     llm: llm, effort: .thinkHarder)
            await finish()
        }

        func finish() async {
            try? await Task.sleep(for: .milliseconds(20))
            for _ in 0..<250 where vm.generatingThreadID != nil { try? await Task.sleep(for: .milliseconds(20)) }
        }

        var requests: [Data] { ScriptedServer.bodies.value }
        func restore() { settings.braveGroundingEnabled = grounding }
    }

    static func event(_ delta: [String: Any], finish: String? = nil) -> String {
        let obj: [String: Any] = ["id": "c", "object": "chat.completion.chunk",
                                  "choices": [["index": 0, "delta": delta, "finish_reason": finish.map { $0 as Any } ?? NSNull()]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }
    static func sse(_ events: [String]) -> Data {
        Data((events.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n").utf8)
    }
    static func reply(_ text: String) -> Data { sse([event(["content": text], finish: "stop")]) }
    static let searchCall = sse([
        event(["tool_calls": [["index": 0, "id": "call_1", "type": "function",
                               "function": ["name": "web_search", "arguments": "{\"query\":\"tide pools\"}"]]]]),
        event([:], finish: "tool_calls"),
    ])

    /// (1) A search turn. History keeps stored text only, so the tool round (R2) breaks at its
    /// assistant message, and the question's own request (R1) still holds: send 2 reuses what a
    /// chat without search would. Resending tool rounds is a product change, not done (pm, 10-22).
    @Test func aSearchTurnsNextSendAndItsToolRounds() async throws {
        let rig = try Rig([Self.searchCall, Self.reply("ANSWER ONE"), Self.reply("ANSWER TWO")])
        defer { rig.restore() }
        await rig.send("what lives in a tide pool")
        await rig.send("and in winter?")
        let r = rig.requests
        try #require(r.count == 3)
        #expect(try Self.messages(r[1]).compactMap { $0["role"] as? String }.suffix(2) == ["assistant", "tool"])
        let fromRound = try Self.prefix(r[1], r[2])
        print("PREFIX-CASE search: R1→send2 \(try Self.prefix(r[0], r[2])); R2→send2 \(fromRound)")
        #expect(try Self.prefix(r[0], r[2]).holds)
        #expect(!fromRound.holds && fromRound.messageIndex == 2 && fromRound.role == "assistant")
    }

    /// (2) Think harder on a reply, then a plain follow-up: N is the think-harder request.
    @Test func aThinkHarderReplysNextSend() async throws {
        let rig = try Rig([Self.reply("FIRST"), Self.reply("HARDER"), Self.reply("NEXT")])
        defer { rig.restore() }
        await rig.send("why is the sea salty")
        try await rig.thinkHarder()
        await rig.send("and the dead sea?")
        let r = rig.requests
        try #require(r.count == 3)
        let result = try Self.prefix(r[1], r[2])
        print("PREFIX-CASE think-harder: \(result); original vs re-ask: \(try Self.prefix(r[0], r[1]))")
        #expect(result.holds, "\(result)")
        #expect(try !Self.messages(r[2]).contains { ($0["content"] as? String) == "FIRST" })
    }

    /// (3) Thinking. A `reasoning_content` field is never stored or resent. A cloud reply's inline
    /// `<think>` stays in the stored text for the display layer, so it is resent, the same bytes every time.
    @Test func aCloudReplysThinkingIsDroppedTheSameWayOnEverySend() async throws {
        let thinking = Self.sse([Self.event(["reasoning_content": "SECRET-FIELD-THOUGHT"]),
                                 Self.event(["content": "<think>INLINE-THOUGHT</think>ANSWER"], finish: "stop")])
        let rig = try Rig([thinking, Self.reply("TWO"), Self.reply("THREE")])
        defer { rig.restore() }
        await rig.send("first")
        await rig.send("second")
        await rig.send("third")
        let r = rig.requests
        try #require(r.count == 3)
        for body in r[1...] {
            #expect(!String(decoding: body, as: UTF8.self).contains("SECRET-FIELD-THOUGHT"))
        }
        let stored = try Self.messages(r[1])[2]["content"] as? String
        #expect(stored == (try Self.messages(r[2])[2]["content"] as? String))
        let result = try Self.prefix(r[1], r[2])
        print("PREFIX-CASE thinking: \(result); stored reply \(stored ?? "-")")
        #expect(result.holds, "\(result)")
    }
}

private final class ScriptedServer: URLProtocol {
    static let bodies = LockedBox<[Data]>([])
    static let script = LockedBox<[Data]>([])
    static func reset(_ s: [Data]) { bodies.value = []; script.value = s }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        }
        let index = Self.bodies.value.count
        Self.bodies.value.append(data)
        guard index < Self.script.value.count else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.script.value[index])
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
