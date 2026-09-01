//
//  AttestationHeroCopyTests.swift
//  teemoonTests
//
//  The attestation sheet's hero is the app's headline security claim. Two ways
//  it used to overclaim:
//
//  1. `attestationState` degrades when the attestation NEVER ARRIVED
//     (`attestation == nil && attestationFetchFailed`), and `degradeIsHardFailure`
//     is false there because it needs a record to find a hard break in — so the
//     soft-degrade branch said "verified hardware" with nothing verified.
//  2. The same branch said "E2EE is unavailable" for degrades where the send is
//     still sealed (unpublished image, incomplete provenance) — false, and false
//     in the direction that talks a user out of encryption they still have.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Attestation hero copy")
struct AttestationHeroCopyTests {

    private func summary(
        attestation: AttestationRecord? = .preview,
        state: AttestationState = .ok,
        attestationFetchFailed: Bool = false,
        imageProvenance: ProvenanceService.ManifestProvenance? = nil,
        degradeIsHardFailure: Bool = false,
        e2eeIntact: Bool = false
    ) -> AttestationSummary {
        AttestationSummary(
            attestation: attestation, state: state, timedOut: false, provider: .nearAI,
            lastRequestUsedE2EE: nil, lastE2EEFailReason: nil,
            verifiedResponseCount: 0, mismatchedResponseCount: 0,
            attestationFetchFailed: attestationFetchFailed, imageProvenance: imageProvenance,
            dcapVerification: nil, nrasVerification: nil, tlsAttestation: nil,
            modelLayerVerification: nil,
            degradeIsHardFailure: degradeIsHardFailure,
            e2eeIntact: e2eeIntact)
    }

    // MARK: - Nothing was verified

    @Test func fetchFailedDegrade_claimsNoVerification() {
        // The attestation request failed: there is no record, so no hardware,
        // no code identity and no key was ever checked.
        let s = summary(attestation: nil, state: .degraded, attestationFetchFailed: true)

        #expect(s.headerTitle == "verification unavailable")
        #expect(!s.headerTitle.contains("verified hardware"))
        #expect(s.headerSubtitle.contains("couldn’t reach the attestation service"))
        // No "tamper-proof hardware verified" claim anywhere in the hero.
        #expect(!s.headerSubtitle.contains("tamper-proof hardware verified"))
        // Still an advisory, not a red security break — nothing attacked us.
        #expect(s.headerSeverity == .advisory)
        // And no lock glyph picturing a guarantee that was never established.
        #expect(s.headerIcon == "exclamationmark.triangle.fill")
    }

    // MARK: - Degraded, but the send is still sealed

    @Test func unpublishedImageDegrade_doesNotRetractE2EE() {
        // A clean GitHub 404 on an image digest. The key is still bound to a
        // verified model TEE, so the bytes on the wire are still encrypted.
        let s = summary(state: .degraded, e2eeIntact: true)

        #expect(s.headerTitle == "verified hardware")
        #expect(!s.headerSubtitle.contains("E2EE is unavailable"))
        #expect(s.headerSubtitle.contains("still sealed"))
        #expect(s.headerSeverity == .advisory)
        #expect(s.headerIcon == "lock.trianglebadge.exclamationmark.fill")
    }

    // MARK: - Degraded because E2EE really is off

    @Test func e2eeOffDegrade_saysSo() {
        // Attestation present and hardware fine, but no usable model key —
        // the one case the original copy was written for.
        let s = summary(state: .degraded, e2eeIntact: false)

        #expect(s.headerTitle == "verified hardware")
        #expect(s.headerSubtitle == "tamper-proof hardware verified, but E2EE is unavailable.")
        #expect(s.headerSeverity == .advisory)
    }

    // MARK: - Hard break and the healthy case are unchanged

    @Test func hardFailureDegrade_staysRed() {
        let s = summary(state: .degraded, degradeIsHardFailure: true, e2eeIntact: false)

        #expect(s.headerTitle == "verification failed")
        #expect(s.headerIcon == "xmark.shield.fill")
        #expect(s.headerSeverity == .failed)
        #expect(s.headerSubtitle.contains("treat this chat as unverified"))
    }

    /// A hard break wins over `e2eeIntact` — the flag must never be able to
    /// soften a tamper/replay/MITM verdict.
    @Test func hardFailureDegrade_isNotSoftenedByE2EEIntact() {
        let s = summary(state: .degraded, degradeIsHardFailure: true, e2eeIntact: true)

        #expect(s.headerTitle == "verification failed")
        #expect(s.headerSeverity == .failed)
    }

    @Test func okState_isUnchanged() {
        let s = summary(state: .ok)

        #expect(s.headerTitle == "end-to-end encrypted")
        #expect(s.headerSubtitle == "only you and the attested TEE hardware can read these messages.")
        #expect(s.headerIcon == "checkmark.shield.fill")
        #expect(s.headerSeverity == .ok)
    }
}
