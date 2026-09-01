//
//  ConfigStoreTests.swift
//  teemoonTests
//
//  Pins the persistence change.
//
//  The test that matters most is `migrationPreservesProviderIDs`. API keys live
//  in the Keychain under `provider.id.uuidString`, and a migration that mints
//  fresh ids orphans every one of them SILENTLY — `Keychain.load` returning nil
//  reads as "not configured", so the failure presents as an empty setup rather
//  than as an error. Nothing else in this suite is as expensive to get wrong.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Config store")
@MainActor
struct ConfigStoreTests {

    // MARK: - Helpers

    /// A fresh directory per test, so nothing leaks between them.
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("configstore-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Legacy: LegacyConfigSource {
        var providersJSON: Data?
        var currentProviderID: String?
        var whereRecentsJSON: Data?
    }

    private func cloud(_ name: String, endpoint: String, model: String,
                       models: [String]? = nil,
                       caps: ModelCapabilities? = nil) -> Provider {
        var provider = Provider(name: name, endpoint: endpoint, model: model,
                                modelCapabilities: caps)
        provider.equippedModels = models
        return provider
    }

    private func legacyBlob(_ providers: [Provider]) -> Data {
        try! JSONEncoder().encode(providers)
    }

    // MARK: - Migration (§4)

    @Test("a migrated server inherits the provider's UUID, so its Keychain entry survives")
    func migrationPreservesProviderIDs() {
        let a = cloud("near.ai", endpoint: "https://api.near.ai/v1", model: "glm-5.1")
        let b = cloud("openrouter", endpoint: "https://openrouter.ai/api/v1", model: "sonnet")
        let store = ConfigStore(directory: tempDirectory(),
                                legacy: Legacy(providersJSON: legacyBlob([a, b])))

        let snapshot = store.load()

        #expect(store.didMigrate)
        #expect(Set(snapshot.servers.map(\.id)) == Set([a.id, b.id]))
    }

    @Test("a provider with no equippedModels migrates to exactly one equipped row")
    func migrationOfAProviderSavedBeforeEquipping() {
        let solo = cloud("brave", endpoint: "https://api.search.brave.com", model: "answers")
        #expect(solo.equippedModels == nil)
        let store = ConfigStore(directory: tempDirectory(),
                                legacy: Legacy(providersJSON: legacyBlob([solo])))

        let snapshot = store.load()

        #expect(snapshot.equipped.count == 1)
        #expect(snapshot.equipped[0].modelID == "answers")
        #expect(snapshot.equipped[0].serverID == solo.id)
    }

    @Test("an on-device provider migrates to a .onDevice server and comes back local")
    func migrationOfALocalProvider() {
        var local = Provider(name: "Gemma 4", endpoint: "on-device", model: "gemma-4-e2b",
                             requiresAPIKey: false, localModelID: "gemma-4-e2b")
        local.equippedModels = ["gemma-4-e2b"]
        let store = ConfigStore(directory: tempDirectory(),
                                legacy: Legacy(providersJSON: legacyBlob([local])))

        let snapshot = store.load()
        #expect(snapshot.servers.first?.kind == .onDevice)

        // `isLocal` is what the whole app branches on — it must survive the trip.
        let projected = ProviderConfigProjection.providers(from: snapshot).providers
        #expect(projected.first?.isLocal == true)
        #expect(projected.first?.localModelID == "gemma-4-e2b")
    }

    @Test("the legacy selection becomes one id naming a (server, model) pair")
    func migrationCarriesTheSelection() {
        let a = cloud("near.ai", endpoint: "https://api.near.ai/v1", model: "glm-5.1",
                      models: ["glm-5.1", "qwen3.5"])
        let store = ConfigStore(directory: tempDirectory(),
                                legacy: Legacy(providersJSON: legacyBlob([a]),
                                               currentProviderID: a.id.uuidString))

        let snapshot = store.load()
        let current = snapshot.equipped.first { $0.id == snapshot.currentEquippedID }

        #expect(current?.serverID == a.id)
        #expect(current?.modelID == "glm-5.1")
        #expect(ProviderConfigProjection.providers(from: snapshot).currentProviderID == a.id.uuidString)
    }

