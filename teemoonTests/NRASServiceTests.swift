//
//  NRASServiceTests.swift
//  teemoonTests
//
//  NVIDIA NRAS GPU attestation, exercised against a REAL captured round trip
//  (Fixtures/nras_gpu_attestation.json: a live near.ai nvidia_payload, the
//  nonce it was requested with, and NVIDIA's actual response — verdict PASS
//  for four attested GPUs).
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

@Suite("NRASService")
struct NRASServiceTests {

    struct Fixture: Decodable {
        let requestNonce: String
        let nvidiaPayload: String
        let nrasResponse: [AnyJSON]
        let jwks: AnyJSON
        let verifiedAt: Double

        enum CodingKeys: String, CodingKey {
            case requestNonce = "request_nonce"
            case nvidiaPayload = "nvidia_payload"
            case nrasResponse = "nras_response"
            case jwks
            case verifiedAt = "verified_at"
        }

        var jwksData: Data { (try? JSONEncoder().encode(jwks)) ?? Data() }

        /// The service as it ran at capture time, against the captured key set.
        func service(response: Data?, jwks: Data? = nil, at: Double? = nil) -> NRASService {
            let when = Date(timeIntervalSince1970: at ?? verifiedAt)
            return NRASService(http: StubHTTP(response: response), keys: StaticKeys(data: jwks ?? jwksData), now: { when })
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

    struct StaticKeys: NRASKeySource {
        let data: Data?
        struct Unreachable: Error {}
        func jwks(refresh: Bool) async throws -> Data { guard let data else { throw Unreachable() }; return data }
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
        let service = fixture.service(response: fixture.responseData)
        let result = await service.verify(
            payloadJSON: fixture.nvidiaPayload, expectedNonceHex: fixture.requestNonce)
        #expect(result == .verified)
    }

    @Test func nonceMismatch_failsBeforeContactingNRAS() async throws {
        let fixture = try Self.loadFixture()
        // Unreachable stub: a nonce mismatch must fail without any HTTP call.
        let service = fixture.service(response: nil)
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
        let service = fixture.service(response: fixture.responseData)
        let result = await service.verify(payloadJSON: fixture.nvidiaPayload, expectedNonceHex: nil)
        #expect(!result.isVerified)
    }

    @Test func unreachableNRAS_failsClosedButSoft() async throws {
        let fixture = try Self.loadFixture()
        let service = fixture.service(response: nil)
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

    /// The claim flip that used to read as NVIDIA's FAIL now breaks the ES384 signature first.
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
        let service = fixture.service(response: response)
        let result = await service.verify(
            payloadJSON: fixture.nvidiaPayload, expectedNonceHex: fixture.requestNonce)
        guard case .failed(let reason) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.contains("signature"))
    }

    @Test func malformedResponse_rejected() async throws {
        let fixture = try Self.loadFixture()
        let service = fixture.service(response: Data("{}".utf8))
        let result = await service.verify(
            payloadJSON: fixture.nvidiaPayload, expectedNonceHex: fixture.requestNonce)
        #expect(!result.isVerified)
    }

    // MARK: token checks (1.0.6)

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// A token signed by a throwaway key, with that key as the only JWKS entry.
    static func minted(claims: [String: Any], alg: String = "ES384") throws -> (response: Data, jwks: Data) {
        let key = P384.Signing.PrivateKey()
        let header = b64url(try JSONSerialization.data(withJSONObject: ["alg": alg, "kid": "test-kid"]))
        let body = b64url(try JSONSerialization.data(withJSONObject: claims))
        let sig = b64url(try key.signature(for: Data("\(header).\(body)".utf8)).rawRepresentation)
        let x963 = key.publicKey.x963Representation
        let jwk: [String: Any] = ["kty": "EC", "crv": "P-384", "kid": "test-kid",
                                  "x": b64url(x963.subdata(in: 1..<49)), "y": b64url(x963.subdata(in: 49..<97))]
        return (Data(#"[["JWT","\#(header).\#(body).\#(sig)"]]"#.utf8),
                try JSONSerialization.data(withJSONObject: ["keys": [jwk]]))
    }

    static func claims(_ f: Fixture, nonce: String? = nil, iss: String = NRASService.issuer) -> [String: Any] {
        let t = Int(f.verifiedAt)
        return ["iss": iss, "eat_nonce": nonce ?? f.requestNonce, "iat": t - 60, "nbf": t - 60, "exp": t + 3600,
                "x-nvidia-overall-att-result": true]
    }

    @Test func mintedToken_verifies() async throws {
        let f = try Self.loadFixture()
        let m = try Self.minted(claims: Self.claims(f))
        #expect(await f.service(response: m.response, jwks: m.jwks).verify(payloadJSON: f.nvidiaPayload, expectedNonceHex: f.requestNonce) == .verified)
    }

    @Test func tokenForAnotherNonce_failsHard() async throws {
        let f = try Self.loadFixture()
        let m = try Self.minted(claims: Self.claims(f, nonce: String(repeating: "ab", count: 32)))
        let r = await f.service(response: m.response, jwks: m.jwks).verify(payloadJSON: f.nvidiaPayload, expectedNonceHex: f.requestNonce)
        #expect(r.isHardFailure && r.reason?.contains("nonce") == true, "\(r)")
    }

    @Test func tokenFromAnotherIssuer_failsHard() async throws {
        let f = try Self.loadFixture()
        let m = try Self.minted(claims: Self.claims(f, iss: "https://evil.example"))
        let r = await f.service(response: m.response, jwks: m.jwks).verify(payloadJSON: f.nvidiaPayload, expectedNonceHex: f.requestNonce)
        #expect(r.isHardFailure && r.reason?.contains("issuer") == true, "\(r)")
    }

    @Test func nonES384Token_failsHard() async throws {
        let f = try Self.loadFixture()
        let m = try Self.minted(claims: Self.claims(f), alg: "none")
        let r = await f.service(response: m.response, jwks: m.jwks).verify(payloadJSON: f.nvidiaPayload, expectedNonceHex: f.requestNonce)
        #expect(r.isHardFailure, "\(r)")
    }

    @Test func realToken_expiredAnHourLater() async throws {
        let f = try Self.loadFixture()
        let r = await f.service(response: f.responseData, at: f.verifiedAt + 2 * 3600)
            .verify(payloadJSON: f.nvidiaPayload, expectedNonceHex: f.requestNonce)
        #expect(r.isHardFailure && r.reason?.contains("expired") == true, "\(r)")
    }

    @Test func realToken_unknownKeyIsInconclusive() async throws {
        let f = try Self.loadFixture()
        let r = await f.service(response: f.responseData, jwks: Data(#"{"keys":[]}"#.utf8))
            .verify(payloadJSON: f.nvidiaPayload, expectedNonceHex: f.requestNonce)
        guard case .inconclusive = r else { Issue.record("expected inconclusive, got \(r)"); return }
    }

    @Test func realToken_keysUnreachableIsInconclusive() async throws {
        let f = try Self.loadFixture()
        let svc = NRASService(http: StubHTTP(response: f.responseData), keys: StaticKeys(data: nil),
                              now: { Date(timeIntervalSince1970: f.verifiedAt) })
        let r = await svc.verify(payloadJSON: f.nvidiaPayload, expectedNonceHex: f.requestNonce)
        guard case .inconclusive = r else { Issue.record("expected inconclusive, got \(r)"); return }
    }

    @Test func overallVerdict_parsesRealResponse() throws {
        let fixture = try Self.loadFixture()
        #expect(NRASService.overallVerdict(fixture.responseData) == true)
    }
}
