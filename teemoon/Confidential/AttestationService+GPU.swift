//
//  AttestationService+GPU.swift
//  teemoon
//
//  Direct GPU-node attestation: signing-address re-fetch and the
//  compose/artifact report. Kept off AttestationService.swift so the
//  orchestrator is not also the node retry loop.
//

import Foundation
import os
import TDXQuoteVerifier

private let logger = Logger(subsystem: "ai.teemoon", category: "attestation")

extension AttestationService {

    /// Used by TEESignatureVerifier to check for key rotation on mismatch.
    static func fetchSigningAddress(
        from nodeURL: URL, apiKey: String, http: any HTTPClient = URLSessionHTTP()
    ) async -> String? {
        guard let (request, _) = makeAttestationRequest(baseURL: nodeURL, apiKey: apiKey) else { return nil }
        guard let data = try? await http.data(for: request).0
        else {
            logger.warning("GPU signing address fetch failed — no data from \(nodeURL.host ?? "", privacy: .public)")
            return nil
        }
        if let report = try? JSONDecoder().decode(GPUNodeReport.self, from: data) {
            if let addr = report.signingAddress {
                logger.debug("GPU re-fetch got signing_address: \(addr, privacy: .public)")
                return addr
            }
            logger.debug("GPU report has no signing_address field")
            if let hex = report.intelQuote,
               let quote = try? QuoteParser.parse(hex: hex) {
                let reportData = quote.body.reportData
                if reportData.count >= 20, reportData.prefix(20) != Data(count: 20) {
                    let addr = "0x" + reportData.prefix(20).map { String(format: "%02x", $0) }.joined()
                    logger.debug("GPU address extracted from TDX report_data: \(addr, privacy: .public)")
                    return addr
                }
            }
        } else {
            logger.error("GPU report decode failed — body: \(data.previewForLog(), privacy: .private)")
        }
        return nil
    }

    /// Fetches GPU attestation data from a direct model inference node.
    /// Retries up to 3 times with exponential backoff (1s, 2s, 4s) to handle
    /// cold-start delays.
    static func fetchGPUData(
        nodeURL: URL, apiKey: String, expectedModel: String, http: any HTTPClient
    ) async -> GPUNodeData? {
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (1 << (attempt - 1))))
            }
            guard let (request, nonce) = makeAttestationRequest(baseURL: nodeURL, apiKey: apiKey) else { return nil }
            let result: (Data, URLResponse)
            do {
                result = try await http.data(for: request)
            } catch {
                logger.warning("GPU fetch attempt \(attempt+1) failed for \(nodeURL.host ?? "", privacy: .public): \(error.localizedDescription)")
                continue
            }
            let data = result.0
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            guard let report = try? JSONDecoder().decode(GPUNodeReport.self, from: data) else {
                logger.warning("GPU fetch attempt \(attempt+1) HTTP \(status) — decode failed: \(data.previewForLog(), privacy: .private)")
                continue
            }
            // Reject a misrouted node before trusting anything in the report.
            // A retry re-rolls the load balancer, so the next attempt usually
            // lands on a correct node; if all attempts misroute, returning nil
            // leaves the model-layer fields empty (provenance stays pending —
            // honest) rather than displaying another model's attested stack.
            if report.modelName != nil,
               report.modelName?.caseInsensitiveCompare(expectedModel) != .orderedSame {
                // Anchor on the EXPECTED model's host, not the host we queried:
                // a misroute/fallback that reached a different model's host must
                // not authenticate that model just because its id maps there.
                let servedHost = await EndpointDirectory.shared
                    .directBase(forModel: report.modelName ?? "")?.host
                let expectedHost = await EndpointDirectory.shared
                    .directBase(forModel: expectedModel)?.host
                if !gpuReportServesExpectedModel(served: report.modelName, expected: expectedModel,
                                                 expectedModelHost: expectedHost, servedModelHost: servedHost) {
                    logger.warning("GPU node \(nodeURL.host ?? "?", privacy: .public) attempt \(attempt+1) serves \(report.modelName ?? "?", privacy: .public), expected \(expectedModel, privacy: .public) — rejected (misrouted node)")
                    continue
                }
            }
            logger.debug("GPU fetch attempt \(attempt+1) HTTP \(status) — signingAddress: \(report.signingAddress ?? "nil", privacy: .public), intelQuote: \(report.intelQuote != nil ? "present" : "nil"), arch: \(report.nvidiaPayload?.arch ?? "nil", privacy: .public)")
            let gpuQuoteVerification = report.intelQuote.flatMap { hex in
                try? TDXQuoteVerifier.verify(quoteHex: hex)
            }
            var resolvedAddr = report.signingAddress
            if resolvedAddr == nil, let hex = report.intelQuote,
               let quote = try? QuoteParser.parse(hex: hex) {
                let rd = quote.body.reportData
                if rd.count >= 20, rd.prefix(20) != Data(count: 20) {
                    resolvedAddr = "0x" + rd.prefix(20).map { String(format: "%02x", $0) }.joined()
                    logger.debug("GPU signing address extracted from report_data: \(resolvedAddr ?? "", privacy: .public)")
                }
            }
            return GPUNodeData(
                arch:              report.nvidiaPayload?.arch,
                composeHash:       report.info?.composeHash,
                composeManifest:   report.info?.tcbInfo?.appCompose,
                modelFileHash:     report.latestModelFileHash,
                modelComposePath:   report.latestComposeUp?.file,
                modelComposeCommit: report.latestComposeUp?.commit,
                modelComposeTag:    report.latestComposeUp?.tag,
                modelDeployedAt:    report.composeUpTimestamps.latest,
                modelPreviouslyDeployedAt: report.composeUpTimestamps.previous,
                signingAddress:    resolvedAddr,
                quoteVerification: gpuQuoteVerification,
                intelQuote:        report.intelQuote,
                nonce:             nonce
            )
        }
        return nil
    }

}
