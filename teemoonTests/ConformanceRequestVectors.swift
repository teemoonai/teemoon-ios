//
//  ConformanceRequestVectors.swift
//  teemoonTests
//
//  Stable request bytes: a chat request body is a pure function of the turn, so
//  a provider's prompt cache can match it. The maintainer, TestFlight 57: unsorted keys
//  gave the tools a new order on every send and the second send cached 0.
//

import Foundation
import Testing
@testable import teemoon

/// Two consecutive sends of one chat, through the production `HTTPTransport`, with
/// web_search offered. The tool's date is fixed after capture so generation stays
/// byte-stable; both bodies carry the same date, so the prefix relation is unchanged.
struct RequestVectors: Encodable {
    let rule: String
    let turn1Messages: [[String: String]]
    let turn2Messages: [[String: String]]
    let turn1Body: String
    let turn2Body: String
    /// Bytes `turn1Body` and `turn2Body` share. It ends at the last shared message:
    /// turn 1's next byte closes `messages`, turn 2's opens the next message.
    let commonPrefixBytes: Int
}

enum ConformanceRequestVectors {
    static let rule = """
        A chat request body is a pure function of the turn: JSON with sorted keys and no \
        per-request values. Sending the same history twice gives identical bytes, and send \
        N+1's body extends send N's byte-for-byte through the last message they share.
        """
    static let fixedDay = "Thursday, October 22, 2026"
    static let turn1: [[String: String]] = [
        ["role": "system", "content": "You are a concise assistant."],
        ["role": "user", "content": "What is a tide pool?\n\n[Sent at 9:41 AM]"],
    ]
    static let turn2: [[String: String]] = turn1 + [
        ["role": "assistant", "content": "A shallow pool of seawater left among rocks at low tide."],
        ["role": "user", "content": "Name three animals that live in one.\n\n[Sent at 9:42 AM]"],
    ]

    static func requests() async throws -> RequestVectors {
        let b1 = try await body(for: turn1)
        let b2 = try await body(for: turn2)
        return RequestVectors(rule: rule, turn1Messages: turn1, turn2Messages: turn2,
                              turn1Body: b1, turn2Body: b2, commonPrefixBytes: commonPrefix(b1, b2))
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(Array(a.utf8), Array(b.utf8)).prefix { $0 == $1 }.count
    }

    /// One send's body as `HTTPTransport` puts it on the wire, today's date fixed.
    static func body(for messages: [[String: String]]) async throws -> String {
        RequestCapture.bodies.value = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RequestCapture.self]
        let provider = Provider(name: "Fireworks", endpoint: "https://api.fireworks.ai/inference/v1",
                                model: "accounts/fireworks/models/glm-5p3-flash", requiresAPIKey: true)
        let transport = HTTPTransport(provider: provider, apiKey: "k", teeContext: nil,
                                      tools: [BraveWebSearchTool(apiKey: "b")],
                                      urlSession: URLSession(configuration: config), effort: .fast)
        _ = try? await transport.runTurn(messages: messages, includeTools: true, onPartialContent: { _ in })
        let raw = try #require(RequestCapture.bodies.value.first)
        let day = DateFormatter()
        day.dateFormat = "EEEE, MMMM d, yyyy"   // BraveWebSearchTool's own format
        let today = day.string(from: Date())
        return String(decoding: raw, as: UTF8.self).replacingOccurrences(of: today, with: fixedDay)
    }
}

@Suite("Conformance vectors — request bytes", .serialized)
struct ConformanceRequestBytesTests {

    @Test func theSameTurnIsTheSameBytes() async throws {
        let a = try await ConformanceRequestVectors.body(for: ConformanceRequestVectors.turn2)
        let b = try await ConformanceRequestVectors.body(for: ConformanceRequestVectors.turn2)
        #expect(a == b)
        let parsed = try JSONSerialization.jsonObject(with: Data(a.utf8))
        #expect(Data(a.utf8) == (try JSONSerialization.data(withJSONObject: parsed, options: .sortedKeys)))
    }

    @Test func theNextSendExtendsThisOneThroughTheLastSharedMessage() async throws {
        let v = try await ConformanceRequestVectors.requests()
        let one = Array(v.turn1Body.utf8), two = Array(v.turn2Body.utf8)
        #expect(one[v.commonPrefixBytes] == UInt8(ascii: "]"), "turn 1 closes messages here")
        #expect(two[v.commonPrefixBytes] == UInt8(ascii: ","), "turn 2 opens its next message here")
        let lastShared = try #require(v.turn1Messages.last?["content"])
        let escaped = String(decoding: try JSONSerialization.data(withJSONObject: [lastShared]), as: UTF8.self).dropFirst().dropLast()
        #expect(String(decoding: two[..<v.commonPrefixBytes], as: UTF8.self).contains(escaped))
        #expect(v.turn1Body.contains(ConformanceRequestVectors.fixedDay), "the tool's date is fixed in the fixture")
    }

    @Test func theCommittedFixtureMatchesProduction() async throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let url = ConformanceEmitTests.outputDirectory().appendingPathComponent("requests.json")
        let committed = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let vectors = try #require(committed?["vectors"] as? [String: Any])
        let fresh = try await ConformanceRequestVectors.requests()
        #expect(vectors["turn1Body"] as? String == fresh.turn1Body)
        #expect(vectors["turn2Body"] as? String == fresh.turn2Body)
        #expect(vectors["commonPrefixBytes"] as? Int == fresh.commonPrefixBytes)
    }
}

private final class RequestCapture: URLProtocol {
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
