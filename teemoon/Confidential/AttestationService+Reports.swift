//
//  AttestationService+Reports.swift
//  teemoon
//
//  Wire envelopes for near.ai attestation reports, and the extracted
//  GPU/model payloads the fetcher turns into AttestationRecord.
//

import Foundation
import TDXQuoteVerifier

extension AttestationService {
    /// Decoded JSON envelope from `/v1/attestation/report`.
    /// Actual response: { "gateway_attestation": { "intel_quote": "...", "info": { "compose_hash": "...",
    ///   "os_image_hash": "...", "tcb_info": { "mrtd": "...", "app_compose": "<yaml string>" } } } }
    struct Report: Decodable {
        let gatewayAttestation: GatewayAttestation

        enum CodingKeys: String, CodingKey {
            case gatewayAttestation = "gateway_attestation"
        }

        struct GatewayAttestation: Decodable {
            let intelQuote: String?
            let info: Info?
            /// Ethereum-style address of the TEE ECDSA signing key.
            let signingAddress: String?

            enum CodingKeys: String, CodingKey {
                case intelQuote    = "intel_quote"
                case info
                case signingAddress = "signing_address"
            }
        }

        struct Info: Decodable {
            let composeHash:  String?
            let osImageHash:  String?
            let tcbInfo:      TcbInfo?

            enum CodingKeys: String, CodingKey {
                case composeHash = "compose_hash"
                case osImageHash = "os_image_hash"
                case tcbInfo     = "tcb_info"
            }
        }

        struct TcbInfo: Decodable {
            let mrtd: String?
            /// Raw docker-compose YAML measured at boot (gateway_attestation.info.tcb_info.app_compose).
            let appCompose: String?

            enum CodingKeys: String, CodingKey {
                case mrtd
                case appCompose = "app_compose"
            }
        }
    }

    /// Flat response format returned by direct GPU inference nodes
    /// (e.g. `https://glm-5.completions.near.ai/v1/attestation/report`).
    struct GPUNodeReport: Decodable {
        let nvidiaPayload: NvidiaPayload?
        let info: GPUNodeInfo?
        let composeManagerAttestation: ComposeManagerAttestation?
        /// Ethereum-style ECDSA signing address of the GPU node TEE.
        let signingAddress: String?
        /// Intel TDX quote hex from the GPU node TEE (same dstack framework as gateway).
        let intelQuote: String?
        /// The model this node says it serves. The load balancer behind a
        /// direct host occasionally hands out a node running a DIFFERENT
        /// model (observed live: glm-5-1 answering with GLM-5.2's stack), so
        /// this must be verified against the requested model before any of
        /// the report's data is trusted.
        let modelName: String?

        enum CodingKeys: String, CodingKey {
            case nvidiaPayload             = "nvidia_payload"
            case info
            case composeManagerAttestation = "compose_manager_attestation"
            case signingAddress            = "signing_address"
            case intelQuote                = "intel_quote"
            case modelName                 = "model_name"
        }

        // nvidia_payload arrives as a JSON-encoded string, so we double-decode it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let payloadStr = try? c.decode(String.self, forKey: .nvidiaPayload),
               let payloadData = payloadStr.data(using: .utf8) {
                nvidiaPayload = try? JSONDecoder().decode(NvidiaPayload.self, from: payloadData)
            } else {
                nvidiaPayload = try? c.decode(NvidiaPayload.self, forKey: .nvidiaPayload)
            }
            info = try? c.decode(GPUNodeInfo.self, forKey: .info)
            composeManagerAttestation = try? c.decode(ComposeManagerAttestation.self,
                                                      forKey: .composeManagerAttestation)
            signingAddress = try? c.decode(String.self, forKey: .signingAddress)
            intelQuote = try? c.decode(String.self, forKey: .intelQuote)
            modelName = try? c.decode(String.self, forKey: .modelName)
        }

        struct NvidiaPayload: Decodable {
            /// GPU architecture, e.g. "HOPPER" (H100) or "AMPERE" (A100).
            let arch: String?
        }

        struct GPUNodeInfo: Decodable {
            /// TEE-measured compose hash of the GPU inference node.
            let composeHash: String?
            let tcbInfo: NodeTcbInfo?
            enum CodingKeys: String, CodingKey {
                case composeHash = "compose_hash"
                case tcbInfo     = "tcb_info"
            }
            struct NodeTcbInfo: Decodable {
                /// Raw docker-compose YAML the GPU node measured at boot
                /// (info.tcb_info.app_compose — hashes to info.compose_hash).
                let appCompose: String?
                enum CodingKeys: String, CodingKey { case appCompose = "app_compose" }
            }
        }

        struct ComposeManagerAttestation: Decodable {
            let actions: [CMAction]?
        }

