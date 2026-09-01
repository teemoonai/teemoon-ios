//
//  ConfigStore.swift
//  teemoon
//
//  Where connection config lives: the servers that answer, the models equipped
//  on each, and which one is running. A versioned JSON file in Application
//  Support, replaced atomically, migrated once from the legacy `providers`
//  UserDefaults blob.
//
//  A file rather than SwiftData or UserDefaults, and one detail must not be
//  got wrong: a `Server` INHERITS its `Provider`'s
//  UUID, because the API key sits in the Keychain under that uuidString. A
//  migration that mints fresh ids orphans every key, silently, because
//  `Keychain.load` returning nil reads as "not configured" rather than as an
//  error.
//
//  Private persistence. Provider is the public API; this file is not.
//  Related: ProviderConfigProjection (Provider ⇄ snapshot), ProviderStore.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "config")

// MARK: - Schema

/// What kind of thing answers at an endpoint.
///
/// Folds in the on-device case, which is what removes the `endpoint:
/// "on-device"` sentinel and with it the class of bug where a non-URL endpoint
/// gets classified by URL parsing (`WhereLocality.of`, `E2EETitleBlock` both
/// hit it).
enum ServerKind: String, Codable, Equatable, Sendable {
    case onDevice
    case ollama
    case lmStudio
    case openAICompatible

    /// An unknown kind decodes to `.openAICompatible` rather than failing the
    /// whole blob. A build that has never heard of a newer kind should lose one
    /// server's classification, not every provider the user has configured.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ServerKind(rawValue: raw) ?? .openAICompatible
    }
}

/// One place that answers. The credential lives in the Keychain under `id`.
struct Server: Codable, Identifiable, Equatable, Sendable {
    /// MUST equal the `Provider.id` this row came from — see the file header.
    var id: UUID
    var name: String
    var endpoint: String
    var kind: ServerKind
    var requiresAPIKey: Bool
    var authHeaderName: String?
    var extraParams: [String: String]
    var maxMessages: Int?
    var hasBuiltInGrounding: Bool
    var omitSystemPrompt: Bool
    var supportsModelBrowsing: Bool

    /// The model this server runs when it is selected — a per-server memory, so
    /// switching away from a machine and back keeps what you were running on it.
    ///
    /// The *global* selection is `ConfigSnapshot.currentEquippedID` alone, and
    /// `validated()` forces this field to agree with it for the current server.
    /// That is the "one id, so the two can't disagree" rule of §3 applied where
    /// it matters — to the pair that is actually live.
    var activeModelID: String?

    /// Shown in the preset picker; supplied by `Provider.presets`, not by the user.
    var presetDescription: String?
    var signupURL: String?

    /// What the server reported having, last time it was asked. NOT the user's
    /// selection — that is the `EquippedModel` rows. Keeping them one column is
    /// §2.3, the silent revert of a removed home model.
    var servedModels: [String]?

    init(
        id: UUID,
        name: String,
        endpoint: String,
        kind: ServerKind = .openAICompatible,
        requiresAPIKey: Bool = true,
        authHeaderName: String? = nil,
        extraParams: [String: String] = [:],
        maxMessages: Int? = nil,
        hasBuiltInGrounding: Bool = false,
        omitSystemPrompt: Bool = false,
        supportsModelBrowsing: Bool = false,
        activeModelID: String? = nil,
        presetDescription: String? = nil,
        signupURL: String? = nil,
        servedModels: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.kind = kind
        self.requiresAPIKey = requiresAPIKey
        self.authHeaderName = authHeaderName
        self.extraParams = extraParams
        self.maxMessages = maxMessages
        self.hasBuiltInGrounding = hasBuiltInGrounding
        self.omitSystemPrompt = omitSystemPrompt
        self.supportsModelBrowsing = supportsModelBrowsing
        self.activeModelID = activeModelID
        self.presetDescription = presetDescription
        self.signupURL = signupURL
        self.servedModels = servedModels
    }
}

