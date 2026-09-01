//
//  ConfidentialLanguageModelTests.swift
//  teemoonTests
//
//  Offline tests for the generation engine behind ConfidentialLanguageModel:
//  a stub URLProtocol plays the server, so streaming, the tool-call loop,
//  E2EE field encryption/decryption, and the decrypt-failure policy are all
//  exercised through the exact code path production uses.
//

import CryptoKit
import Foundation
import Testing
import ModelBackend
@testable import teemoon

// MARK: - Stub transport

/// One scripted exchange: inspect the Nth request, return a response.
private struct StubExchange: @unchecked Sendable {
    let contentType: String
    /// Builds the response body from the request (body already drained to Data).
    let respond: (URLRequest, Data) -> Data
}

private final class StubServer: URLProtocol {
    nonisolated(unsafe) static var exchanges: [StubExchange] = []
    nonisolated(unsafe) static var capturedBodies: [Data] = []
    nonisolated(unsafe) static var requestCount = 0
    static let lock = NSLock()

    static func reset(_ script: [StubExchange]) {
        lock.lock(); defer { lock.unlock() }
        exchanges = script
        capturedBodies = []
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body: Data = {
            if let data = request.httpBody { return data }
            guard let stream = request.httpBodyStream else { return Data() }
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            stream.open()
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: bufSize)
                if n > 0 { data.append(buf, count: n) } else { break }
            }
            stream.close()
            return data
        }()

        Self.lock.lock()
        let index = Self.requestCount
        Self.requestCount += 1
        Self.capturedBodies.append(body)
        let exchange = index < Self.exchanges.count ? Self.exchanges[index] : nil
        Self.lock.unlock()

        guard let exchange else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let responseBody = exchange.respond(request, body)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": exchange.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Helpers

private struct EchoTool: Tool {
    let name = "echo"
    let description = "Echoes the query back."

    @Generable
    struct Arguments {
        let query: String
    }

    func call(arguments: Arguments) async throws -> String {
        "echoed: \(arguments.query)"
    }
}

@MainActor
private func makeHarness(
    tools: [any Tool] = [],
    attestation: AttestationRecord? = nil,
    endpoint: String = "https://api.example.com/v1"
) -> (session: LanguageModelSession, results: LockedBox<[RequestResult]>) {
    let provider = Provider(name: "Stub", endpoint: endpoint, model: "stub-model")
    let results = LockedBox<[RequestResult]>([])
    let callbacks = StreamCallbacks(
        onSourcesFound: { _ in },
        onQueriesFound: { _ in },
        onToolExecutionEnded: {},
        onSuccess: { result in results.value = results.value + [result] }
    )
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubServer.self]
    let context = attestation.flatMap {
        TEEContext(provider: provider, apiKey: "test-key", attestation: $0)
    }
    let model = ConfidentialLanguageModel(
        provider: provider, apiKey: "test-key", priorMessages: [
            WireMessage(role: "system", content: "You are a test."),
        ],
        context: context, events: callbacks,
        urlSession: URLSession(configuration: config)
    )
    return (LanguageModelSession(model: model, tools: tools), results)
}