    @Test("the recents blob becomes lastUsedAt on the row it belongs to")
    func migrationAbsorbsRecents() {
        let a = cloud("near.ai", endpoint: "https://api.near.ai/v1", model: "glm-5.1",
                      models: ["glm-5.1", "qwen3.5"])
        let used = Date(timeIntervalSince1970: 1_753_000_000)
        // The shape `WhereRecentsStore` writes; extra keys it also writes are
        // ignored by the migration, which is why this can be a subset.
        let recents = """
            [{"providerID":"\(a.id.uuidString)","modelID":"qwen3.5",\
            "recordedAt":\(used.timeIntervalSinceReferenceDate),\
            "modelLabel":"Qwen","placeCaption":"near.ai","localityRaw":"cloud"}]
            """
        let store = ConfigStore(directory: tempDirectory(),
                                legacy: Legacy(providersJSON: legacyBlob([a]),
                                               whereRecentsJSON: Data(recents.utf8)))

        let snapshot = store.load()
        let qwen = snapshot.equipped.first { $0.modelID == "qwen3.5" }
        let glm = snapshot.equipped.first { $0.modelID == "glm-5.1" }

        #expect(qwen?.lastUsedAt == used)
        #expect(glm?.lastUsedAt == nil)
    }

    @Test("a v1 blob written before equipping, capabilities or local models still decodes")
    func migrationOfCapturedLegacyJSON() {
        // Hand-written in the shape the v1 encoder produced, deliberately
        // missing every field added since — the case §4 rule 3 is about.
        let id = UUID()
        let raw = """
            [{"id":"\(id.uuidString)","name":"near.ai",\
            "endpoint":"https://api.near.ai/v1","model":"glm-5.1",\
            "requiresAPIKey":true,"supportsModelBrowsing":true,"extraParams":{},\
            "hasBuiltInGrounding":false,"omitSystemPrompt":false}]
            """
        let store = ConfigStore(directory: tempDirectory(),
                                legacy: Legacy(providersJSON: Data(raw.utf8)))

        let snapshot = store.load()

        #expect(store.loadFailure == nil)
        #expect(snapshot.servers.first?.id == id)
        #expect(snapshot.equipped.map(\.modelID) == ["glm-5.1"])
    }

    @Test("a fresh install migrates nothing and reports no failure")
    func freshInstallIsNotAFailure() {
        let store = ConfigStore(directory: tempDirectory(), legacy: Legacy())

        let snapshot = store.load()

        #expect(snapshot.isEmpty)
        #expect(store.loadFailure == nil)
        #expect(!store.didMigrate)
    }

    // MARK: - The file (§7 amendments)

