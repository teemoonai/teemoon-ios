//
//  ConformanceVectorsSignatures.swift
//  teemoonTests
//
//  Per-response signature vectors (conformance/signatures.json), built from
//  three real near.ai captures and mutations of them, each answered by the
//  production TEESignatureVerifier.evaluate. conformance/tools/sdk_verdicts.py
//  replays the same cases through near.ai's own inference-sdk (pinned) and
//  writes conformance/signatures.sdk.json; `iosAgreesWithTheSDK` holds the
//  two to the same verdict wherever the SDK can express the case.
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

struct SignatureVectors: Codable {
    struct Signature: Codable {
        let text: String
        let signature: String
        let signingAddress: String
        let signingAlgo: String
        let signatureKind: String?
    }
    /// Which keys the attestation holds and whether each sits in its quote's report_data.
    struct Attestation: Codable {
        var gatewayAddress: String? = nil
        var gatewayBound = true
        var gpuAddress: String? = nil
        var gpuBound = true
        var modelKey: String? = nil
        var modelKeyBound = true
    }
    struct Case: Codable {
        let note: String
        /// [0] is the wire body (what the SDK hashes); later entries are other candidates (E2EE plaintext).
        let requestBodiesB64: [String]
        let responseText: String
        let signature: Signature
        let attestation: Attestation
        /// verified | gatewayTrustOnly | signerUnattested | rejected
        let outcome: String
        /// false when the case is about key-to-quote binding, which the SDK checks in attestation, not here.
        let sdkApplies: Bool
    }
    let sdkCommit: String
    let cases: [Case]
}

enum ConformanceSignatureVectors {
    static let sdkCommit = "4bccfd94549f6e5061821f90a5d8901d7299a8c0"

    static func outcome(_ v: ResponseVerification) -> String {
        switch v {
        case .verified: return "verified"
        case .unverified(.gatewayTrustOnly): return "gatewayTrustOnly"
        case .unverified(.signerUnattested): return "signerUnattested"
        case .unverified: return "rejected"
        }
    }

    static func record(_ a: SignatureVectors.Attestation) -> AttestationRecord {
        SignatureVerdictTests.record(
            gateway: a.gatewayAddress, gatewayBound: a.gatewayBound,
            gpu: a.gpuAddress, gpuBound: a.gpuBound,
            modelKey: a.modelKey.map { SignatureVerdictTests.hex($0) }, modelKeyBound: a.modelKeyBound)
    }

    static func evaluate(_ c: SignatureVectors.Case) throws -> ResponseVerification {
        var fields = ["text": c.signature.text, "signature": c.signature.signature,
                      "signing_address": c.signature.signingAddress, "signing_algo": c.signature.signingAlgo]
        if let k = c.signature.signatureKind { fields["signature_kind"] = k }
        let sig = try JSONDecoder().decode(TEEMessageSignature.self, from: JSONSerialization.data(withJSONObject: fields))
        let exchange = SignedExchange(requestBodyCandidates: c.requestBodiesB64.compactMap { Data(base64Encoded: $0) },
                                      responseText: c.responseText)
        return TEESignatureVerifier.evaluate(sig, attestation: record(c.attestation), exchange: exchange)
    }

    struct E2EECapture: Decodable {
        let candidatesB64: [String]
        let responseText: String
        let sig: [String: String]
        let modelKey: String
        enum CodingKeys: String, CodingKey {
            case candidatesB64 = "candidates_b64", responseText = "response_text", sig, modelKey = "model_key"
        }
    }