        struct CMAction: Decodable {
            let action:    String?
            /// SHA256 of the model-specific compose YAML file.
            let fileSha256: String?
            /// Repo-relative path of that YAML (e.g. "prod/GLM-5.1-SGL-AWQ-TP4.yaml").
            let file: String?
            /// Git commit of the compose-files repo the YAML was taken from.
            let commit: String?
            /// Git tag corresponding to that commit.
            let tag: String?
            /// ISO8601 time compose-manager recorded for this action — the
            /// operator's clock, inside the signed action log (label it as
            /// such; it is log data, not hardware-proven time).
            let timestamp: String?
            enum CodingKeys: String, CodingKey {
                case action, file, commit, tag, timestamp
                case fileSha256 = "file_sha256"
            }
        }

        /// The most recent compose_up action (the currently running model YAML).
        var latestComposeUp: CMAction? {
            composeManagerAttestation?.actions?.last(where: { $0.action == "compose_up" })
        }

        /// Timestamps of the newest and previous compose_up — the engine
        /// layer's current deployment time and the one before it (deployment
        /// cadence context for the expert sheet).
        var composeUpTimestamps: (latest: String?, previous: String?) {
            let ups = (composeManagerAttestation?.actions ?? [])
                .filter { $0.action == "compose_up" }
                .compactMap(\.timestamp)
            return (ups.last, ups.count >= 2 ? ups[ups.count - 2] : nil)
        }

        /// SHA256 of the most recent compose_up action (the currently running model YAML).
        var latestModelFileHash: String? { latestComposeUp?.fileSha256 }
    }

    /// Data extracted from a GPU inference node attestation report.
    struct GPUNodeData {
        let arch: String?
        let composeHash: String?
        let composeManifest: String?
        let modelFileHash: String?
        let modelComposePath: String?
        let modelComposeCommit: String?
        let modelComposeTag: String?
        let modelDeployedAt: String?
        let modelPreviouslyDeployedAt: String?
        let signingAddress: String?
        let quoteVerification: TDXVerificationResult?
        let intelQuote: String?
        let nonce: String?
    }

    /// Response from `/v1/attestation/report?signing_algo=ed25519&model=...`.
    /// Supports both the current format (top-level fields + `all_attestations`)
    /// and the legacy format (`model_attestations` array).
    struct Ed25519Report: Decodable {
        let modelName: String?
        let signingPublicKey: String?
        let intelQuote: String?
        let nvidiaPayload: String?
        let info: Info?
        let allAttestations: [ModelAttestation]?
        let modelAttestations: [ModelAttestation]?
        enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case signingPublicKey = "signing_public_key"
            case intelQuote = "intel_quote"
            case nvidiaPayload = "nvidia_payload"
            case info
            case allAttestations = "all_attestations"
            case modelAttestations = "model_attestations"
        }
        /// The model node's measured metadata — we consume only `os_image_hash`,
        /// the guest image this node boots on.
        struct Info: Decodable {
            let osImageHash: String?
            enum CodingKeys: String, CodingKey { case osImageHash = "os_image_hash" }
        }
        struct ModelAttestation: Decodable {
            let modelName: String?
            let signingPublicKey: String?
            let intelQuote: String?
            let nvidiaPayload: String?
            let info: Info?
            enum CodingKeys: String, CodingKey {
                case modelName = "model_name"
                case signingPublicKey = "signing_public_key"
                case intelQuote = "intel_quote"
                case nvidiaPayload = "nvidia_payload"
                case info
            }
        }

        var resolvedModelName: String? { modelName ?? allAttestations?.first?.modelName ?? modelAttestations?.first?.modelName }
        var resolvedKey: String? { signingPublicKey ?? allAttestations?.first?.signingPublicKey ?? modelAttestations?.first?.signingPublicKey }
        var resolvedQuote: String? { intelQuote ?? allAttestations?.first?.intelQuote ?? modelAttestations?.first?.intelQuote }
        var resolvedNvidiaPayload: String? { nvidiaPayload ?? allAttestations?.first?.nvidiaPayload ?? modelAttestations?.first?.nvidiaPayload }
        /// Model-node OS image hash, from whichever response shape arrived: the
        /// flat direct-host report (`info.os_image_hash`) or the gateway-with-
        /// model envelope (`model_attestations[0].info.os_image_hash`).
        var resolvedOSImageHash: String? { info?.osImageHash ?? allAttestations?.first?.info?.osImageHash ?? modelAttestations?.first?.info?.osImageHash }
    }

    /// Result of fetching the model's Ed25519 attestation data.
    struct ModelAttestationData {
        let ed25519PubKey: Data
        let quoteVerification: TDXVerificationResult?
        let gpuArch: String?
        let intelQuote: String?
        let nonce: String?
        /// Raw `nvidia_payload` JSON string, retained for NRAS verification.
        let nvidiaPayload: String?
        /// The model node's guest-OS measurement (info.os_image_hash) — the
        /// image the plaintext-facing enclave boots on. nil if the response
        /// didn't carry it.
        var osImageHash: String? = nil
    }
}
