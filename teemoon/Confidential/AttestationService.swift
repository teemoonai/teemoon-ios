//
//  AttestationService.swift
//  teemoon
//
//  Orchestrates the near.ai remote attestation report. Wire envelopes
//  live in +Reports, host routing in +Routing, GPU node fetch in +GPU,
//  model Ed25519 race in +Model. The resulting data model is AttestationRecord.
//

import Foundation
import os
import TDXQuoteVerifier

private let logger = Logger(subsystem: "ai.teemoon", category: "attestation")

// MARK: - Fetcher

/// Fetches the near.ai remote attestation report.
enum AttestationService {

    static func randomNonce() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Awaits `task`'s value, giving up after `timeout` nanoseconds and
    /// returning nil. Does not itself cancel `task` — the caller decides
    /// whether the in-flight work should keep running or be cancelled.
    static func awaitValue<T>(of task: Task<T?, Never>, timeout: UInt64) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Builds an attestation request carrying a fresh random nonce, returning
    /// the nonce so the caller can verify its echo in the quote's
    /// report_data[32..64] (anti-replay — Phase 2 of the verification plan).
    static func makeAttestationRequest(baseURL: URL, apiKey: String) -> (request: URLRequest, nonce: String)? {
        let nonce = randomNonce()
        guard var components = URLComponents(url: baseURL.appendingPathComponent("attestation/report"),
                                              resolvingAgainstBaseURL: false) else {
            logger.error("Failed to build URLComponents from base URL: \(baseURL.absoluteString)")
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "nonce",        value: nonce),
            URLQueryItem(name: "signing_algo", value: "ecdsa"),
        ]
        guard let url = components.url else {
            logger.error("Failed to construct attestation URL from components")
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return (request, nonce)
    }

    /// Quickly fetches just the signing address from a GPU node's attestation endpoint.
    #if DEBUG
    /// Test hook: extract the model node's `os_image_hash` from a raw
    /// model-attestation response body, exercising the same `Ed25519Report`
    /// decode + `resolvedOSImageHash` resolution the live path uses. Covers both
    /// wire shapes — the flat direct-host report (`info.os_image_hash`) and the
    /// gateway-with-model envelope (`model_attestations[0].info.os_image_hash`).
    static func _testModelOSImageHash(fromModelReport data: Data) -> String? {
        (try? JSONDecoder().decode(Ed25519Report.self, from: data))?.resolvedOSImageHash
    }
    #endif

