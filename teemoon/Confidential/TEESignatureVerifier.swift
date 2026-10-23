//
//  TEESignatureVerifier.swift
//  teemoon
//
//  Verifies per-response signatures from near.ai.
//
//  Protocol (nearai/inference-sdk core/chat.py):
//    GET /v1/signature/{id}?model={model}&signing_algo=ed25519|ecdsa
//    →  { "text", "signature", "signing_address", "signing_algo",
//         "signature_kind": "provider_tee" | "gateway" }
//
//  `.verified` needs all of: the exact text for the kind (provider_tee
//  carries the request's model prefix, gateway does not); the signer
//  recovered (ecdsa) or checked (ed25519) from the signature itself; and
//  that signer being a model-node key bound to its quote's report_data.
//  A gateway signature is at most `.gatewayTrustOnly`.
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
    /// Absent on older servers; the SDK reads absent as `provider_tee`.
    let signatureKind: String?

    enum Kind: String { case providerTEE = "provider_tee", gateway, unknown }

    var kind: Kind { Kind(rawValue: (signatureKind ?? "provider_tee").lowercased()) ?? .unknown }

    enum CodingKeys: String, CodingKey {
        case text
        case signature
        case signingAddress = "signing_address"
        case signingAlgo    = "signing_algo"
        case signatureKind  = "signature_kind"
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
        /// A valid `gateway`-kind signature by the attested, quote-bound
        /// gateway key. Proves the gateway relayed these bytes, not that the
        /// model wrote them; rendered distinctly, never as verified.
        case gatewayTrustOnly(signingAddress: String)
        /// A valid model-node signature whose key is not bound to a quote
        /// (no GPU quote, or report_data does not carry the address).
        case signerUnattested(signingAddress: String)
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

    /// Fetches the signature for a completed chat response and evaluates it.
    /// Asks for ed25519 first when the model key is attested: a model-node
    /// signature then checks against the key the model quote binds. A
    /// gateway signature is refetched as ecdsa, the only gateway key attested.
    static func verify(chatID: String, ctx: TEEContext, exchange: SignedExchange? = nil) async -> ResponseVerification {
        let att = ctx.attestation
        let attestedSigners = [att.signingAddress, att.gpuSigningAddress].compactMap { $0 }.filter { !$0.isEmpty }
        guard !attestedSigners.isEmpty || att.modelEd25519PubKey != nil else { return .unverified(.signatureUnavailable) }
        guard let exchange else { return .unverified(.contentMismatch(detail: "no captured exchange to bind")) }

        // Wait 2s — the TEE stores signatures asynchronously after stream completion.
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let first = att.modelEd25519PubKey != nil ? "ed25519" : "ecdsa"
        var fetched = await fetch(chatID: chatID, ctx: ctx, algo: first)
        if case .success(let sig) = fetched, sig.kind == .gateway, sig.signingAlgo.lowercased() != "ecdsa" {
            fetched = await fetch(chatID: chatID, ctx: ctx, algo: "ecdsa")
        }
        switch fetched {
        case .success(let sig): return evaluate(sig, attestation: att, exchange: exchange)
        case .failure(let verdict): return verdict
        }
    }

    private enum Fetched { case success(TEEMessageSignature), failure(ResponseVerification) }

    private static func fetch(chatID: String, ctx: TEEContext, algo: String) async -> Fetched {
        guard var components = URLComponents(url: ctx.baseURL.appendingPathComponent("signature/\(chatID)"),
                                             resolvingAgainstBaseURL: false) else {
            return .failure(.unverified(.signatureUnavailable))
        }
        components.queryItems = [URLQueryItem(name: "model", value: ctx.model),
                                 URLQueryItem(name: "signing_algo", value: algo)]
        guard let sigURL = components.url else { return .failure(.unverified(.signatureUnavailable)) }
        var request = URLRequest(url: sigURL, timeoutInterval: 10)
        if !ctx.apiKey.isEmpty {
            request.setValue("Bearer \(ctx.apiKey)", forHTTPHeaderField: "Authorization")
        }

        // 2 attempts: immediately, then after 4s.
        for attempt in 1...2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                logger.debug("Attempt \(attempt): HTTP \(status) algo=\(algo, privacy: .public)")
                if status == 404 {
                    if attempt == 1 { try? await Task.sleep(nanoseconds: 4_000_000_000) }
                    continue
                }
                // A 2xx `{error_code, message}` envelope is "not available", not a parse failure.
                guard let sig = try? JSONDecoder().decode(TEEMessageSignature.self, from: data) else {
                    if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_code"] != nil {
                        return .failure(.unverified(.signatureUnavailable))
                    }
                    return .failure(.unverified(.fetchFailed(URLError(.cannotParseResponse))))
                }
                return .success(sig)
            } catch {
                return .failure(.unverified(.fetchFailed(error)))
            }
        }
        logger.info("Signature unavailable after retries")
        return .failure(.unverified(.signatureUnavailable))
    }

    /// Pure verdict for one signature. `.verified` only for a model-node
    /// (`provider_tee`) signature whose signer is a key bound to its quote;
    /// a gateway signature is never more than `.gatewayTrustOnly`. Never
    /// trust `signing_address` without checking the signature against it.
    static func evaluate(_ sig: TEEMessageSignature, attestation att: AttestationRecord,
                         exchange: SignedExchange) -> ResponseVerification {
        let kind = sig.kind
        guard kind != .unknown else {
            return .unverified(.signatureMismatch(expected: "a provider_tee or gateway signature",
                                                  got: "signature_kind \(sig.signatureKind ?? "")"))
        }
        if let mismatch = SignedText.mismatch(text: sig.text, kind: kind, exchange: exchange) {
            logger.warning("[TEE] content binding failed — \(mismatch, privacy: .public)")
            return .unverified(.contentMismatch(detail: mismatch))
        }

        let signer: String
        switch sig.signingAlgo.lowercased() {
        case "ecdsa":
            guard let recovered = EthereumSignature.recoverAddress(text: sig.text, signatureHex: sig.signature) else {
                return .unverified(.signatureMismatch(expected: "a valid ecdsa signature", got: "unrecoverable signature"))
            }
            signer = recovered
        case "ed25519":
            // Only the model's Ed25519 key is attested (and quote-bound); a
            // gateway Ed25519 key never is.
            guard kind == .providerTEE, let key = att.modelEd25519PubKey, key.count == 32,
                  att.e2eeKeyBoundToModelTEE == true,
                  sig.signingAddress.lowercased() == key.hexString,
                  Ed25519Signature.isValid(text: sig.text, signatureHex: sig.signature, publicKey: key) else {
                return .unverified(.signatureMismatch(expected: "a valid ed25519 signature by the attested model key",
                                                      got: sig.signingAddress.lowercased()))
            }
            return .verified(.init(signingAddress: key.hexString))
        default:
            return .unverified(.signatureMismatch(expected: "ecdsa or ed25519",
                                                  got: "unsupported signing_algo \(sig.signingAlgo)"))
        }

        switch kind {
        case .providerTEE:
            if let model = att.gpuSigningAddress?.lowercased(), signer == model,
               att.gpuSigningKeyBoundToHardware == true {
                return .verified(.init(signingAddress: signer))
            }
            if att.gpuSigningKeyBoundToHardware != true, att.gpuSigningAddress?.lowercased() == signer {
                return .unverified(.signerUnattested(signingAddress: signer))
            }
            return .unverified(.signatureMismatch(expected: att.gpuSigningAddress?.lowercased() ?? "an attested model key",
                                                  got: signer))
        case .gateway:
            if let gw = att.signingAddress?.lowercased(), signer == gw,
               att.signingKeyBoundToHardware == true, att.quoteVerification?.isVerified == true {
                return .unverified(.gatewayTrustOnly(signingAddress: signer))
            }
            return .unverified(.signatureMismatch(expected: att.signingAddress?.lowercased() ?? "an attested gateway key",
                                                  got: signer))
        case .unknown:
            return .unverified(.signatureMismatch(expected: "a known signature_kind", got: "unknown"))
        }
    }
}