/// One model you can pick, on one server. The join row that `WhereSheetView`
/// had to invent as `Equipped` because the model layer had nowhere to put one.
struct EquippedModel: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var serverID: UUID
    var modelID: String
    var displayName: String?
    /// Per MODEL, which is the fix for §2.2: `Provider.modelCapabilities` is a
    /// single optional, so equipping a second model overwrote the first one's
    /// capabilities and `modelSupportsTools` then answered for the wrong model.
    var capabilities: ModelCapabilities?
    var addedAt: Date
    /// Absorbs `WhereRecentsStore`'s `recordedAt`. Written when a model first
    /// produces output — used, not merely picked.
    var lastUsedAt: Date?
    /// When this model stopped being equipped, if it has.
    ///
    /// The row OUTLIVES the unequip, which is what lets `lastUsedAt` absorb
    /// `WhereRecentsStore` (§2.6). "Recently used" is almost entirely made of
    /// models that were used and then unequipped — anything still equipped is
    /// already listed in `ready now` — so deleting the row on unequip would throw
    /// away the only fact the section is built from.
    ///
    /// Optional and additive, so a config written before this field decodes
    /// unchanged: absent means still equipped, which is what every existing row is.
    var unequippedAt: Date?
    /// Whether this row is part of the user's current selection.
    var isEquipped: Bool { unequippedAt == nil }

    init(
        id: UUID = UUID(),
        serverID: UUID,
        modelID: String,
        displayName: String? = nil,
        capabilities: ModelCapabilities? = nil,
        addedAt: Date = .now,
        lastUsedAt: Date? = nil,
        unequippedAt: Date? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.modelID = modelID
        self.displayName = displayName
        self.capabilities = capabilities
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
        self.unequippedAt = unequippedAt
    }
}

/// The whole persisted config, version included.
///
/// The version lives INSIDE the blob (§7 amendment 2) rather than in a sibling
/// `UserDefaults["schemaVersion"]`: two stores that can disagree eventually do,
/// and a restore from backup is enough to do it. Data that describes itself
/// cannot desynchronise from its own version.
struct ConfigSnapshot: Codable, Equatable, Sendable {
    /// Bump when a change stops being readable by the previous decoder.
    static let currentVersion = 2

    var version: Int
    var servers: [Server]
    var equipped: [EquippedModel]
    var currentEquippedID: UUID?

    static let empty = ConfigSnapshot()

    var isEmpty: Bool { servers.isEmpty && equipped.isEmpty }

    init(
        version: Int = ConfigSnapshot.currentVersion,
        servers: [Server] = [],
        equipped: [EquippedModel] = [],
        currentEquippedID: UUID? = nil
    ) {
        self.version = version
        self.servers = servers
        self.equipped = equipped
        self.currentEquippedID = currentEquippedID
    }

    /// The equipped rows of one server, in stored order.
    func rows(of serverID: UUID) -> [EquippedModel] {
        equipped.filter { $0.serverID == serverID }
    }

    /// The two invariants a database would have enforced, applied on every read
    /// and every write (§7). Without a foreign key an equipped row can outlive
    /// its server — a dangling reference with no sweep, and this codebase has
    /// paid for that class before; a second one is not worth having.
    ///
    /// - drops rows whose server is gone, loudly;
    /// - collapses duplicate (server, model) rows, keeping the first;
    /// - clears a `currentEquippedID` that points at neither;
    /// - forces each server's `activeModelID` to be a model it actually has, and
    ///   the CURRENT server's to be the current row — so the pair that is live
    ///   cannot disagree with itself.
    func validated() -> ConfigSnapshot {
        var copy = self
        let serverIDs = Set(servers.map(\.id))

        var seen = Set<String>()
        var kept: [EquippedModel] = []
        var droppedOrphans = 0
        var droppedDuplicates = 0
        for row in equipped {
            guard serverIDs.contains(row.serverID) else { droppedOrphans += 1; continue }
            let key = "\(row.serverID.uuidString)|\(row.modelID)"
            guard !seen.contains(key) else { droppedDuplicates += 1; continue }
            seen.insert(key)
            kept.append(row)
        }
        if droppedOrphans > 0 {
            logger.error("[config] dropped \(droppedOrphans, privacy: .public) equipped row(s) with no server")
        }
        if droppedDuplicates > 0 {
            logger.error("[config] collapsed \(droppedDuplicates, privacy: .public) duplicate equipped row(s)")
        }
        copy.equipped = kept

        let current = copy.currentEquippedID.flatMap { id in kept.first { $0.id == id } }
        if copy.currentEquippedID != nil && current == nil {
            logger.error("[config] cleared a selection pointing at a model that is no longer equipped")
            copy.currentEquippedID = nil
        }

        copy.servers = copy.servers.map { server in
            var server = server
            let models = kept.filter { $0.serverID == server.id }.map(\.modelID)
            if let current, current.serverID == server.id {
                // The live pair, reconciled at the one place that can see both.
                server.activeModelID = current.modelID
            } else if let active = server.activeModelID, !models.contains(active) {
                server.activeModelID = models.first
            } else if server.activeModelID == nil {
                server.activeModelID = models.first
            }
            return server
        }
        return copy
    }
}

