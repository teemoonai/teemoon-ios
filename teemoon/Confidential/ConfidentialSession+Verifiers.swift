//
//  ConfidentialSession+Verifiers.swift
//  teemoon
//
//  The four post-fetch checks: image provenance, DCAP, NVIDIA NRAS, TLS.
//  Kept off ConfidentialSession.swift so the lifecycle file is not also
//  the verifier fan-out.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "confidential")

extension ConfidentialSession {

    /// Verifies image provenance for the record's manifest (async, off the
    /// attestation fetch). Fail-closed: any fetch/verify failure yields an
    /// `.incomplete` result, which degrades the security state. Skipped when
    /// there is no manifest to check.
    func verifyImageProvenance(for record: AttestationRecord) {
        if freezeAttestationFixtures { return }
        provenanceTask?.cancel()
        imageProvenance = nil
        modelLayerVerification = nil
        modelLayerManifest = nil
        modelArtifact = nil
        // Both attested container sets: the gateway CVM's manifest and the
        // model node's own manifest (the enclave that reads plaintext).
        let manifests: [(host: String, manifest: String)] = [
            (host: "gateway", manifest: record.composeManifest ?? ""),
            (host: "model", manifest: record.gpuNodeComposeManifest ?? ""),
        ].filter { !$0.manifest.isEmpty }
        guard !manifests.isEmpty || record.modelComposeCommit != nil else { return }
        let service = provenanceService
        provenanceTask = Task { [weak self] in
            var all = manifests
            var layerVerification: ModelLayerVerification? = nil
            // The inference layer: fetch the model YAML at the attested
            // commit/path and hash-check it against the pinned value — extending
            // per-image provenance one level down. The three outcomes are
            // distinct: a `.hashMismatch` is fail-closed (degrades via
            // `modelComposeIntegrityFailed`); a `.fetchFailed` is transient
            // (advisory only, never a tamper accusation).
            if let path = record.modelComposePath, let commit = record.modelComposeCommit,
               let sha = record.modelFileHash {
                switch await service.fetchModelLayerManifest(
                    path: path, commit: commit, expectedSHA256: sha) {
                case .verified(let inner):
                    layerVerification = .verified
                    // Scope a COMBINED node's compose to the REQUESTED model for
                    // display: near.ai reuses one node for several models, but the
                    // E2EE proxy routes YOUR request only to YOUR model's server,
                    // so the co-located servers never receive your plaintext. Drop
                    // them (and their engine-image anchors) so the tiers + image
                    // list reflect only the model you're talking to. Hash
                    // verification already passed on the FULL attested inner; the
                    // scoped view is a subset of that same document.
                    let scopedInner = PlaintextExposure.scoped(inner, toModel: record.model)
                    let artifact = ModelArtifact.parse(fromComposeYAML: scopedInner, servingModel: record.model)
                    // The manifest is ALWAYS kept: identity was already established
                    // by the verified served `model_name` (gpuReportServesExpectedModel),
                    // so the compose is only DISPLAY enrichment. On reused/combined
                    // nodes vLLM's bare-positional form (gpt-oss / Qwen3-VL) isn't
                    // cleanly parseable, so if the selected artifact doesn't serve
                    // the requested model, adopt NO artifact (header falls back to
                    // the requested id — never the wrong model, the original
                    // DeepSeek-shows-Qwen bug) but STILL keep the manifest so the
                    // panel stays complete instead of collapsing to "couldn't
                    // determine".
                    all.append((host: "model", manifest: scopedInner))
                    if !Task.isCancelled {
                        // Keep the verified (scoped) text: PlaintextExposure + the
                        // measured-config panel read this same document.
                        self?.modelLayerManifest = scopedInner
                        if let artifact,
                           !NearAIModelCatalog.differentVendor(artifact.servedName, record.model) {
                            logger.warning("[provenance] artifact base=\(artifact.baseModelName, privacy: .public) served=\(artifact.servedName ?? "nil", privacy: .public) for \(record.model ?? "nil", privacy: .public)")
                            self?.modelArtifact = artifact
                        } else {
                            logger.warning("[provenance] no matching model-layer artifact for \(record.model ?? "nil", privacy: .public) on reused/combined node — keeping images+tiers, name falls back to requested id")
                            self?.modelArtifact = nil
                        }
                    }
                case .hashMismatch(let expected, let got):
                    // Adversarial: the recipe on disk is NOT what the action log
                    // pinned. Do NOT add it to the provenance set — but the
                    // session fails closed via `modelComposeIntegrityFailed`, so
                    // the outer-only provenance can't fall back to a benign
                    // `.allVerified` and read as safe.
                    layerVerification = .hashMismatch
                    logger.error("[provenance] INTEGRITY BREAK — inner compose hash mismatch (pinned \(expected, privacy: .public), got \(got, privacy: .public)) — degrading fail-closed")
                case .fetchFailed:
                    // Transient — could not reach the source. Advisory only; the
                    // next refresh retries. Never a tamper accusation.
                    layerVerification = .fetchFailed
                }
                // Publish the recipe verdict IMMEDIATELY (before the slow
                // per-image manifest sweep below). A detected hash mismatch must
                // degrade fail-closed the instant it's known — not render green
                // for the seconds `verifyManifests` takes, and never be dropped
                // if this task is cancelled mid-sweep (model switch / re-verify).
                if !Task.isCancelled { self?.modelLayerVerification = layerVerification }
            }
            let result = await service.verifyManifests(all)
            guard !Task.isCancelled else { return }
            self?.modelLayerVerification = layerVerification
            if result.isInconclusive {
                // Rate limit / network trouble only — no negative evidence.
                // Leave provenance pending instead of degrading the session;
                // the next attestation refresh retries.
                logger.warning("[provenance] inconclusive (transient fetch errors only) — leaving pending")
                self?.imageProvenance = nil
                return
            }
            self?.imageProvenance = result
            switch result {
            case .allVerified(let refs, let thirdParty):
                logger.info("[provenance] all \(refs.count) near.ai image(s) trace to a pinned workflow (\(thirdParty.count) third-party sidecar(s) digest-pinned)")
            case .incomplete(let verified, let failures, _):
                if result.isUnpublishedOnly {
                    logger.warning("[provenance] \(verified.count) verified, \(failures.count) unpublished (GitHub 404) — sealed send still allowed")
                } else {
                    logger.warning("[provenance] \(verified.count) verified, \(failures.count) near.ai image(s) unverified — degrading")
                }
            }
        }
    }