    @Test("the version travels inside the blob, not beside it")
    func versionIsInsideTheFile() throws {
        let directory = tempDirectory()
        let store = ConfigStore(directory: directory, legacy: Legacy())
        store.write(ConfigSnapshot(servers: [], equipped: []))

        let data = try Data(contentsOf: directory.appendingPathComponent(ConfigStore.fileName))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["version"] as? Int == ConfigSnapshot.currentVersion)
    }

    @Test("the legacy blob is frozen, not dual-written")
    func migrationDoesNotRewriteV1() {
        let a = cloud("near.ai", endpoint: "https://api.near.ai/v1", model: "glm-5.1")
        let original = legacyBlob([a])
        let legacy = Legacy(providersJSON: original, currentProviderID: a.id.uuidString)
        let store = ConfigStore(directory: tempDirectory(), legacy: legacy)

        store.load()
        var snapshot = store.snapshot
        snapshot.servers[0].name = "renamed after migrating"
        store.write(snapshot)

        // A rollback loses changes made after the migration — recoverable. It
        // must never read a v1 blob that a v2 write corrupted, which is not.
        #expect(legacy.providersJSON == original)
    }

    @Test("a write survives being read back")
    func writeRoundTrips() {
        let directory = tempDirectory()
        let server = Server(id: UUID(), name: "box", endpoint: "https://box.ts.net:11434/v1",
                            kind: .ollama, requiresAPIKey: false, activeModelID: "gemma4")
        let row = EquippedModel(serverID: server.id, modelID: "gemma4", capabilities: [.tools])

        let writer = ConfigStore(directory: directory, legacy: Legacy())
        writer.write(ConfigSnapshot(servers: [server], equipped: [row], currentEquippedID: row.id))

        let reader = ConfigStore(directory: directory, legacy: Legacy())
        let snapshot = reader.load()

        #expect(snapshot.servers == [server])
        #expect(snapshot.equipped == [row])
        #expect(snapshot.currentEquippedID == row.id)
        #expect(!reader.didMigrate)          // the file won, not the legacy blob
    }

    @Test("an unreadable config falls back to v1, keeps the bad file, and says so")
    func corruptFileFallsBackToLegacyRatherThanEmpty() {
        let directory = tempDirectory()
        try! Data("{ this is not json".utf8)
            .write(to: directory.appendingPathComponent(ConfigStore.fileName))
        let a = cloud("near.ai", endpoint: "https://api.near.ai/v1", model: "glm-5.1")
        let store = ConfigStore(directory: directory,
                                legacy: Legacy(providersJSON: legacyBlob([a])))

        let snapshot = store.load()

        // Rule 2: never present a decode failure as "no setups".
        #expect(snapshot.servers.map(\.id) == [a.id])
        #expect(store.loadFailure != nil)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("teemoon-config.corrupt.json").path))
    }

    @Test("a config from a newer build is not silently downgraded")
    func futureVersionIsRefused() {
        let directory = tempDirectory()
        let ahead = """
            {"version":\(ConfigSnapshot.currentVersion + 1),"servers":[],"equipped":[]}
            """
        try! Data(ahead.utf8).write(to: directory.appendingPathComponent(ConfigStore.fileName))
        let store = ConfigStore(directory: directory, legacy: Legacy())

        store.load()

        #expect(store.loadFailure != nil)
    }

    // MARK: - The invariants a database would have enforced (§7)

    @Test("an equipped row whose server is gone is dropped on load")
    func orphanRowsAreSwept() {
        let server = Server(id: UUID(), name: "box", endpoint: "https://box.ts.net/v1")
        let orphan = EquippedModel(serverID: UUID(), modelID: "ghost")
        let kept = EquippedModel(serverID: server.id, modelID: "gemma4")

        let snapshot = ConfigSnapshot(servers: [server], equipped: [orphan, kept]).validated()

        #expect(snapshot.equipped.map(\.modelID) == ["gemma4"])
    }

    @Test("a selection pointing at a dropped row is cleared, not left dangling")
    func danglingSelectionIsCleared() {
        let server = Server(id: UUID(), name: "box", endpoint: "https://box.ts.net/v1")
        let orphan = EquippedModel(serverID: UUID(), modelID: "ghost")

        let snapshot = ConfigSnapshot(servers: [server], equipped: [orphan],
                                      currentEquippedID: orphan.id).validated()

        #expect(snapshot.currentEquippedID == nil)
    }

    @Test("the same model equipped twice on one server collapses to one row")
    func duplicateRowsCollapse() {
        let server = Server(id: UUID(), name: "box", endpoint: "https://box.ts.net/v1")
        let first = EquippedModel(serverID: server.id, modelID: "gemma4")
        let second = EquippedModel(serverID: server.id, modelID: "gemma4")

        let snapshot = ConfigSnapshot(servers: [server], equipped: [first, second]).validated()

        #expect(snapshot.equipped.count == 1)
        #expect(snapshot.equipped[0].id == first.id)
    }

    @Test("the live pair cannot disagree with itself")
    func theCurrentServerRunsTheCurrentModel() {
        var server = Server(id: UUID(), name: "box", endpoint: "https://box.ts.net/v1",
                            activeModelID: "gemma4")
        let gemma = EquippedModel(serverID: server.id, modelID: "gemma4")
        let qwen = EquippedModel(serverID: server.id, modelID: "qwen3.5")
        server.activeModelID = "gemma4"

        // Selection says qwen, the server still claims gemma — the disagreement
        // that having two fields makes possible.
        let snapshot = ConfigSnapshot(servers: [server], equipped: [gemma, qwen],
                                      currentEquippedID: qwen.id).validated()

        #expect(snapshot.servers[0].activeModelID == "qwen3.5")
    }

    @Test("a server pointing at a model it no longer has falls back to one it does")
    func staleActiveModelFallsBack() {
        let server = Server(id: UUID(), name: "box", endpoint: "https://box.ts.net/v1",
                            activeModelID: "removed")
        let kept = EquippedModel(serverID: server.id, modelID: "gemma4")

        let snapshot = ConfigSnapshot(servers: [server], equipped: [kept]).validated()

        #expect(snapshot.servers[0].activeModelID == "gemma4")
    }

    // MARK: - Projection

    @Test("a provider survives normalization unchanged")
    func providerRoundTripsThroughTheSchema() {
        var provider = cloud("near.ai", endpoint: "https://api.near.ai/v1", model: "glm-5.1",
                             models: ["glm-5.1", "qwen3.5"], caps: [.tools])
        provider.authHeaderName = "X-Subscription-Token"
        provider.extraParams = ["temperature": "0.7"]
        provider.maxMessages = 1
        provider.hasBuiltInGrounding = true
        provider.omitSystemPrompt = true
        provider.supportsModelBrowsing = true

        let snapshot = ProviderConfigProjection.snapshot(
            providers: [provider], currentProviderID: provider.id.uuidString)
        let back = ProviderConfigProjection.providers(from: snapshot)

        #expect(back.providers == [provider])
        #expect(back.currentProviderID == provider.id.uuidString)
    }

    @Test("equipping a second model no longer erases the first one's capabilities")
    func capabilitiesAreKeptPerModel() {
        // §2.2. `Provider.modelCapabilities` is singular, so this was
        // unrepresentable: one key with a tool-using model and a non-tool model
        // equipped could only remember whichever was equipped last, and
        // `modelSupportsTools` then answered for the wrong model.
        let toolModel = cloud("near.ai", endpoint: "https://api.near.ai/v1", model: "glm-5.1",
                              models: ["glm-5.1"], caps: [.tools])
        let first = ProviderConfigProjection.snapshot(providers: [toolModel],
                                                      currentProviderID: nil)

        var second = toolModel.equipping("no-tools-model")
        second.modelCapabilities = []       // a KNOWN "supports none of these"
        let after = ProviderConfigProjection.snapshot(providers: [second],
                                                      currentProviderID: nil,
                                                      previous: first)

        let glm = after.equipped.first { $0.modelID == "glm-5.1" }
        let plain = after.equipped.first { $0.modelID == "no-tools-model" }
        #expect(glm?.capabilities == [.tools])
        #expect(plain?.capabilities == [])
    }

    @Test("a save cannot flatten what a Provider has nowhere to carry")
    func normalizationPreservesServerFacts() {
        let provider = cloud("box", endpoint: "https://box.ts.net:11434/v1", model: "gemma4",
                             models: ["gemma4"])
        var previous = ProviderConfigProjection.snapshot(providers: [provider],
                                                         currentProviderID: nil)
        // Facts a probe establishes (phase 2) and `Provider` cannot express.
        previous.servers[0].kind = .ollama
        previous.servers[0].servedModels = ["gemma4", "qwen3.5"]
        let addedAt = previous.equipped[0].addedAt
        let rowID = previous.equipped[0].id

        let after = ProviderConfigProjection.snapshot(providers: [provider],
                                                      currentProviderID: nil,
                                                      previous: previous)

        #expect(after.servers[0].kind == .ollama)
        #expect(after.servers[0].servedModels == ["gemma4", "qwen3.5"])
        #expect(after.equipped[0].id == rowID)
        #expect(after.equipped[0].addedAt == addedAt)
    }

    @Test("re-saving from a screen that knows no capabilities does not wipe them")
    func unknownCapabilitiesNeverClearKnownOnes() {
        let known = cloud("near.ai", endpoint: "https://api.near.ai/v1", model: "glm-5.1",
                          models: ["glm-5.1"], caps: [.tools])
        let previous = ProviderConfigProjection.snapshot(providers: [known],
                                                         currentProviderID: nil)

        var edited = known
        edited.modelCapabilities = nil       // nil is "unknown", not "none"
        let after = ProviderConfigProjection.snapshot(providers: [edited],
                                                      currentProviderID: nil,
                                                      previous: previous)

        #expect(after.equipped[0].capabilities == [.tools])
    }

    // MARK: - Through ProviderStore

    @Test("the store loads what a previous run saved")
    func providerStoreRoundTripsThroughTheFile() {
        let directory = tempDirectory()
        let provider = cloud("near.ai", endpoint: "https://api.near.ai/v1", model: "glm-5.1",
                             models: ["glm-5.1", "qwen3.5"])

        let first = ProviderStore(config: ConfigStore(directory: directory, legacy: Legacy()))
        first.addProvider(provider)
        first.currentProviderID = provider.id.uuidString

        let second = ProviderStore(config: ConfigStore(directory: directory, legacy: Legacy()))

        #expect(second.providers == [provider])
        #expect(second.currentProviderID == provider.id.uuidString)
        #expect(second.activeProvider?.model == "glm-5.1")
    }

    @Test("the store migrates a v1 install on first launch and writes v2 down")
    func providerStoreMigratesOnce() {
        let directory = tempDirectory()
        let provider = cloud("near.ai", endpoint: "https://api.near.ai/v1", model: "glm-5.1")
        let legacy = Legacy(providersJSON: legacyBlob([provider]),
                            currentProviderID: provider.id.uuidString)

        let first = ProviderStore(config: ConfigStore(directory: directory, legacy: legacy))
        #expect(first.providers.map(\.id) == [provider.id])

        // Second launch reads the file, not the blob — so the migration is over.
        let store = ConfigStore(directory: directory, legacy: Legacy())
        let second = ProviderStore(config: store)
        #expect(second.providers.map(\.id) == [provider.id])
        #expect(!store.didMigrate)
    }

    @Test("an unreadable config surfaces on the store rather than reading as empty")
    func providerStoreSurfacesLoadFailure() {
        let directory = tempDirectory()
        try! Data("{ nope".utf8)
            .write(to: directory.appendingPathComponent(ConfigStore.fileName))
        let provider = cloud("near.ai", endpoint: "https://api.near.ai/v1", model: "glm-5.1")

        let store = ProviderStore(config: ConfigStore(
            directory: directory, legacy: Legacy(providersJSON: legacyBlob([provider]))))

        #expect(store.loadFailure != nil)
        #expect(store.providers.count == 1)
    }

    @Test("using a model stamps the row it ran on")
    func recordUseStampsTheRow() {
        let directory = tempDirectory()
        let config = ConfigStore(directory: directory, legacy: Legacy())
        let store = ProviderStore(config: config)
        var provider = cloud("near.ai", endpoint: "https://api.near.ai/v1", model: "glm-5.1",
                             models: ["glm-5.1", "qwen3.5"])
        store.addProvider(provider)
        provider = store.providers[0]

        store.recordUse(of: provider)

        let glm = config.snapshot.equipped.first { $0.modelID == "glm-5.1" }
        let qwen = config.snapshot.equipped.first { $0.modelID == "qwen3.5" }
        #expect(glm?.lastUsedAt != nil)
        #expect(qwen?.lastUsedAt == nil)
    }

    @Test("an in-memory store touches no file")
    func inMemoryStoreIsInert() {
        let store = ProviderStore(inMemory: true)
        store.addProvider(cloud("near.ai", endpoint: "https://api.near.ai/v1", model: "glm-5.1"))

        #expect(store.providers.count == 1)
        #expect(ConfigStore.inMemory().fileURL == nil)
    }
}

