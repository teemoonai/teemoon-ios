//
//  XAIRequestShapeTests.swift
//  teemoonTests
//
//  The maintainer, 2026-10-19: Grok must never search server-side — xAI's search is a
//  plaintext exfiltration path we cannot audit; web search is Brave, run by
//  the app. So an xAI request carries no `search_parameters`, no xAI server
//  tools, and only our own function tools.
//

import Foundation
import Testing
@testable import teemoon
import AnyLanguageModel

@Suite("xAI request shape", .serialized)
struct XAIRequestShapeTests {

    @Test func aGrokTurnWithSearchOnAsksForNoServerSideSearch() async throws {
        CapturingProtocol.bodies.value = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingProtocol.self]
        let provider = Provider(name: "xAI", endpoint: "https://api.x.ai/v1", model: "grok-4.7", requiresAPIKey: true)
        let transport = HTTPTransport(provider: provider, apiKey: "k", teeContext: nil,
                                      tools: [BraveWebSearchTool(apiKey: "b")],
                                      urlSession: URLSession(configuration: config), effort: .fast)
        _ = try? await transport.runTurn(messages: [["role": "user", "content": "news today"]],
                                         includeTools: true, onPartialContent: { _ in })
        let body = try #require(CapturingProtocol.bodies.value.first)
        #expect(Set(body.keys).isSubset(of: ["model", "messages", "stream", "stream_options", "tools", "reasoning_effort"]),
                "\(body.keys.sorted())")
        #expect(body["search_parameters"] == nil)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(!tools.isEmpty)
        for tool in tools {
            #expect(tool["type"] as? String == "function", "no xAI server-side tool (web_search / x_search)")
        }
        #expect(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String } == ["web_search"])
    }
}

private final class CapturingProtocol: URLProtocol {
    static let bodies = LockedBox<[[String: Any]]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        }
        if let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { Self.bodies.value.append(body) }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
