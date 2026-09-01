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
        if Self.seededState?.suppressLiveAttestation == true { return }
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
        attestationTask = Task { [weak self] in
            // Adopt results only while this task still speaks for the CURRENT
            // (provider, model): a cancelled-but-completing fetch from the
            // previous selection must never write its record back over the
            // fresh state (the second half of the switch-staleness bug — the
            // context clear alone can't stop an in-flight task that is
            // already past its last cancellation checkpoint).
            do {
                // Resolve the model's direct TEE host from near.ai's live
                // /endpoints directory (with the shipped hardcoded map as a
                // fallback), not just the hardcoded presets. Newer models like
                // GLM-5.2 only appear in the live directory, and without their
                // direct host the model-enclave manifest (its image set) is never
                // fetched and the E2EE key can't bind to the node. Mirrors what
                // the TLS path already does.
                let gpuNodeURL = await EndpointDirectory.shared.directBase(forModel: provider.model)
                    ?? provider.directGPUNodeURL
                // near.ai's confidential models each publish a direct host (the
                // invariant the catalog gate enforces). An attestable-classified
                // model that resolves none is one near.ai doesn't serve in an
                // enclave — a retired/stale model like deepseek-v3.2. Attesting it
                // would stall on "verifying" then fail closed, so short-circuit to
                // non-attestable: no false lock, no send block, no spinner.
                guard !Task.isCancelled, self?.attestedContext == context else { return }
                guard let gpuNodeURL else {
                    // No direct host resolved. Distinguish two very different
                    // situations before declaring the model non-attestable:
                    //  • the directory AUTHORITATIVELY lists no confidential host
                    //    → an ordinary model (honest .none: no lock, no block); vs
                    //  • a COLD MISS (directory never reached, nothing persisted)
                    //    for a model the catalog classifies as attestable → we
                    //    can't confirm it's ordinary, so failing to .none would
                    //    fail OPEN to a silent unencrypted send. Surface it as a
                    //    fetch failure (degraded → send needs confirmation) until
                    //    the directory loads and we can tell for sure.
                    let authoritative = await EndpointDirectory.shared.hasAuthoritativeData()
                    guard !Task.isCancelled, self?.attestedContext == context else { return }
                    if !authoritative && NearAIModelCatalog.isAttestable(provider.model) {
                        logger.warning("[refresh] no host for attestable model=\(provider.model, privacy: .public) on a cold directory — failing closed (degraded), not .none")
                        self?.attestation = nil
                        self?.attestationFetchFailed = true
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
        dcapTask?.cancel()
        nrasTask?.cancel()
        tlsTask?.cancel()
        attestation = nil
        noConfidentialEndpoint = false
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
        guard let record = attestation else { return }
        let age = Date().timeIntervalSince(record.fetchedAt)
        let keyMissing = record.modelEd25519PubKey == nil
        if age > Self.attestationMaxAge || keyMissing {
            logger.debug("Attestation refetch: \(keyMissing ? "Ed25519 key missing" : "stale (\(Int(age))s old)")")
            refreshAttestation(keepExisting: true)
        }
    }
}