/// §2.3 / §2.4 — a probe writes SERVER facts, never the user's selection, and they
/// survive the next launch.
@MainActor
@Suite("Probe facts are server facts")
struct ProbeFactsTests {

    /// `ProviderStore(config:)`, never `ProviderStore(inMemory: true)` — the latter
    /// sets `persists` false, so `recordProbe` (like `recordUse`) is a no-op and the
    /// test would be asserting against a store that never wrote anything.
    private func persistingStore() -> ProviderStore { ProviderStore(config: .inMemory()) }

    private func machine(_ store: ProviderStore) -> Provider {
        var p = Provider(name: "box", endpoint: "http://100.100.0.12:11434/v1",
                         model: "gemma4", requiresAPIKey: false)
        p.equippedModels = ["gemma4"]
        store.addProvider(p)
        return p
    }

    /// The observation must not touch what is equipped. Writing the probe's list
    /// into `equippedModels` is what made every home gesture revert.
    @Test func recordingAProbeLeavesTheSelectionAlone() {
        let store = persistingStore()
        let p = machine(store)

        store.recordProbe(of: p, kind: .ollama, servedModels: ["gemma4", "qwen3.5:4b"])

        let after = store.providers.first { $0.id == p.id }
        #expect(after?.equipped == ["gemma4"], "a probe changed the equipped set")
        #expect(store.servedModels(of: p) == ["gemma4", "qwen3.5:4b"])
        #expect(store.storedKind(of: p) == .ollama)
    }

