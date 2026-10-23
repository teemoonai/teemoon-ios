//
//  StreamStallTests.swift
//  teemoonTests
//
//  NVIDIA's free endpoint held glm-5.3-flash 253–282 s before headers
//  (2026-10-19, internal curl runs), so a 240 s request timeout failed requests
//  that were only queued. The wait for headers is long; a stream that stops
//  after headers still ends.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Stream stall", .serialized)
struct StreamStallTests {

    @Test func theWatchdogFiresOnlyAfterTheLimitSinceTheLastByte() {
        let clock = LockedBox(Date(timeIntervalSince1970: 0))
        let dog = StreamStallWatchdog(limit: 240, now: { clock.value })
        clock.value = Date(timeIntervalSince1970: 239)
        #expect(!dog.check())
        dog.touch()
        clock.value = Date(timeIntervalSince1970: 239 + 239)
        #expect(!dog.check())
        clock.value = Date(timeIntervalSince1970: 239 + 240)
        #expect(dog.check())
        #expect(dog.didFire)
    }

    @Test func theWaitForHeadersOutlastsAQueuedFreeTierModel() async throws {
        #expect(StreamStallWatchdog.headerWait >= 600)
        #expect(URLSession.chat.configuration.timeoutIntervalForRequest >= 600)
        StallingSSEProtocol.reset(stallAfterFirstLine: false)
        _ = try await Self.transport(streamIdle: 5).runTurn(
            messages: [["role": "user", "content": "hi"]], includeTools: false, onPartialContent: { _ in })
        #expect(StallingSSEProtocol.seenTimeout.value >= 600)
    }

    @Test(.timeLimit(.minutes(1))) func aStreamThatStopsAfterHeadersTimesOut() async throws {
        StallingSSEProtocol.reset(stallAfterFirstLine: true)
        var partial = ""
        var thrown: Error?
        let started = Date()
        do {
            _ = try await Self.transport(streamIdle: 0.4).runTurn(
                messages: [["role": "user", "content": "hi"]], includeTools: false,
                onPartialContent: { partial = $0 })
        } catch { thrown = error }
        #expect((thrown as? URLError)?.code == .timedOut)
        #expect(partial == "Hel")
        #expect(Date().timeIntervalSince(started) < 10)
    }

    static func transport(streamIdle: TimeInterval) -> HTTPTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StallingSSEProtocol.self]
        return HTTPTransport(
            provider: Provider(name: "Stall", endpoint: "https://stall.invalid/v1", model: "m"),
            apiKey: "k", teeContext: nil, tools: [],
            urlSession: URLSession(configuration: config), streamIdle: streamIdle)
    }
}

private final class StallingSSEProtocol: URLProtocol {
    nonisolated(unsafe) static var stallAfterFirstLine = false
    static let seenTimeout = LockedBox<TimeInterval>(0)

    static func reset(stallAfterFirstLine: Bool) {
        self.stallAfterFirstLine = stallAfterFirstLine
        seenTimeout.value = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seenTimeout.value = request.timeoutInterval
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let first = #"data: {"choices":[{"delta":{"content":"Hel"}}]}"# + "\n\n"
        client?.urlProtocol(self, didLoad: Data(first.utf8))
        guard !Self.stallAfterFirstLine else { return }
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
