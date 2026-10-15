//
//  ConformanceVectorsAttestation.swift
//  teemoonTests
//
//  §7 items 2–4 of the conformance kit: quote fixtures, collateral fixtures,
//  Sigstore fixtures — plus the NRAS and TLS-attestation classes (recorded
//  round trips the Android NRASService / TLSAttestationVerifier rows gate on). Same two rules as ConformanceVectors.swift — every input
//  is a recorded fixture or a frozen constant, and every vector is proved by
//  the production code path in ConformanceAttestationRoundTripTests before it
//  is written. Negatives record what production ANSWERED (the reason kind),
//  never what the author expected; a port that disagrees with a recorded
//  answer disagrees with the app as shipped.
//
//  These are the classes that gate the Android rows the port spec calls
//  kit-gated: DCAP + collateral, AttestationService, and the Sigstore
//  verifier. Without them a Kotlin port could only certify itself.
//

import CryptoKit
import Foundation
import TDXQuoteVerifier
import Testing
@testable import teemoon

// MARK: - §7 item 2: quotes

struct QuoteVectors: Encodable {
    struct Measurements: Encodable {
        let mrtd, mrSeam, mrConfigID, mrOwner, rtmr0, rtmr1, rtmr2, rtmr3, reportData: String
    }
    struct QuoteVector: Encodable {
        let note: String
        let quoteHex: String
        /// The instant the verdict was rendered at — collateral windows are judged against it.
        let nowSecs: UInt64
        let measurements: Measurements
        let signatureValid: Bool
        let certChainValid: Bool
        /// dcap-qvl against the captured collateral: "verified" | "failed".
        let dcapOutcome: String
        let tcbStatus: String?
        let dcapMrConfigIdHex: String?
        let dcapReportDataHex: String?
    }
    struct NegativeQuoteVector: Encodable {
        let note: String
        let quoteHex: String
        let nowSecs: UInt64
        /// Whether the Swift parser refuses the quote outright.
        let swiftParseThrows: Bool
        let dcapOutcome: String
    }
    let quotes: [QuoteVector]
    let negatives: [NegativeQuoteVector]
}

// MARK: - §7 item 3: collateral

struct CollateralVectors: Encodable {
    struct Response: Encodable { let url: String; let bodyB64: String; let headers: [String: String] }
    /// A byte-exact sub-object the extractor must produce from a PCS body.
    struct Extraction: Encodable { let url: String; let key: String; let rawObject: String }
    struct RawJSONObjectVector: Encodable { let note: String; let body: String; let key: String; let rawObject: String? }
    let quoteHex: String
    let nowSecs: UInt64
    /// The captured Intel PCS responses, by exact URL. The Kotlin provider is fed these and nothing else.
    let responses: [Response]
    /// Every field of the QuoteCollateralV3 JSON the provider assembles for dcap-qvl, byte-exact per field.
    let assembledCollateralFields: [String: String]
    let extractions: [Extraction]
    let rawJSONObject: [RawJSONObjectVector]
    let crlDistributionPointFromQEIssuerRoot: String
}

// MARK: - §7 item 4: Sigstore

struct SigstoreVectors: Encodable {
    struct Expected: Encodable {
        let repositoryURL: String
        let workflowIdentity: String
        let sourceRef: String?
        let sourceCommit: String?
        let transparencyLogChecked: Bool
    }
    struct Positive: Encodable {
        let note: String
        let attestationJSONB64: String
        let expectedDigest: String
        let organizationURL: String
        let leafSubjectAltNameURI: String
        let expected: Expected
    }
    struct Negative: Encodable {
        let note: String
        let attestationJSONB64: String
        let expectedDigest: String
        let organizationURL: String
        /// The `ImageProvenance.Reason` case production answered with.
        let reason: String
    }
    let positives: [Positive]
    let negatives: [Negative]
}


// MARK: - NRAS (GPU attestation) — a real captured round trip