    /// A probe that can't classify the server must not erase a kind an earlier one
    /// established — losing it takes away `/api/pull`, which is §2.4's dead end.
    @Test func anUndeterminedKindDoesNotEraseAKnownOne() {
        let store = persistingStore()
        let p = machine(store)
        store.recordProbe(of: p, kind: .ollama, servedModels: ["gemma4"])

        // What a failed detection reports: `LocalServerKind.unknown.stored` is nil.
        #expect(LocalServerKind.unknown.stored == nil)
        store.recordProbe(of: p, kind: LocalServerKind.unknown.stored, servedModels: nil)

        #expect(store.storedKind(of: p) == .ollama, "an unknown kind erased a known one")
        #expect(store.servedModels(of: p) == ["gemma4"], "a nil list erased the known one")
    }

    /// And they persist, which is the whole point — the in-memory probe cache did
    /// not, so one dropped request cost the machine its name and its affordances.
    @Test func probeFactsSurviveAReload() throws {
        let config = ConfigStore.inMemory()
        let store = ProviderStore(config: config)
        let p = machine(store)
        store.recordProbe(of: p, kind: .ollama, servedModels: ["gemma4", "qwen3.5:4b"])

        let reloaded = ProviderStore(config: config)

        #expect(reloaded.servedModels(of: p) == ["gemma4", "qwen3.5:4b"])
        #expect(reloaded.storedKind(of: p) == .ollama)
    }
}