// MARK: - The legacy blob

/// The v1 data, read once and then left alone.
///
/// A protocol so the migration can be tested against captured device JSON
/// without going near `UserDefaults` (§4 rule 3).
protocol LegacyConfigSource {
    var providersJSON: Data? { get }
    var currentProviderID: String? { get }
    var whereRecentsJSON: Data? { get }
}

struct UserDefaultsLegacyConfig: LegacyConfigSource {
    var providersJSON: Data? { UserDefaults.standard.data(forKey: UserDefaultsKey.providers) }
    var currentProviderID: String? { UserDefaults.standard.string(forKey: UserDefaultsKey.currentProviderID) }
    var whereRecentsJSON: Data? { UserDefaults.standard.data(forKey: UserDefaultsKey.whereRecents) }
}

/// Only the three fields the migration needs. The old blob also stored
/// snapshot labels this store never reads; unknown keys are ignored.
private struct LegacyRecent: Decodable {
    let providerID: UUID
    let modelID: String
    let recordedAt: Date
}

// MARK: - The store

@MainActor
final class ConfigStore {

    /// The v2 file. Application Support, not UserDefaults: a normalized config
    /// store is data, not a preferences cache read wholesale into memory
    /// (§7 amendment 1).
    static let fileName = "teemoon-config.json"

    /// nil → in-memory. Previews and tests MUST use in-memory stores: the
    /// preview host is one shared sandbox, so a persisting store leaks config
    /// into every other preview.
    private let directory: URL?
    private let legacy: LegacyConfigSource

    /// The last snapshot read or written. Kept so a save can preserve the facts
    /// a `Provider` cannot carry — a probed `kind`, per-model capabilities,
    /// `lastUsedAt` — instead of flattening them on every write.
    private(set) var snapshot: ConfigSnapshot = .empty

    /// Non-nil when the stored config could not be read. §4 rule 2: a decode
    /// failure must not present as "no setups" to someone with four keys
    /// configured. The bad file is preserved next to the good one and this
    /// string names what happened.
    private(set) var loadFailure: String?

    /// True when `load()` built the snapshot out of the v1 blob. The caller
    /// writes it back, which is what freezes v1 from that moment on.
    private(set) var didMigrate = false

    init(directory: URL? = ConfigStore.defaultDirectory,
         legacy: LegacyConfigSource = UserDefaultsLegacyConfig()) {
        self.directory = directory
        self.legacy = legacy
    }

    /// In-memory: nothing is read from or written to disk.
    static func inMemory() -> ConfigStore {
        ConfigStore(directory: nil, legacy: EmptyLegacyConfig())
    }

    /// nonisolated so it can be a default argument — those are evaluated in the
    /// caller's context, not the store's.
    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    var fileURL: URL? { directory?.appendingPathComponent(Self.fileName) }

    /// The bad blob, kept for forensics rather than deleted. One fixed name, so
    /// a repeatedly-corrupt file cannot fill the disk with copies.
    var quarantineURL: URL? { directory?.appendingPathComponent("teemoon-config.corrupt.json") }

    // MARK: Read

