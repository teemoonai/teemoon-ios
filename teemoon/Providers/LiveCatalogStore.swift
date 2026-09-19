//
//  LiveCatalogStore.swift
//  teemoon
//
//  The last list each server answered with, kept on disk.
//
//  teemoon ships no model catalogue. A provider's models are whatever its
//  `/models` says today; this store is the copy of that answer, so a count,
//  a picker row and a model's price survive a relaunch and an aeroplane.
//
//  ONE STORE. Counts, browser rows and "what is this model called" all read
//  it, so they cannot disagree — a second cache of the same numbers is a
//  second answer.
//

import CryptoKit
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "catalog-store")

@Observable
@MainActor
final class LiveCatalogStore {

    static let shared = LiveCatalogStore()

    /// One server's last answer. `tiers` is near.ai's `owned_by` map, saved
    /// beside the rows: without it a cold launch would label every row from
    /// the id guess, which answers "own fleet" for ids it has never seen.
    struct Entry: Codable, Equatable {
        static let currentVersion = 1
        var version = currentVersion
        var endpoint: String
        var scope: String
        var fetchedAt: Date
        var models: [KnownModel]
        var tiers: [String: NearAIModelCatalog.Confidentiality] = [:]
    }

    /// A server, plus whose list it is. A keyed catalogue can differ per
    /// account (Fireworks lists what the key is entitled to), so those entries
    /// are scoped by a hash of the key — never the key itself.
    struct Key: Hashable {
        let endpoint: String
        let scope: String
    }

    private let directory: URL?
    private var entries: [Key: Entry] = [:]
    private var loaded: Set<Key> = []
    private var inFlight: [Key: Task<[KnownModel]?, Never>] = [:]

    /// Test seam; production lists through `ModelCatalog.liveCatalog`.
    var list: (EndpointModelCatalog.Source, URL, String, String?) async -> EndpointModelCatalog.ProbeResult = {
        source, base, key, header in
        await ModelCatalog.liveCatalog(for: source, baseURL: base, apiKey: key, authHeaderName: header)
    }

    init(directory: URL? = LiveCatalogStore.defaultDirectory) {
        self.directory = directory
    }

