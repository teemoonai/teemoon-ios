//
//  AttestationEvidenceTests.swift
//  teemoonTests
//
//  The raw-evidence strings the advanced section shows — reflecting the
//  updated E2EE/TEE validation (DCAP/TCB, nonce freshness, NRAS, provenance,
//  ecrecover response signatures, corrected cipher suite).
//

import Foundation
import Testing
@testable import teemoon

@Suite("AttestationEvidence")
struct AttestationEvidenceTests {

    private func summary(
        dcap: RecordDCAPVerification? = nil,
        nras: NRASVerification? = nil,
        imageProvenance: ProvenanceService.ManifestProvenance? = nil,
        verified: Int = 0, mismatched: Int = 0, gatewayTrust: Int = 0,
        attestation: AttestationRecord? = .preview
    ) -> AttestationSummary {
        AttestationSummary(
            attestation: attestation, state: .ok, timedOut: false, provider: .nearAI,
            lastRequestUsedE2EE: nil, lastE2EEFailReason: nil,
            verifiedResponseCount: verified, mismatchedResponseCount: mismatched,
            gatewayTrustResponseCount: gatewayTrust,
            attestationFetchFailed: false, imageProvenance: imageProvenance,
            dcapVerification: dcap, nrasVerification: nras)
    }

    @Test func dcapEvidenceReflectsTcbStatus() {
        var upToDate = RecordDCAPVerification()
        upToDate.gateway = .verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
        #expect(summary(dcap: upToDate).dcapEvidence == "verified · TCB up to date")

        var outOfDate = RecordDCAPVerification()
        outOfDate.gateway = .verified(tcbStatus: .outOfDate, mrConfigIdHex: "01", reportDataHex: "")
        #expect(summary(dcap: outOfDate).dcapEvidence?.contains("out of date") == true)

        var failed = RecordDCAPVerification()
        failed.gateway = .failed("collateral: HTTP 429 from api.trustedservices.intel.com (tcb)")
        // The specific reason + which quote is now surfaced, not a generic string.
        let evidence = summary(dcap: failed).dcapEvidence
        #expect(evidence?.contains("gateway quote") == true)
        #expect(evidence?.contains("HTTP 429") == true)

        #expect(summary(dcap: nil).dcapEvidence == nil)
    }

    @Test func dcapFailureReasonTagsWhichQuote() {
        var rec = RecordDCAPVerification()
        rec.gateway = .verified(tcbStatus: .outOfDate, mrConfigIdHex: "01", reportDataHex: "")
        rec.model = .failed("collateral: HTTP 429 from api.trustedservices.intel.com (tcb)")
        #expect(rec.failureReason == "model quote — collateral: HTTP 429 from api.trustedservices.intel.com (tcb)")

        var revoked = RecordDCAPVerification()
        revoked.gpu = .verified(tcbStatus: .revoked, mrConfigIdHex: "01", reportDataHex: "")
        #expect(revoked.failureReason == "gpu quote — TCB revoked by Intel")

        var clean = RecordDCAPVerification()
        clean.gateway = .verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
        #expect(clean.failureReason == nil)
    }

    @Test func nrasEvidence() {
        #expect(summary(nras: .verified).nrasEvidence?.contains("PASS") == true)
        #expect(summary(nras: .failed("unreachable")).nrasEvidence?.contains("unreachable") == true)
        #expect(summary(nras: nil).nrasEvidence == nil)
    }

    @Test func provenanceEvidenceNamesTheOrg() {
        let ref = ProvenanceService.ImageRef(image: "nearaidev/cloud-api", digest: String(repeating: "a", count: 64))
        let s = summary(imageProvenance: .allVerified(verified: [ref], thirdParty: [ref]))
        #expect(s.provenanceEvidence?.contains("github.com/nearai") == true)
        #expect(s.provenanceEvidence?.contains("sidecar") == true)
    }

    @Test func responseSigEvidenceDescribesEcrecover() {
        #expect(summary(verified: 3).responseSigEvidence?.contains("ecrecover") == true)
        #expect(summary(mismatched: 1).responseSigEvidence?.contains("mismatch") == true)
        #expect(summary(gatewayTrust: 2).responseSigEvidence?.contains("gateway trust") == true)
        #expect(summary().responseSigEvidence == nil)  // no responses yet
    }

    @Test func cipherSuiteMatchesNearAIProtocol() {
        // near.ai's documented v2 scheme — X25519 ECDH → HKDF-SHA256 → XChaCha20-Poly1305.
        let s = AttestationSummary.cipherSuiteLabel
        #expect(s.contains("X25519 ECDH"))
        #expect(s.contains("HKDF-SHA256"))
        #expect(s.contains("XChaCha20-Poly1305"))
    }

    @Test func nonceEvidenceReflectsFreshness() {
        // preview record has no recorded nonces → nil (not checkable)
        #expect(summary().nonceEvidence == nil)
    }
}
