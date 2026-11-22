//
//  AttestationRecord.swift
//  teemoon
//
//  The attestation data model: what one fetch from the near.ai attestation
//  endpoints produced, plus the pass/fail bindings derived from it. The
//  fetcher lives in AttestationService.swift; interpretation for the sheet
//  lives in AttestationSummary.swift.
//

import CryptoKit
import Foundation
import os
import TDXQuoteVerifier

// MARK: - Data model

/// Remembers one manifest's SHA-256 so repeated reads don't re-hash it. Don't make it per-read state again:
/// `attestationState` reads `codeIdentityVerified` several times per view body.
final class ComposeDigest: Sendable {
    private let hash: @Sendable (String) -> String
    private let memo = OSAllocatedUnfairLock<(manifest: String, hex: String)?>(initialState: nil)

    init(hash: @escaping @Sendable (String) -> String = ComposeDigest.sha256Hex) { self.hash = hash }

    func hex(of manifest: String) -> String {
        if let hit = memo.withLock({ $0 }), hit.manifest == manifest { return hit.hex }
        let hex = hash(manifest)
        memo.withLock { $0 = (manifest, hex) }
        return hex
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Cryptographic attestation data returned by the near.ai attestation endpoint.
struct AttestationRecord {
    /// Docker Compose hash pinning the gateway service images (gateway_attestation.info.compose_hash).
    let composeHash: String
    /// Intel TDX MRTD measurement of the gateway TEE (gateway_attestation.info.tcb_info.mrtd).
    let mrtd: String
    /// OS image hash of the GATEWAY node (gateway_attestation.info.os_image_hash).
    let osImageHash: String
    /// OS image hash of the MODEL node (model_attestations[0].info.os_image_hash)
    /// — the guest image the enclave that actually touches your plaintext boots
    /// on. Distinct from `osImageHash` (the gateway node runs a different image).
    /// Optional: absent on older/degraded parses. Ephemeral, non-persisted.
    var modelOSImageHash: String? = nil
    /// Full Intel TDX quote hex from the gateway TEE (gateway_attestation.intel_quote).
    let intelQuote: String
    /// Full Intel TDX quote hex from the model TEE (model attestation intel_quote),
    /// retained raw so real DCAP verification can run on it.
    var modelIntelQuote: String? = nil
    /// Full Intel TDX quote hex from the direct GPU node, retained raw for DCAP.
    var gpuIntelQuote: String? = nil
    /// Random nonces teemoon sent with each attestation request; each quote
    /// must echo its nonce in report_data[32..64] (anti-replay).
    var gatewayNonce: String? = nil
    var modelNonce: String? = nil
    var gpuNonce: String? = nil
    /// Raw `nvidia_payload` JSON from the model attestation, retained for
    /// NRAS verification (its embedded nonce must equal `modelNonce`).
    var nvidiaPayload: String? = nil
    /// Raw docker-compose.yaml manifest from the gateway TEE (tcb_info.app_compose).
    let composeManifest: String?
    /// GPU architecture string from the model TEE (nvidia_payload.arch), e.g. "HOPPER".
    let gpuArch: String?
    /// TEE-measured compose hash of the GPU inference node (info.compose_hash).
    let gpuNodeComposeHash: String?
    /// Raw docker-compose.yaml manifest the GPU node measured at boot
    /// (info.tcb_info.app_compose). The model enclave's own container set —
    /// provenance-checked alongside the gateway's manifest.
    var gpuNodeComposeManifest: String? = nil
    /// SHA256 of the model-specific compose YAML file (compose_manager_attestation.actions[last].file_sha256).
    let modelFileHash: String?
    /// Repo-relative path, git commit, and tag of that YAML, from the same
    /// compose-manager action — pins the inference layer to public source.
    var modelComposePath: String? = nil
    var modelComposeCommit: String? = nil
    var modelComposeTag: String? = nil
    /// ISO8601 times of the newest and previous engine-layer `compose_up`,
    /// read from compose-manager's signed action log (the operator's clock,
    /// inside the signed log — label as log data, never as proven time).
    /// Ephemeral like the rest of the record; never persisted.
    var modelDeployedAt: String? = nil
    var modelPreviouslyDeployedAt: String? = nil

    /// One expert-sheet caption line for the model enclave's deployment
    /// recency: "config deployed 2026-07-16 · previous 2026-07-12"; the view adds
    /// `TrustScopeText.deploymentSuffix`. Dates only (the log carries nanoseconds; the value
    /// here is recency and cadence, not the wall-clock instant). nil when the
    /// action log carried no timestamps.
    var deploymentCaption: String? {
        guard let latest = modelDeployedAt, latest.count >= 10 else { return nil }
        var line = "config deployed \(latest.prefix(10))"
        if let prev = modelPreviouslyDeployedAt, prev.count >= 10 {
            line += " · previous \(prev.prefix(10))"
        }
        return line
    }
    /// Ethereum-style address of the gateway TEE signing key (gateway_attestation.signing_address).
    /// Used when inference goes through the gateway router.
    let signingAddress: String?
    /// Ethereum-style address of the GPU node TEE signing key (signing_address on the direct node).
    /// Used when inference bypasses the gateway and goes directly to the model node.
    let gpuSigningAddress: String?
    /// Model's Ed25519 public key (32 bytes) for E2EE encryption.
    /// Fetched from attestation endpoint with `signing_algo=ed25519`.
    let modelEd25519PubKey: Data?
    /// Result of on-device TDX quote verification for the gateway (nil if not yet checked or quote was empty).
    let quoteVerification: TDXVerificationResult?
    /// Result of on-device TDX quote verification for the GPU node (nil if no GPU node or quote unavailable).
    let gpuQuoteVerification: TDXVerificationResult?
    /// Result of on-device TDX quote verification for the model TEE (from model_attestations[0].intel_quote).
    /// This is the strongest E2EE guarantee: the Ed25519 key is bound to a verified TDX quote.
    var modelQuoteVerification: TDXVerificationResult?
    /// When this record was fetched from the endpoint.
    let fetchedAt: Date
    /// Provider UUID this was fetched for — used for stale detection.
    let providerID: UUID
    /// The model id this record was fetched FOR. The session's read gate
    /// refuses to expose a record whose model doesn't match the active
    /// provider — making stale-model display structurally impossible,
    /// independent of which refresh trigger or task race slips through.
    var model: String? = nil
    /// The GPU node's report as served: trust scope (a)(b) check its compose-manager quote and boot log.
    var gpuNodeReportJSON: Data? = nil
    /// The model node's host the report came from: the chat path is resolved for this host.
    var gpuNodeHost: String? = nil
    /// The report_data each leg's JSON advertises beside its quote; DCAPService fails a quote whose own differs.
    var gatewayAdvertisedReportData: String? = nil
    var modelAdvertisedReportData: String? = nil
    var gpuAdvertisedReportData: String? = nil
    /// Every enclave near.ai listed for the model and each one's result (C3); nil when no list was read.
    var modelCandidates: ModelCandidates.Listed? = nil
    /// The list was asked for and never came: a couldn't-check, never "verified".
    var modelCandidatesListFailed = false
    /// The model leg's measured compose (its info.tcb_info.app_compose), read from the attestation its quote came from.
    var modelComposeManifest: String? = nil
    /// Holds SHA-256 of `composeManifest` once worked out; copies of the record share it.
    var composeDigest = ComposeDigest()
    var modelComposeDigest = ComposeDigest()
    var gpuNodeComposeDigest = ComposeDigest()

    /// Lowercase hex SHA-256 of `composeManifest`, hashed once per record.
    var composeManifestSHA256: String? {
        guard let manifest = composeManifest, !manifest.isEmpty else { return nil }
        return composeDigest.hex(of: manifest)
    }

    /// Whether the gateway signing address is cryptographically bound to the TDX quote's report_data.
    ///
    /// Canonical layout: the 20-byte Ethereum signing address occupies the
    /// first 20 bytes of report_data — the same layout address *extraction*
    /// uses elsewhere (AttestationService reads `reportData.prefix(20)`).
    /// Previously this check compared 32 zero-padded bytes, which silently
    /// also asserted that bytes 20..<32 are zero — a different, stricter
    /// layout than extraction assumed.
    var signingKeyBoundToHardware: Bool? {
        guard let qv = quoteVerification,
              let addr = signingAddress, !addr.isEmpty else { return nil }
        let reportData = qv.measurements.reportData
        let addrHex = addr.hasPrefix("0x") ? String(addr.dropFirst(2)) : addr
        guard let addrBytes = try? Data(hexString: addrHex), addrBytes.count == 20,
              reportData.count >= 20 else { return false }
        return reportData.prefix(20) == addrBytes
    }

    /// Same binding for the model node's ECDSA address against the GPU-leg quote, which must itself verify.
    /// The report's `signing_address` JSON field alone proves nothing.
    var gpuSigningKeyBoundToHardware: Bool? {
        guard let qv = gpuQuoteVerification,
              let addr = gpuSigningAddress, !addr.isEmpty else { return nil }
        let addrHex = addr.hasPrefix("0x") ? String(addr.dropFirst(2)) : addr
        guard let addrBytes = try? Data(hexString: addrHex), addrBytes.count == 20,
              qv.measurements.reportData.count >= 20 else { return false }
        return qv.measurements.reportData.prefix(20) == addrBytes && qv.isVerified
    }

    /// Whether the E2EE Ed25519 key is cryptographically bound to the model TEE's TDX quote: the key is in the
    /// first 32 bytes of report_data AND the quote verified. A key in a quote that didn't verify is not bound (T6).
    var e2eeKeyBoundToModelTEE: Bool? {
        guard let inReportData = e2eeKeyInModelReportData else { return nil }
        return inReportData && modelQuoteVerification?.isVerified == true
    }

    /// Only that the key bytes appear in the model quote's report_data, whether or not the quote verified.
    var e2eeKeyInModelReportData: Bool? {
        guard let mqv = modelQuoteVerification,
              let key = modelEd25519PubKey, key.count == 32 else { return nil }
        let reportData = mqv.measurements.reportData
        guard reportData.count >= 32 else { return false }
        return reportData.prefix(32) == key
    }

    /// The booted code is the manifest shown: SHA256(app_compose) == compose_hash and mr_config == 01 ‖ compose_hash on
    /// the gateway, and every model-node quote commits to the compose it served. Never drop the model nodes from this.
    var codeIdentityVerified: Bool? {
        if modelNodesBootedTheirCompose == false { return false }
        guard let manifest = composeManifest, !manifest.isEmpty,
              !composeHash.isEmpty,
              let qv = quoteVerification else { return nil }
        guard composeDigest.hex(of: manifest) == composeHash.lowercased() else { return false }
        return QuoteChecks.mrConfigCommits(qv.measurements.mrConfigID, toComposeSHA256: composeHash)
    }

    /// The model leg's and the GPU node's quotes each commit to their own app_compose (dstack MRCONFIGID);
    /// nil when neither has a quote and a compose to compare.
    var modelNodesBootedTheirCompose: Bool? {
        func binds(_ qv: TDXVerificationResult?, _ manifest: String?, _ digest: ComposeDigest) -> Bool? {
            guard let qv, let manifest, !manifest.isEmpty else { return nil }
            return QuoteChecks.mrConfigCommits(qv.measurements.mrConfigID, toComposeSHA256: digest.hex(of: manifest))
        }
        let legs = [binds(modelQuoteVerification, modelComposeManifest, modelComposeDigest),
                    binds(gpuQuoteVerification, gpuNodeComposeManifest, gpuNodeComposeDigest)].compactMap { $0 }
        return legs.isEmpty ? nil : legs.allSatisfy { $0 }
    }

    /// Whether every fetched quote echoes the nonce teemoon sent with its
    /// attestation request in report_data[32..64] — proving the quote was
    /// generated for THIS request, not replayed from an earlier one.
    ///
    /// false if any checkable pair mismatches; true if at least one pair
    /// checked and none mismatched; nil when nothing is checkable (no nonce
    /// recorded or no parsed quote).
    var nonceEchoed: Bool? {
        let pairs: [Bool?] = [
            Self.nonceMatches(gatewayNonce, quoteVerification),
            Self.nonceMatches(modelNonce, modelQuoteVerification),
            Self.nonceMatches(gpuNonce, gpuQuoteVerification),
        ]
        let checked = pairs.compactMap { $0 }
        guard !checked.isEmpty else { return nil }
        return checked.allSatisfy { $0 }
    }

    private static func nonceMatches(_ nonce: String?, _ verification: TDXVerificationResult?) -> Bool? {
        guard let nonce, let verification else { return nil }
        let reportData = verification.measurements.reportData
        guard reportData.count >= 64 else { return false }
        return reportData.dropFirst(32).prefix(32).hexString == nonce.lowercased()
    }

    /// Human-readable GPU model name derived from `gpuArch`.
    var gpuModelName: String? {
        switch gpuArch?.uppercased() {
        case "HOPPER":    return "NVIDIA H100"
        case "AMPERE":    return "NVIDIA A100"
        case "ADA":       return "NVIDIA L40S"
        case "BLACKWELL": return "NVIDIA B200"
        case let arch?:   return "NVIDIA \(arch.capitalized)"
        case nil:         return nil
        }
    }
}

extension AttestationRecord {

    // MARK: - Mock TDX data for previews

    /// Builds a mock `TDXVerificationResult` with the given report_data and verification flags.
    private static func mockVerification(
        reportData: Data,
        mrConfigID: Data = Data(count: 48),
        signatureValid: Bool = true,
        certChainValid: Bool = true,
        certChainError: String? = nil
    ) -> TDXVerificationResult {
        let zero48 = Data(count: 48)
        let body = TDXQuote.TDReportBody(
            teeTcbSvn: Data(count: 16), mrSeam: zero48, mrSignerSeam: zero48,
            seamAttributes: Data(count: 8), tdAttributes: Data(count: 8), xfam: Data(count: 8),
            mrtd: zero48, mrConfigID: mrConfigID, mrOwner: zero48, mrOwnerConfig: zero48,
            rtmr0: zero48, rtmr1: zero48, rtmr2: zero48, rtmr3: zero48, reportData: reportData
        )
        let quote = TDXQuote(
            header: TDXQuote.Header(
                version: 4, attestationKeyType: 2, teeType: 0x00000081,
                qeVendorID: Data(count: 16), userData: Data(count: 20)
            ),
            body: body,
            signature: TDXQuote.SignatureData(
                ecdsaSignature: Data(count: 64), attestationPublicKey: Data(count: 64),
                certificateChainPEM: [], rawCertificationData: Data()
            )
        )
        return TDXVerificationResult(
            quote: quote,
            measurements: TDXMeasurements(from: body),
            signatureValid: signatureValid,
            certChainValid: certChainValid,
            certChainError: certChainError
        )
    }

    /// Report_data with the signing address in the first 20 bytes, right-padded to 64.
    private static func reportDataWithAddress(_ hex: String) -> Data {
        let addrHex = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        var data = Data(count: 64)
        if let addrBytes = try? Data(hexString: addrHex) {
            data.replaceSubrange(0..<min(addrBytes.count, 32), with: addrBytes.prefix(32))
        }
        return data
    }

    /// Report_data with a 32-byte key in the first 32 bytes.
    private static func reportDataWithKey(_ key: Data) -> Data {
        var data = Data(count: 64)
        data.replaceSubrange(0..<min(key.count, 32), with: key.prefix(32))
        return data
    }

    // MARK: - Preview records

    /// Stub values used in previews and prototype views.
    /// Preview record without Ed25519 key — simulates degraded (no E2EE) state.
    static let previewDegraded: AttestationRecord = {
        let signingAddr = "0x4a8b3f2e9d1c7a5e2b0f8d3c6e1a4b7f2e9d1c7a"
        let gwReport = reportDataWithAddress(signingAddr)
        return AttestationRecord(
            composeHash:        "3a5b9747bc6731c5de6c6d6740c3c37cc4522a935b1655e2b757d81089df31f0",
            mrtd:               "f06dfda6dce1cf904d4e2bab1dc370634cf95cefa2ceb2de2eee127c9382698090d7a4a13e14c536",
            osImageHash:        "da9a3d5cc196a1a76d953fb27069be428ddf60a1ce10b0534c3cf968d3053fde",
            modelOSImageHash:   "9b69bb1698bacbb6985409a2c272bcb892e09cdcea63d5399c6768b67d3ff677",
            intelQuote:         "04020000000000000a0013000000000043414c00000000005c5c9eb4e7ff3b2a",
            composeManifest:    nil,
            gpuArch:            "HOPPER",
            gpuNodeComposeHash: "242a62724303cc32f364da0fc92738706b0078e7587821b7ba3e75488223797b",
            modelFileHash:      "ae5fa3a8ee2e826bf2a089dadda7270032dd358b8c2af67844e143951baeee5e",
            signingAddress:     signingAddr,
            gpuSigningAddress:  "0x614bc66ff0407dbb70b9c7ca1f5e983e4a02c921",
            modelEd25519PubKey:   nil,
            quoteVerification:      mockVerification(reportData: gwReport),
            gpuQuoteVerification:   nil,  // GPU unreachable
            modelQuoteVerification: nil,  // No model attestation without E2EE
            fetchedAt:            Date(),
            providerID:           Provider.nearAI.id,
            model:              "zai-org/GLM-5.1-FP8"
        )
    }()

    static let preview: AttestationRecord = {
        let signingAddr = "0x4a8b3f2e9d1c7a5e2b0f8d3c6e1a4b7f2e9d1c7a"
        let e2eeKey = Data(repeating: 0xAB, count: 32)
        let gwReport = reportDataWithAddress(signingAddr)
        let modelReport = reportDataWithKey(e2eeKey)
        // Manifest, its hash, and the matching MRCONFIGID (0x01 ‖ hash ‖ pad),
        // computed together so the code-identity check binds in previews.
        let manifest = "services:\n  cloud-api:\n    image: nearaidev/cloud-api@sha256:ac8a539ce1ac9ae3ebd0dfcffdba18effaaedfa69685fce220e3b3a35357e326\n  dstack-service-mesh:\n    image: nearaidev/dstack-vpc@sha256:03bd4b222d07059af91fc3d2aa851026cecbecf719ba7423616058272db57b2c\n    ports:\n      - \"443:443\"\n  ingress:\n    image: nearaidev/cvm-ingress@sha256:2d5d9d4fe317ae6f04fe8a46f61fecfadc14bb75dceca06ae51dc2e9621fc34d"
        let manifestHash = SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()
        let mrConfig = ((try? Data(hexString: "01" + manifestHash)) ?? Data()) + Data(count: 15)
        // Model-node OUTER app_compose: production shape — the management
        // harness only (compose-manager, launcher, telemetry). It carries NO
        // plaintext-toucher signals; the engine + E2EE proxy live in the INNER
        // model-layer compose, which previews set on the session directly
        // (`previewSession` → `modelLayerManifest`). Planting engine services
        // here would mask the wrong-document bug PlaintextExposure fixed —
        // production analysis runs on the inner document.
        let modelCompose = """
        services:
          compose-manager:
            image: nearaidev/compose-manager@sha256:b487f391aabbccddeeff001122334455667788990011223344556677889900aa
            pid: host
          launcher:
            image: nearaidev/compose-manager-launcher@sha256:6e035c8faabbccddeeff001122334455667788990011223344556677889900bb
          datadog:
            image: datadog/agent:7.55.0
            volumes:
              - /var/run/docker.sock:/var/run/docker.sock:ro
              - /var/lib/docker/containers:/var/lib/docker/containers:ro
          otelcol:
            image: otel/opentelemetry-collector-contrib:0.98.0
            volumes:
              - /var/lib/docker/containers:/var/lib/docker/containers:ro
        """
        return AttestationRecord(
            composeHash:        manifestHash,
            mrtd:               "f06dfda6dce1cf904d4e2bab1dc370634cf95cefa2ceb2de2eee127c9382698090d7a4a13e14c536",
            osImageHash:        "da9a3d5cc196a1a76d953fb27069be428ddf60a1ce10b0534c3cf968d3053fde",
            modelOSImageHash:   "9b69bb1698bacbb6985409a2c272bcb892e09cdcea63d5399c6768b67d3ff677",
            intelQuote:         "04020000000000000a0013000000000043414c00000000005c5c9eb4e7ff3b2a",
            composeManifest:    manifest,
            gpuArch:            "HOPPER",
            gpuNodeComposeHash: "242a62724303cc32f364da0fc92738706b0078e7587821b7ba3e75488223797b",
            gpuNodeComposeManifest: modelCompose,
            modelFileHash:      "ae5fa3a8ee2e826bf2a089dadda7270032dd358b8c2af67844e143951baeee5e",
            modelComposePath:   "prod/GLM-5.1-SGL-AWQ-TP4.yaml",
            modelComposeCommit: "c545c95545dba47d8bea293aaae317089ea52f4d",
            modelComposeTag:    "v0.0.296",
            modelDeployedAt:    "2026-07-16T22:16:29.773189510+00:00",
            modelPreviouslyDeployedAt: "2026-07-12T09:41:03.000000000+00:00",
            signingAddress:     signingAddr,
            gpuSigningAddress:  "0x614bc66ff0407dbb70b9c7ca1f5e983e4a02c921",
            modelEd25519PubKey:     e2eeKey,
            quoteVerification:      mockVerification(reportData: gwReport, mrConfigID: mrConfig),
            gpuQuoteVerification:   nil,  // GPU unreachable — shows as gray dash
            modelQuoteVerification: mockVerification(reportData: modelReport),
            fetchedAt:            Date(),
            providerID:           Provider.nearAI.id,
            model:              "zai-org/GLM-5.1-FP8"
        )
    }()
}

