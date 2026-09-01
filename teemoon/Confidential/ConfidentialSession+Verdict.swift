//
//  ConfidentialSession+Verdict.swift
//  teemoon
//
//  What the session *means* right now: chip state, degrade reason, send
//  gate. Kept off ConfidentialSession.swift so the lifecycle file is not
//  also the interpreter.
//

import Foundation

extension ConfidentialSession {

    /// Title / ladder mismatch count, honouring the UI-test seed.
    var effectiveMismatchCount: Int {
        #if DEBUG
        if let seeded = Self.seededState, seeded.mismatchCount > 0 { return seeded.mismatchCount }
        #endif
        return mismatchedResponseCount
    }

    /// Combined security state derived from attestation + E2EE status.
    var attestationState: AttestationState {
        #if DEBUG
        if let seeded = Self.seededState { return seeded.state }
        #endif
        // NO PLATFORM GUARD HERE, DELIBERATELY.
        //
        // This whole computation used to sit inside `#if os(iOS)` with an
        // `#else return .none`, carried in mechanically by the AppManager
        // refactor (3500bd7) rather than decided. The effect on macOS was that
        // every fail-closed check below — code identity, recipe integrity, image
        // provenance, DCAP verdict, nonce echo, GPU and TLS attestation, E2EE key
        // binding to a verified model TEE — did not run, and every provider
        // reported "nothing to attest" while the UI looked like it had checked.
        //
        // Nothing in here is platform-specific: it reads model state and returns
        // an enum. An app whose stated value is verified confidential inference
        // must not silently answer `.none` on a platform it ships.
        guard let provider = activeProvider, provider.capabilities.contains(.attestation) else { return .none }
        // near.ai serves no confidential endpoint for this model — it can't be
        // attested, so present it as a plain non-attestable model rather than
        // spinning on "verifying" forever.
        if noConfidentialEndpoint { return .none }
        guard let attestation else {
            return attestationFetchFailed ? .degraded : .verifying
        }
        // Fail-closed: if the manifest we were shown does not match what the
        // enclave actually booted, the code identity is broken regardless of E2EE.
        if attestation.codeIdentityVerified == false { return .degraded }
        // Fail-closed: the running recipe (inner compose) did not match the hash
        // the signed action log pinned — the config that launched the model
        // enclave is unverified/tampered. This is the trust seam's load-bearing
        // check; a transient fetch failure (`.fetchFailed`) deliberately does
        // NOT reach here, so a GitHub blip never masquerades as tamper.
        if modelComposeIntegrityFailed { return .degraded }
        // Fail-closed: if an image in the manifest did not trace to a pinned
        // near.ai workflow, the running code is not provably near.ai's. (A
        // pending/nil result does not degrade — provenance is still in flight.)
        // Signature / identity / digest failures degrade. A clean GitHub 404
        // (unpublished image) does not — E2EE can still be intact. The chip
        // stays off `.ok` via `unpublishedOnlyButE2EEIntact`, not this gate.
        if case .incomplete = imageProvenance, imageProvenance?.isUnpublishedOnly != true {
            return .degraded
        }
        // Fail-closed: real DCAP verification is the authoritative quote
        // verdict. A hard failure — quote doesn't verify, collateral
        // unavailable, or TCB revoked — breaks the hardware root of trust.
        // Out-of-date TCB is flagged in the sheet, not degraded (matching
        // near.ai's own verifier). nil = still in flight.
        if dcapVerification?.hasHardFailure == true { return .degraded }
        // Fail-closed: a quote that does not echo our request nonce may be a
        // replay of an older attestation.
        if attestation.nonceEchoed == false { return .degraded }
        // Fail-closed: GPU evidence that didn't verify — whether NVIDIA rejected
        // it (hard) or NRAS was simply unreachable (inconclusive) — breaks the
        // GPU half of the trust chain either way. Both degrade; only a genuine
        // rejection is HARD (see `degradeIsHardFailure`). nil = in flight.
        if gpuAttestation?.isUnverified == true { return .degraded }
        // Fail-closed: TLS attestation that didn't verify — a fingerprint
        // mismatch (hard, possible MITM) or an unreachable/unparseable check
        // (inconclusive) — means the connection isn't provably terminating in
        // the enclave. `.notPerformed` (no direct host) is neutral; nil = in flight.
        if tlsAttestation?.isUnverified == true { return .degraded }
        // Fail-closed: a present-but-malformed key is a broken E2EE promise,
        // not "no E2EE expected". Both `e2eeDegradedReason` and
        // `e2eeBindingIntact` require `key.count == 32`; without this gate a
        // wrong-length key with a verified model quote read as `.ok` (green
        // chip) because `e2eeKeyBoundToModelTEE` returns nil — not false —
        // when the length is wrong.
        if let key = attestation.modelEd25519PubKey, key.count != 32 { return .degraded }
        let e2eeExpected = attestation.modelEd25519PubKey != nil
        if e2eeExpected {
            // After a request: reflect actual result.
            if lastRequestUsedE2EE == false { return .degraded }
            // E2EE key must be cryptographically bound to a verified model TEE.
            // If model attestation was parsed, check TDX verification + key binding.
            if let mqv = attestation.modelQuoteVerification {
                if !mqv.isVerified { return .degraded }
                if attestation.e2eeKeyBoundToModelTEE == false { return .degraded }
                // Sealed, but a digest has no published attestation — not `.ok`.
                if imageProvenance?.isUnpublishedOnly == true { return .degraded }
                return .ok
            }
            // No model attestation available — can't confirm E2EE key provenance.
            return .degraded
        }
        // Attestation available but no Ed25519 key — TEE verified, no E2EE possible.
        return .degraded
    }

