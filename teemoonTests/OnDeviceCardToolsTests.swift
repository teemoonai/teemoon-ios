//
//  OnDeviceCardToolsTests.swift
//  teemoonTests
//
//  The maintainer, 2026-10-22: Gemma 4 E2B's card said "tools-offered: 1" but showed no tool.
//  The on-device card's request body carries the tools in the cloud card's shape.
//

import Foundation
import Testing
@testable import teemoon

@Suite("The on-device card shows the tools", .serialized)
struct OnDeviceCardToolsTests {

    private let messages: [[String: Any]] = [["role": "system", "content": "persona"],
                                             ["role": "user", "content": "What's the weather in Paris?"]]

    @Test func aTurnWithSearchShowsTheToolAsTheCloudSendsIt() async throws {
        let tool = BraveWebSearchTool(apiKey: "b")
        let card = try #require(LiteRTTransport.prettyRequest(messages, tools: [tool]))
        let shown = try #require(try JSONSerialization.jsonObject(with: Data(card.utf8)) as? [String: Any])
        #expect(Set(shown.keys) == ["messages", "tools"])
        let tools = try #require(shown["tools"] as? [[String: Any]])
        #expect(tools.count == 1, "one per tool offered, as tools-offered counts them")
        let fn = try #require(tools.first?["function"] as? [String: Any])
        #expect(tools.first?["type"] as? String == "function")
        #expect(fn["name"] as? String == "web_search")
        #expect((fn["description"] as? String)?.isEmpty == false)
        #expect((fn["parameters"] as? [String: Any])?["properties"] != nil)

        // The same JSON a cloud request carries for the same tool.
        CardCapture.bodies.value = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CardCapture.self]
        let cloud = HTTPTransport(provider: Provider(name: "p", endpoint: "https://api.fireworks.ai/inference/v1", model: "m"),
                                  apiKey: "k", teeContext: nil, tools: [tool],
                                  urlSession: URLSession(configuration: config))
        _ = try? await cloud.runTurn(messages: messages, includeTools: true, onPartialContent: { _ in })
        let sent = try #require(CardCapture.bodies.value.first)
        let wire = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let wireTools = try #require(wire["tools"])
        let sorted: (Any) throws -> Data = { try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
        #expect(try sorted(tools) == sorted(wireTools))
    }

    @Test func aTurnWithoutToolsShowsNoToolsKey() throws {
        let card = try #require(LiteRTTransport.prettyRequest(messages, tools: []))
        #expect(card == LiteRTTransport.prettyMessages(messages), "unchanged from before")
        #expect(!card.contains("\"tools\""))
    }

    @Test func theMessagesAreUnchanged() throws {
        let card = try #require(LiteRTTransport.prettyRequest(messages, tools: [BraveWebSearchTool(apiKey: "")]))
        let shown = try #require(try JSONSerialization.jsonObject(with: Data(card.utf8)) as? [String: Any])
        let sorted: (Any) throws -> Data = { try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
        let shownMessages = try #require(shown["messages"])
        #expect(try sorted(shownMessages) == sorted(messages))
    }
}

private final class CardCapture: URLProtocol {
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