struct NrasVectors: Encodable {
    /// The live near.ai `nvidia_payload`, the nonce it was requested with, and NVIDIA's actual response text.
    let nvidiaPayload: String
    let requestNonce: String
    let nrasResponse: String
    /// What `overallVerdict` answers for the recorded response.
    let overallVerdict: Bool
    /// One `NRASService.verify` run: the inputs, and what production ANSWERED ("verified" | "failed" | "inconclusive").
    struct Case: Encodable {
        let note: String
        let expectedNonceHex: String?
        /// The stub's answer; nil means NRAS was unreachable.
        let response: String?
        let outcome: String
        let reasonContains: String?
    }
    let cases: [Case]
}

// MARK: - TLS attestation — a real captured exchange

struct TlsVectors: Encodable {
    let nonce: String
    let certDerB64: String
    let intelQuote: String
    let signingAddress: String
    let signingAlgo: String
    let tlsCertFingerprint: String
    /// SHA-256 of the live certificate's SubjectPublicKeyInfo, as production computes it.
    let spkiSha256: String
    /// One `verifyBindings` run over the recorded exchange with these overrides, and what production ANSWERED.
    struct Case: Encodable {
        let note: String
        let nonceHex: String
        let tlsCertFingerprintHex: String
        let certDerB64: String
        let outcome: String
        let reasonContains: String?
    }
    let cases: [Case]
    /// DER blobs `spkiSHA256` must refuse (answer nil).
    let malformedCertsB64: [String]
}

// MARK: - Builders

enum ConformanceAttestationVectors {

    // MARK: quotes

    static func quotes(file: String = #filePath) async throws -> QuoteVectors {
        let snapshot = try CollateralServiceTests.loadSnapshot(file: file)
        let provider = CollateralServiceTests.provider(snapshot)
        let verifier = DCAPVerifier(collateral: provider)

        let parse = try TDXQuoteVerifier.verify(quoteHex: snapshot.quoteHex)
        let verdict = await verifier.verify(quoteHex: snapshot.quoteHex, nowSecs: snapshot.nowSecs)
        let real = QuoteVectors.QuoteVector(
            note: "live near.ai gateway TDX quote (Fixtures/dcap_pcs_snapshot.json), judged at the snapshot's now_secs",
            quoteHex: snapshot.quoteHex, nowSecs: snapshot.nowSecs,
            measurements: measurements(parse.measurements),
            signatureValid: parse.signatureValid, certChainValid: parse.certChainValid,
            dcapOutcome: outcomeKind(verdict), tcbStatus: tcbStatus(verdict),
            dcapMrConfigIdHex: mrConfig(verdict), dcapReportDataHex: reportData(verdict))

        // Collateral has a validity window: the same quote, judged two years on — far outside every
        // nextUpdate window, as CollateralServiceTests proves — must fail. Never a silent pass on stale collateral.
        let twoYears: UInt64 = 2 * 365 * 86400
        let stale = await verifier.verify(quoteHex: snapshot.quoteHex, nowSecs: snapshot.nowSecs + twoYears)
        // A quote with one byte of MRTD flipped: TDX v4 header (48 bytes) then the TD report body, whose
        // MRTD sits at body offset 64 — absolute byte 112, hex offset 224. The trailing bytes of the quote
        // are zero padding outside the signed region, which is why the tamper is placed INSIDE the report.
        var tampered = Array(snapshot.quoteHex)
        tampered[224] = tampered[224] == "0" ? "1" : "0"
        let tamperedHex = String(tampered)
        var tamperedParseThrows = false
        var tamperedSignatureValid = true
        do { tamperedSignatureValid = try TDXQuoteVerifier.verify(quoteHex: tamperedHex).signatureValid } catch { tamperedParseThrows = true }
        let tamperedVerdict = await verifier.verify(quoteHex: tamperedHex, nowSecs: snapshot.nowSecs)

        return QuoteVectors(
            quotes: [real],
            negatives: [
                .init(note: "the real quote judged two years after its collateral was fetched — the validity window must fail it",
                      quoteHex: snapshot.quoteHex, nowSecs: snapshot.nowSecs + twoYears,
                      swiftParseThrows: false, dcapOutcome: outcomeKind(stale)),
                .init(note: "one byte of MRTD flipped inside the signed TD report — the quote signature no longer verifies (swift parser: \(tamperedParseThrows ? "throws" : (tamperedSignatureValid ? "signatureValid=true" : "signatureValid=false")))",
                      quoteHex: tamperedHex, nowSecs: snapshot.nowSecs,
                      swiftParseThrows: tamperedParseThrows || !tamperedSignatureValid, dcapOutcome: outcomeKind(tamperedVerdict)),
            ])
    }

