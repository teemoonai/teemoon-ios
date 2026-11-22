//
//  TrustReviewEntriesTests.swift
//  teemoonTests
//
//  The maintainer's review page, 2026-11-06: trust-unchecked-glyph, trust-provenance-unchecked (T2b), and
//  trust-running-undecidable. Each pins the state its words appear in.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Trust review entries 2026-11-06")
struct TrustReviewEntriesTests {
    private func summary(dcap: RecordDCAPVerification? = nil, provenanceInconclusive: Bool = false) -> AttestationSummary {
        AttestationSummary(
            attestation: .preview, state: .ok, timedOut: false, provider: .nearAI,
            lastRequestUsedE2EE: true, lastE2EEFailReason: nil, verifiedResponseCount: 0, mismatchedResponseCount: 0,
            attestationFetchFailed: false, imageProvenance: nil, dcapVerification: dcap,
            provenanceInconclusive: provenanceInconclusive)
    }

    @Test func anUncheckedIntelQuoteIsOrangeNotTheRedCross() {
        var unchecked = RecordDCAPVerification()
        unchecked.model = .unchecked("collateral: no response from api.trustedservices.intel.com")
        #expect(summary(dcap: unchecked).dcapState == .unchecked)
        #expect(summary(dcap: unchecked).dcapDetail == "intel's hardware check couldn't be completed (service unreachable).")
        var failed = RecordDCAPVerification()
        failed.model = .failed("signature invalid")
        #expect(summary(dcap: failed).dcapState == .stuck, "evidence keeps the red ✕")
    }

    /// pm 2026-11-06 under the send rule: an unreachable NVIDIA or TLS check is "couldn't check", orange;
    /// a rejection or mismatch stays red.
    @Test func unreachableNvidiaAndTLSAreOrangeRejectionsRed() {
        var record = AttestationRecord.preview
        record.nvidiaPayload = "{}"
        func s(nras: NRASVerification? = nil, tls: TLSAttestation? = nil) -> AttestationSummary {
            AttestationSummary(
                attestation: record, state: .ok, timedOut: false, provider: .nearAI,
                lastRequestUsedE2EE: true, lastE2EEFailReason: nil, verifiedResponseCount: 0, mismatchedResponseCount: 0,
                attestationFetchFailed: false, nrasVerification: nras, tlsAttestation: tls)
        }
        let down = s(nras: .inconclusive("NVIDIA attestation service unreachable"))
        #expect(down.nrasState == .unchecked)
        #expect(down.gpuRowDetail == "NVIDIA attestation service unreachable", "only the glyph changes; NVIDIA's own reason stays")
        #expect(s(nras: .failed("NVIDIA rejected the evidence")).nrasState == .stuck)
        #expect(s(tls: .inconclusive("probe unreachable")).tlsRow?.state == .unchecked)
        #expect(s(tls: .inconclusive("probe unreachable")).tlsRow?.detail == "probe of the model node: probe unreachable — could not complete")
        // A teemoon fault isn't an outage: the row says the fault line itself (pm 2026-11-06).
        #expect(s(tls: .inconclusive(NRASVerification.teemoonFault)).tlsRow?.detail == NRASVerification.teemoonFault)
        #expect(s(nras: .inconclusive(NRASVerification.teemoonFault)).gpuRowDetail == NRASVerification.teemoonFault)
        #expect(s(tls: .failed("fingerprint mismatch")).tlsRow?.state == .stuck)
        #expect(s(tls: .notPerformed).tlsRow == nil)
    }

    @Test func anInconclusiveCodeCheckSaysSoInsteadOfSpinning() {
        #expect(summary().provenanceState != .unchecked, "no pass has come back inconclusive")
        let s = summary(provenanceInconclusive: true)
        #expect(s.provenanceState == .unchecked)
        let verdict = TrustVerdict.make(.init(attestationState: .ok, modelName: "GLM", e2eeKeyBound: true,
                                              provenanceState: s.provenanceState))
        #expect(verdict.heroTitle == "encrypted to GLM", "no enclave-key tail over an unchecked code check")
        #expect(verdict.heroSubtitle == ProvenanceUncheckedText.header)
        #expect(verdict.chipCaption == "end-to-end encrypted", "the chip and title keep their words")
        #expect(verdict.everydayClaims.contains { $0.title == ProvenanceUncheckedText.step && $0.status == .alert })
        #expect(verdict.sendPolicy == .allow, "never gates")
    }

    @Test func anUndecidableRowSaysTheLogCantTell() {
        let source = ActionLogReading.Source(commit: "3c2f033b", file: "prod/rotate-compose-manager-token.yaml", fileSHA256: "s")
        let service = ActionLogReading.RunningService(service: "rotate-token", source: source, tag: "v0.0.457", since: "2026-09-29")
        let row = TrustScopeText.runningRow(.init(service: service, outcome: .verified, undecidable: true))
        #expect(row.liveness == TrustScopeLine(text: "the action log can't tell whether this is still running",
                                               detail: "a later full redeploy of another model may have removed it",
                                               tone: .caution))
        #expect(TrustScopeText.runningRow(.init(service: service, outcome: .verified)).liveness == nil)
        #expect(!TrustScope(binding: .bound, boot: .matches,
                            running: [.init(service: service, outcome: .verified, undecidable: true)]).hardBreak)
    }
}
