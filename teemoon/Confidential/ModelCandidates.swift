//
//  ModelCandidates.swift
//  teemoon
//
//  SDK track C3 (docs/NEARAI_SDK_C.md §C3): every enclave near.ai lists for a model (gateway `?model=` →
//  `model_attestations[]`) holds the key a sealed request goes to, so each passes the checks the read one passes.
//  Residual, never to be called closed: the key is derived from app_id, so enclaves near.ai's key service admits but
//  doesn't list hold it too.
//

import Foundation
import TDXQuoteVerifier

enum ModelCandidates {
    enum Mismatch: String, Equatable, Sendable {
        case keyDiffers, quoteInvalid, keyNotInQuote, nonce, quotePolicy, mrConfig, bootLog, keyProviderDiffers
    }

    enum Result: Equatable, Sendable {
        case clean
        case mismatch(Mismatch)
    }

    /// One listed enclave, as the expert view (C4) shows it. `keyProviderID` and `mrKMS` must agree across the list.
    struct Enclave: Equatable, Sendable {
        let instanceID: String
        let composeHash: String
        let appID: String
        let keyProviderID: String?
        let mrKMS: String?
        var result: Result
        /// The enclave's own quote and the report_data it advertises: DCAPService runs them as it runs the model leg's.
        var quoteHex: String? = nil
        var advertisedReportData: String? = nil
        /// The enclave's GPU evidence, checked with NRAS against the list's nonce like the model leg's (A3).
        var nvidiaPayload: String? = nil
        /// The entry as served: TrustScope.run reads it as it reads the model node's report (A4).
        var reportJSON: Data? = nil
        /// The guest OS its boot measured: the reviewed row looks its page up as it does the read enclave's (A5).
        var osImageHash: String? = nil
    }

    struct Listed: Equatable, Sendable {
        let enclaves: [Enclave]
        /// The nonce the list was asked with: each enclave's quote and GPU evidence must echo it.
        var nonce: String? = nil
    }

