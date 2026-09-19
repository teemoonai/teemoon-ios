//
//  EndpointDirectory.swift
//  teemoon
//
//  near.ai's authoritative model → direct-completions-host directory,
//  published (unauthenticated) at https://completions.near.ai/endpoints as
//  `{ "endpoints": [ { "domain": "<slug>.completions.near.ai",
//                      "models": ["vendor/Model", …] }, … ] }`.
//
//  This is the source of truth for the per-model direct TEE host used by the
//  E2EE key fetch (see AttestationService). It is served off the gateway's
//  DB-backed path, so it stays available during the model-resolution outages
//  the direct path exists to survive. Resolution order:
//    1. the fetched directory (cached in-memory + persisted for offline),
//    2. the persisted last-good copy,
//    3. nil — and for an own-fleet model that means degraded, never
//       "ordinary model, send in the clear".
//  Every resolved host is still model_name-verified at fetch time, so a stale
//  directory can never bind E2EE to the wrong model. Hosts are accepted only
//  under near.ai over https: this map picks where sealed traffic goes.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "endpoints")

actor EndpointDirectory {
    static let shared = EndpointDirectory()

    private let url = URL(string: "https://completions.near.ai/endpoints")!
    private let ttl: TimeInterval = 3600
    private let session: URLSession

    /// model id (lowercased) → "https://<domain>/v1"
    private var cache: [String: String] = [:]
    private var lastLoad: Date?
    /// A failed fetch is not retried for a minute: `buildModels` asks once per
    /// own-fleet row, and a blackholed host would otherwise cost a timeout each.
    private var lastFailure: Date?
    private let failureTTL: TimeInterval = 60

    private static let persistKey = "ai.teemoon.endpointDirectory.json"

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// The direct-completions base URL (`https://<domain>/v1`) for `model`,
    /// or nil if the model has no direct host. Loads/refreshes the directory
    /// on demand (bounded, failure-tolerant); the persisted copy answers while
    /// the network does not.
    func directBase(forModel model: String) async -> URL? {
        await loadIfNeeded()
        if let base = cache[model.lowercased()], let u = URL(string: base) { return u }
        return Self.persistedBase(forModel: model)
    }

    /// Synchronous last-good answer, for the inference URL, which cannot await.
    /// Decoded once per process — it is read on every send and on every render
    /// of the verification screen.
    nonisolated static func persistedBase(forModel model: String) -> URL? {
        persisted.withLock { slot in
            if slot == nil {
                slot = UserDefaults.standard.data(forKey: persistKey).flatMap(parseDirectory) ?? [:]
            }
            return slot?[model.lowercased()].flatMap(URL.init(string:))
        }
    }

    /// Keeps the synchronous copy in step with a fetch.
    nonisolated static func rememberPersisted(_ map: [String: String]) {
        persisted.withLock { $0 = map }
    }

    private nonisolated static let persisted = OSAllocatedUnfairLock<[String: String]?>(initialState: nil)

    private func loadIfNeeded() async {
        if let last = lastLoad, Date().timeIntervalSince(last) < ttl, !cache.isEmpty { return }
        if let failed = lastFailure, Date().timeIntervalSince(failed) < failureTTL { return }
        // Seed from the persisted snapshot first so an offline / slow launch
        // still resolves recently-seen models.
        if cache.isEmpty, let saved = UserDefaults.standard.data(forKey: Self.persistKey),
           let parsed = Self.parseDirectory(saved), !parsed.isEmpty {
            cache = parsed
        }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = Self.parseDirectory(data), !parsed.isEmpty else {
            logger.warning("[endpoints] directory unavailable — using \(self.cache.isEmpty ? "no" : "cached/persisted", privacy: .public) hosts")
            lastFailure = Date()
            return
        }
        cache = parsed
        lastLoad = Date()
        lastFailure = nil
        UserDefaults.standard.set(data, forKey: Self.persistKey)
        Self.rememberPersisted(parsed)
        logger.info("[endpoints] directory loaded — \(parsed.count) model host(s)")
    }

    /// Parses the directory JSON into a model-id(lowercased) → "<base>/v1" map.
    /// Pure and static so it is unit-testable against the captured fixture.
    static func parseDirectory(_ data: Data) -> [String: String]? {
        struct Directory: Decodable {
            struct Endpoint: Decodable { let domain: String; let models: [String] }
            let endpoints: [Endpoint]
        }
        guard let dir = try? JSONDecoder().decode(Directory.self, from: data) else { return nil }
        var map: [String: String] = [:]
        for endpoint in dir.endpoints {
            // near.ai over https only. These hosts receive sealed prompts and
            // the API key on the signature re-fetch, so a directory that ever
            // named something else must not be able to redirect either.
            guard let host = confidentialHost(endpoint.domain) else { continue }
            for model in endpoint.models { map[model.lowercased()] = "\(host)/v1" }
        }
        return map
    }

    /// "<slug>.completions.near.ai" → "https://<slug>.completions.near.ai".
    /// nil for any other host, any scheme but https, and anything carrying a
    /// port or a path.
    static func confidentialHost(_ domain: String) -> String? {
        let raw = domain.contains("://") ? domain : "https://" + domain
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.port == nil, url.path.isEmpty || url.path == "/",
              let host = url.host, Provider.isNearAIHost(host) else { return nil }
        return "https://" + host
    }
}
