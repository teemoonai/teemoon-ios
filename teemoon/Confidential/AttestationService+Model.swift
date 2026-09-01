//
//  AttestationService+Model.swift
//  teemoon
//
//  The Ed25519 / model-quote race: direct host vs gateway. Kept off
//  AttestationService.swift so fetch() is not also the race.
//

import Foundation
import os
import TDXQuoteVerifier

private let logger = Logger(subsystem: "ai.teemoon", category: "attestation")

extension AttestationService {

    /// Fetches the model's Ed25519 E2EE key + TDX attestation, racing two
    /// documented near.ai sources and returning the first VALID attestation:
    ///
    ///  - **Gateway** (`<baseURL>/attestation/report?model=…&signing_algo=ed25519`) —
    ///    resolves the model through near.ai's database.
    ///  - **Direct completions host** (`<directBase>/attestation/report?signing_algo=ed25519`,
    ///    no `model=` param) — the host *is* the model, so it skips the
    ///    gateway's DB-backed model resolution and stays up when that lookup
    ///    is failing. near.ai documents this as the "direct completions" path.
    ///
    /// The direct source is preferred (fewer hops, outage-resilient); the
    /// gateway runs concurrently as a fallback. A fast failure never beats a
    /// slower success. The winner's own nonce is returned so the caller's
    /// `report_data[32..64]` echo check validates the right value.
    static func fetchModelAttestation(
        baseURL: URL, model: String, apiKey: String, http: any HTTPClient
    ) async -> ModelAttestationData? {
        var tasks: [Task<ModelAttestationData?, Never>] = []
        // Direct sources (the model's own completions host — no ?model= param,
        // so no DB-backed model resolution). The authoritative hardcoded host
        // gets full retries; best-effort derived candidates get a single
        // attempt (a wrong guess just loses the race). Every direct response is
        // model_name-verified, so a stale/wrong host is rejected, never trusted.
        for source in await directSources(forModel: model) {
            tasks.append(Task {
                await fetchModelAttestation(from: source.base, includeModelParam: false,
                                            expectedModel: model, apiKey: apiKey,
                                            maxAttempts: source.authoritative ? 8 : 1,
                                            label: source.label, http: http)
            })
        }
        // Gateway fallback (resolves the model via near.ai's database).
        tasks.append(Task {
            await fetchModelAttestation(from: baseURL, includeModelParam: true,
                                        expectedModel: model, apiKey: apiKey,
                                        maxAttempts: 8, label: "gateway", http: http)
        })
        return await firstSuccess(tasks)
    }

    /// The direct completions hosts to try for `model`, most-trusted first:
    /// near.ai's authoritative endpoints directory (also covers the shipped
    /// `KnownModel.directBaseURL` when the directory is unreachable), else
    /// best-effort candidates derived from the model id. All are gated by the
    /// `model_name` check in the fetch, so a stale/wrong host is never trusted.
    static func directSources(forModel model: String) async -> [(base: URL, label: String, authoritative: Bool)] {
        if let authoritative = await EndpointDirectory.shared.directBase(forModel: model) {
            return [(authoritative, "direct", true)]
        }
        return derivedDirectHostSlugs(forModel: model).compactMap { slug in
            URL(string: "https://\(slug).completions.near.ai/v1").map { ($0, "direct?\(slug)", false) }
        }
    }