private func sseBody(_ events: [String]) -> Data {
    Data((events.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n").utf8)
}

private func contentEvent(_ text: String, id: String = "chatcmpl-test") -> String {
    let obj: [String: Any] = [
        "id": id, "object": "chat.completion.chunk",
        "choices": [["index": 0, "delta": ["content": text], "finish_reason": NSNull()]],
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
}

/// Attestation record with no signing addresses (verification short-circuits
/// offline) and the given model E2EE key.
private func makeAttestation(modelEd25519PubKey: Data?) -> AttestationRecord {
    AttestationRecord(
        composeHash: "test", mrtd: "test", osImageHash: "test", intelQuote: "",
        composeManifest: nil, gpuArch: nil, gpuNodeComposeHash: nil, modelFileHash: nil,
        signingAddress: nil, gpuSigningAddress: nil,
        modelEd25519PubKey: modelEd25519PubKey,
        quoteVerification: nil, gpuQuoteVerification: nil, modelQuoteVerification: nil,
        fetchedAt: Date(), providerID: UUID()
    )
}

// MARK: - Tests

@Suite("ConfidentialLanguageModel engine", .serialized)
struct ConfidentialLanguageModelTests {

    @Test @MainActor func plainStreaming_accumulatesContent() async throws {
        StubServer.reset([
            StubExchange(contentType: "text/event-stream") { _, _ in
                sseBody([contentEvent("Hello, "), contentEvent("world")])
            },
        ])
        let (session, results) = makeHarness()
        var finalText = ""
        for try await snapshot in session.streamResponse(to: "hi") {
            finalText = snapshot.content
        }
        #expect(finalText == "Hello, world")

        // Request body: system prompt + user prompt, stream flags, auth header.
        let body = try JSONSerialization.jsonObject(with: StubServer.capturedBodies[0]) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.map { $0["role"] as! String } == ["system", "user"])
        #expect(messages[1]["content"] as! String == "hi")
        #expect(body["stream"] as! Bool == true)
        #expect(body["model"] as! String == "stub-model")

        // onSuccess fires (from a detached task) with the response body.
        await waitFor(timeout: .seconds(3)) {
            !results.value.isEmpty
        }
        #expect(results.value.last?.responseBody == "Hello, world")
        #expect(results.value.last?.isE2EEActive == false)
    }

    @Test @MainActor func toolRound_executesAndChainsFollowUp() async throws {
        let toolCallEvent: String = {
            let obj: [String: Any] = [
                "id": "chatcmpl-tools", "object": "chat.completion.chunk",
                "choices": [[
                    "index": 0,
                    "delta": ["tool_calls": [[
                        "index": 0, "id": "call_1",
                        "function": ["name": "echo", "arguments": "{\"query\": \"ping\"}"],
                    ]]],
                    "finish_reason": NSNull(),
                ]],
            ]
            return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        }()
        let finishToolsEvent: String = {
            let obj: [String: Any] = [
                "id": "chatcmpl-tools", "object": "chat.completion.chunk",
                "choices": [["index": 0, "delta": [String: Any](), "finish_reason": "tool_calls"]],
            ]
            return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        }()

        StubServer.reset([
            StubExchange(contentType: "text/event-stream") { _, _ in
                sseBody([toolCallEvent, finishToolsEvent])
            },
            StubExchange(contentType: "text/event-stream") { _, _ in
                sseBody([contentEvent("Answer after tool")])
            },
        ])
        let (session, results) = makeHarness(tools: [EchoTool()])
        var finalText = ""
        for try await snapshot in session.streamResponse(to: "use the tool") {
            finalText = snapshot.content
        }
        #expect(finalText == "Answer after tool")
        #expect(StubServer.requestCount == 2)

        // Follow-up request carries the assistant tool_calls turn and the tool result.
        let followUp = try JSONSerialization.jsonObject(with: StubServer.capturedBodies[1]) as! [String: Any]
        let messages = followUp["messages"] as! [[String: Any]]
        let roles = messages.map { $0["role"] as! String }
        #expect(roles == ["system", "user", "assistant", "tool"])
        #expect(messages[3]["content"] as! String == "echoed: ping")
        #expect(messages[3]["tool_call_id"] as! String == "call_1")

        await waitFor(timeout: .seconds(3)) {
            results.value.contains { !$0.toolCalls.isEmpty }
        }
        let records = results.value.last?.toolCalls ?? []
        #expect(records.count == 1)
        #expect(records.first?.name == "echo")
        #expect(records.first?.result == "echoed: ping")
    }

    @Test @MainActor func e2ee_sealsRequestAndDecryptsResponse() async throws {
        // "Model" keypair: the attestation carries the Ed25519 public key.
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let modelXPrivate = try Ed25519ToX25519.privateKey(seed: modelEdKey.rawRepresentation)
        let attestation = makeAttestation(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        StubServer.reset([
            StubExchange(contentType: "text/event-stream") { request, body in
                // The request must carry E2EE headers and encrypted content.
                let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
                let messages = json["messages"] as! [[String: Any]]
                let userField = messages[1]["content"] as! String
                let decrypted = try! E2EEEnvelope.open(
                    wireFormat: try! Data(hexString: userField), privateKey: modelXPrivate
                )
                precondition(String(data: decrypted, encoding: .utf8) == "secret prompt",
                             "request content was not sealed for the model key")

                // Encrypt the reply to the client's key from the request header.
                let clientEdPub = try! Data(hexString: request.value(forHTTPHeaderField: "X-Client-Pub-Key")!)
                let clientXPub = try! Ed25519ToX25519.publicKey(edPub: clientEdPub)
                let sealed = try! E2EEEnvelope.seal(
                    plaintext: Data("encrypted answer".utf8), recipientPubKey: clientXPub
                ).hexString
                return sseBody([contentEvent(sealed)])
            },
        ])
        // near.ai endpoint so the provider has the E2EE capability path.
        let (session, results) = makeHarness(
            attestation: attestation, endpoint: "https://cloud-api.near.ai/v1"
        )
        var finalText = ""
        for try await snapshot in session.streamResponse(to: "secret prompt") {
            finalText = snapshot.content
        }
        #expect(finalText == "encrypted answer")

        await waitFor(timeout: .seconds(3)) {
            !results.value.isEmpty
        }
        #expect(results.value.last?.isE2EEActive == true)
    }

    @Test @MainActor func e2ee_decryptFailure_failsTheStream() async throws {
        // Security fix #3: ciphertext is never rendered as content — a field
        // that fails to decrypt fails the whole stream.
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let attestation = makeAttestation(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        StubServer.reset([
            StubExchange(contentType: "text/event-stream") { _, _ in
                // Valid hex, but not a valid envelope for the client's key.
                sseBody([contentEvent(Data(repeating: 0x42, count: 100).hexString)])
            },
        ])
        let (session, _) = makeHarness(
            attestation: attestation, endpoint: "https://cloud-api.near.ai/v1"
        )
        var thrown: Error?
        var yieldedText: String?
        do {
            for try await snapshot in session.streamResponse(to: "secret prompt") {
                yieldedText = snapshot.content
            }
        } catch {
            thrown = error
        }
        #expect(thrown != nil, "decrypt failure must fail the stream")
        #expect(yieldedText == nil || yieldedText?.isEmpty == true,
                "ciphertext must never be yielded as content")
        #expect((thrown as? LLMError)?.underlyingError is E2EEError)
    }

    @Test @MainActor func nonStreamingJSONResponse_isHandled() async throws {
        let responseJSON: [String: Any] = [
            "id": "chatcmpl-nonstream",
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": "full response"],
                "finish_reason": "stop",
            ]],
            "usage": ["completion_tokens": 7],
        ]
        StubServer.reset([
            StubExchange(contentType: "application/json") { _, _ in
                try! JSONSerialization.data(withJSONObject: responseJSON)
            },
        ])
        let (session, results) = makeHarness()
        var finalText = ""
        for try await snapshot in session.streamResponse(to: "hi") {
            finalText = snapshot.content
        }
        #expect(finalText == "full response")

        await waitFor(timeout: .seconds(3)) {
            !results.value.isEmpty
        }
        #expect(results.value.last?.outputTokens == 7)
    }

    @Test @MainActor func httpError_drainsBodyIntoLLMError() async throws {
        // StubServer always returns 200, so a dedicated 401 stub plays the server here.
        Stub401Server.body = Data(#"{"error": {"message": "invalid api key"}}"#.utf8)
        let provider = Provider(name: "Stub", endpoint: "https://api.example.com/v1", model: "stub-model")
        let callbacks = StreamCallbacks(
            onSourcesFound: { _ in }, onQueriesFound: { _ in }, onToolExecutionEnded: {},
            onSuccess: { _ in }
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub401Server.self]
        let model = ConfidentialLanguageModel(
            provider: provider, apiKey: "bad-key", priorMessages: [],
            events: callbacks, urlSession: URLSession(configuration: config)
        )
        let session = LanguageModelSession(model: model)
        var thrown: Error?
        do {
            for try await _ in session.streamResponse(to: "hi") {}
        } catch {
            thrown = error
        }
        #expect(thrown is LLMError)
        #expect((thrown as? LLMError)?.httpStatus == 401)
        #expect((thrown as? LLMError)?.userMessage.contains("invalid api key") == true)
    }
}

private final class Stub401Server: URLProtocol {
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