    /// Fetches and parses the attestation report.
    /// - Parameters:
    ///   - baseURL: The provider's OpenAI-compatible base URL (e.g. `https://cloud-api.near.ai/v1`).
    ///   - apiKey:  Bearer token used to authenticate the request.
    ///   - model:   Model identifier for E2EE key fetch.
    ///   - providerID: Stored in the returned record for stale-detection at the call site.
    ///   - gpuNodeURL: Optional direct GPU inference node URL for NVIDIA attestation.
    static func fetch(
        baseURL: URL, apiKey: String, model: String = "", providerID: UUID,
        gpuNodeURL: URL? = nil, http: any HTTPClient = URLSessionHTTP()
    ) async throws -> AttestationRecord {
        // Kick off GPU node + model attestation (Ed25519 key + TDX quote) fetches concurrently.
        let gpuTask: Task<GPUNodeData?, Never>? = gpuNodeURL.map { url in
            Task { await fetchGPUData(nodeURL: url, apiKey: apiKey, expectedModel: model, http: http) }
        }
        let modelAttTask: Task<ModelAttestationData?, Never>? = model.isEmpty ? nil : Task {
            await fetchModelAttestation(baseURL: baseURL, model: model, apiKey: apiKey, http: http)
        }

        // Retry gateway fetch up to 3 times with exponential backoff (1s, 2s).
        var gatewayData: Data?
        var lastError: Error?
        var gatewayNonce: String?
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (1 << (attempt - 1))))
            }
            guard let (request, nonce) = makeAttestationRequest(baseURL: baseURL, apiKey: apiKey) else {
                throw NSError(domain: "AttestationService", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to build attestation request URL"])
            }
            do {
                let (data, _) = try await http.data(for: request)
                gatewayData = data
                gatewayNonce = nonce
                break
            } catch {
                logger.warning("Gateway fetch attempt \(attempt+1) failed: \(error.localizedDescription)")
                lastError = error
            }
        }
        guard let data = gatewayData else {
            // Gateway failed (possibly due to task cancellation). Still await the model
            // attestation so the Ed25519 key isn't orphaned — E2EE needs it even without
            // full gateway data.
            let modelAtt = await modelAttTask?.value
            if let modelAtt {
                logger.info("Gateway failed but model attestation succeeded — returning partial record with Ed25519 key")
                return AttestationRecord(
                    composeHash: "", mrtd: "", osImageHash: "",
                    modelOSImageHash: modelAtt.osImageHash,
                    intelQuote: "",
                    modelIntelQuote: modelAtt.intelQuote,
                    modelNonce: modelAtt.nonce,
                    nvidiaPayload: modelAtt.nvidiaPayload,
                    composeManifest: nil, gpuArch: modelAtt.gpuArch,
                    gpuNodeComposeHash: nil, modelFileHash: nil,
                    signingAddress: nil, gpuSigningAddress: nil,
                    modelEd25519PubKey: modelAtt.ed25519PubKey,
                    quoteVerification: nil, gpuQuoteVerification: nil,
                    modelQuoteVerification: modelAtt.quoteVerification,
                    fetchedAt: Date(), providerID: providerID, model: model
                )
            }
            throw lastError ?? NSError(domain: "AttestationService", code: -2,
                                        userInfo: [NSLocalizedDescriptionKey: "Gateway attestation fetch failed"])
        }
        let report = try JSONDecoder().decode(Report.self, from: data)
        let gw = report.gatewayAttestation
        let gpu = await gpuTask?.value
        // Bound the wait on model attestation. The gateway record is the
        // primary trust anchor and verifies in <1s; the model-attestation
        // endpoint (E2EE key, model quote, GPU evidence) can be slow (TEE
        // cold-start) or down independently of the gateway. Blocking the whole
        // record on its full retry budget (~160s) is what makes the sheet time
        // out to "Can't Reach Verifier" with everything unverified — even
        // though the gateway quote is genuine. If the key doesn't arrive in
        // time, return the gateway record now (E2EE/model rows degrade
        // honestly) and let refreshAttestationIfStale refetch it later.
        var modelAtt: ModelAttestationData?
        if let modelAttTask {
            modelAtt = await Self.awaitValue(of: modelAttTask, timeout: 15_000_000_000)
            if modelAtt == nil { modelAttTask.cancel() }
        }
        logger.notice("fetch() results: gateway=ok, modelAtt=\(modelAtt != nil ? "key present" : "unavailable", privacy: .public), gpu=\(gpu != nil)")

        // Verify the gateway TDX quote on-device (signature + cert chain back to Intel Root CA).
        let quoteVerification = try? TDXQuoteVerifier.verify(quoteHex: gw.intelQuote ?? "")

        // Prefer GPU arch from model attestation (always available from gateway),
        // fall back to direct GPU node fetch.
        let gpuArch = modelAtt?.gpuArch ?? gpu?.arch

        return AttestationRecord(
            composeHash:          gw.info?.composeHash  ?? "",
            mrtd:                 gw.info?.tcbInfo?.mrtd ?? "",
            osImageHash:          gw.info?.osImageHash   ?? "",
            // Model node's guest-OS hash — from the model attestation (the
            // gateway's own report never carries it: the app's gateway request
            // sends no `model=` param, so the envelope has no model_attestations).
            modelOSImageHash:     modelAtt?.osImageHash,
            intelQuote:           gw.intelQuote          ?? "",
            modelIntelQuote:      modelAtt?.intelQuote,
            gpuIntelQuote:        gpu?.intelQuote,
            gatewayNonce:         gatewayNonce,
            modelNonce:           modelAtt?.nonce,
            gpuNonce:             gpu?.nonce,
            nvidiaPayload:        modelAtt?.nvidiaPayload,
            composeManifest:      gw.info?.tcbInfo?.appCompose,
            gpuArch:              gpuArch,
            gpuNodeComposeHash:   gpu?.composeHash,
            gpuNodeComposeManifest: gpu?.composeManifest,
            modelFileHash:        gpu?.modelFileHash,
            modelComposePath:     gpu?.modelComposePath,
            modelComposeCommit:   gpu?.modelComposeCommit,
            modelComposeTag:      gpu?.modelComposeTag,
            modelDeployedAt:      gpu?.modelDeployedAt,
            modelPreviouslyDeployedAt: gpu?.modelPreviouslyDeployedAt,
            signingAddress:       gw.signingAddress,
            gpuSigningAddress:    gpu?.signingAddress,
            modelEd25519PubKey:   modelAtt?.ed25519PubKey,
            quoteVerification:    quoteVerification,
            gpuQuoteVerification: gpu?.quoteVerification,
            modelQuoteVerification: modelAtt?.quoteVerification,
            fetchedAt:            Date(),
            providerID:           providerID,
            model:                model
        )
    }
}