    /// One model-attestation source: the retry loop against a single endpoint.
    /// `includeModelParam` adds the `?model=` param (gateway); omit it for a
    /// direct host. `expectedModel` is verified against the response's
    /// `model_name` when present — a mismatch (wrong or stale direct host)
    /// is rejected so E2EE never binds to the wrong model.
    static func fetchModelAttestation(
        from endpoint: URL, includeModelParam: Bool, expectedModel: String,
        apiKey: String, maxAttempts: Int, label: String, http: any HTTPClient
    ) async -> ModelAttestationData? {
        guard var components = URLComponents(url: endpoint.appendingPathComponent("attestation/report"),
                                              resolvingAgainstBaseURL: false) else {
            logger.error("Failed to build URLComponents for \(label, privacy: .public) model attestation from: \(endpoint.absoluteString)")
            return nil
        }
        let nonce = randomNonce()
        var items = [URLQueryItem(name: "signing_algo", value: "ed25519"),
                     URLQueryItem(name: "nonce",        value: nonce)]
        if includeModelParam { items.insert(URLQueryItem(name: "model", value: expectedModel), at: 0) }
        components.queryItems = items
        guard let url = components.url else { return nil }

        for attempt in 0..<max(1, maxAttempts) {
            // Stop promptly if the caller bounded the wait and moved on, or the
            // sibling source already won the race.
            if Task.isCancelled { return nil }
            if attempt > 0 {
                let delay = min(UInt64(2_000_000_000) * UInt64(1 << min(attempt - 1, 3)), 8_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return nil }
            }
            var request = URLRequest(url: url, timeoutInterval: 15)
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            guard let (data, response) = try? await http.data(for: request) else {
                logger.warning("[\(label, privacy: .public)] model attestation attempt \(attempt+1): network request failed")
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 500 {
                logger.warning("[\(label, privacy: .public)] model attestation attempt \(attempt+1) HTTP \(status): server error — \(data.previewForLog(), privacy: .private)")
                continue
            }
            guard let report = try? JSONDecoder().decode(Ed25519Report.self, from: data) else {
                logger.warning("[\(label, privacy: .public)] model attestation attempt \(attempt+1) HTTP \(status): decode failed — \(data.previewForLog(), privacy: .private)")
                continue
            }
            // Reject a host serving a different model than requested — otherwise
            // E2EE would encrypt to the wrong model's key. near.ai's direct
            // hosts can be repurposed (a stale mapping is a live example), so
            // this gate is what makes hardcoded and derived hosts alike safe.
            if let served = report.resolvedModelName, served.caseInsensitiveCompare(expectedModel) != .orderedSame {
                logger.warning("[\(label, privacy: .public)] model attestation: host serves \(served, privacy: .public), expected \(expectedModel, privacy: .public) — rejected")
                return nil
            }
            guard let hex = report.resolvedKey else {
                logger.warning("[\(label, privacy: .public)] model attestation attempt \(attempt+1) HTTP \(status): signing_public_key missing — \(data.previewForLog(), privacy: .private)")
                continue
            }
            guard let keyData = try? Data(hexString: hex), keyData.count == 32 else {
                logger.warning("[\(label, privacy: .public)] model attestation attempt \(attempt+1) HTTP \(status): invalid key hex (\(hex.prefix(20))..., \(hex.count/2) bytes)")
                continue
            }

            let quoteVerification = report.resolvedQuote.flatMap { quoteHex in
                try? TDXQuoteVerifier.verify(quoteHex: quoteHex)
            }
            let gpuArch: String? = report.resolvedNvidiaPayload.flatMap { payload in
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return json["arch"] as? String
            }

            if let qv = quoteVerification {
                let bound = qv.measurements.reportData.count >= 32 && qv.measurements.reportData.prefix(32) == keyData
                logger.info("[\(label, privacy: .public)] model attestation: quote \(qv.isVerified ? "verified" : "FAILED"), key bound: \(bound), gpu: \(gpuArch ?? "nil", privacy: .public)")
            } else {
                logger.debug("[\(label, privacy: .public)] model attestation: no intel_quote in response")
            }

            return ModelAttestationData(
                ed25519PubKey: keyData,
                quoteVerification: quoteVerification,
                gpuArch: gpuArch,
                intelQuote: report.resolvedQuote,
                nonce: nonce,
                nvidiaPayload: report.resolvedNvidiaPayload,
                osImageHash: report.resolvedOSImageHash
            )
        }
        logger.error("[\(label, privacy: .public)] model attestation: Ed25519 key unavailable after \(max(1, maxAttempts)) attempt(s)")
        return nil
    }

    /// Awaits the first task to produce a non-nil value, then cancels the rest.
    /// A task that finishes with nil (all retries failed) does not win — a fast
    /// failure never beats a slower success. Returns nil only if all fail.
    static func firstSuccess<T>(_ tasks: [Task<T?, Never>]) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            for task in tasks { group.addTask { await task.value } }
            var winner: T?
            for await value in group where value != nil {
                winner = value
                break
            }
            for task in tasks { task.cancel() }
            group.cancelAll()
            return winner
        }
    }

}
