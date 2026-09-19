//
//  ConfidentialSession+Refresh.swift
//  teemoon
//
//  Fetch and adopt an attestation record for the active provider. Kept
//  off ConfidentialSession.swift so the type file is not also the
//  refresh task.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "confidential")

extension ConfidentialSession {

    /// Cancels any in-flight fetch and starts a new one if the active provider supports attestation.
    /// The network request runs off the main thread via URLSession; state updates land back on the main actor.
    /// When `keepExisting` is true, the current attestation record stays visible while the fresh one loads
    /// (used by the "verify now" button so the sheet doesn't flash to a loading state).
    func refreshAttestation(keepExisting: Bool = false) {
        // Xcode Previews must never touch the network: the attestation pipeline
        // (gateway + racing model fetch, Intel PCS, GitHub, NVIDIA) would hang
        // the preview sandbox and its spinners keep RenderPreview from ever
        // reaching a stable snapshot. Previews render from the static data the
        // view is initialized with, so skipping the fetch loses nothing.
        // Preview and `-DesignTour` must not fetch. A tour launch still
        // constructs this type in `TeemoonApp.init` before the body picks
        // the fixture tree, so the skip has to live here — but it must
        // read process flags, not `DesignTour` (Views).
        //
        // `freezeAttestationFixtures` protects a planted record; it does
        // not stop `attestationFetchFailed`. A near.ai outage during a
        // tour run stamped "(refresh failed)" onto the verified-ladder
        // screenshot. Treat the harness as offline, same as Preview.
        if Self.skipsLiveAttestation() { return }
        #if DEBUG
        // `UITEST_SEED_ATTESTATION=e2eeUnavailable`: keep the REAL record
        // absent (no live fetch, so no Ed25519 key and no E2EE peer) while
        // the seeded verdict still answers `.ok` for the send gate — the
        // forcing state for the finding-4.1 fail-closed refusal test. Same
        // DEBUG + `--uitesting` gate as `seededState` itself; a shipping
        // build cannot reach it.
        if let seeded = Self.seededState, seeded.suppressLiveAttestation {
            if seeded.plantsPendingVerifier, tlsTask == nil,
               activeProvider?.capabilities.contains(.attestation) == true {
                tlsTask = Task { try? await Task.sleep(for: .seconds(600)) }
            }
            return
        }
        #endif
        attestationTask?.cancel()
        attestationFetchFailed = false
        // A genuine provider *or model* switch must reset every piece of
        // attestation-derived state — otherwise the previous model's name,
        // images, drift and verdict bleed into the new selection. This clear
        // fires on a context change REGARDLESS of keepExisting: keepExisting
        // only preserves state for the SAME context (re-verify, staleness,
        // foreground refreshes). Gating it on !keepExisting was a trap — the
        // first keepExisting refresh after a switch (the re-verify button, the
        // pre-send staleness check) recorded the new context without clearing,
        // so no later refresh ever saw a change, and the old model's state
        // stuck permanently (observed: GLM-5.1 → 5.2 still showing 5.1).
        let context = activeProvider.map { "\($0.id.uuidString)|\($0.model)" }
        logger.warning("[refresh] context \(self.attestedContext ?? "nil", privacy: .public) -> \(context ?? "nil", privacy: .public) keepExisting=\(keepExisting)")
        if context != attestedContext {
            clearDerivedState(resetCounts: true)
        }
        attestedContext = context
        guard let provider = activeProvider,
              provider.capabilities.contains(.attestation),
              let base = provider.openAIBaseURL else {
            attestation = nil
            return
        }
        let provID = provider.id
        let apiKey = credential(for: provider)
        directHostMissing = false
        attestationAttemptedAt = Date()
        attestationTask = Task { [weak self] in
            // Adopt results only while this task still speaks for the CURRENT
            // (provider, model): a cancelled-but-completing fetch from the
            // previous selection must never write its record back over the
            // fresh state (the second half of the switch-staleness bug — the
            // context clear alone can't stop an in-flight task that is
            // already past its last cancellation checkpoint).
            do {
                // near.ai's live /endpoints directory is the only host map:
                // without the model's direct host the model-enclave manifest is
                // never fetched and the E2EE key cannot bind to the node.
                let gpuNodeURL = await EndpointDirectory.shared.directBase(forModel: provider.model)
                guard !Task.isCancelled, self?.attestedContext == context else { return }
                guard let gpuNodeURL else {
                    // See `outcome(whenNoDirectHostFor:)`.
                    // `.none` — "ordinary model, nothing to verify" — is honest
                    // ONLY for a tier that claims no encryption: proxied, or
                    // attested third-party, neither of which has a confidential
                    // endpoint by design.
                    //
                    // An OWN-FLEET model with no host is unexplained: a cold
                    // directory, a failed fetch, or a gap in the published map.
                    // All three mean "couldn't check", and `.none` there sends
                    // in the clear under a row that says end-to-end encrypted.
                    // Degrade instead, so the send asks first.
                    let outcome = ConfidentialSession.outcome(whenNoDirectHostFor: provider.model)
                    guard !Task.isCancelled, self?.attestedContext == context else { return }
                    if outcome == .degraded {
                        logger.warning("[refresh] no direct host for own-fleet model=\(provider.model, privacy: .public) — degraded, not .none")
                        self?.attestation = nil
                        self?.attestationFetchFailed = true
                        self?.directHostMissing = true
                        return
                    }
                    self?.noConfidentialEndpoint = true
                    self?.attestation = nil
                    return
                }
                self?.noConfidentialEndpoint = false
                logger.warning("[refresh] fetching model=\(provider.model, privacy: .public) gpuNode=\(gpuNodeURL.absoluteString, privacy: .public)")
                let record = try await AttestationService.fetch(
                    baseURL: base, apiKey: apiKey, model: provider.model,
                    providerID: provID, gpuNodeURL: gpuNodeURL
                )
                logger.info("Attestation loaded — gateway: \(record.signingAddress ?? "nil", privacy: .public), gpu: \(record.gpuSigningAddress ?? "nil", privacy: .public)")
                guard !Task.isCancelled, self?.attestedContext == context else {
                    logger.info("Discarding stale attestation result (context switched mid-fetch)")
                    return
                }
                logger.warning("[refresh] adopting record model=\(record.model ?? "nil", privacy: .public) nonce=\(String((record.gatewayNonce ?? "").prefix(4)), privacy: .public) composePath=\(record.modelComposePath ?? "nil", privacy: .public)")
                self?.attestation = record
                self?.verifyImageProvenance(for: record)
                self?.verifyDCAP(for: record)
                self?.verifyGPU(for: record)
                self?.verifyTLS(for: provider)
            } catch {
                logger.error("Attestation fetch failed: \(error)")
                guard !Task.isCancelled, let self, self.attestedContext == context else { return }
                // Keep the cached record for E2EE — a stale key is better than plaintext.
                if self.attestation?.providerID == provID {
                    logger.info("Keeping cached attestation (age: \(Int(Date().timeIntervalSince(self.attestation?.fetchedAt ?? .distantPast)))s)")
                }
                self.attestationFetchFailed = true
            }
        }
    }

