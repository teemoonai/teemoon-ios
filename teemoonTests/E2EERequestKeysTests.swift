//
//  E2EERequestKeysTests.swift
//  teemoonTests
//
//  conformance/e2ee-request-keys.json: a sealed request never asks the proxy for a field it returns in plaintext.
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

@Suite("E2EE requests never ask for plaintext reply fields", .serialized)
struct E2EERequestKeysTests {
    struct Kit: Decodable {
        struct Extras: Decodable { let keys: [String] }
        let forbiddenKeys: [String]; let allowedPathSuffix: String; let extraParamsVectors: Extras
    }

    static func kit(file: String = #filePath) throws -> Kit? {
        guard TestFixture.sourceTreeAvailable() else { return nil }
        let url = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conformance/e2ee-request-keys.json")
        return try JSONDecoder().decode(Kit.self, from: Data(contentsOf: url))
    }

    static func keys(in value: Any) -> Set<String> {
        switch value {
        case let d as [String: Any]: Set(d.keys).union(d.values.flatMap { keys(in: $0) })
        case let a as [Any]: Set(a.flatMap { keys(in: $0) })
        default: []
        }
    }

    private func sealedRequest(effort: ReasoningEffort?, tools: Bool, image: Bool,
                               extras: [String: String] = [:]) async throws -> URLRequest? {
        SealedCapture.requests.value = []
        NearAIModelCatalog.seeTierListForTests()
        var provider = Provider(name: "near.ai", endpoint: "https://cloud-api.near.ai/v1", model: "z-ai/glm-5.3-flash")
        provider.extraParams = extras
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let peer = try E2EEPeer(modelEd25519PubKey: key)
        let record = AttestationRecord(
            composeHash: "t", mrtd: "t", osImageHash: "t", intelQuote: "", composeManifest: nil, gpuArch: nil,
            gpuNodeComposeHash: nil, modelFileHash: nil, signingAddress: nil, gpuSigningAddress: nil,
            modelEd25519PubKey: key, quoteVerification: nil, gpuQuoteVerification: nil, modelQuoteVerification: nil,
            fetchedAt: Date(), providerID: UUID())
        let context = TEEContext(baseURL: try #require(provider.openAIBaseURL), model: provider.model, apiKey: "k",
                                 attestation: record, gpuNodeURL: nil, e2eePeer: peer)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SealedCapture.self]
        let transport = HTTPTransport(provider: provider, apiKey: "k", teeContext: context,
                                      tools: tools ? [BraveWebSearchTool(apiKey: "b")] : [],
                                      urlSession: URLSession(configuration: config), effort: effort)
        let content: Any = image
            ? [["type": "text", "text": "what is this?"],
               ["type": "image_url", "image_url": ["url": "data:image/png;base64,iVBORw0KGgo="]]]
            : "hello"
        _ = try? await transport.runTurn(messages: [["role": "user", "content": content]], includeTools: tools,
                                         onPartialContent: { _ in })
        return SealedCapture.requests.value.first
    }

    @Test func noSealedRequestCarriesAPlaintextReplyField() async throws {
        guard let kit = try Self.kit() else { return }
        #expect(Self.keys(in: ["a": [["b": ["logprobs": 1]]]]).contains("logprobs"), "the walk sees nested keys")
        for effort in [nil, ReasoningEffort.fast, .thinkHarder] {
            for tools in [false, true] {
                for image in [false, true] {
                    let request = try #require(try await sealedRequest(effort: effort, tools: tools, image: image),
                                               "the sealed request reached the wire")
                    #expect(request.value(forHTTPHeaderField: "X-Encrypt-All-Fields") == "true", "precondition: sealed")
                    #expect(request.url?.path.hasSuffix(kit.allowedPathSuffix) == true, "\(request.url?.path ?? "")")
                    let body = try JSONSerialization.jsonObject(with: try #require(SealedCapture.body(of: request)))
                    let found = Self.keys(in: body).intersection(kit.forbiddenKeys)
                    #expect(found.isEmpty, "effort \(String(describing: effort)) tools \(tools) image \(image): \(found)")
                }
            }
        }
    }

    /// An image to a sealed model leaves the phone only inside the sealed content: the wire carries no data URL, no
    /// image part and none of the image's bytes (IMAGES.md §4; the sealer serializes text and image parts whole).
    @Test func aSealedImageNeverReachesTheWireInTheClear() async throws {
        let request = try #require(try await sealedRequest(effort: nil, tools: false, image: true),
                                   "the sealed request reached the wire")
        #expect(request.value(forHTTPHeaderField: "X-Encrypt-All-Fields") == "true", "precondition: sealed")
        let wire = String(decoding: try #require(SealedCapture.body(of: request)), as: UTF8.self)
        for clear in ["data:image", "image_url", "iVBORw0KGgo", "what is this?"] {
            #expect(!wire.contains(clear), "\(clear) went out in the clear")
        }
    }

    /// A place's extra parameters reach the body, so a sealed turn refuses before the wire when one asks for a
    /// plaintext reply field (latent on both platforms: no screen sets extras). The kit's list is the code's.
    @Test func aPlacesExtraParametersNeverAskForPlaintext() async throws {
        guard let kit = try Self.kit() else { return }
        #expect(Set(kit.extraParamsVectors.keys) == HTTPTransport.plaintextReplyKeys)
        #expect(Set(kit.forbiddenKeys).isSubset(of: HTTPTransport.plaintextReplyKeys))
        for key in kit.extraParamsVectors.keys {
            let request = try await sealedRequest(effort: nil, tools: false, image: false, extras: [key: "true"])
            #expect(request == nil, "\(key): refused before the wire")
        }
    }

    @Test func aSealedRequestOffChatCompletionsIsRefused() throws {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let codec = E2EEStreamCodec(peer: try E2EEPeer(modelEd25519PubKey: key))
        let provider = Provider(name: "near.ai", endpoint: "https://cloud-api.near.ai/v1", model: "z-ai/glm-5.3-flash")
        let transport = HTTPTransport(provider: provider, apiKey: "k", teeContext: nil, tools: [], urlSession: .shared)
        let body = Data(#"{"messages":[{"role":"user","content":"hi"}],"model":"m"}"#.utf8)
        for path in ["https://cloud-api.near.ai/v1/completions", "https://cloud-api.near.ai/v1/responses"] {
            var request = URLRequest(url: URL(string: path)!)
            #expect(throws: LLMError.self, "\(path)") {
                _ = try transport.e2eeSealedBody(body, codec: codec, endpoint: URL(string: path)!, request: &request)
            }
            #expect(request.value(forHTTPHeaderField: "X-Encrypt-All-Fields") == nil, "no E2EE headers on a refused request")
        }
        var ok = URLRequest(url: URL(string: "https://cloud-api.near.ai/v1/chat/completions")!)
        #expect(throws: Never.self) {
            _ = try transport.e2eeSealedBody(body, codec: codec, endpoint: URL(string: "https://cloud-api.near.ai/v1/chat/completions")!, request: &ok)
        }
    }

    @Test func noPresetCarriesAPlaintextReplyField() {
        for preset in Provider.presets {
            #expect(Set(preset.extraParams.keys).isDisjoint(with: HTTPTransport.plaintextReplyKeys), "\(preset.name)")
        }
    }
}

private final class SealedCapture: URLProtocol, @unchecked Sendable {
    static let requests = LockedBox<[URLRequest]>([])
    static func body(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var copy = request
        copy.httpBody = Self.body(of: request)
        Self.requests.value.append(copy)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}
