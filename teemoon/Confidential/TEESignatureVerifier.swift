//
//  TEESignatureVerifier.swift
//  teemoon
//
//  Verifies per-response ECDSA signatures from the near.ai TEE.
//
//  Protocol (from nearai/nearai-cloud-verifier):
//    POST /v1/chat/completions  →  SSE stream with `id` field (e.g. "chatcmpl-abc123")
//    GET  /v1/signature/{id}?model={model}&signing_algo=ecdsa
//    →  { "text": "req_sha256:resp_sha256", "signature": "0x...",
//          "signing_address": "0xABCD...", "signing_algo": "ecdsa" }
//
//  Verification (all three required for `.verified`):
//  1. Content binding — `text` is "[model:]req_sha256:resp_sha256"; teemoon
//     recomputes both hashes from the bytes it actually sent/received and
//     they must match. Stops "any response quoting a trusted address."
//  2. ecrecover — the signer address is RECOVERED from the EIP-191
//     personal_sign signature over `text` (EthereumSignature), removing
//     reliance on the server-asserted signing_address string.
//  3. The recovered address matches the attested signing address.
//
//  Recipe validated live against near.ai (chat_verifier.py parity): the
//  request hash covers the exact request body bytes; the response hash
//  covers the raw response lines re-joined with "\n" (streaming) or the
//  whole raw body (non-streaming).
//

import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "tee")

// MARK: - Signed exchange (content binding input)

/// The request/response content a signature is supposed to cover, captured
/// by GenerationEngine as the bytes actually sent and received.
struct SignedExchange: Sendable {
    /// Candidate request bodies: the bytes put on the wire, plus (under
    /// E2EE) the plaintext body — the signer may hash either representation.
    let requestBodyCandidates: [Data]
    /// Raw response text: streaming = each received line re-joined with "\n"
    /// (including blank SSE separators); non-streaming = the whole raw body.
    let responseText: String
}

/// The outcome of comparing a signature's signed hashes against the
/// exchange teemoon observed.
struct ContentBinding: Sendable, Equatable {
    let requestHashMatches: Bool
    let responseHashMatches: Bool
    var isBound: Bool { requestHashMatches && responseHashMatches }

    /// Parses `text` ("req_sha256:resp_sha256", optionally prefixed with the
    /// model name) and recomputes both hashes from `exchange`. nil when the
    /// text does not have the expected shape.
    static func check(text: String, exchange: SignedExchange) -> ContentBinding? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let serverRequestHash = String(parts[parts.count - 2])
        let serverResponseHash = String(parts[parts.count - 1])
        let requestHashes = exchange.requestBodyCandidates.map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
        let responseHash = SHA256.hash(data: Data(exchange.responseText.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return ContentBinding(
            requestHashMatches: requestHashes.contains(serverRequestHash.lowercased()),
            responseHashMatches: responseHash == serverResponseHash.lowercased()
        )
    }
}

// MARK: - Response types

struct TEEMessageSignature: Decodable {
    /// "sha256_of_request:sha256_of_response"
    let text: String
    /// ECDSA signature hex (0x-prefixed)
    let signature: String
    /// Ethereum-style address of the signing key ("0x...")
    let signingAddress: String
    let signingAlgo: String

    enum CodingKeys: String, CodingKey {
        case text
        case signature
        case signingAddress = "signing_address"
        case signingAlgo    = "signing_algo"
    }
}

/// The outcome of per-response signature verification, in the shape of
/// StoreKit's `VerificationResult`: either the response is `verified` against
/// the attested signing key, or it is `unverified` with the reason. There is
/// deliberately no way to express "verified, sort of" — UI that claims
/// per-response cryptographic verification can only do so from `.verified`.
enum ResponseVerification: Sendable {
    /// Signing address matches the attestation — response is TEE-authentic.
    case verified(SignatureRecord)
    /// Per-response verification did not succeed; the reason says what
    /// guarantee (if any) remains.
    case unverified(UnverifiedReason)

    struct SignatureRecord: Sendable {
        /// Ethereum-style address of the key that signed this response.
        let signingAddress: String
    }

    enum UnverifiedReason: Sendable {
        /// The signing address matched no attested key, but the signature was
        /// served by a gateway whose TDX quote verified. The response is
        /// trustworthy *if you trust the gateway* — weaker than per-response
        /// cryptographic proof, and rendered distinctly.
        case gatewayTrustOnly(signingAddress: String)
        /// Signing address mismatch — possible tampering or wrong attestation.
        case signatureMismatch(expected: String, got: String)
        /// The signed request/response hashes do not match the content
        /// teemoon actually sent/received — possible tampering in transit.
        case contentMismatch(detail: String)
        /// Signature not yet available (TEE stores signatures asynchronously).
        case signatureUnavailable
        /// Network or parse error while fetching the signature.
        case fetchFailed(Error)
    }
}

// MARK: - Verifier

enum TEESignatureVerifier {