    /// Resets all attestation-derived display state on a provider/model switch
    /// so nothing from the previous selection bleeds into the new one. Cancels
    /// the in-flight verify tasks too. Counts are per-context, so they reset on
    /// a real switch but not on an in-place re-verify (keepExisting).
    func clearDerivedState(resetCounts: Bool) {
        provenanceTask?.cancel()
        // Cancel AND drop the handles: a cancelled verifier never answers, and
        // a handle with no answer reads as a verdict still pending.
        dcapTask?.cancel(); dcapTask = nil
        nrasTask?.cancel(); nrasTask = nil
        tlsTask?.cancel(); tlsTask = nil
        attestation = nil
        noConfidentialEndpoint = false
        directHostMissing = false
        modelArtifact = nil
        imageProvenance = nil
        modelLayerVerification = nil
        modelLayerManifest = nil
        dcapVerification = nil
        gpuAttestation = nil
        tlsAttestation = nil
        lastRequestUsedE2EE = nil
        lastE2EEFailReason = nil
        if resetCounts {
            verifiedResponseCount = 0
            mismatchedResponseCount = 0
            gatewayTrustResponseCount = 0
        }
    }

    /// Refetches attestation if the current record is older than `attestationMaxAge`
    /// or if the Ed25519 key is missing (e.g. model TEE was cold-starting during initial fetch).
    /// Called before each generation to keep the Ed25519 key fresh.
    func refreshAttestationIfStale() {
        guard let record = attestation else {
            // A failed fetch is retried, at most once a minute: a directory
            // that lagged the catalogue, or a server that was down, must not
            // stay degraded until a provider switch.
            if attestationFetchFailed,
               attestationAttemptedAt.map({ Date().timeIntervalSince($0) > Self.attestationRetryInterval }) ?? true {
                refreshAttestation()
            }
            return
        }
        let age = Date().timeIntervalSince(record.fetchedAt)
        let keyMissing = record.modelEd25519PubKey == nil
        if age > Self.attestationMaxAge || keyMissing {
            logger.debug("Attestation refetch: \(keyMissing ? "Ed25519 key missing" : "stale (\(Int(age))s old)")")
            refreshAttestation(keepExisting: true)
        }
    }
}
