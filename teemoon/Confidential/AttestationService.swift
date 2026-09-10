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

    /// Fetches the attestation report as three independent claims — the
    /// gateway's own quote, the model node's quote + Ed25519 key, the GPU
    /// node's evidence. Any leg may be missing; its fields are then nil/empty.
    /// Throws only when no leg produced anything.
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
        let gpuTask: Task<GPUNodeData?, Never>? = gpuNodeURL.map { url in
            Task { await fetchGPUData(nodeURL: url, apiKey: apiKey, expectedModel: model, http: http) }
        }
        let modelAttTask: Task<ModelAttestationData?, Never>? = model.isEmpty ? nil : Task {
            await fetchModelAttestation(baseURL: baseURL, model: model, apiKey: apiKey, http: http)
        }

        let gateway = await fetchGatewayAttestation(baseURL: baseURL, apiKey: apiKey, http: http)
        let gpu = await gpuTask?.value
        // Do not block the record on the model leg's full retry budget: what
        // the other legs proved is usable now; refreshAttestationIfStale refetches.
        var modelAtt: ModelAttestationData?
        if let modelAttTask {
            modelAtt = await Self.awaitValue(of: modelAttTask, timeout: 15_000_000_000)
            if modelAtt == nil { modelAttTask.cancel() }
        }
        logger.notice("fetch() results: gateway=\(gateway != nil ? "ok" : "unavailable", privacy: .public), modelAtt=\(modelAtt != nil ? "key present" : "unavailable", privacy: .public), gpu=\(gpu != nil)")

        guard gateway != nil || modelAtt != nil || gpu != nil else {
            throw NSError(domain: "AttestationService", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Attestation fetch failed: no evidence from the gateway, the model node, or the GPU node"])
        }

        // Every gateway field below reads through `gw`; a missing gateway must
        // leave them nil/empty — never verify or report a quote it did not serve.
        let gw = gateway?.report.gatewayAttestation
        let quoteVerification = gw?.intelQuote.flatMap { try? TDXQuoteVerifier.verify(quoteHex: $0) }
        let gpuArch = modelAtt?.gpuArch ?? gpu?.arch

        return AttestationRecord(
            composeHash:          gw?.info?.composeHash  ?? "",
            mrtd:                 gw?.info?.tcbInfo?.mrtd ?? "",
            osImageHash:          gw?.info?.osImageHash   ?? "",
            // The gateway's own report never carries the model node's hash
            // (no `model=` param is sent); only the model leg can supply it.
            modelOSImageHash:     modelAtt?.osImageHash,
            intelQuote:           gw?.intelQuote          ?? "",
            modelIntelQuote:      modelAtt?.intelQuote,
            gpuIntelQuote:        gpu?.intelQuote,
            gatewayNonce:         gateway?.nonce,
            modelNonce:           modelAtt?.nonce,
            gpuNonce:             gpu?.nonce,
            nvidiaPayload:        modelAtt?.nvidiaPayload,
            composeManifest:      gw?.info?.tcbInfo?.appCompose,
            gpuArch:              gpuArch,
            gpuNodeComposeHash:   gpu?.composeHash,
            gpuNodeComposeManifest: gpu?.composeManifest,
            modelFileHash:        gpu?.modelFileHash,
            modelComposePath:     gpu?.modelComposePath,
            modelComposeCommit:   gpu?.modelComposeCommit,
            modelComposeTag:      gpu?.modelComposeTag,
            modelDeployedAt:      gpu?.modelDeployedAt,
            modelPreviouslyDeployedAt: gpu?.modelPreviouslyDeployedAt,
            signingAddress:       gw?.signingAddress,
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

    /// The gateway's own attestation and the nonce it must echo, or nil when
    /// the gateway gave nothing usable. Up to 3 attempts (1s, 2s backoff) for
    /// a thrown transport error or a 5xx; a 4xx or an undecodable body is
    /// final on the first answer — retrying a 401 cannot succeed. Never throw
    /// from here: a gateway failure must not discard the other legs.
    static func fetchGatewayAttestation(
        baseURL: URL, apiKey: String, http: any HTTPClient
    ) async -> (report: Report, nonce: String)? {
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (1 << (attempt - 1))))
            }
            guard let (request, nonce) = makeAttestationRequest(baseURL: baseURL, apiKey: apiKey) else {
                return nil
            }
            let data: Data
            let status: Int
            do {
                let (body, response) = try await http.data(for: request)
                data = body
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                logger.warning("Gateway fetch attempt \(attempt+1) failed: \(error.localizedDescription)")
                continue
            }
            if status >= 500 {
                logger.warning("Gateway fetch attempt \(attempt+1) HTTP \(status): server error — \(data.previewForLog(), privacy: .private)")
                continue
            }
            if status >= 400 {
                logger.warning("Gateway fetch HTTP \(status): no gateway attestation — \(data.previewForLog(), privacy: .private)")
                return nil
            }
            guard let report = try? JSONDecoder().decode(Report.self, from: data) else {
                logger.warning("Gateway fetch HTTP \(status): decode failed — \(data.previewForLog(), privacy: .private)")
                return nil
            }
            return (report, nonce)
        }
        logger.error("Gateway attestation unavailable after 3 attempt(s)")
        return nil
    }
}