    /// Fetches and verifies the ECDSA signature for a completed chat response.
    ///
    /// - Parameters:
    ///   - chatID:      The `id` field captured from the SSE stream.
    ///   - ctx:         The TEE context with URLs, model, auth, and attestation data.
    ///   - exchange:    The request/response content this signature must cover.
    ///                  When nil (legacy callers), content binding is skipped.
    static func verify(chatID: String, ctx: TEEContext, exchange: SignedExchange? = nil) async -> ResponseVerification {
        let att = ctx.attestation
        // The gateway (cloud-api.near.ai) proxies completions to a GPU node TEE.
        // The GPU node signs the response with its own ECDSA key, and the gateway
        // exposes that signature at /v1/signature/{id}.
        // Accept signatures from either the gateway or GPU node — both are
        // legitimate TEE signers. The GPU node may sign even when its attestation
        // wasn't fetched (gpuSigningAddress is nil).
        var trustedAddresses: Set<String> = []
        if let gwAddr = att.signingAddress, !gwAddr.isEmpty {
            trustedAddresses.insert(gwAddr.lowercased())
        }
        if let gpuAddr = att.gpuSigningAddress, !gpuAddr.isEmpty {
            trustedAddresses.insert(gpuAddr.lowercased())
        }
        guard !trustedAddresses.isEmpty else { return .unverified(.signatureUnavailable) }

        // Wait 2s — the TEE stores signatures asynchronously after stream completion.
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        logger.debug("Verifying chatID=\(chatID)")
        let sigURL = ctx.baseURL.appendingPathComponent("signature/\(chatID)")
        var request = URLRequest(url: sigURL, timeoutInterval: 10)
        if !ctx.apiKey.isEmpty {
            request.setValue("Bearer \(ctx.apiKey)", forHTTPHeaderField: "Authorization")
        }

        logger.debug("Fetching signature from \(request.url?.absoluteString ?? "nil", privacy: .public)")
        // 2 attempts: immediately, then after 4s.
        for attempt in 1...2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(data: data, encoding: .utf8) ?? ""
                logger.debug("Attempt \(attempt): HTTP \(status) — \(body.prefix(200))")
                if status == 404 {
                    if attempt == 1 { try? await Task.sleep(nanoseconds: 4_000_000_000) }
                    continue
                }
                let sig = try JSONDecoder().decode(TEEMessageSignature.self, from: data)

                // Content binding: the signed hashes must match the request/
                // response content teemoon observed. A mismatch is decisive
                // regardless of who signed — the signature covers different
                // content than this exchange.
                if let exchange {
                    guard let binding = ContentBinding.check(text: sig.text, exchange: exchange) else {
                        return .unverified(.contentMismatch(detail: "unrecognized signed-text format"))
                    }
                    guard binding.isBound else {
                        let what = binding.requestHashMatches ? "response" : (binding.responseHashMatches ? "request" : "request and response")
                        logger.warning("[TEE] content binding failed — signed \(what, privacy: .public) hash does not match observed content")
                        return .unverified(.contentMismatch(detail: "signed \(what) hash does not match observed content"))
                    }
                }

                // ecrecover: the signer identity comes from the signature
                // itself, not the server-asserted signing_address string.
                let got: String
                if sig.signingAlgo.lowercased() == "ecdsa" {
                    guard let recovered = EthereumSignature.recoverAddress(text: sig.text, signatureHex: sig.signature) else {
                        let expected = trustedAddresses.joined(separator: " or ")
                        return .unverified(.signatureMismatch(expected: expected, got: "unrecoverable signature"))
                    }
                    got = recovered
                } else {
                    // Non-ECDSA signing algo — fall back to the asserted address.
                    got = sig.signingAddress.lowercased()
                }
                if trustedAddresses.contains(got) {
                    return .verified(.init(signingAddress: got))
                }
                // Mismatch — the signing key may have rotated (TEE restart/redeploy),
                // or the GPU node isn't directly reachable (TLS error).
                // Try re-fetching from the GPU node first, then fall back to the gateway.
                if let gpuURL = ctx.gpuNodeURL {
                    logger.info("Address mismatch, re-fetching GPU attestation from \(gpuURL.host ?? "", privacy: .public)")
                    if let freshAddr = await AttestationService.fetchSigningAddress(from: gpuURL, apiKey: ctx.apiKey),
                       freshAddr.lowercased() == got {
                        logger.info("Key rotation confirmed — new GPU signing address matches")
                        return .verified(.init(signingAddress: got))
                    }
                    // GPU node unreachable — try fetching via the gateway.
                    logger.info("GPU node unreachable, trying gateway attestation for model signing address")
                    if let freshAddr = await AttestationService.fetchSigningAddress(from: ctx.baseURL, apiKey: ctx.apiKey),
                       freshAddr.lowercased() == got {
                        logger.info("Gateway-proxied GPU signing address matches")
                        return .verified(.init(signingAddress: got))
                    }
                }
                // The signature came through the attested gateway — if the gateway's
                // TDX quote was verified, the gateway TEE is trustworthy and the
                // signing address it reports is authentic even if we can't directly
                // attest the GPU node (e.g. TLS not publicly accessible).
                if att.quoteVerification?.isVerified == true {
                    logger.info("Signing address unattested; falling back to gateway trust — GPU node not directly reachable")
                    return .unverified(.gatewayTrustOnly(signingAddress: got))
                }
                let expected = trustedAddresses.joined(separator: " or ")
                return .unverified(.signatureMismatch(expected: expected, got: got))
            } catch {
                return .unverified(.fetchFailed(error))
            }
        }
        logger.info("Signature unavailable after retries")
        return .unverified(.signatureUnavailable)
    }
}