    /// Human-readable reason why E2EE is not available. Non-nil only when the provider
    /// supports attestation but E2EE cannot be established.
    var e2eeDegradedReason: String? {
        guard let provider = activeProvider, provider.capabilities.contains(.attestation) else { return nil }
        guard let attestation else {
            if attestationFetchFailed { return "Could not reach the attestation server." }
            return nil // still loading
        }
        if dcapVerification?.hasHardFailure == true {
            return "The hardware quote failed Intel DCAP verification."
        }
        // Mirror every degrade condition in `attestationState` so the alert
        // names the actual cause — an unexplained block gets misattributed to
        // whatever flag happens to be visible (e.g. an out-of-date TCB, which
        // deliberately does NOT degrade).
        if attestation.codeIdentityVerified == false {
            return "The running code does not match the attested manifest."
        }
        if modelComposeIntegrityFailed {
            return "The running recipe doesn’t match the signed action log — the launched configuration is unverified."
        }
        if unpublishedOnlyButE2EEIntact {
            return "An image has no published attestation — the send is still sealed."
        }
        if case .incomplete = imageProvenance {
            return "An image could not be traced to near.ai's published source."
        }
        if attestation.nonceEchoed == false {
            return "The attestation did not echo this session's nonce (possible replay)."
        }
        if let gpu = gpuAttestation, gpu.isUnverified {
            return gpu.isHardFailure
                ? "NVIDIA GPU attestation failed verification."
                : "NVIDIA GPU attestation couldn't be completed (service unreachable)."
        }
        if let tls = tlsAttestation, tls.isUnverified {
            return tls.isHardFailure
                ? "The connection could not be verified to end inside the enclave (possible interception)."
                : "The connection to the enclave couldn't be verified (attestation unreachable)."
        }
        if lastRequestUsedE2EE == false, let reason = lastE2EEFailReason {
            return reason
        }
        guard let key = attestation.modelEd25519PubKey, key.count == 32 else {
            return "The model's encryption key is unavailable."
        }
        if let mqv = attestation.modelQuoteVerification {
            if !mqv.isVerified { return "The model's hardware attestation failed verification." }
            if attestation.e2eeKeyBoundToModelTEE == false { return "The encryption key is not bound to verified hardware." }
        } else {
            return "The model's hardware attestation is unavailable."
        }
        return nil
    }

    /// True when the ONLY blocking failure is image provenance while E2EE
    /// itself is fully established — the key is bound to verified hardware, so
    /// a send would still be sealed end-to-end; the residual risk is an
    /// unverified image inside the enclave boundary, not plaintext on the
    /// wire. The confirmation alert uses this to say the truth ("still
    /// encrypted — code unverified") instead of the misleading "send
    /// unencrypted" (observed: a node-lottery provenance 404 read as an
    /// encryption failure).
    var provenanceBlockedButE2EEIntact: Bool {
        guard case .incomplete = imageProvenance else { return false }
        return e2eeBindingIntact
    }

