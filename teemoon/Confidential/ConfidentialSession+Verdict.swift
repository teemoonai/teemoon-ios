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
    /// DCAP couldn't fetch or read Intel's collateral for a quote, or (a) couldn't for the compose manager's.
    var couldntCheckHardware: Bool {
        dcapVerification?.hasUnchecked == true || trustScope?.binding == .unchecked
    }

    /// A soft state in which the send would still go out sealed (the same peer the send seals to), and it
    /// isn't the provenance-only case: the "still checking near.ai's hardware" confirm, never "send
    /// unencrypted" (near-send-gate-rule, the maintainer 2026-11-06).
    var softButSealed: Bool {
        !degradeIsHardFailure && !provenanceBlockedButE2EEIntact && canSeal
    }

    /// The title's "encrypted · hardware not confirmed" (trust-caption-sealed): a soft state that asks, whose
    /// send is still sealed, and whose last request didn't go out plain.
    var sealedButHardwareUnconfirmed: Bool {
        let asksAboutHardware = sendPolicy == .confirm && !provenanceUncheckedAsks
        let answeredWhileChecking = chipState == .degraded && attestationState == .verifying
        return (asksAboutHardware || answeredWhileChecking) && softButSealed && lastRequestUsedE2EE != false
    }

    /// The lookup ended inconclusive (T2b) and nothing else degrades: the chip keeps its look, the send asks.
    var provenanceUncheckedAsks: Bool {
        provenanceInconclusive && imageProvenance == nil && attestation != nil
            && attestationState != .degraded && attestationState != .none
    }

    /// What the chip reads; the gate reads `attestationState`. Once "send anyway" answered a pending ask for this
    /// record a send may leave while it runs, so the chip must not read verifying (formal/ ChipNeverVerifyingAtSend).
    var chipState: AttestationState {
        guard attestationState == .verifying, let kind = pendingKind, hasConfirmed(pending: true) else { return attestationState }
        return kind == .hardware ? .degraded : .ok
    }

    /// One confirm per (record, reason): the same record and reason don't ask again (near-send-gate-rule).
    func confirmationKey(pending: Bool) -> String? {
        guard let att = attestation else { return nil }
        let record = "\(att.fetchedAt.timeIntervalSince1970)|\(att.gatewayNonce ?? att.gpuNonce ?? "")"
        // A couldn't-check already known (policy .confirm) is what the ask answers, even while other checks run:
        // one answer covers the record (F4 strict). "pending" only when nothing is known yet.
        let pendingReason = pendingKind == .provenance ? "provenancePending" : "pending"
        let reason = pending && sendPolicy != .confirm ? pendingReason
            : e2eeDegradedReason ?? (provenanceUncheckedAsks ? "provenanceUnchecked" : "")
        return "\(record)|\(reason)"
    }

    func hasConfirmed(pending: Bool) -> Bool {
        confirmationKey(pending: pending).map(confirmedDegrades.contains) ?? false
    }

    func rememberConfirmation(pending: Bool) {
        if let key = confirmationKey(pending: pending) { confirmedDegrades.insert(key) }
    }

    /// The policy the composer asks with: a confirm already given for this record and reason doesn't ask again.
    var sendPolicyAfterConfirmations: TrustSendPolicy {
        sendPolicy == .confirm && hasConfirmed(pending: false) ? .allow : sendPolicy
    }

    /// Older than `attestationMaxAge`, and the refetch failed.
    func recordIsStaleAndUnrefreshable(_ record: AttestationRecord) -> Bool {
        attestationFetchFailed && now().timeIntervalSince(record.fetchedAt) > Self.attestationMaxAge
    }

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
        // A record past its age whose refetch failed is not still verified: soft, the send asks (T5).
        if recordIsStaleAndUnrefreshable(attestation) { return .degraded }
        // Fail-closed: if the manifest we were shown does not match what the
        // enclave actually booted, the code identity is broken regardless of E2EE.
        if attestation.codeIdentityVerified == false { return .degraded }
        // Fail-closed: the running recipe (inner compose) did not match the hash
        // the signed action log pinned — the config that launched the model
        // enclave is unverified/tampered. This is the trust seam's load-bearing
        // check; a transient fetch failure (`.fetchFailed`) deliberately does
        // NOT reach here, so a GitHub blip never masquerades as tamper.
        if modelComposeIntegrityFailed { return .degraded }
        // The action log, the boot log or a running compose file contradicts the hardware (trust scope).
        if trustScope?.hardBreak == true { return .degraded }
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
        // Intel couldn't be asked about a quote: soft, the send asks (near-send-gate-rule).
        if couldntCheckHardware { return .degraded }
        // near.ai's tier list never came: can't check, soft, the send asks (formal/ TierTimeout).
        if tierGaveUp { return .degraded }
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
                // DCAP, GPU or TLS still in flight: the same predicate the send gate waits on. Before the
                // unpublished-image case too, which asks nothing at the gate and would read "verified" early.
                if verdictsPending { return .verifying }
                // Sealed, but a digest has no published attestation — not `.ok`.
                if imageProvenance?.isUnpublishedOnly == true { return .degraded }
                // Sealed, and provenance is still being fetched: not green yet; the send waits for it (S30).
                if imageProvenance == nil, !provenanceSettled, provenanceTask != nil { return .verifying }
                // The near.ai tier is still unknown: it could resolve to third-party and the send go plain, so never
                // "verified" yet (`verdictsPending` holds the send).
                if deadline.tier(for: provider.model) == .unknown { return .verifying }
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
            if directHostMissing { return "near.ai lists no confidential host for this model yet." }
            if attestationFetchFailed { return "couldn't reach the attestation server." }
            return nil // still loading
        }
        if recordIsStaleAndUnrefreshable(attestation) { return "couldn't reach the attestation server." }
        if dcapVerification?.hasHardFailure == true {
            return "the hardware quote failed intel dcap verification."
        }
        // Mirror every degrade condition in `attestationState` so the alert
        // names the actual cause — an unexplained block gets misattributed to
        // whatever flag happens to be visible (e.g. an out-of-date TCB, which
        // deliberately does NOT degrade).
        if attestation.codeIdentityVerified == false {
            return "the running code doesn't match the attested manifest."
        }
        if modelComposeIntegrityFailed {
            return trustScope?.binding == .bound
                ? "the running recipe doesn't match the signed action log, so the launched configuration is unverified."
                : TrustScopeText.runningMismatchUnsignedBanner
        }
        if let scope = trustScope {
            if case .mismatch = scope.binding { return TrustScopeText.actionLogBanner }
            if case .mismatch = scope.boot { return TrustScopeText.bootLogBanner }
            if scope.runningMismatch {
                return scope.binding == .bound
                    ? "the running recipe doesn't match the signed action log, so the launched configuration is unverified."
                    : TrustScopeText.runningMismatchUnsignedBanner
            }
        }
        if unpublishedOnlyButE2EEIntact {
            return "an image has no published attestation. the send is still sealed."
        }
        if case .incomplete = imageProvenance {
            return "an image couldn't be traced to near.ai's published source."
        }
        if attestation.nonceEchoed == false {
            return "the attestation didn't echo this session's nonce (possible replay)."
        }
        if couldntCheckHardware { return "intel's hardware check couldn't be completed (service unreachable)." }
        // A check that failed inside teemoon proved nothing about the service: say so, not "unreachable".
        if case .inconclusive(NRASVerification.teemoonFault)? = gpuAttestation { return NRASVerification.teemoonFault }
        if case .inconclusive(NRASVerification.teemoonFault)? = tlsAttestation { return NRASVerification.teemoonFault }
        // No GPU evidence was sent: nothing was unreachable, so never "(service unreachable)".
        if case .inconclusive(NRASVerification.evidenceAbsent)? = gpuAttestation { return NRASVerification.evidenceAbsent }
        if let gpu = gpuAttestation, gpu.isUnverified {
            return gpu.isHardFailure
                ? "nvidia gpu attestation failed verification."
                : "nvidia gpu attestation couldn't be completed (service unreachable)."
        }
        if let tls = tlsAttestation, tls.isUnverified {
            return tls.isHardFailure
                ? "the model node's tls certificate doesn't match its attestation."
                : "teemoon couldn't check the model node's tls certificate (unreachable)."
        }
        if lastRequestUsedE2EE == false, let reason = lastE2EEFailReason {
            return reason
        }
        guard let key = attestation.modelEd25519PubKey, key.count == 32 else {
            return "the model's encryption key is unavailable."
        }
        if let mqv = attestation.modelQuoteVerification {
            if !mqv.isVerified { return "the model's hardware attestation failed verification." }
            if attestation.e2eeKeyBoundToModelTEE == false { return "the encryption key isn't bound to verified hardware." }
        } else {
            return NRASVerification.evidenceAbsent
        }
        // The mildest reason: last, so it never masks a worse one in the hero.
        if tierGaveUp { return VerdictDeadline.tierReason }
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
        // An unpublished-only image never blocks by itself, so any ask beside it is about something else.
        guard case .incomplete = imageProvenance, imageProvenance?.isUnpublishedOnly != true else { return false }
        return e2eeBindingIntact
    }

    /// Clean GitHub 404s only, with the model key bound to verified hardware, and nothing else wrong: the
    /// exemption covers the unpublished image alone. Never widen it past that; other evidence must still
    /// block and other outages must still ask (formal/ finding F1, sendgate.json unpublished+… vectors).
    var unpublishedOnlyButE2EEIntact: Bool {
        guard imageProvenance?.isUnpublishedOnly == true, e2eeBindingIntact, let attestation else { return false }
        // Belt (android parity): any hard break beside the image ends the exemption, listed above or not.
        guard !degradeIsHardFailure else { return false }
        return !modelComposeIntegrityFailed && trustScope?.hardBreak != true && !couldntCheckHardware
            && !recordIsStaleAndUnrefreshable(attestation) && lastRequestUsedE2EE != false && !tierGaveUp
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
        if trustScope?.hardBreak == true { return true }
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
        let policy = TrustVerdict.sendPolicy(requiresConfirmation: requiresE2EEConfirmation,
                                             hardFailure: degradeIsHardFailure)
        return policy == .allow && provenanceUncheckedAsks ? .confirm : policy
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