    static func measurements(_ m: TDXMeasurements) -> QuoteVectors.Measurements {
        .init(mrtd: m.mrtd.hexString, mrSeam: m.mrSeam.hexString, mrConfigID: m.mrConfigID.hexString,
              mrOwner: m.mrOwner.hexString, rtmr0: m.rtmr0.hexString, rtmr1: m.rtmr1.hexString,
              rtmr2: m.rtmr2.hexString, rtmr3: m.rtmr3.hexString, reportData: m.reportData.hexString)
    }

    static func outcomeKind(_ v: DCAPVerification) -> String { if case .verified = v { return "verified" } else { return "failed" } }
    static func tcbStatus(_ v: DCAPVerification) -> String? { if case .verified(let tcb, _, _) = v { return tcb.rawValue } else { return nil } }
    static func mrConfig(_ v: DCAPVerification) -> String? { if case .verified(_, let m, _) = v { return m.lowercased() } else { return nil } }
    static func reportData(_ v: DCAPVerification) -> String? { if case .verified(_, _, let r) = v { return r.lowercased() } else { return nil } }

    // MARK: collateral

    static func collateral(file: String = #filePath) async throws -> CollateralVectors {
        let snapshot = try CollateralServiceTests.loadSnapshot(file: file)
        let provider = CollateralServiceTests.provider(snapshot)
        let responses = snapshot.responses.keys.sorted().map { url in
            CollateralVectors.Response(url: url, bodyB64: snapshot.responses[url]!.bodyB64, headers: snapshot.responses[url]!.headers)
        }
        // The assembled QuoteCollateralV3, per field: JSON dictionary order is not
        // stable across runs, the field VALUES are — and the values are what dcap-qvl reads.
        let assembled = try await provider.collateralJSON(forQuote: try Data(hexString: snapshot.quoteHex))
        let object = try JSONSerialization.jsonObject(with: assembled) as? [String: Any] ?? [:]
        var fields: [String: String] = [:]
        for (k, v) in object {
            if let s = v as? String { fields[k] = s }
            else if let n = v as? NSNumber { fields[k] = n.stringValue }
        }
        // The byte-exact sub-objects the extractor lifts out of the PCS bodies.
        var extractions: [CollateralVectors.Extraction] = []
        for url in snapshot.responses.keys.sorted() {
            guard let body = Data(base64Encoded: snapshot.responses[url]!.bodyB64) else { continue }
            for key in ["tcbInfo", "enclaveIdentity"] {
                if let raw = IntelPCSCollateralProvider.rawJSONObject(forKey: key, in: body) {
                    extractions.append(.init(url: url, key: key, rawObject: raw))
                }
            }
        }
        let unit = #"{"tcbInfo":{"a":1,"z":{"nested":"br{ce\" }"},"b":[1,2]},"signature":"aabb"}"#
        let rawVectors: [CollateralVectors.RawJSONObjectVector] = [
            .init(note: "byte-exact sub-object, braces and escaped quotes inside strings", body: unit, key: "tcbInfo",
                  rawObject: IntelPCSCollateralProvider.rawJSONObject(forKey: "tcbInfo", in: Data(unit.utf8))),
            .init(note: "missing key → nil", body: #"{"other":{}}"#, key: "tcbInfo",
                  rawObject: IntelPCSCollateralProvider.rawJSONObject(forKey: "tcbInfo", in: Data(#"{"other":{}}"#.utf8))),
        ]
        let qeURL = snapshot.responses.keys.first { $0.contains("qe/identity") }!
        let pem = snapshot.responses[qeURL]!.headers["SGX-Enclave-Identity-Issuer-Chain"]!.removingPercentEncoding!
        let rootDER = IntelPCSCollateralProvider.pemCertificatesDER(pem).last!
        let crl = IntelPCSCollateralProvider.crlDistributionPointURI(certDER: rootDER) ?? ""
        return CollateralVectors(quoteHex: snapshot.quoteHex, nowSecs: snapshot.nowSecs, responses: responses,
                                 assembledCollateralFields: fields, extractions: extractions, rawJSONObject: rawVectors,
                                 crlDistributionPointFromQEIssuerRoot: crl)
    }

    // MARK: Sigstore

    static let sigstoreOrg = "https://github.com/nearai"

    static func sigstore(file: String = #filePath) throws -> SigstoreVectors {
        let json = try TestFixture.data("nearai_cloudapi_attestation.json", file: file)
        let digest = ImageProvenanceTests.fixtureDigest
        let verifier = ProvenanceVerifier()
        guard case .verified(let repo, let identity, let ref, let commit, let tlog) = verifier.verify(attestationJSON: json, expectedDigest: digest) else {
            throw KitError("the recorded near.ai attestation no longer verifies under production")
        }
        let obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        let cert = (((obj["attestations"] as! [[String: Any]])[0]["bundle"] as! [String: Any])["verificationMaterial"] as! [String: Any])["certificate"] as! [String: Any]
        let leafDER = Data(base64Encoded: cert["rawBytes"] as! String)!
        let positive = SigstoreVectors.Positive(
            note: "GitHub build attestation for nearai/cloud-api @ the recorded digest (Fixtures/nearai_cloudapi_attestation.json)",
            attestationJSONB64: json.base64EncodedString(), expectedDigest: digest, organizationURL: sigstoreOrg,
            leafSubjectAltNameURI: ProvenanceVerifier.subjectAltNameURI(certDER: leafDER) ?? "",
            expected: .init(repositoryURL: repo, workflowIdentity: identity, sourceRef: ref, sourceCommit: commit, transparencyLogChecked: tlog))

        func negative(_ note: String, _ data: Data, digest d: String = digest, org: String = sigstoreOrg) -> SigstoreVectors.Negative {
            let v = ProvenanceVerifier(policies: [BuildIdentityPolicy(organizationURL: org)])
            return .init(note: note, attestationJSONB64: data.base64EncodedString(), expectedDigest: d, organizationURL: org,
                         reason: reasonKind(v.verify(attestationJSON: data, expectedDigest: d)))
        }
        return SigstoreVectors(positives: [positive], negatives: [
            negative("wrong digest — the signed subject is not the running image", json, digest: String(repeating: "00", count: 32)),
            negative("DSSE signature tampered (last four base64 chars flipped)", try mutated(json) { bundle in
                var env = bundle["dsseEnvelope"] as! [String: Any]
                var sigs = env["signatures"] as! [[String: Any]]
                let sig = sigs[0]["sig"] as! String
                sigs[0]["sig"] = String(sig.dropLast(4)) + (sig.hasSuffix("AAAA") ? "BBBB" : "AAAA")
                env["signatures"] = sigs; bundle["dsseEnvelope"] = env
            }),
            negative("wrong organization policy — a valid attestation from a repo the app does not trust", json, org: "https://github.com/someone"),
            negative("empty attestations list", Data(#"{"attestations":[]}"#.utf8)),
            negative("Rekor integratedTime rewritten to 0 — the Fulcio leaf was not yet valid at the claimed signing time", try mutated(json) { bundle in
                var vm = bundle["verificationMaterial"] as! [String: Any]
                var entries = vm["tlogEntries"] as! [[String: Any]]
                entries[0]["integratedTime"] = "0"
                vm["tlogEntries"] = entries; bundle["verificationMaterial"] = vm
            }),
            negative("Rekor integratedTime rewritten to 2100 — the ten-minute Fulcio leaf had long expired at the claimed signing time", try mutated(json) { bundle in
                var vm = bundle["verificationMaterial"] as! [String: Any]
                var entries = vm["tlogEntries"] as! [[String: Any]]
                entries[0]["integratedTime"] = "4102444800"
                vm["tlogEntries"] = entries; bundle["verificationMaterial"] = vm
            }),
        ])
    }


    // MARK: NRAS

    private struct StubNRAS: NRASHTTPClient {
        let response: Data?
        struct Unreachable: Error {}
        func post(_ url: URL, body: Data) async throws -> Data { guard let response else { throw Unreachable() }; return response }
    }

    static func nrasKind(_ v: NRASVerification) -> String {
        switch v { case .verified: return "verified"; case .failed: return "failed"; case .inconclusive: return "inconclusive" }
    }

    static func nras(file: String = #filePath) async throws -> NrasVectors {
        let fixture = try NRASServiceTests.loadFixture(file: file)
        // Re-encoded with sorted keys so the bytes are stable run to run; the parser reads values, not order.
        let responseObj = try JSONSerialization.jsonObject(with: fixture.responseData)
        let response = String(decoding: try JSONSerialization.data(withJSONObject: responseObj, options: [.sortedKeys]), as: UTF8.self)
        let verdict = try #require(NRASService.overallVerdict(Data(response.utf8)))
        // The tampered JWT: the overall verdict claim flipped to false, signature untouched (TLS trust model).
        guard case .array(let pair) = fixture.nrasResponse[0], case .string(let jwt) = pair[1] else { throw KitError("unexpected NRAS fixture shape") }
        var claims = try #require(NRASService.decodeJWTClaims(jwt))
        claims["x-nvidia-overall-att-result"] = false
        let b64url = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let segments = jwt.split(separator: ".")
        let tampered = "[[\"JWT\",\"\(segments[0]).\(b64url).\(segments[2])\"]]"

        func run(_ note: String, nonce: String?, response: String?, contains: String?) async -> NrasVectors.Case {
            let service = NRASService(http: StubNRAS(response: response.map { Data($0.utf8) }))
            let result = await service.verify(payloadJSON: fixture.nvidiaPayload, expectedNonceHex: nonce)
            return .init(note: note, expectedNonceHex: nonce, response: response, outcome: nrasKind(result), reasonContains: contains)
        }
        return NrasVectors(nvidiaPayload: fixture.nvidiaPayload, requestNonce: fixture.requestNonce, nrasResponse: response, overallVerdict: verdict, cases: [
            await run("real evidence, real NVIDIA response, matching nonce", nonce: fixture.requestNonce, response: response, contains: nil),
            await run("nonce mismatch — must fail before contacting NRAS (the stub is unreachable)", nonce: String(repeating: "00", count: 32), response: nil, contains: "nonce"),
            await run("no recorded request nonce — freshness cannot be proven", nonce: nil, response: response, contains: "nonce"),
            await run("NRAS unreachable — fail closed but soft", nonce: fixture.requestNonce, response: nil, contains: "unreachable"),
            await run("overall verdict claim flipped to false", nonce: fixture.requestNonce, response: tampered, contains: "FAIL"),
            await run("malformed NRAS response", nonce: fixture.requestNonce, response: "{}", contains: nil),
        ])
    }

    // MARK: TLS

    static func tlsKind(_ v: TLSAttestation) -> String {
        switch v { case .verified: return "verified"; case .failed: return "failed"; case .inconclusive: return "inconclusive"; case .notPerformed: return "notPerformed" }
    }

    static func tls(file: String = #filePath) throws -> TlsVectors {
        let f = try TLSAttestationVerifierTests.load(file: file)
        let spki = try #require(TLSAttestationVerifier.spkiSHA256(certDER: f.certDER))
        func run(_ note: String, nonce: String = f.nonce, fp: String = f.tlsCertFingerprint, cert: String = f.certDerB64, contains: String?) -> TlsVectors.Case {
            let result = TLSAttestationVerifier.verifyBindings(
                quoteHex: f.intelQuote, signingAddress: f.signingAddress, signingAlgo: f.signingAlgo,
                tlsCertFingerprintHex: fp, liveCertDER: Data(base64Encoded: cert) ?? Data(), nonceHex: nonce)
            return .init(note: note, nonceHex: nonce, tlsCertFingerprintHex: fp, certDerB64: cert, outcome: tlsKind(result), reasonContains: contains)
        }
        var flipped = Array(f.tlsCertFingerprint); flipped[0] = flipped[0] == "a" ? "b" : "a"
        return TlsVectors(nonce: f.nonce, certDerB64: f.certDerB64, intelQuote: f.intelQuote, signingAddress: f.signingAddress,
                          signingAlgo: f.signingAlgo, tlsCertFingerprint: f.tlsCertFingerprint, spkiSha256: spki, cases: [
            run("the real exchange", contains: nil),
            run("wrong nonce — freshness fails", nonce: String(repeating: "00", count: 32), contains: "nonce"),
            run("a different (throwaway) certificate — SPKI does not match", cert: TLSAttestationVerifierTests.throwawayCertBase64, contains: nil),
            run("attested fingerprint tampered — the live certificate no longer matches", fp: String(flipped), contains: nil),
        ], malformedCertsB64: [Data([0x30, 0x03, 0x02, 0x01, 0x00]).base64EncodedString(), ""])
    }

    /// Re-serialised with SORTED keys, so the bytes are stable run to run — the production verifier decodes, so order does not change its answer.
    static func mutated(_ json: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        var attestations = obj["attestations"] as! [[String: Any]]
        var bundle = attestations[0]["bundle"] as! [String: Any]
        edit(&bundle)
        attestations[0]["bundle"] = bundle; obj["attestations"] = attestations
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    static func reasonKind(_ p: ImageProvenance) -> String {
        switch p {
        case .verified: return "verified"
        case .unverified(.malformedBundle): return "malformedBundle"
        case .unverified(.signatureInvalid): return "signatureInvalid"
        case .unverified(.certificateChainInvalid): return "certificateChainInvalid"
        case .unverified(.identityNotTrusted): return "identityNotTrusted"
        case .unverified(.digestMismatch): return "digestMismatch"
        case .unverified(.fetchFailed): return "fetchFailed"
        case .unverified(.fetchTransient): return "fetchTransient"
        }
    }

    struct KitError: Error, CustomStringConvertible { let description: String; init(_ d: String) { description = d } }
}

// MARK: - Round trip against production (the Phase 0 gate for these classes)

@Suite("Conformance vectors — attestation classes round-trip against production")
struct ConformanceAttestationRoundTripTests {

    @Test func quoteVectorMatchesTheSwiftParserAndDcapQvl() async throws {
        let v = try await ConformanceAttestationVectors.quotes()
        let q = try #require(v.quotes.first)
        let parse = try TDXQuoteVerifier.verify(quoteHex: q.quoteHex)
        #expect(parse.measurements.mrtd.hexString == q.measurements.mrtd)
        #expect(parse.measurements.reportData.hexString == q.measurements.reportData)
        #expect(parse.isVerified == (q.signatureValid && q.certChainValid))
        // The real quote verifies, and dcap-qvl agrees with the Swift parser on the bytes the cross-check tripwire compares.
        #expect(q.dcapOutcome == "verified")
        #expect(q.dcapMrConfigIdHex == q.measurements.mrConfigID.lowercased())
        #expect(q.dcapReportDataHex == q.measurements.reportData.lowercased())
        // Both negatives are negatives.
        #expect(v.negatives.allSatisfy { $0.dcapOutcome == "failed" })
        #expect(v.negatives.count == 2)
    }

    @Test func collateralExtractionsAreTheFieldsDcapQvlIsHanded() async throws {
        let v = try await ConformanceAttestationVectors.collateral()
        let tcb = try #require(v.extractions.first { $0.key == "tcbInfo" })
        let qe = try #require(v.extractions.first { $0.key == "enclaveIdentity" })
        #expect(v.assembledCollateralFields["tcb_info"] == tcb.rawObject)
        #expect(v.assembledCollateralFields["qe_identity"] == qe.rawObject)
        #expect(v.crlDistributionPointFromQEIssuerRoot == "https://certificates.trustedservices.intel.com/IntelSGXRootCA.der")
        #expect(v.rawJSONObject[0].rawObject == #"{"a":1,"z":{"nested":"br{ce\" }"},"b":[1,2]}"#)
        #expect(v.rawJSONObject[1].rawObject == nil)
    }

    @Test func sigstoreVectorsReproduceUnderProduction() throws {
        let v = try ConformanceAttestationVectors.sigstore()
        let p = try #require(v.positives.first)
        let json = try #require(Data(base64Encoded: p.attestationJSONB64))
        guard case .verified(let repo, let identity, _, let commit, let tlog) = ProvenanceVerifier().verify(attestationJSON: json, expectedDigest: p.expectedDigest) else {
            Issue.record("positive did not verify"); return
        }
        #expect(repo == p.expected.repositoryURL && identity == p.expected.workflowIdentity && commit == p.expected.sourceCommit && tlog == p.expected.transparencyLogChecked)
        #expect(p.expected.transparencyLogChecked)
        for n in v.negatives {
            let data = try #require(Data(base64Encoded: n.attestationJSONB64))
            let got = ConformanceAttestationVectors.reasonKind(ProvenanceVerifier(policies: [BuildIdentityPolicy(organizationURL: n.organizationURL)]).verify(attestationJSON: data, expectedDigest: n.expectedDigest))
            #expect(got == n.reason, "\(n.note)")
            #expect(n.reason != "verified", "\(n.note) must be a negative")
        }
        // The spec's named negatives are all present and answered as expected.
        #expect(v.negatives.first { $0.note.hasPrefix("wrong digest") }?.reason == "digestMismatch")
        #expect(v.negatives.first { $0.note.hasPrefix("wrong organization") }?.reason == "identityNotTrusted")
        #expect(v.negatives.first { $0.note.hasPrefix("empty") }?.reason == "malformedBundle")
        #expect(v.negatives.first { $0.note.hasPrefix("DSSE") }?.reason == "signatureInvalid")
        #expect(v.negatives.filter { $0.note.hasPrefix("Rekor") }.allSatisfy { $0.reason == "certificateChainInvalid" })
    }


    @Test func nrasVectorsReproduceUnderProduction() async throws {
        let v = try await ConformanceAttestationVectors.nras()
        #expect(v.overallVerdict)
        #expect(NRASService.overallVerdict(Data(v.nrasResponse.utf8)) == true)
        for c in v.cases {
            let service = NRASService(http: StubNRASCheck(response: c.response.map { Data($0.utf8) }))
            let result = await service.verify(payloadJSON: v.nvidiaPayload, expectedNonceHex: c.expectedNonceHex)
            #expect(ConformanceAttestationVectors.nrasKind(result) == c.outcome, "\(c.note)")
            if let needle = c.reasonContains { #expect(result.reason?.contains(needle) == true, "\(c.note)") }
        }
        #expect(v.cases[0].outcome == "verified")
        #expect(v.cases.filter { $0.outcome == "failed" }.count == 2)
        #expect(v.cases.filter { $0.outcome == "inconclusive" }.count == 3)
    }

    private struct StubNRASCheck: NRASHTTPClient {
        let response: Data?
        struct Unreachable: Error {}
        func post(_ url: URL, body: Data) async throws -> Data { guard let response else { throw Unreachable() }; return response }
    }

    @Test func tlsVectorsReproduceUnderProduction() throws {
        let v = try ConformanceAttestationVectors.tls()
        #expect(TLSAttestationVerifier.spkiSHA256(certDER: Data(base64Encoded: v.certDerB64) ?? Data()) == v.spkiSha256)
        #expect(v.spkiSha256 == v.tlsCertFingerprint)
        for c in v.cases {
            let result = TLSAttestationVerifier.verifyBindings(
                quoteHex: v.intelQuote, signingAddress: v.signingAddress, signingAlgo: v.signingAlgo,
                tlsCertFingerprintHex: c.tlsCertFingerprintHex, liveCertDER: Data(base64Encoded: c.certDerB64) ?? Data(), nonceHex: c.nonceHex)
            #expect(ConformanceAttestationVectors.tlsKind(result) == c.outcome, "\(c.note)")
            if let needle = c.reasonContains { #expect(result.reason?.contains(needle) == true, "\(c.note)") }
        }
        #expect(v.cases[0].outcome == "verified")
        #expect(v.cases.dropFirst().allSatisfy { $0.outcome != "verified" })
        for b64 in v.malformedCertsB64 { #expect(TLSAttestationVerifier.spkiSHA256(certDER: Data(base64Encoded: b64) ?? Data()) == nil) }
    }

    @Test func attestationGenerationIsByteStable() async throws {
        let a = try ConformanceEncoder.encode(ConformanceDocument(kitVersion: ConformanceVectors.kitVersion, fixtureClass: "sigstore", sourceOfTruth: "teemoon-ios", vectors: try ConformanceAttestationVectors.sigstore()))
        let b = try ConformanceEncoder.encode(ConformanceDocument(kitVersion: ConformanceVectors.kitVersion, fixtureClass: "sigstore", sourceOfTruth: "teemoon-ios", vectors: try ConformanceAttestationVectors.sigstore()))
        #expect(a == b)
        let c = try ConformanceEncoder.encode(ConformanceDocument(kitVersion: ConformanceVectors.kitVersion, fixtureClass: "collateral", sourceOfTruth: "teemoon-ios", vectors: try await ConformanceAttestationVectors.collateral()))
        let d = try ConformanceEncoder.encode(ConformanceDocument(kitVersion: ConformanceVectors.kitVersion, fixtureClass: "collateral", sourceOfTruth: "teemoon-ios", vectors: try await ConformanceAttestationVectors.collateral()))
        #expect(c == d)
        let e = try ConformanceEncoder.encode(ConformanceDocument(kitVersion: ConformanceVectors.kitVersion, fixtureClass: "nras", sourceOfTruth: "teemoon-ios", vectors: try await ConformanceAttestationVectors.nras()))
        let f = try ConformanceEncoder.encode(ConformanceDocument(kitVersion: ConformanceVectors.kitVersion, fixtureClass: "nras", sourceOfTruth: "teemoon-ios", vectors: try await ConformanceAttestationVectors.nras()))
        #expect(e == f)
        let g = try ConformanceEncoder.encode(ConformanceDocument(kitVersion: ConformanceVectors.kitVersion, fixtureClass: "tls", sourceOfTruth: "teemoon-ios", vectors: try ConformanceAttestationVectors.tls()))
        let h = try ConformanceEncoder.encode(ConformanceDocument(kitVersion: ConformanceVectors.kitVersion, fixtureClass: "tls", sourceOfTruth: "teemoon-ios", vectors: try ConformanceAttestationVectors.tls()))
        #expect(g == h)
    }
}