    /// Clean GitHub 404s only, with the model key bound to verified hardware.
    /// Send stays sealed and ungated; the session is not fully verified.
    var unpublishedOnlyButE2EEIntact: Bool {
        imageProvenance?.isUnpublishedOnly == true && e2eeBindingIntact
    }

    /// Key bound to a verified model TEE; GPU/TLS not in an unverified state.
    ///
    /// Internal, not private: the attestation sheet's hero copy needs the same
    /// signal (`AttestationSummary.e2eeIntact`) so a degrade whose send is still
    /// sealed does not announce "E2EE is unavailable".
    var e2eeBindingIntact: Bool {
        guard let att = attestation,
              dcapVerification?.hasHardFailure != true,
              att.codeIdentityVerified != false,
              att.nonceEchoed != false,
              let key = att.modelEd25519PubKey, key.count == 32,
              att.modelQuoteVerification?.isVerified == true,
              att.e2eeKeyBoundToModelTEE != false else { return false }
        if gpuAttestation?.isUnverified == true { return false }
        if tlsAttestation?.isUnverified == true { return false }
        return true
    }

    /// Whether the current degrade is a HARD, adversarial integrity break
    /// (tamper, replay, MITM, an unbound/unverified key) as opposed to a
    /// transient/operational condition (verifier unreachable, an image still
    /// tracing to source). Drives the red-vs-orange hero tier: a hard break must
    /// render RED, never as a benign advisory. False whenever the session isn't
    /// degraded, or the only cause is soft (fetch failure, provenance still in
    /// flight, or E2EE simply unavailable with the key otherwise intact).
    var degradeIsHardFailure: Bool {
        #if DEBUG
        if let seeded = Self.seededState { return seeded.hardFailure }
        #endif
        guard attestationState == .degraded, let att = attestation else { return false }
        if att.codeIdentityVerified == false { return true }
        if modelComposeIntegrityFailed { return true }
        if dcapVerification?.hasHardFailure == true { return true }
        if att.nonceEchoed == false { return true }
        // HARD only for a genuine negative verdict (NVIDIA rejection / nonce
        // replay; TLS fingerprint mismatch / binding failure). An unreachable
        // NRAS/TLS check is `.inconclusive` → soft: it still degrades (above),
        // but must never be branded tamper/MITM with a no-bypass block.
        if gpuAttestation?.isHardFailure == true { return true }
        if tlsAttestation?.isHardFailure == true { return true }
        if att.modelEd25519PubKey != nil {
            // Plaintext went out unsealed, or the key isn't bound to a verified
            // model TEE — both are hard breaks of the E2EE guarantee.
            if lastRequestUsedE2EE == false { return true }
            if let mqv = att.modelQuoteVerification {
                if !mqv.isVerified { return true }
                if att.e2eeKeyBoundToModelTEE == false { return true }
            }
        }
        // Remaining degrades — provenance `.incomplete` with E2EE intact, no
        // Ed25519 key, or model attestation simply unavailable — are advisory.
        return false
    }

    /// THE send gate, canonical. `.allow` sends; `.confirm` requires the user
    /// to see the degrade and choose; `.block` refuses outright. Every entry
    /// point that can start a generation — ChatView (via
    /// `ChatViewModel.sendPolicy(session:)`, which delegates here) and the
    /// Siri/Shortcuts `RequestLLMIntent` — must consult THIS property; a
    /// second derivation is exactly how the intent bypassed the gate.
    var sendPolicy: TrustSendPolicy {
        TrustVerdict.sendPolicy(
            requiresConfirmation: requiresE2EEConfirmation,
            hardFailure: degradeIsHardFailure
        )
    }

    /// Whether sending a message requires user confirmation because E2EE is expected
    /// but cannot be established.
    var requiresE2EEConfirmation: Bool {
        guard let provider = activeProvider, provider.capabilities.contains(.attestation) else { return false }
        // Unpublished image + sealed E2EE: no modal. The ladder still names
        // the digest. Shopping for another CVM's report would be a false verify.
        if unpublishedOnlyButE2EEIntact { return false }
        return attestationState == .degraded
    }
}
