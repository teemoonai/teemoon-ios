//
//  NRASService.swift
//  teemoon
//
//  Verifies the GPU attestation evidence (`nvidia_payload`) from a near.ai
//  model attestation against NVIDIA's Remote Attestation Service (NRAS) —
//  the same check near.ai's own verifier performs (model_verifier.check_gpu):
//
//  1. The payload's embedded nonce must equal the nonce teemoon sent with
//     the attestation request (freshness — the evidence was generated for
//     this request, not replayed).
//  2. POST the payload to NRAS; the response is [["JWT", <overall>], {per-GPU}].
//     The overall JWT's `x-nvidia-overall-att-result` claim must be true.
//
//  3. The overall JWT is ES384-signed by a key in NVIDIA's JWKS, its `iss`
//     is NRAS, it is inside nbf..exp, and its `eat_nonce` is our nonce
//     (nearai/inference-sdk utils/nvidia.py).
//
//  Fail-closed: unreachable NRAS, malformed payload/response, nonce
//  mismatch, or a false verdict all yield .failed (never silently green).
//

import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "nras")

/// Outcome of NVIDIA NRAS GPU attestation verification.
enum NRASVerification: Equatable, Sendable {
    /// NRAS verdict is PASS and the evidence nonce matches our request nonce.
    case verified
    /// A genuine NEGATIVE verdict — NVIDIA rejected the evidence, or the nonce
    /// didn't echo (possible replay). Adversarial: this is a HARD failure.
    case failed(String)
    /// The check couldn't be completed — NRAS unreachable, an unparseable/
    /// unrecognized response, no recorded nonce. Fail-closed (still degrades),
    /// but NOT adversarial: a network blip must never be branded tamper.
    case inconclusive(String)

    var isVerified: Bool { self == .verified }
    /// True only for a genuine negative verdict — drives the RED hard-failure
    /// tier. `.inconclusive` is soft (confirm-to-proceed), never hard.
    var isHardFailure: Bool { if case .failed = self { return true }; return false }
    /// Any non-verified, non-pending outcome — both degrade the session.
    var isUnverified: Bool { self != .verified }
    var reason: String? {
        switch self {
        case .failed(let s), .inconclusive(let s): return s
        case .verified: return nil
        }
    }
}

/// Minimal HTTP seam so tests can stub the NRAS response.
protocol NRASHTTPClient: Sendable {
    func post(_ url: URL, body: Data) async throws -> Data
}

