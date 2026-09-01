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
//    2. the shipped KnownModel.directBaseURL (offline / directory-down),
//    3. nil — caller may then try derived guesses.
//  Every resolved host is still model_name-verified at fetch time, so a stale
//  directory or hardcoded entry can never bind E2EE to the wrong model.
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

    private static let persistKey = "ai.teemoon.endpointDirectory.json"

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// The direct-completions base URL (`https://<domain>/v1`) for `model`,
    /// or nil if the model has no direct host. Loads/refreshes the directory
    /// on demand (bounded, failure-tolerant), falling back to the shipped
    /// hardcoded map when the directory is unavailable.
    func directBase(forModel model: String) async -> URL? {
        await loadIfNeeded()
        if let base = cache[model.lowercased()], let u = URL(string: base) { return u }
        if let hardcoded = KnownModel.nearAIModels.first(where: { $0.id == model })?.directBaseURL,
           let u = URL(string: hardcoded) { return u }
        return nil
    }

    /// Whether the directory holds AUTHORITATIVE data — a successful fetch this
    /// session or a persisted snapshot. When false (a cold miss: never loaded,
    /// nothing persisted), a nil `directBase` means "couldn't check," NOT "this
    /// model has no confidential host." Callers must not declare a model
    /// non-attestable on a cold miss — that would fail open to a silent
    /// unencrypted send. Loads on demand so the verdict reflects a real attempt.
    func hasAuthoritativeData() async -> Bool {
        await loadIfNeeded()
        return !cache.isEmpty
    }

    private func loadIfNeeded() async {
        if let last = lastLoad, Date().timeIntervalSince(last) < ttl, !cache.isEmpty { return }
        // Seed from the persisted snapshot first so an offline / slow launch
        // still resolves recently-seen models.
        if cache.isEmpty, let saved = UserDefaults.standard.data(forKey: Self.persistKey),
           let parsed = Self.parseDirectory(saved), !parsed.isEmpty {
            cache = parsed
        }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = Self.parseDirectory(data), !parsed.isEmpty else {
            logger.warning("[endpoints] directory unavailable — using \(self.cache.isEmpty ? "hardcoded" : "cached/persisted", privacy: .public) hosts")
            return
        }
        cache = parsed
        lastLoad = Date()
        UserDefaults.standard.set(data, forKey: Self.persistKey)
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
            let host = endpoint.domain.hasPrefix("http") ? endpoint.domain : "https://\(endpoint.domain)"
            for model in endpoint.models { map[model.lowercased()] = "\(host)/v1" }
        }
        return map
    }
}