    /// Reads the v2 file, or migrates v1 once, or returns empty for a fresh
    /// install. Never throws: every failure path ends in the most data we can
    /// still account for, plus a `loadFailure` for the ones that lost some.
    @discardableResult
    func load() -> ConfigSnapshot {
        loadFailure = nil
        didMigrate = false

        guard let fileURL else {                       // in-memory
            snapshot = snapshot.validated()
            return snapshot
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode(ConfigSnapshot.self, from: data)
                guard decoded.version <= ConfigSnapshot.currentVersion else {
                    // Written by a NEWER build. Reading it with this decoder
                    // would silently drop whatever that version added, and the
                    // next write would make the loss permanent.
                    throw ConfigError.futureVersion(decoded.version)
                }
                snapshot = decoded.validated()
                return snapshot
            } catch {
                logger.error("[config] could not read stored config: \(error, privacy: .public)")
                loadFailure = "The saved connection list could not be read (\(error.localizedDescription))."
                quarantineUnreadableFile()
                // Falls through to v1 — which is still there, because the
                // migration never deletes it.
            }
        }

        let migrated = migrateFromLegacy()
        snapshot = migrated.validated()
        return snapshot
    }

    private func quarantineUnreadableFile() {
        guard let fileURL, let quarantineURL else { return }
        do {
            if FileManager.default.fileExists(atPath: quarantineURL.path) {
                try FileManager.default.removeItem(at: quarantineURL)
            }
            try FileManager.default.moveItem(at: fileURL, to: quarantineURL)
            logger.error("[config] unreadable config preserved at \(quarantineURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("[config] could not preserve unreadable config: \(error, privacy: .public)")
        }
    }

    /// v1 → v2. `Server.id` inherits `Provider.id` so no Keychain entry moves.
    private func migrateFromLegacy() -> ConfigSnapshot {
        guard let data = legacy.providersJSON else { return .empty }   // fresh install
        let providers: [Provider]
        do {
            providers = try JSONDecoder().decode([Provider].self, from: data)
        } catch {
            // The v1 blob is left exactly where it is. Something that can read
            // it may still come along; deleting it here would be the one
            // irreversible move available.
            logger.error("[config] legacy providers blob did not decode: \(error, privacy: .public)")
            loadFailure = "The saved connection list could not be read (\(error.localizedDescription))."
            return .empty
        }
        guard !providers.isEmpty else { return .empty }

        var lastUsed: [String: Date] = [:]
        if let recentsData = legacy.whereRecentsJSON {
            if let recents = try? JSONDecoder().decode([LegacyRecent].self, from: recentsData) {
                for recent in recents {
                    let key = ProviderConfigProjection.rowKey(recent.providerID, recent.modelID)
                    if let existing = lastUsed[key], existing >= recent.recordedAt { continue }
                    lastUsed[key] = recent.recordedAt
                }
            } else {
                // Not worth failing the migration over: recents are a
                // convenience, and losing them costs three rows in one section.
                logger.error("[config] legacy recents blob did not decode; migrating without lastUsedAt")
            }
        }

        didMigrate = true
        logger.info("""
            [config] migrated \(providers.count, privacy: .public) provider(s) from v1; \
            the legacy blob is kept and will not be written again
            """)
        return ProviderConfigProjection.snapshot(
            providers: providers,
            currentProviderID: legacy.currentProviderID,
            previous: .empty,
            lastUsed: lastUsed
        )
    }

    // MARK: Write

    /// Replaces the file atomically — write temp, rename — so a crash mid-write
    /// cannot truncate the config (§7 amendment 1).
    ///
    /// Writes v2 ONLY. The v1 blob is frozen, never dual-written (amendment 3):
    /// keeping it updated would mean maintaining a v1 encoder and two
    /// representations that can drift, and a rollback that reads a v1 blob a v2
    /// write corrupted is not recoverable, while one that loses post-migration
    /// changes is.
    func write(_ newSnapshot: ConfigSnapshot) {
        let validated = newSnapshot.validated()
        snapshot = validated
        guard let fileURL, let directory else { return }        // in-memory
        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(validated)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logger.error("[config] failed to write config: \(error, privacy: .public)")
        }
    }

    /// Stamps a model as used. The one writer of `lastUsedAt`, so "recently
    /// used" keeps meaning *used* — recorded when a model produces output, not
    /// when it is picked.
    func stampUse(serverID: UUID, modelID: String, at when: Date = .now) {
        guard let index = snapshot.equipped.firstIndex(where: {
            $0.serverID == serverID && $0.modelID == modelID
        }) else { return }
        var updated = snapshot
        updated.equipped[index].lastUsedAt = when
        write(updated)
    }

    /// Drops a model's row outright — the model AND its history.
    ///
    /// `stampUse` above is the only writer of `lastUsedAt`, and the projection
    /// keeps a retired row precisely so `recently used` has something to show.
    /// That is right for a model that merely stopped being equipped, and wrong
    /// for one the user DELETED: an explicit delete means "get this out of my
    /// list", and leaving it in `recently used` answers a request the user did
    /// not make. Unequipping alone cannot express that — the row survives by
    /// design — so forgetting is its own verb.
    ///
    /// The server, its key and everything else equipped on it are untouched.
    func forget(serverID: UUID, modelID: String) {
        var updated = snapshot
        updated.equipped.removeAll { $0.serverID == serverID && $0.modelID == modelID }
        guard updated.equipped.count != snapshot.equipped.count else { return }
        write(updated)
    }

    /// Records what a probe found: what the server SERVES, what kind it is, and
    /// when it last answered. Server facts, not the user's selection.
    ///
    /// This is the seam §2.3 was missing. The probe's model list used to be written
    /// into `equippedModels` — the user's selection — so the two facts shared one
    /// column and every probe overwrote a choice with an observation. That produced
    /// a silent revert on anything the user did to a home model, and it stripped a
    /// model that was still being pulled because the server doesn't serve it yet.
    ///
    /// Deliberately touches no `EquippedModel` row. A probe is an observation about
    /// a machine; it must never add, remove or reorder what someone picked.
    func recordProbe(serverID: UUID, kind: ServerKind?, servedModels: [String]?) {
        guard let index = snapshot.servers.firstIndex(where: { $0.id == serverID })
        else { return }
        var updated = snapshot
        // `kind` nil means "couldn't tell this time" and must not erase a kind an
        // earlier probe established — losing it costs the machine its `/api/pull`
        // affordance, which is §2.4's dead end.
        if let kind { updated.servers[index].kind = kind }
        if let servedModels { updated.servers[index].servedModels = servedModels }
        write(updated)
    }

    /// What a machine was last seen serving — the persisted half of a probe, so a
    /// failed refresh falls back to the last known answer instead of nothing.
    func servedModels(serverID: UUID) -> [String]? {
        snapshot.servers.first { $0.id == serverID }?.servedModels
    }

    /// What a probe last determined this server to be.
    func kind(serverID: UUID) -> ServerKind? {
        snapshot.servers.first { $0.id == serverID }?.kind
    }

    /// Removes a model's row outright — history included.
    ///
    /// Distinct from unequipping, which KEEPS the row so `recently used` can read
    /// its `lastUsedAt` (§2.6). That is right when the model still exists somewhere
    /// and could be re-equipped; it is wrong when the weights are gone. A model
    /// deleted from the phone or from its machine cannot answer, so a history entry
    /// for it is a row that can only fail when tapped, and the honest thing is for
    /// it to leave rather than be filtered out of sight on every read.
    ///
    /// Also drops it from the server's `servedModels`, so the persisted answer stops
    /// claiming a machine has something teemoon just removed from it.
    func forgetModel(serverID: UUID, modelID: String) {
        var updated = snapshot
        updated.equipped.removeAll { $0.serverID == serverID && $0.modelID == modelID }
        if let index = updated.servers.firstIndex(where: { $0.id == serverID }) {
            updated.servers[index].servedModels =
                updated.servers[index].servedModels?.filter { $0 != modelID }
        }
        write(updated)
    }

    enum ConfigError: LocalizedError {
        case futureVersion(Int)

        var errorDescription: String? {
            switch self {
            case .futureVersion(let version):
                "config schema v\(version) was written by a newer version of teemoon"
            }
        }
    }
}

/// No v1 data at all — what an in-memory store migrates from.
struct EmptyLegacyConfig: LegacyConfigSource {
    var providersJSON: Data? { nil }
    var currentProviderID: String? { nil }
    var whereRecentsJSON: Data? { nil }
}
