//
//  SignatureVerdictTests.swift
//  teemoonTests
//
//  TEESignatureVerifier.evaluate against two real captures:
//  nearai_signed_response.json (a provider_tee ecdsa signature with the model
//  prefix) and nearai_gateway_signed_response.json (2026-10-19: a plaintext
//  request, answered with signature_kind=gateway in both ecdsa and ed25519).
//
//  Before 1.0.6 the verifier returned .verified for any non-ecdsa signature on
//  the server-asserted address, counted the gateway's key as a model signer,
//  and accepted a "key rotation" address read from an unverified report. Each
//  of those has a negative test here.
//

import CryptoKit
import Foundation
import Testing
import TDXQuoteVerifier
@testable import teemoon

@Suite("Signature verdict")
struct SignatureVerdictTests {

    // MARK: Fixtures

    struct ModelCapture: Decodable {
        let bodyJson: String
        let lines: [String]
        let sig: [String: String]
        enum CodingKeys: String, CodingKey { case bodyJson = "body_json", lines, sig }
        var exchange: SignedExchange {
            SignedExchange(requestBodyCandidates: [Data(bodyJson.utf8)],
                           responseText: lines.map { $0 + "\n" }.joined())
        }
    }

    struct GatewayCapture: Decodable {
        let bodyJson: String
        let responseText: String
        let gatewayEcdsaAddress: String
        let gatewayEd25519Key: String
        let sigEcdsa: [String: String]
        let sigEd25519: [String: String]
        enum CodingKeys: String, CodingKey {
            case bodyJson = "body_json", responseText = "response_text"
            case gatewayEcdsaAddress = "gateway_ecdsa_address", gatewayEd25519Key = "gateway_ed25519_key"
            case sigEcdsa = "sig_ecdsa", sigEd25519 = "sig_ed25519"
        }
        var exchange: SignedExchange {
            SignedExchange(requestBodyCandidates: [Data(bodyJson.utf8)], responseText: responseText)
        }
    }

    static func model(file: String = #filePath) throws -> ModelCapture {
        try JSONDecoder().decode(ModelCapture.self, from: TestFixture.data("nearai_signed_response.json", file: file))
    }

    static func gateway(file: String = #filePath) throws -> GatewayCapture {
        try JSONDecoder().decode(GatewayCapture.self, from: TestFixture.data("nearai_gateway_signed_response.json", file: file))
    }

    static func signature(_ fields: [String: String], _ overrides: [String: String?] = [:]) throws -> TEEMessageSignature {
        var f = fields
        for (k, v) in overrides { f[k] = v }
        return try JSONDecoder().decode(TEEMessageSignature.self, from: JSONSerialization.data(withJSONObject: f))
    }

    static func quote(reportData: Data) -> TDXVerificationResult {
        let zero48 = Data(count: 48)
        let body = TDXQuote.TDReportBody(
            teeTcbSvn: Data(count: 16), mrSeam: zero48, mrSignerSeam: zero48,
            seamAttributes: Data(count: 8), tdAttributes: Data(count: 8), xfam: Data(count: 8),
            mrtd: zero48, mrConfigID: zero48, mrOwner: zero48, mrOwnerConfig: zero48,
            rtmr0: zero48, rtmr1: zero48, rtmr2: zero48, rtmr3: zero48, reportData: reportData)
        let quote = TDXQuote(
            header: TDXQuote.Header(version: 4, attestationKeyType: 2, teeType: 0x81,
                                    qeVendorID: Data(count: 16), userData: Data(count: 20)),
            body: body,
            signature: TDXQuote.SignatureData(
                ecdsaSignature: Data(count: 64), attestationPublicKey: Data(count: 64),
                certificateChainPEM: [], rawCertificationData: Data()))
        return TDXVerificationResult(quote: quote, measurements: TDXMeasurements(from: body),
                                     signatureValid: true, certChainValid: true, certChainError: nil)
    }

    /// report_data carrying `prefix` (an address or key) in its first bytes.
    static func reportData(_ prefix: Data) -> Data {
        var d = Data(count: 64)
        d.replaceSubrange(0..<prefix.count, with: prefix)
        return d
    }

    static func hex(_ s: String) -> Data {
        (try? Data(hexString: s.hasPrefix("0x") ? String(s.dropFirst(2)) : s)) ?? Data()
    }

