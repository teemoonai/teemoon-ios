//
//  ReplyEndTransportTests.swift
//  teemoonTests
//
//  How a remote turn ended, as the transport saw it (reply-machine.json G4, G5): finish_reason length and a stream
//  that closed without [DONE] are cut short, never complete; a sealed reasoning field that does not decrypt is a
//  decrypt failure, never the reply.
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

@Suite("How a remote turn ended", .serialized)
struct ReplyEndTransportTests {

    private func transport(_ body: String, sse: Bool, sealed: Bool = false) throws -> HTTPTransport {
        CannedReplyProtocol.body = body
        CannedReplyProtocol.contentType = sse ? "text/event-stream" : "application/json"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CannedReplyProtocol.self]
        let provider = Provider(name: "p", endpoint: "https://reply-end.invalid/v1", model: "m")
        var context: TEEContext?
        if sealed {
            let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
            let record = AttestationRecord(
                composeHash: "test", mrtd: "test", osImageHash: "test", intelQuote: "",
                composeManifest: nil, gpuArch: nil, gpuNodeComposeHash: nil, modelFileHash: nil,
                signingAddress: nil, gpuSigningAddress: nil, modelEd25519PubKey: key,
                quoteVerification: nil, gpuQuoteVerification: nil, modelQuoteVerification: nil,
                fetchedAt: Date(), providerID: UUID())
            context = TEEContext(baseURL: try #require(provider.openAIBaseURL), model: provider.model, apiKey: "k",
                                 attestation: record, gpuNodeURL: nil, e2eePeer: try E2EEPeer(modelEd25519PubKey: key))
        }
        return HTTPTransport(provider: provider, apiKey: "k", teeContext: context, tools: [],
                             urlSession: URLSession(configuration: config))
    }

    private func run(_ t: HTTPTransport) async throws -> TurnOutput {
        try await t.runTurn(messages: [["role": "user", "content": "hi"]], includeTools: false, onPartialContent: { _ in })
    }

    private func sse(_ events: [String], done: Bool) -> String {
        events.map { "data: \($0)\n\n" }.joined() + (done ? "data: [DONE]\n\n" : "")
    }

    @Test func finishLengthIsCutShort() async throws {
        let body = sse([#"{"choices":[{"delta":{"content":"An essay that"}}]}"#,
                        #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#], done: true)
        let out = try await run(try transport(body, sse: true))
        #expect(out.content == "An essay that")
        #expect(out.finish == .length)
    }

    @Test func contentFilterIsCutShort() async throws {
        let body = sse([#"{"choices":[{"delta":{"content":"Part"}}]}"#,
                        #"{"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#], done: true)
        #expect(try await run(try transport(body, sse: true)).finish == .contentFilter)
    }

    @Test func eofWithoutDoneOrFinishReasonEndedWithoutDone() async throws {
        let body = sse([#"{"choices":[{"delta":{"content":"The answer is"}}]}"#], done: false)
        let out = try await run(try transport(body, sse: true))
        #expect(out.content == "The answer is")
        #expect(out.finish == .endedWithoutDone)
    }

    @Test func finishStopWithoutDoneIsStop() async throws {
        let body = sse([#"{"choices":[{"delta":{"content":"Done."}}]}"#,
                        #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#], done: false)
        #expect(try await run(try transport(body, sse: true)).finish == .stop)
    }

    @Test func doneWithNoFinishReasonIsNone() async throws {
        let body = sse([#"{"choices":[{"delta":{"content":"Ok"}}]}"#], done: true)
        #expect(try await run(try transport(body, sse: true)).finish == TurnEnd.none)
    }

    @Test func nonStreamingLengthIsCutShort() async throws {
        let body = #"{"choices":[{"message":{"role":"assistant","content":"Half"},"finish_reason":"length"}]}"#
        #expect(try await run(try transport(body, sse: false)).finish == .length)
    }

    /// G5: a sealed non-streaming reply whose reasoning does not decrypt and whose content is empty used to hand
    /// the ciphertext on as the reasoning, which the engine then showed as the reply.
    @Test func undecryptableReasoningIsADecryptFailure() async throws {
        let body = #"{"id":"c1","choices":[{"message":{"role":"assistant","content":"","reasoning_content":"zz-not-ciphertext"},"finish_reason":"stop"}]}"#
        var thrown: Error?
        var output: TurnOutput?
        do { output = try await run(try transport(body, sse: false, sealed: true)) } catch { thrown = error }
        #expect(output == nil, "returned reasoning: \(output?.reasoning ?? "")")
        #expect((thrown as? LLMError)?.underlyingError as? E2EEError == .decryptionFailed)
    }
}

private final class CannedReplyProtocol: URLProtocol {
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var contentType = "text/event-stream"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": Self.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
