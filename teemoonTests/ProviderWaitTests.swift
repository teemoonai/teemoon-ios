//
//  ProviderWaitTests.swift
//  teemoonTests
//
//  Fireworks held requests 2–69 s before headers and NVIDIA's free tier
//  4–5 min (2026-10-19), with "thinking..." on screen the whole time. The
//  chip now says the request is waiting on the provider, and only that.
//

import Foundation
import Testing
import ModelBackend
@testable import teemoon

@Suite("Provider wait", .serialized)
struct ProviderWaitTests {

    @Test func shownOnlyFromTheThresholdAndCountsThisRequest() {
        let sent = Date(timeIntervalSince1970: 100)
        let wait = ProviderWait(turn: 1, sentAt: sent, providerName: "fireworks")
        #expect(wait.shownSeconds(at: sent.addingTimeInterval(4.9)) == nil)
        #expect(wait.shownSeconds(at: sent.addingTimeInterval(5)) == 5)
        #expect(wait.shownSeconds(at: sent.addingTimeInterval(69.7)) == 69)
    }

    @Test func theLabelClaimsNoQueue() {
        let label = ProviderWait.label(providerName: "nvidia", seconds: 42)
        #expect(label == "waiting for nvidia... 42s")
        #expect(!label.contains("queue") && !label.contains("busy"))
    }

    /// Each request of a search turn gets its own wait, cleared by its own headers.
    @Test func everyRequestOfAToolTurnWaitsAfresh() async throws {
        final class TwoRequests: GenerationTransport, @unchecked Sendable {
            let calls = LockedBox(0)
            func runTurn(messages: [[String: Any]], includeTools: Bool,
                         onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
                Issue.record("the engine must call the headers-aware entry point")
                return TurnOutput(content: "")
            }
            func runTurn(messages: [[String: Any]], includeTools: Bool,
                         onResponse: @escaping @Sendable () -> Void,
                         onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
                calls.value += 1
                try await Task.sleep(for: .milliseconds(30))
                onResponse()
                if calls.value == 1 {
                    var call = ToolCallState(); call.id = "c1"; call.name = "web_search"
                    call.arguments = #"{"query":"q"}"#
                    return TurnOutput(content: "", toolCalls: [0: call])
                }
                onPartialContent("Done.")
                return TurnOutput(content: "Done.")
            }
        }
        let edges = LockedBox<[(Int, Bool)]>([])
        var callbacks = StreamCallbacks(onSourcesFound: { _ in }, onQueriesFound: { _ in },
                                        onToolExecutionEnded: {}, onSuccess: { _ in })
        callbacks.onAwaitingResponse = { turn, sentAt in edges.value = edges.value + [(turn, sentAt != nil)] }
        try await GenerationEngine(events: callbacks, tools: [NoopSearch()], initialMessages: [],
                                   prompt: "hi", transport: TwoRequests()).run { _ in }
        let opened = edges.value.filter(\.1).map(\.0)
        #expect(opened == [1, 2], "got \(edges.value)")
        for turn in [1, 2] {
            let open = try #require(edges.value.firstIndex { $0 == (turn, true) })
            let close = try #require(edges.value.firstIndex { $0 == (turn, false) })
            #expect(open < close)
        }
    }

    /// On-device has no network wait: the default entry point clears it at once.
    @Test func aTransportWithoutHeadersNeverWaits() async throws {
        final class Local: GenerationTransport, @unchecked Sendable {
            let edgesAtStart: @Sendable () -> Int
            init(edgesAtStart: @escaping @Sendable () -> Int) { self.edgesAtStart = edgesAtStart }
            let seen = LockedBox(-1)
            func runTurn(messages: [[String: Any]], includeTools: Bool,
                         onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
                seen.value = edgesAtStart()
                onPartialContent("Hi.")
                return TurnOutput(content: "Hi.")
            }
        }
        let edges = LockedBox<[(Int, Bool)]>([])
        var callbacks = StreamCallbacks(onSourcesFound: { _ in }, onQueriesFound: { _ in },
                                        onToolExecutionEnded: {}, onSuccess: { _ in })
        callbacks.onAwaitingResponse = { turn, sentAt in edges.value = edges.value + [(turn, sentAt != nil)] }
        let local = Local { edges.value.count }
        try await GenerationEngine(events: callbacks, tools: [], initialMessages: [],
                                   prompt: "hi", transport: local).run { _ in }
        #expect(local.seen.value == 2, "opened and cleared before any work: \(edges.value)")
    }

    @Test func httpReportsHeadersBeforeTheFirstText() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OneLineSSEProtocol.self]
        let transport = HTTPTransport(
            provider: Provider(name: "Wait", endpoint: "https://wait.invalid/v1", model: "m"),
            apiKey: "k", teeContext: nil, tools: [], urlSession: URLSession(configuration: config))
        let order = LockedBox<[String]>([])
        _ = try await transport.runTurn(
            messages: [["role": "user", "content": "hi"]], includeTools: false,
            onResponse: { order.value = order.value + ["headers"] },
            onPartialContent: { _ in if !order.value.contains("text") { order.value = order.value + ["text"] } })
        #expect(order.value == ["headers", "text"])
    }
}

private struct NoopSearch: Tool {
    let name = "web_search"
    let description = "Search the web."
    @Generable struct Arguments: Sendable {
        @Guide(description: "The search query.")
        var query: String
    }
    func call(arguments: Arguments) async throws -> String { "nothing" }
}

private final class OneLineSSEProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let line = #"data: {"choices":[{"delta":{"content":"Hi"}}]}"# + "\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(line.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