    /// Runs real DCAP verification over the record's quotes (async, off the
    /// attestation fetch — it needs Intel PCS collateral). Fail-closed: a
    /// hard failure degrades the security state via `attestationState`.
    func verifyDCAP(for record: AttestationRecord) {
        dcapTask?.cancel()
        dcapVerification = nil
        let service = dcapService
        dcapTask = Task { [weak self] in
            let result = await service.verify(record: record)
            guard !Task.isCancelled else { return }
            self?.dcapVerification = result
            if result.hasHardFailure {
                logger.warning("[dcap] hard failure — degrading session")
            }
        }
    }

    /// Verifies the record's GPU evidence against NVIDIA NRAS (async, off the
    /// attestation fetch). Skipped when there is no `nvidia_payload`;
    /// fail-closed once evidence exists.
    func verifyGPU(for record: AttestationRecord) {
        nrasTask?.cancel()
        gpuAttestation = nil
        guard let payload = record.nvidiaPayload, !payload.isEmpty else { return }
        let service = nrasService
        let nonce = record.modelNonce
        nrasTask = Task { [weak self] in
            let result = await service.verify(payloadJSON: payload, expectedNonceHex: nonce)
            guard !Task.isCancelled else { return }
            self?.gpuAttestation = result
        }
    }

    /// Verifies that HTTPS terminates inside the model TEE (async, off the
    /// fetch). Runs against the model's authoritative direct host; when the
    /// model has no direct host, TLS attestation isn't applicable
    /// (`.notPerformed`). Fail-closed: a `.failed` verdict degrades the state.
    func verifyTLS(for provider: Provider) {
        tlsTask?.cancel()
        tlsAttestation = nil
        let service = tlsService
        let model = provider.model
        tlsTask = Task { [weak self] in
            guard let directBase = await EndpointDirectory.shared.directBase(forModel: model) else {
                self?.tlsAttestation = .notPerformed
                return
            }
            // No credential is passed: the probe is deliberately unauthenticated
            // (see TLSAttestationVerifier.makeProbeRequest) — it rides an
            // any-trust connection whose peer is only verified AFTER the fact.
            let result = await service.verify(directBaseURL: directBase)
            guard !Task.isCancelled else { return }
            self?.tlsAttestation = result
            if case .failed(let why) = result { logger.warning("[tls] failed — \(why, privacy: .public)") }
        }
    }
}
