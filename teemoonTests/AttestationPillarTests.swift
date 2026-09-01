//
//  AttestationPillarTests.swift
//  teemoonTests
//
//  The three-pillar grouping the redesigned attestation sheet renders:
//  every check lands under genuine-hardware / published-code / private-to-you,
//  and each pillar's roll-up state reflects its checks.
//

import Foundation
import TDXQuoteVerifier
import Testing
@testable import teemoon

@Suite("AttestationPillars")
struct AttestationPillarTests {

    private func summary(
        attestation: AttestationRecord?,
        state: AttestationState = .ok,
        lastRequestUsedE2EE: Bool? = nil,
        verifiedResponseCount: Int = 0,
        imageProvenance: ProvenanceService.ManifestProvenance? = nil,
        dcap: RecordDCAPVerification? = nil,
        nras: NRASVerification? = nil
    ) -> AttestationSummary {
        AttestationSummary(
            attestation: attestation, state: state, timedOut: false, provider: .nearAI,
            lastRequestUsedE2EE: lastRequestUsedE2EE, lastE2EEFailReason: nil,
            verifiedResponseCount: verifiedResponseCount, mismatchedResponseCount: 0,
            attestationFetchFailed: false, imageProvenance: imageProvenance,
            dcapVerification: dcap, nrasVerification: nras)
    }

    private func pillar(_ s: AttestationSummary, _ id: String) -> AttestationPillar? {
        s.pillars.first { $0.id == id }
    }

    @Test func threePillarsInTrustOrder() {
        let s = summary(attestation: .preview, verifiedResponseCount: 3)
        #expect(s.pillars.map(\.id) == ["hardware", "code", "private"])
        #expect(s.pillars.allSatisfy { !$0.checks.isEmpty })
    }

    @Test func checksLandUnderTheRightPillar() {
        var dcap = RecordDCAPVerification()
        dcap.gateway = .verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
        let s = summary(attestation: .preview, verifiedResponseCount: 2,
                        imageProvenance: .allVerified(verified: [], thirdParty: []), dcap: dcap)

        let hardware = Set((pillar(s, "hardware")?.checks ?? []).map(\.label))
        #expect(hardware.contains("Intel DCAP verification"))
        #expect(hardware.contains("TDX quote signature"))
        #expect(hardware.contains("Intel certificate chain"))

        let code = Set((pillar(s, "code")?.checks ?? []).map(\.label))
        #expect(code.contains("Running code matches manifest"))
        #expect(code.contains("Images built from near.ai source"))

        let priv = Set((pillar(s, "private")?.checks ?? []).map(\.label))
        #expect(priv.contains("End-to-end encryption"))
        #expect(priv.contains("Signing key bound to hardware"))
        #expect(priv.contains("Response signatures"))
    }

    @Test func allVerified_pillarsAreVerified() {
        var dcap = RecordDCAPVerification()
        dcap.gateway = .verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
        let s = summary(attestation: .preview, verifiedResponseCount: 2,
                        imageProvenance: .allVerified(verified: [], thirdParty: []), dcap: dcap)
        #expect(pillar(s, "hardware")?.state == .verified)
        #expect(pillar(s, "code")?.state == .verified)
        #expect(pillar(s, "private")?.state == .verified)
        #expect(pillar(s, "private")?.chipLabel == "encrypted")
    }

    @Test func e2eeDown_onlyPrivacyPillarNeedsAttention() {
        // E2EE failed on the last request, but hardware + code are fine — the
        // privacy failure must not drag the other pillars down.
        let s = summary(attestation: .preview, state: .degraded, lastRequestUsedE2EE: false,
                        imageProvenance: .allVerified(verified: [], thirdParty: []))
        #expect(pillar(s, "private")?.state == .attention)
        #expect(pillar(s, "hardware")?.state == .verified)
        #expect(pillar(s, "code")?.state == .verified)
    }

    @Test func noManifest_codePillarIsAbsent() {
        // previewDegraded carries no compose manifest → nothing to vouch for.
        let s = summary(attestation: .previewDegraded, state: .degraded)
        #expect(pillar(s, "code") == nil)
    }

    @Test func dcapHardFailure_marksHardwareAttention() {
        var dcap = RecordDCAPVerification()
        dcap.gateway = .failed("PCCS collateral unavailable")
        let s = summary(attestation: .preview, dcap: dcap)
        #expect(pillar(s, "hardware")?.state == .attention)
        #expect(pillar(s, "hardware")?.chipLabel == "needs attention")
    }

    @Test func verifying_pillarsAreChecking() {
        let s = summary(attestation: nil, state: .verifying)
        // With no record yet, verifying pillars still surface with pending rows.
        for p in s.pillars { #expect(p.state == .checking) }
    }

    @Test func hardwareLineNamesGPUWhenPresent() {
        let s = summary(attestation: .preview)  // preview has gpuArch HOPPER
        #expect(pillar(s, "hardware")?.summaryLine.contains("NVIDIA") == true)
    }
}