    static func record(gateway: String? = nil, gatewayBound: Bool = true,
                       gpu: String? = nil, gpuBound: Bool = true,
                       modelKey: Data? = nil, modelKeyBound: Bool = true) -> AttestationRecord {
        AttestationRecord(
            composeHash: "", mrtd: "", osImageHash: "", intelQuote: "",
            composeManifest: nil, gpuArch: nil, gpuNodeComposeHash: nil, modelFileHash: nil,
            signingAddress: gateway, gpuSigningAddress: gpu, modelEd25519PubKey: modelKey,
            quoteVerification: gateway.map { quote(reportData: reportData(gatewayBound ? hex($0) : Data(count: 20))) },
            gpuQuoteVerification: gpu.map { quote(reportData: reportData(gpuBound ? hex($0) : Data(count: 20))) },
            modelQuoteVerification: modelKey.map { quote(reportData: reportData(modelKeyBound ? $0 : Data(count: 32))) },
            fetchedAt: Date(), providerID: UUID())
    }

    // MARK: provider_tee (model node)

    @Test func modelSignatureByBoundKeyIsVerified() throws {
        let m = try Self.model()
        let sig = try Self.signature(m.sig)
        let v = TEESignatureVerifier.evaluate(sig, attestation: Self.record(gpu: m.sig["signing_address"]), exchange: m.exchange)
        guard case .verified(let r) = v else { Issue.record("expected verified, got \(v)"); return }
        #expect(r.signingAddress == m.sig["signing_address"]?.lowercased())
    }

    @Test func modelSignatureByUnboundKeyIsNotVerified() throws {
        let m = try Self.model()
        let v = TEESignatureVerifier.evaluate(try Self.signature(m.sig),
                                              attestation: Self.record(gpu: m.sig["signing_address"], gpuBound: false),
                                              exchange: m.exchange)
        guard case .unverified(.signerUnattested) = v else { Issue.record("expected signerUnattested, got \(v)"); return }
    }

    @Test func tamperedSignatureIsRejected() throws {
        let m = try Self.model()
        var s = Array(m.sig["signature"]!)
        s[10] = s[10] == "a" ? "b" : "a"
        let v = TEESignatureVerifier.evaluate(try Self.signature(m.sig, ["signature": String(s)]),
                                              attestation: Self.record(gpu: m.sig["signing_address"]), exchange: m.exchange)
        if case .verified = v { Issue.record("a tampered signature verified") }
    }

    @Test func modelSignatureWithoutPrefixIsRejected() throws {
        let m = try Self.model()
        let unprefixed = m.sig["text"]!.split(separator: ":").suffix(2).joined(separator: ":")
        let v = TEESignatureVerifier.evaluate(try Self.signature(m.sig, ["text": unprefixed]),
                                              attestation: Self.record(gpu: m.sig["signing_address"]), exchange: m.exchange)
        guard case .unverified(.contentMismatch(let detail)) = v else { Issue.record("expected contentMismatch, got \(v)"); return }
        #expect(detail.contains("prefix"))
    }

    @Test func gatewayKindOverModelTextIsRejected() throws {
        let m = try Self.model()
        let v = TEESignatureVerifier.evaluate(try Self.signature(m.sig, ["signature_kind": "gateway"]),
                                              attestation: Self.record(gateway: m.sig["signing_address"]), exchange: m.exchange)
        guard case .unverified(.contentMismatch) = v else { Issue.record("expected contentMismatch, got \(v)"); return }
    }

    /// The removed rotation path: a signer that matches no bound key is a
    /// mismatch even when the gateway quote verified.
    @Test func signerOutsideTheAttestationIsAMismatch() throws {
        let m = try Self.model()
        let other = "0x" + String(repeating: "11", count: 20)
        let v = TEESignatureVerifier.evaluate(try Self.signature(m.sig),
                                              attestation: Self.record(gateway: other, gpu: other), exchange: m.exchange)
        guard case .unverified(.signatureMismatch) = v else { Issue.record("expected signatureMismatch, got \(v)"); return }
    }

    @Test func unknownAlgorithmOnATrustedAddressIsRejected() throws {
        let m = try Self.model()
        for algo in ["rsa", "", "none"] {
            let v = TEESignatureVerifier.evaluate(try Self.signature(m.sig, ["signing_algo": algo]),
                                                  attestation: Self.record(gpu: m.sig["signing_address"]), exchange: m.exchange)
            guard case .unverified(.signatureMismatch) = v else { Issue.record("\(algo): expected signatureMismatch, got \(v)"); continue }
        }
    }

    @Test func unknownSignatureKindIsRejected() throws {
        let m = try Self.model()
        let v = TEESignatureVerifier.evaluate(try Self.signature(m.sig, ["signature_kind": "proxy"]),
                                              attestation: Self.record(gpu: m.sig["signing_address"]), exchange: m.exchange)
        guard case .unverified(.signatureMismatch) = v else { Issue.record("expected signatureMismatch, got \(v)"); return }
    }