    static func signatures(file: String = #filePath) throws -> SignatureVectors {
        let e = try JSONDecoder().decode(E2EECapture.self, from: TestFixture.data("nearai_e2ee_signed_response.json", file: file))
        let g = try SignatureVerdictTests.gateway(file: file)
        let m = try SignatureVerdictTests.model(file: file)

        func sig(_ f: [String: String], _ o: [String: String] = [:]) -> SignatureVectors.Signature {
            let f = f.merging(o) { $1 }
            return .init(text: f["text"]!, signature: f["signature"]!, signingAddress: f["signing_address"]!,
                         signingAlgo: f["signing_algo"]!, signatureKind: f["signature_kind"].flatMap { $0.isEmpty ? nil : $0 })
        }
        func flip(_ hex: String) -> String { var a = Array(hex); let i = a.count - 7; a[i] = a[i] == "a" ? "b" : "a"; return String(a) }
        let b64 = { (s: String) in Data(s.utf8).base64EncodedString() }
        let unprefixed = { (t: String) in t.split(separator: ":").suffix(2).joined(separator: ":") }

        let eAtt = SignatureVectors.Attestation(modelKey: e.modelKey)
        let gAtt = SignatureVectors.Attestation(gatewayAddress: g.gatewayEcdsaAddress)
        let mAtt = SignatureVectors.Attestation(gpuAddress: m.sig["signing_address"])
        let otherKey = String(repeating: "5a", count: 32)

        var cases: [SignatureVectors.Case] = []
        func add(_ note: String, _ bodies: [String], _ resp: String, _ s: SignatureVectors.Signature,
                 _ a: SignatureVectors.Attestation, sdk: Bool = true) throws {
            let partial = SignatureVectors.Case(note: note, requestBodiesB64: bodies, responseText: resp, signature: s,
                                                attestation: a, outcome: "", sdkApplies: sdk)
            cases.append(.init(note: note, requestBodiesB64: bodies, responseText: resp, signature: s, attestation: a,
                               outcome: outcome(try evaluate(partial)), sdkApplies: sdk))
        }
        let eb = e.candidatesB64, er = e.responseText
        try add("E2EE reply, provider_tee ed25519 by the quote-bound model key", eb, er, sig(e.sig), eAtt)
        try add("E2EE reply, signature tampered", eb, er, sig(e.sig, ["signature": flip(e.sig["signature"]!)]), eAtt)
        try add("E2EE reply, model prefix stripped from the signed text", eb, er, sig(e.sig, ["text": unprefixed(e.sig["text"]!)]), eAtt)
        try add("E2EE reply relabelled signature_kind=gateway", eb, er, sig(e.sig, ["signature_kind": "gateway"]), eAtt)
        try add("E2EE reply, unknown signing_algo", eb, er, sig(e.sig, ["signing_algo": "rsa"]), eAtt)
        try add("E2EE reply, unknown signature_kind", eb, er, sig(e.sig, ["signature_kind": "proxy"]), eAtt)
        try add("E2EE reply, asserted signer swapped for another key", eb, er, sig(e.sig, ["signing_address": otherKey]),
                SignatureVectors.Attestation(modelKey: otherKey))
        try add("E2EE reply, model key not in the model quote's report_data", eb, er, sig(e.sig),
                SignatureVectors.Attestation(modelKey: e.modelKey, modelKeyBound: false), sdk: false)

        let gb = [b64(g.bodyJson)], gr = g.responseText
        try add("plaintext reply, gateway ecdsa by the quote-bound gateway key", gb, gr, sig(g.sigEcdsa), gAtt)
        try add("plaintext reply, gateway signature with a model prefix", gb, gr,
                sig(g.sigEcdsa, ["text": "z-ai/glm-5.3-flash:" + g.sigEcdsa["text"]!]), gAtt)
        try add("plaintext reply, gateway ed25519 (that key is never attested)", gb, gr, sig(g.sigEd25519), gAtt)
        try add("plaintext reply, gateway ecdsa signer is not the attested gateway", gb, gr, sig(g.sigEcdsa),
                SignatureVectors.Attestation(gatewayAddress: "0x" + String(repeating: "11", count: 20)))

        let mb = [b64(m.bodyJson)], mr = m.lines.map { $0 + "\n" }.joined()
        try add("provider_tee ecdsa (no signature_kind field, read as provider_tee) by the bound model-node address",
                mb, mr, sig(m.sig), mAtt)
        try add("provider_tee ecdsa by a model-node address its GPU quote does not bind", mb, mr, sig(m.sig),
                SignatureVectors.Attestation(gpuAddress: m.sig["signing_address"], gpuBound: false), sdk: false)
        return SignatureVectors(sdkCommit: sdkCommit, cases: cases)
    }
}

@Suite("Conformance vectors — signatures")
struct ConformanceSignatureTests {

    @Test func vectorsReproduceUnderProduction() throws {
        let v = try ConformanceSignatureVectors.signatures()
        for c in v.cases {
            #expect(ConformanceSignatureVectors.outcome(try ConformanceSignatureVectors.evaluate(c)) == c.outcome, "\(c.note)")
        }
        #expect(v.cases.filter { $0.outcome == "verified" }.count == 2)
        #expect(v.cases.filter { $0.outcome == "gatewayTrustOnly" }.count == 1)
    }

    /// conformance/signatures.sdk.json is written by conformance/tools/sdk_verdicts.py from near.ai's SDK.
    @Test(.enabled(if: TestFixture.sourceTreeAvailable())) func iosAgreesWithTheSDK() throws {
        let url = ConformanceEmitTests.outputDirectory().appendingPathComponent("signatures.sdk.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(obj?["sdkCommit"] as? String == ConformanceSignatureVectors.sdkCommit)
        let sdk = obj?["verdicts"] as? [String: String] ?? [:]
        let v = try ConformanceSignatureVectors.signatures()
        let applicable = v.cases.filter(\.sdkApplies)
        #expect(sdk.count == applicable.count, "signatures.sdk.json is stale: re-run conformance/tools/sdk_verdicts.py")
        for c in applicable {
            // The SDK has no unattested-signer state; it either accepts a kind or rejects.
            #expect(sdk[c.note] == c.outcome, "\(c.note): sdk=\(sdk[c.note] ?? "missing") ios=\(c.outcome)")
        }
    }
}