    /// nonisolated so it can be a default argument, which is evaluated in
    /// the caller's context.
    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ModelLists", isDirectory: true)
    }

    // MARK: - Reading

    /// The saved rows for this server, or [] when it has never answered.
    /// Cheap on repeat: a file is decoded once per process.
    func models(for provider: Provider, apiKey: String) -> [KnownModel] {
        guard let key = Self.key(for: provider, apiKey: apiKey) else { return [] }
        return entry(key)?.models ?? []
    }

    func count(for provider: Provider, apiKey: String) -> Int? {
        guard let key = Self.key(for: provider, apiKey: apiKey), let entry = entry(key) else { return nil }
        return entry.models.isEmpty ? nil : entry.models.count
    }

    func model(id: String, for provider: Provider, apiKey: String) -> KnownModel? {
        models(for: provider, apiKey: apiKey).first { $0.id.lowercased() == id.lowercased() }
    }

    /// Every saved row for an endpoint, whichever key fetched it. For naming a
    /// setup, where the question is "is this word one of its models".
    func allModels(forEndpoint endpoint: String) -> [KnownModel] {
        let target = Provider.presetMatchKey(endpoint)
        loadAll()
        return entries.filter { $0.key.endpoint == target }.flatMap { $0.value.models }
    }

    // MARK: - Writing

    /// Records an answer teemoon already has (a probe, a browser fetch), so
    /// every door updates the same copy.
    func record(_ models: [KnownModel], for provider: Provider, apiKey: String) {
        guard !models.isEmpty, let key = Self.key(for: provider, apiKey: apiKey) else { return }
        var entry = Entry(endpoint: key.endpoint, scope: key.scope, fetchedAt: Date(), models: models)
        if provider.isNearAI { entry.tiers = NearAIModelCatalog.knownTiers(forIDs: models.map(\.id)) }
        entries[key] = entry
        loaded.insert(key)
        pruneOtherScopes(of: key)
        write(entry, at: key)
    }

    /// Lists the server when the saved copy is older than `maxAge`, and saves
    /// what comes back. A failure keeps the copy; the caller shows it either
    /// way. Concurrent callers share one fetch.
    @discardableResult
    func refresh(_ provider: Provider, apiKey: String, maxAge: TimeInterval) async -> [KnownModel]? {
        guard let key = Self.key(for: provider, apiKey: apiKey),
              let source = WhereProviderPresentation.liveCatalogSource(for: provider),
              let base = provider.openAIBaseURL else { return nil }
        if let entry = entry(key), Date().timeIntervalSince(entry.fetchedAt) < maxAge {
            return entry.models
        }
        if let running = inFlight[key] { return await running.value }

        // A public list is read without a key: counting OpenRouter's catalogue
        // must not hand it a credential it did not ask for.
        let sent = Self.listIsPublic(source) ? "" : apiKey
        let header = provider.authHeaderName
        let lister = list
        let task = Task<[KnownModel]?, Never> { [weak self] in
            guard case .connected(let models) = await lister(source, base, sent, header),
                  !models.isEmpty else { return nil }
            self?.record(models, for: provider, apiKey: apiKey)
            return models
        }
        inFlight[key] = task
        let models = await task.value
        inFlight[key] = nil
        return models
    }

    /// Brings every configured server's list up to date, at most one fetch
    /// each. Only servers the user has set up: opening a sheet is not consent
    /// to contact a vendor they never chose.
    func refreshAll(_ providers: [Provider], maxAge: TimeInterval,
                    credential: (Provider) -> String) async {
        var seen = Set<Key>()
        let jobs = providers.compactMap { provider -> (Provider, String)? in
            let key = credential(provider)
            guard let storeKey = Self.key(for: provider, apiKey: key),
                  let source = WhereProviderPresentation.liveCatalogSource(for: provider),
                  seen.insert(storeKey).inserted else { return nil }
            // A custom endpoint has no catalogue to keep fresh: a browse tap is
            // the only consent to send its key to `/models`.
            guard source != .generic else { return nil }
            // A keyed list 401s without one, so there is nothing to ask for yet.
            guard Self.listIsPublic(source) || !key.isEmpty else { return nil }
            return (provider, key)
        }
        await withTaskGroup(of: Void.self) { group in
            for (provider, key) in jobs {
                group.addTask { @MainActor in
                    await self.refresh(provider, apiKey: key, maxAge: maxAge)
                }
            }
        }
    }

    /// Drops a server's saved lists — every scope, so removing a key cannot
    /// leave the old account's models on screen.
    func forget(endpoint: String) {
        let target = Provider.presetMatchKey(endpoint)
        loadAll()
        for key in entries.keys where key.endpoint == target {
            entries[key] = nil
            if let url = fileURL(for: key) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// near.ai tiers from the saved lists, so a cold launch labels rows from
    /// what near.ai said rather than from the id guess.
    func seedNearAITiers() {
        loadAll()
        for entry in entries.values where !entry.tiers.isEmpty {
            NearAIModelCatalog.recordTiers(entry.tiers)
        }
    }

    // MARK: - Keys and storage

    /// nil when there is no server list to ask for (on-device, Brave).
    nonisolated static func key(for provider: Provider, apiKey: String) -> Key? {
        guard let source = WhereProviderPresentation.liveCatalogSource(for: provider) else { return nil }
        let scope = listIsPublic(source) ? "public" : scopeHash(apiKey)
        return Key(endpoint: provider.presetMatchKey, scope: scope)
    }

    /// Lists that answer without a credential. Everything else is one
    /// account's view and is stored under that account only.
    nonisolated static func listIsPublic(_ source: EndpointModelCatalog.Source) -> Bool {
        switch source {
        case .nearAI, .openRouter, .nvidia: return true
        case .xAI, .fireworks, .generic:    return false
        }
    }

    /// A key never lands on disk, in a filename or in a file's contents.
    nonisolated static func scopeHash(_ apiKey: String) -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "keyless" }
        return "key-" + hex(trimmed).prefix(16)
    }

    nonisolated static func hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func entry(_ key: Key) -> Entry? {
        if !loaded.contains(key) {
            loaded.insert(key)
            entries[key] = read(at: key)
        }
        return entries[key]
    }

    private func loadAll() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let entry = decode(data) else { continue }
            let key = Key(endpoint: entry.endpoint, scope: entry.scope)
            guard !loaded.contains(key) else { continue }
            loaded.insert(key)
            entries[key] = entry
        }
    }

    private func decode(_ data: Data) -> Entry? {
        guard var entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == Entry.currentVersion else { return nil }
        // Badges age even while the copy sits on disk, and a near.ai row's
        // direct host belongs to the directory, not to a month-old list.
        let now = Date()
        entry.models = entry.models.map { model in
            var row = model
            row.isNew = ModelCatalog.isNew(created: model.created, now: now)
            // Every own-fleet row, not only those that had a host: a list
            // built while the directory was cold has none, and must not stay
            // that way once the directory is on disk.
            if row.directBaseURL != nil || entry.tiers[row.id.lowercased()] == .teeOwn {
                row.directBaseURL = EndpointDirectory.persistedBase(forModel: row.id)?.absoluteString
            }
            return row
        }
        return entry
    }

    private func read(at key: Key) -> Entry? {
        guard let url = fileURL(for: key), let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    private func write(_ entry: Entry, at key: Key) {
        guard let directory, let url = fileURL(for: key) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: url, options: [.atomic])
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(resource)
        } catch {
            logger.error("[catalog] could not save \(key.endpoint, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// One account's list replaces another's; two keys' entitlements must not
    /// stack up as one catalogue.
    private func pruneOtherScopes(of key: Key) {
        loadAll()
        for other in entries.keys where other.endpoint == key.endpoint && other.scope != key.scope {
            entries[other] = nil
            if let url = fileURL(for: other) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func fileURL(for key: Key) -> URL? {
        directory?.appendingPathComponent(Self.hex(key.endpoint + "|" + key.scope) + ".json")
    }
}