    // MARK: gateway

    @Test func gatewaySignatureIsGatewayTrustOnly() throws {
        let g = try Self.gateway()
        let v = TEESignatureVerifier.evaluate(try Self.signature(g.sigEcdsa),
                                              attestation: Self.record(gateway: g.gatewayEcdsaAddress), exchange: g.exchange)
        guard case .unverified(.gatewayTrustOnly(let addr)) = v else { Issue.record("expected gatewayTrustOnly, got \(v)"); return }
        #expect(addr == g.gatewayEcdsaAddress.lowercased())
    }

    /// Pre-1.0.6 this was `.verified`: the gateway address sat in the trusted set.
    @Test func gatewaySignerIsNeverVerifiedEvenAsAModelKey() throws {
        let g = try Self.gateway()
        let v = TEESignatureVerifier.evaluate(try Self.signature(g.sigEcdsa),
                                              attestation: Self.record(gateway: g.gatewayEcdsaAddress, gpu: g.gatewayEcdsaAddress),
                                              exchange: g.exchange)
        if case .verified = v { Issue.record("a gateway-kind signature verified") }
    }

    @Test func gatewaySignatureByUnboundKeyIsAMismatch() throws {
        let g = try Self.gateway()
        let v = TEESignatureVerifier.evaluate(try Self.signature(g.sigEcdsa),
                                              attestation: Self.record(gateway: g.gatewayEcdsaAddress, gatewayBound: false),
                                              exchange: g.exchange)
        guard case .unverified(.signatureMismatch) = v else { Issue.record("expected signatureMismatch, got \(v)"); return }
    }

    @Test func gatewaySignatureWithModelPrefixIsRejected() throws {
        let g = try Self.gateway()
        let v = TEESignatureVerifier.evaluate(try Self.signature(g.sigEcdsa, ["text": "z-ai/glm-5.3-flash:" + g.sigEcdsa["text"]!]),
                                              attestation: Self.record(gateway: g.gatewayEcdsaAddress), exchange: g.exchange)
        guard case .unverified(.contentMismatch) = v else { Issue.record("expected contentMismatch, got \(v)"); return }
    }

    // MARK: ed25519

    @Test func realEd25519SignatureChecksAgainstItsKey() throws {
        let g = try Self.gateway()
        let key = Self.hex(g.gatewayEd25519Key)
        #expect(Ed25519Signature.isValid(text: g.sigEd25519["text"]!, signatureHex: g.sigEd25519["signature"]!, publicKey: key))
        #expect(!Ed25519Signature.isValid(text: g.sigEd25519["text"]! + "x", signatureHex: g.sigEd25519["signature"]!, publicKey: key))
    }

    /// The gateway's Ed25519 key is not attested, so a valid one is still rejected.
    @Test func gatewayEd25519IsRejected() throws {
        let g = try Self.gateway()
        let v = TEESignatureVerifier.evaluate(try Self.signature(g.sigEd25519),
                                              attestation: Self.record(gateway: g.gatewayEcdsaAddress,
                                                                       modelKey: Self.hex(g.gatewayEd25519Key)),
                                              exchange: g.exchange)
        guard case .unverified(.signatureMismatch) = v else { Issue.record("expected signatureMismatch, got \(v)"); return }
    }

    @Test func modelEd25519ByBoundKeyIsVerifiedAndUnboundIsNot() throws {
        let m = try Self.model()
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation
        let text = m.sig["text"]!
        let sig = try Self.signature(m.sig, [
            "signing_algo": "ed25519",
            "signing_address": pub.hexString,
            "signature": try key.signature(for: Data(text.utf8)).hexString,
        ])
        let bound = TEESignatureVerifier.evaluate(sig, attestation: Self.record(modelKey: pub), exchange: m.exchange)
        guard case .verified = bound else { Issue.record("expected verified, got \(bound)"); return }
        let unbound = TEESignatureVerifier.evaluate(sig, attestation: Self.record(modelKey: pub, modelKeyBound: false), exchange: m.exchange)
        if case .verified = unbound { Issue.record("an unbound model key verified") }
        let forged = TEESignatureVerifier.evaluate(
            try Self.signature(m.sig, ["signing_algo": "ed25519", "signing_address": pub.hexString,
                                       "signature": String(repeating: "00", count: 64)]),
            attestation: Self.record(modelKey: pub), exchange: m.exchange)
        if case .verified = forged { Issue.record("a zero ed25519 signature verified on the asserted key") }
    }
}