struct URLSessionNRASHTTP: NRASHTTPClient {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func post(_ url: URL, body: Data) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// NVIDIA's signing keys. They rotate several times a day, so the live
/// source refetches on an unknown kid rather than pinning.
protocol NRASKeySource: Sendable {
    func jwks(refresh: Bool) async throws -> Data
}

actor LiveNRASKeys: NRASKeySource {
    static let shared = LiveNRASKeys()
    static let url = URL(string: "https://nras.attestation.nvidia.com/.well-known/jwks.json")!
    private var cached: (data: Data, at: Date)?

    func jwks(refresh: Bool) async throws -> Data {
        if !refresh, let cached, Date().timeIntervalSince(cached.at) < 3600 { return cached.data }
        let (data, response) = try await URLSession.shared.data(from: Self.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        cached = (data, Date())
        return data
    }
}

struct NRASService {
    let http: NRASHTTPClient
    let keys: NRASKeySource
    let now: @Sendable () -> Date

    static let endpoint = URL(string: "https://nras.attestation.nvidia.com/v3/attest/gpu")!
    static let issuer = "https://nras.attestation.nvidia.com"
    /// Clock skew allowed on nbf/exp.
    static let leeway: TimeInterval = 120

    init(http: NRASHTTPClient = URLSessionNRASHTTP(), keys: NRASKeySource = LiveNRASKeys.shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.keys = keys
        self.now = now
    }

    /// Verifies one `nvidia_payload` JSON string. `expectedNonceHex` is the
    /// nonce teemoon sent with the attestation request that returned this
    /// payload; without it freshness cannot be proven, so the check fails.
    func verify(payloadJSON: String, expectedNonceHex: String?) async -> NRASVerification {
        guard let payload = try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any],
              let payloadNonce = payload["nonce"] as? String else {
            return .inconclusive("GPU evidence payload unparseable")
        }
        guard let expectedNonceHex else {
            return .inconclusive("no request nonce recorded for GPU evidence")
        }
        guard payloadNonce.lowercased() == expectedNonceHex.lowercased() else {
            logger.warning("[nras] evidence nonce mismatch — possible replay")
            return .failed("GPU evidence nonce mismatch (possible replay)")
        }

        let responseData: Data
        do {
            responseData = try await http.post(Self.endpoint, body: Data(payloadJSON.utf8))
        } catch {
            logger.warning("[nras] unreachable: \(error)")
            return .inconclusive("NVIDIA attestation service unreachable")
        }

        guard let jwt = Self.overallJWT(responseData) else {
            return .inconclusive("unrecognized NRAS response")
        }
        if let problem = await checkToken(jwt, nonceHex: payloadNonce) { return problem }
        guard let verdict = Self.overallVerdict(responseData) else {
            return .inconclusive("unrecognized NRAS response")
        }
        guard verdict else {
            logger.warning("[nras] NVIDIA verdict: FAIL")
            return .failed("NVIDIA attestation verdict: FAIL")
        }
        logger.info("[nras] GPU attestation verified — verdict PASS, nonce matched")
        return .verified
    }

    /// nil when the overall token is authentic, fresh and ours; otherwise the verdict to return.
    func checkToken(_ jwt: String, nonceHex: String) async -> NRASVerification? {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3,
              let headerData = Self.base64URLDecode(segments[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = Self.decodeJWTClaims(jwt),
              let signature = Self.base64URLDecode(segments[2]) else {
            return .inconclusive("unrecognized NRAS token")
        }
        guard header["alg"] as? String == "ES384" else { return .failed("NRAS token is not ES384-signed") }
        guard let kid = header["kid"] as? String else { return .failed("NRAS token names no signing key") }
        guard claims["iss"] as? String == Self.issuer else { return .failed("NRAS token issuer is not NVIDIA") }
        guard let nonce = claims["eat_nonce"] as? String, nonce.lowercased() == nonceHex.lowercased() else {
            return .failed("NRAS token nonce mismatch (possible replay)")
        }
        guard let nbf = (claims["nbf"] as? NSNumber)?.doubleValue,
              let exp = (claims["exp"] as? NSNumber)?.doubleValue,
              claims["iat"] is NSNumber else { return .failed("NRAS token has no validity window") }
        let t = now().timeIntervalSince1970
        guard t + Self.leeway >= nbf, t - Self.leeway <= exp else { return .failed("NRAS token expired or not yet valid") }

        var key: P384.Signing.PublicKey?
        for refresh in [false, true] where key == nil {
            guard let data = try? await keys.jwks(refresh: refresh) else {
                return .inconclusive("NVIDIA signing keys unreachable")
            }
            key = Self.publicKey(kid: kid, jwks: data)
        }
        guard let key else { return .inconclusive("NRAS signing key \(kid) not in NVIDIA's key set") }
        guard let sig = try? P384.Signing.ECDSASignature(rawRepresentation: signature),
              key.isValidSignature(sig, for: Data("\(segments[0]).\(segments[1])".utf8)) else {
            logger.warning("[nras] token signature invalid")
            return .failed("NRAS token signature invalid")
        }
        return nil
    }

    static func publicKey(kid: String, jwks: Data) -> P384.Signing.PublicKey? {
        guard let obj = try? JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let list = obj["keys"] as? [[String: Any]],
              let jwk = list.first(where: { $0["kid"] as? String == kid }),
              jwk["kty"] as? String == "EC", jwk["crv"] as? String == "P-384",
              let x = (jwk["x"] as? String).flatMap(base64URLDecode), x.count == 48,
              let y = (jwk["y"] as? String).flatMap(base64URLDecode), y.count == 48 else { return nil }
        return try? P384.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    /// The overall JWT from `[["JWT", <token>], {per-GPU tokens}]`.
    static func overallJWT(_ responseData: Data) -> String? {
        guard let response = try? JSONSerialization.jsonObject(with: responseData) as? [Any] else { return nil }
        for element in response {
            if let pair = element as? [String], pair.count == 2, pair[0] == "JWT" { return pair[1] }
        }
        return nil
    }

    /// Extracts `x-nvidia-overall-att-result` from the overall JWT in an NRAS
    /// response (`[["JWT", <token>], {per-GPU tokens}]`).
    static func overallVerdict(_ responseData: Data) -> Bool? {
        guard let response = try? JSONSerialization.jsonObject(with: responseData) as? [Any] else { return nil }
        for element in response {
            guard let pair = element as? [String], pair.count == 2, pair[0] == "JWT" else { continue }
            guard let claims = decodeJWTClaims(pair[1]) else { return nil }
            switch claims["x-nvidia-overall-att-result"] {
            case let result as Bool: return result
            case let result as String: return result.uppercased() == "PASS" || result.lowercased() == "true"
            default: return nil
            }
        }
        return nil
    }

    /// Decodes a JWT's payload segment. Reads claims only; `checkToken` verifies.
    static func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