/// The exact text each signature kind must sign (near.ai inference-sdk
/// `core/chat.py`): `provider_tee` = "<request model>:<req sha256>:<resp sha256>",
/// `gateway` = "<req sha256>:<resp sha256>". Compared whole, never split.
enum SignedText {
    static func expected(kind: TEEMessageSignature.Kind, exchange: SignedExchange) -> [String] {
        let resp = sha256Hex(Data(exchange.responseText.utf8))
        return exchange.requestBodyCandidates.compactMap { body in
            let req = sha256Hex(body)
            switch kind {
            case .gateway: return "\(req):\(resp)"
            case .providerTEE:
                guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let model = obj["model"] as? String, !model.isEmpty else { return nil }
                return "\(model):\(req):\(resp)"
            case .unknown: return nil
            }
        }
    }

    /// nil when `text` is exactly what `kind` must sign for this exchange.
    static func mismatch(text: String, kind: TEEMessageSignature.Kind, exchange: SignedExchange) -> String? {
        if expected(kind: kind, exchange: exchange).contains(text) { return nil }
        guard let binding = ContentBinding.check(text: text, exchange: exchange) else {
            return "unrecognized signed-text format"
        }
        if binding.isBound { return "signed text has the wrong prefix for a \(kind.rawValue) signature" }
        let what = binding.requestHashMatches ? "response" : (binding.responseHashMatches ? "request" : "request and response")
        return "signed \(what) hash does not match observed content"
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum Ed25519Signature {
    static func isValid(text: String, signatureHex: String, publicKey: Data) -> Bool {
        let hex = signatureHex.hasPrefix("0x") ? String(signatureHex.dropFirst(2)) : signatureHex
        guard let sig = try? Data(hexString: hex), sig.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(sig, for: Data(text.utf8))
    }
}
