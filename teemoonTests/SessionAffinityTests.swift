//
//  SessionAffinityTests.swift
//  teemoonTests
//
//  A chat's routing id survives a relaunch (Fireworks glm-5p3 / -flash,
//  2026-10-19: turn-2 cache hits 7/12 with the same id, 3/12 with a fresh one,
//  which is what a relaunch sent before). Each provider gets only its own
//  documented key.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Session affinity", .serialized)
@MainActor struct SessionAffinityTests {
    @Test func stablePerThreadAndDistinctAcrossThreads() {
        let a = UUID(), b = UUID()
        #expect(SessionAffinity.id(for: a) == SessionAffinity.id(for: a))
        #expect(SessionAffinity.id(for: a) != SessionAffinity.id(for: b))
        #expect(!SessionAffinity.id(for: a).contains(a.uuidString.lowercased()), "the thread id never shows")
    }

    /// Derived, not stored: the same secret gives the same id after a relaunch.
    @Test func theIdIsAKeyedHashOfTheThread() {
        let thread = UUID()
        let secret = Data(repeating: 7, count: 32), other = Data(repeating: 9, count: 32)
        let id = SessionAffinity.derive(threadID: thread, secret: secret)
        #expect(id == SessionAffinity.derive(threadID: thread, secret: secret))
        #expect(id != SessionAffinity.derive(threadID: thread, secret: other), "another install cannot reproduce it")
        #expect(id != SessionAffinity.derive(threadID: UUID(), secret: secret))
        #expect(id.count == 32 && id.allSatisfy(\.isHexDigit))
    }

    static func p(_ url: String) -> Provider { Provider(name: "p", endpoint: url, model: "m", requiresAPIKey: true) }

    @Test func eachProviderGetsItsOwnDocumentedKey() {
        #expect(SessionAffinity.header(for: Self.p("https://api.fireworks.ai/inference/v1")) == "x-session-affinity")
        #expect(SessionAffinity.header(for: Self.p("https://api.x.ai/v1")) == "x-grok-conv-id")
        #expect(SessionAffinity.header(for: Self.p("https://openrouter.ai/api/v1")) == "x-session-id")
        for url in ["https://cloud-api.near.ai/v1", "https://integrate.api.nvidia.com/v1",
                    "http://192.168.1.2:11434/v1", "https://api.openai.com/v1"] {
            #expect(SessionAffinity.header(for: Self.p(url)) == nil, "\(url)")
        }
    }

    @Test func theRequestCarriesItWhereDocumentedAndNowhereElse() async throws {
        let cases: [(String, String?)] = [("https://api.x.ai/v1", "x-grok-conv-id"),
                                          ("https://openrouter.ai/api/v1", "x-session-id"),
                                          ("https://api.fireworks.ai/inference/v1", "x-session-affinity"),
                                          ("https://integrate.api.nvidia.com/v1", nil)]
        for (url, header) in cases {
            HeaderCapturingProtocol.headers.value = [:]
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [HeaderCapturingProtocol.self]
            _ = try await HTTPTransport(provider: Self.p(url), apiKey: "k", teeContext: nil, tools: [],
                                        urlSession: URLSession(configuration: config), affinityID: "abc123")
                .runTurn(messages: [["role": "user", "content": "hi"]], includeTools: false, onPartialContent: { _ in })
            let sent = HeaderCapturingProtocol.headers.value
            for known in ["x-session-affinity", "x-grok-conv-id", "x-session-id"] {
                let value = sent.first { $0.key.lowercased() == known }?.value
                #expect(value == (known == header ? "abc123" : nil), "\(url) \(known)")
            }
        }
    }
}

private final class HeaderCapturingProtocol: URLProtocol {
    static let headers = LockedBox<[String: String]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.headers.value = request.allHTTPHeaderFields ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