/// A model whose weights are GONE leaves the history too — §2.6's counterpart.
@MainActor
@Suite("Deleting a model forgets it")
struct ForgetModelTests {

    private func usedMachine() -> (ProviderStore, Provider) {
        let store = ProviderStore(config: .inMemory())
        var p = Provider(name: "box", endpoint: "http://100.100.0.12:11434/v1",
                         model: "gemma4", requiresAPIKey: false)
        p.equippedModels = ["gemma4", "qwen3.5:4b"]
        store.addProvider(p)
        store.recordProbe(of: p, kind: .ollama, servedModels: ["gemma4", "qwen3.5:4b"])
        // Both have answered, so both are in the history.
        for model in ["gemma4", "qwen3.5:4b"] {
            var used = p; used.model = model
            store.recordUse(of: used)
        }
        return (store, p)
    }

    /// Unequipping KEEPS the history — the model still exists and can come back.
    @Test func unequippingKeepsItInRecentlyUsed() {
        let (store, p) = usedMachine()

        store.unequip(modelID: "qwen3.5:4b", from: p)

        #expect(store.recentlyUsed(limit: 9).contains { $0.modelID == "qwen3.5:4b" })
    }

    /// Deleting does NOT. The weights are gone from the machine, so a history row
    /// for it could only fail when tapped — and it must leave rather than be
    /// filtered out of sight, which is what left it in the list before: the
    /// persisted `servedModels` still claimed the machine had it.
    @Test func deletingRemovesItFromRecentlyUsed() {
        let (store, p) = usedMachine()

        store.forgetModel("qwen3.5:4b", on: p)

        #expect(!store.recentlyUsed(limit: 9).contains { $0.modelID == "qwen3.5:4b" })
        #expect(store.servedModels(of: p) == ["gemma4"],
                "the machine still claims to serve a model teemoon deleted")
        // The model that was NOT deleted is untouched.
        #expect(store.recentlyUsed(limit: 9).contains { $0.modelID == "gemma4" })
    }
}
