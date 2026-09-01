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
//  Trust model (matches the reference verifier): the verdict is trusted via
//  TLS to nras.attestation.nvidia.com — the JWT's own signature is not
//  independently verified against NVIDIA's JWKS.
//
//  Fail-closed: unreachable NRAS, malformed payload/response, nonce
//  mismatch, or a false verdict all yield .failed (never silently green).
//

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

struct NRASService {
    let http: NRASHTTPClient

    static let endpoint = URL(string: "https://nras.attestation.nvidia.com/v3/attest/gpu")!

    init(http: NRASHTTPClient = URLSessionNRASHTTP()) {
        self.http = http
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

    /// Decodes a JWT's payload segment (base64url, no signature verification —
    /// see the trust-model note in the header).
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