    /// `model_attestations[]` from the gateway's `?model=` answer; empty when there is none.
    static func list(fromGatewayReport data: Data) -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["model_attestations"] as? [[String: Any]] ?? []
    }

    /// The checks the read enclave always passes, on one listed enclave, no network. DCAP, NRAS and the compose
    /// manager per enclave are C3b. Every failure is evidence: the key a sealed request goes to reaches this enclave.
    static func check(_ c: [String: Any], sealedKey: Data, nonceHex: String) -> Result {
        guard let key = hex(c["signing_public_key"]), key == sealedKey else { return .mismatch(.keyDiffers) }
        guard let quoteHex = c["intel_quote"] as? String,
              let qv = try? TDXQuoteVerifier.verify(quoteHex: quoteHex), qv.isVerified else { return .mismatch(.quoteInvalid) }
        let rd = qv.measurements.reportData
        guard rd.count >= 64, rd.prefix(32) == key else { return .mismatch(.keyNotInQuote) }
        guard let nonce = hex(nonceHex), rd.dropFirst(32).prefix(32) == nonce else { return .mismatch(.nonce) }
        if QuoteChecks.failure(quoteHex: quoteHex, advertisedReportData: c["report_data"] as? String) != nil {
            return .mismatch(.quotePolicy)
        }
        let info = c["info"] as? [String: Any]
        let tcb = tcbInfo(info)
        guard let compose = tcb?["app_compose"] as? String,
              QuoteChecks.mrConfigCommits(qv.measurements.mrConfigID, toComposeSHA256: ComposeDigest().hex(of: compose))
        else { return .mismatch(.mrConfig) }
        let boot = BootLogReplay.check(entries: BootLogReplay.entries(from: tcb?["event_log"]), nodeRTMR3: qv.measurements.rtmr3,
                                       appCompose: compose, osImageHash: hex(info?["os_image_hash"]))
        if case .mismatch = boot { return .mismatch(.bootLog) }
        // `.absent` is not clean: the enclave's trust scope (`trustScopes`) reads it as couldn't-check (A4).
        return .clean
    }

    /// Each listed enclave with its result and what the expert view names it by.
    static func enclaves(body: Data, nonce: String, sealedKey: Data) -> Listed? {
        let list = list(fromGatewayReport: body)
        guard !list.isEmpty else { return nil }
        return Listed(enclaves: sameKeyService(list.map { c in
            let info = c["info"] as? [String: Any]
            let events = BootLogReplay.entries(from: tcbInfo(info)?["event_log"]) ?? []
            func payload(_ name: String) -> Data? { events.last { $0.imr == 3 && $0.event == name }?.payload }
            let provider = payload("key-provider").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return Enclave(instanceID: info?["instance_id"] as? String ?? "", composeHash: info?["compose_hash"] as? String ?? "",
                           appID: info?["app_id"] as? String ?? "", keyProviderID: provider?["id"] as? String,
                           mrKMS: payload("mr-kms")?.hexString, result: check(c, sealedKey: sealedKey, nonceHex: nonce),
                           quoteHex: c["intel_quote"] as? String, advertisedReportData: c["report_data"] as? String,
                           nvidiaPayload: Self.payloadString(c["nvidia_payload"]),
                           reportJSON: try? JSONSerialization.data(withJSONObject: c),
                           osImageHash: info?["os_image_hash"] as? String)
        }), nonce: nonce)
    }

    /// One key, one key service: an enclave whose key provider or mr-kms differs from the FIRST listed's is evidence (a
    /// split list marks every enclave unlike the first). Absent on every enclave is nothing to compare; a prior mismatch stays.
    static func sameKeyService(_ enclaves: [Enclave]) -> [Enclave] {
        guard let first = enclaves.first else { return enclaves }
        return enclaves.map { e in
            guard e.result == .clean, e.keyProviderID != first.keyProviderID || e.mrKMS != first.mrKMS else { return e }
            var e = e
            e.result = .mismatch(.keyProviderDiffers)
            return e
        }
    }

    /// Trust scope on each listed enclave through TrustScope.run, the read enclave's path: the entry's own quote, the
    /// list's nonce, the host the app connects to (its chat path, A5). An entry it can't read is not bound with no boot log: couldn't check, never clean.
    static func trustScopes(_ listed: Listed, dcap: @escaping @Sendable (_ quoteHex: String, _ label: String) async -> DCAPVerification?,
                            pairs: RunningPairCheck, host: String? = nil) async -> [TrustScope] {
        await withTaskGroup(of: (Int, TrustScope).self) { group in
            for (i, enclave) in listed.enclaves.enumerated() {
                group.addTask {
                    let unread = TrustScope(binding: .notBound, boot: .absent)
                    guard let json = enclave.reportJSON, let quote = enclave.quoteHex, !quote.isEmpty else { return (i, unread) }
                    let node = await dcap(quote, "listed \(i + 1)")
                    let scope = await TrustScope.run(reportJSON: json, nodeQuoteHex: quote, nonceHex: listed.nonce,
                                                     dcap: { await dcap($0, "listed \(i + 1) compose-manager") },
                                                     nodeDCAP: node, pairs: pairs, host: host)
                    return (i, scope ?? unread)
                }
            }
            var out: [(Int, TrustScope)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// `nvidia_payload` arrives as a JSON string; an object is re-encoded so NRAS reads the same bytes either way.
    private static func payloadString(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        guard let v, JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    private static func tcbInfo(_ info: [String: Any]?) -> [String: Any]? {
        if let t = info?["tcb_info"] as? [String: Any] { return t }
        guard let s = info?["tcb_info"] as? String, let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    private static func hex(_ v: Any?) -> Data? {
        guard let s = v as? String else { return nil }
        return try? Data(hexString: s.hasPrefix("0x") ? String(s.dropFirst(2)) : s)
    }
}

extension AttestationRecord {
    /// C3: a listed enclave failed a check. Evidence wherever it is read.
    var candidatesBroken: Bool { modelCandidates?.enclaves.contains { $0.result != .clean } ?? false }

    /// The worst listed enclave's reason. Never the read enclave's lines: the reader must learn it was another enclave.
    var candidatesReason: String? {
        guard let bad = modelCandidates?.enclaves.first(where: { $0.result != .clean }) else { return nil }
        switch bad.result {
        case .mismatch(.keyDiffers): return ListedEnclaveReason.otherKey
        case .mismatch(.keyProviderDiffers): return ListedEnclaveReason.otherKeyService
        case .mismatch(.bootLog): return ListedEnclaveReason.bootLog
        default: return ListedEnclaveReason.enclaveFailed
        }
    }
}

/// Card trust-copy-sweep-111 v4 (A10, A12, A13), verbatim: why a send is held over the enclaves near.ai lists.
enum ListedEnclaveReason {
    static let listFailed = "teemoon couldn't load near.ai's list of enclaves for this model."
    static let enclaveFailed = "another enclave near.ai lists for this model failed verification."
    static let bootLog = "another enclave near.ai lists for this model runs code its boot log doesn't match."
    static let otherKey = "near.ai lists an enclave for this model that holds a different key."
    static let otherKeyService = "near.ai's enclaves for this model name different key services for the same key."
}

extension AttestationService {
    static func adoptCandidates(body: Data, nonce: String, sealedKey: Data) -> ModelCandidates.Listed? {
        ModelCandidates.enclaves(body: body, nonce: nonce, sealedKey: sealedKey)
    }

    /// A list larger than this is a list that didn't load (audit 1.1.1 A11): every entry costs a DCAP verify inside the
    /// send's pending hold. The live glm-5.3-flash list is 3 entries, ~0.8 MB.
    static let maxListedEnclaves = 8
    static let maxListBytes = 4_000_000

    /// The list within `timeout`; the request is cancelled at the cap and when the caller is (a model switch), so no
    /// key-bearing request outlives the fetch that asked for it.
    static func candidateList(baseURL: URL, model: String, apiKey: String, http: any HTTPClient,
                              timeout: UInt64 = 15_000_000_000) async -> (body: Data, nonce: String)? {
        let listTask = Task { await fetchCandidateList(baseURL: baseURL, model: model, apiKey: apiKey, http: http) }
        defer { listTask.cancel() }
        return await withTaskCancellationHandler {
            await awaitValue(of: listTask, timeout: timeout)
        } onCancel: { listTask.cancel() }
    }

    /// The gateway's full list for `model` with a fresh nonce: up to 3 attempts, like the gateway leg.
    static func fetchCandidateList(baseURL: URL, model: String, apiKey: String,
                                   http: any HTTPClient) async -> (body: Data, nonce: String)? {
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (1 << (attempt - 1)))) }
            if Task.isCancelled { return nil }
            let nonce = randomNonce()
            guard var c = URLComponents(url: baseURL.appendingPathComponent("attestation/report"), resolvingAgainstBaseURL: false)
            else { return nil }
            c.queryItems = [URLQueryItem(name: "model", value: model), URLQueryItem(name: "signing_algo", value: "ed25519"),
                            URLQueryItem(name: "nonce", value: nonce)]
            guard let url = c.url else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 15)
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            let body: Data, response: URLResponse
            do { (body, response) = try await http.data(for: request, limit: maxListBytes) }
            catch is HTTPBodyTooLarge { return nil }
            catch { continue }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 500 { continue }
            guard status < 400 else { return nil }
            let list = ModelCandidates.list(fromGatewayReport: body)
            guard !list.isEmpty, list.count <= maxListedEnclaves else { return nil }
            return (body, nonce)
        }
        return nil
    }
}
