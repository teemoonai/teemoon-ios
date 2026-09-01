//
//  NRASServiceTests.swift
//  teemoonTests
//
//  NVIDIA NRAS GPU attestation, exercised against a REAL captured round trip
//  (Fixtures/nras_gpu_attestation.json: a live near.ai nvidia_payload, the
//  nonce it was requested with, and NVIDIA's actual response — verdict PASS
//  for four attested GPUs).
//

import Foundation
import Testing
@testable import teemoon

@Suite("NRASService")
struct NRASServiceTests {

    struct Fixture: Decodable {
        let requestNonce: String
        let nvidiaPayload: String
        let nrasResponse: [AnyJSON]

        enum CodingKeys: String, CodingKey {
            case requestNonce = "request_nonce"
            case nvidiaPayload = "nvidia_payload"
            case nrasResponse = "nras_response"
        }

        /// Raw response bytes as NVIDIA sent them (re-encoded from the fixture).
        var responseData: Data {
            (try? JSONEncoder().encode(nrasResponse)) ?? Data()
        }
    }

    /// Minimal JSON passthrough so the fixture's heterogeneous NRAS response
    /// array ([["JWT", token], {per-GPU dict}]) survives decode/encode.
    enum AnyJSON: Codable {
        case string(String)
        case array([AnyJSON])
        case object([String: AnyJSON])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) { self = .string(s) }
            else if let a = try? container.decode([AnyJSON].self) { self = .array(a) }
            else { self = .object(try container.decode([String: AnyJSON].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let s): try container.encode(s)
            case .array(let a): try container.encode(a)
            case .object(let o): try container.encode(o)
            }
        }
    }

    static func loadFixture(file: String = #filePath) throws -> Fixture {
        let data = try TestFixture.data("nras_gpu_attestation.json", file: file)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    struct StubHTTP: NRASHTTPClient {
        var response: Data?

        struct Unreachable: Error {}

        func post(_ url: URL, body: Data) async throws -> Data {
            guard let response else { throw Unreachable() }
            return response
        }
    }

    @Test func realEvidence_verifies() async throws {
        let fixture = try Self.loadFixture()
        let service = NRASService(http: StubHTTP(response: fixture.responseData))
        let result = await service.verify(
            payloadJSON: fixture.nvidiaPayload, expectedNonceHex: fixture.requestNonce)
        #expect(result == .verified)
    }

    @Test func nonceMismatch_failsBeforeContactingNRAS() async throws {
        let fixture = try Self.loadFixture()
        // Unreachable stub: a nonce mismatch must fail without any HTTP call.
        let service = NRASService(http: StubHTTP(response: nil))
        let result = await service.verify(
            payloadJSON: fixture.nvidiaPayload,
            expectedNonceHex: String(repeating: "00", count: 32))
        guard case .failed(let reason) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.contains("nonce"))
    }

    @Test func missingRecordedNonce_failsClosed() async throws {
        let fixture = try Self.loadFixture()
        let service = NRASService(http: StubHTTP(response: fixture.responseData))
        let result = await service.verify(payloadJSON: fixture.nvidiaPayload, expectedNonceHex: nil)
        #expect(!result.isVerified)
    }

    @Test func unreachableNRAS_failsClosedButSoft() async throws {
        let fixture = try Self.loadFixture()
        let service = NRASService(http: StubHTTP(response: nil))
        let result = await service.verify(
            payloadJSON: fixture.nvidiaPayload, expectedNonceHex: fixture.requestNonce)
        // Unreachable NRAS fails CLOSED (degrades the session)…
        #expect(result.isUnverified)
        // …but is NOT a hard/adversarial failure — a network blip must never be
        // branded a GPU-attestation tamper with a no-bypass block.
        #expect(!result.isHardFailure)
        guard case .inconclusive(let reason) = result else {
            Issue.record("expected .inconclusive, got \(result)"); return
        }
        #expect(reason.contains("unreachable"))
    }

    @Test func failVerdict_rejected() async throws {
        let fixture = try Self.loadFixture()
        // Flip the overall verdict claim to false and re-encode the JWT
        // payload segment (the signature is not checked — TLS trust model).
        guard case .array(let pair) = fixture.nrasResponse[0],
              case .string(let jwt) = pair[1] else {
            Issue.record("unexpected fixture shape"); return
        }
        var claims = try #require(NRASService.decodeJWTClaims(jwt))
        claims["x-nvidia-overall-att-result"] = false
        let claimsData = try JSONSerialization.data(withJSONObject: claims)
        let claimsB64url = claimsData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let segments = jwt.split(separator: ".")
        let tampered = "\(segments[0]).\(claimsB64url).\(segments[2])"
        let response = Data(#"[["JWT","\#(tampered)"]]"#.utf8)
        let service = NRASService(http: StubHTTP(response: response))
        let result = await service.verify(
            payloadJSON: fixture.nvidiaPayload, expectedNonceHex: fixture.requestNonce)
        guard case .failed(let reason) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.contains("FAIL"))
    }

    @Test func malformedResponse_rejected() async throws {
        let fixture = try Self.loadFixture()
        let service = NRASService(http: StubHTTP(response: Data("{}".utf8)))
        let result = await service.verify(
            payloadJSON: fixture.nvidiaPayload, expectedNonceHex: fixture.requestNonce)
        #expect(!result.isVerified)
    }

    @Test func overallVerdict_parsesRealResponse() throws {
        let fixture = try Self.loadFixture()
        #expect(NRASService.overallVerdict(fixture.responseData) == true)
    }
}
