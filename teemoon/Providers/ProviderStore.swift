//
//  ProviderStore.swift
//  teemoon
//
//  Owns the configured providers and the active selection: CRUD, persistence,
//  and credential storage via Keychain. Views never touch Keychain for provider
//  keys directly. Identity repair lives in ProviderStore+Healing.swift;
//  keys in ProviderStore+Credentials.swift; recents and probes in
//  ProviderStore+Recents.swift.
//
//  Persistence is a versioned `ConfigStore` file — servers, the models equipped
//  on each, and one selection — not the flat `providers` blob in UserDefaults
//  it used to be. `Provider` is now a projection of that schema
//  (`ProviderConfigProjection`), so this store's API is unchanged and the
//  migration is invisible to every caller.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "providers")

@Observable
@MainActor
final class ProviderStore {

    var providers: [Provider] = [] {
        didSet { save() }
    }

    /// The selected server. Persisted as `ConfigSnapshot.currentEquippedID` —
    /// one id naming a (server, model) pair, rather than a provider id and a
    /// model string that could disagree.
    var currentProviderID: String? {
        get {
            access(keyPath: \.currentProviderID)
            return selectedProviderID
        }
        set {
            withMutation(keyPath: \.currentProviderID) {
                selectedProviderID = newValue
                save()
            }
            onActiveProviderChanged?(activeProvider)
        }
    }

    var activeProvider: Provider? {
        providers.first { $0.id.uuidString == currentProviderID }
    }

    /// Invoked whenever the active provider changes. Wired by the app entry
    /// point to kick off attestation for the new provider (ConfidentialSession)
    /// without this store depending on the attestation layer.
    @ObservationIgnored
    var onActiveProviderChanged: ((Provider?) -> Void)?

    /// False for in-memory stores: nothing is read from or written to disk.
    /// Previews MUST use in-memory stores — the preview host is one shared
    /// sandbox, so a persisting store leaks providers into every other preview.
    @ObservationIgnored
    let persists: Bool
    @ObservationIgnored
    private var selectedProviderID: String?
    @ObservationIgnored
    let config: ConfigStore

    /// Set when the stored config could not be read. Non-nil means the list
    /// below may be incomplete — which must be *shown*, not presented as "no
    /// setups configured" to someone who has four keys saved.
    private(set) var loadFailure: String?

    /// Records that this launch folded duplicate records together, so the sheet
    /// can say so once.
    ///
    /// The merges are silent otherwise, and they DELETE records: a user with two
    /// records for one endpoint loses one, and the only evidence is a row that
    /// stopped being there. Telling them once is the difference between a fix
    /// and an unexplained disappearance.
    var mergeNotice: String?

    func dismissMergeNotice() { mergeNotice = nil }

    /// Preview/test seam: these states are only reachable through a corrupt file
    /// or a duplicated store, neither of which a preview can produce — so the
    /// copy would otherwise go unreviewed.
    func simulate(loadFailure: String? = nil, mergeNotice: String? = nil) {
        if let loadFailure { self.loadFailure = loadFailure }
        if let mergeNotice { self.mergeNotice = mergeNotice }
    }

    /// Suppresses the write that `providers.didSet` would otherwise fire while
    /// the list is being populated from disk — a load is not an edit.
    @ObservationIgnored
    private var isLoading = false

    init(inMemory: Bool = false, config: ConfigStore? = nil) {
        persists = !inMemory
        self.config = config ?? (inMemory ? .inMemory() : ConfigStore())
        if persists { load() }
    }

    // MARK: CRUD

    /// The key one record per place is matched on. Trimmed, case-folded, and
    /// trailing slashes dropped, so `…/v1` and `…/V1/ ` are one endpoint.
    static func endpointKey(_ endpoint: String) -> String {
        var key = endpoint.trimmingCharacters(in: .whitespaces).lowercased()
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    /// Registers a provider, or folds it into the record that already points at
    /// the same endpoint.
    ///
    /// **Returns the id that actually holds the setup**, which may not be the
    /// one passed in — the caller must write the Keychain entry under the
    /// returned id, or the credential lands in a slot nothing reads.
    ///
    /// One record per endpoint. A fresh UUID used to be minted on every save,
    /// so re-entering a key for an endpoint already configured produced a
    /// second record with a second Keychain entry, and neither knew about the
    /// other. Observed: rotating a near.ai key left two identical records, the
    /// stale one still holding the revoked key and still offering a model the
    /// new one did not have.
    ///
    /// Keeping the EXISTING id is what makes rotation work — the new key
    /// overwrites the old one in the same Keychain slot, rather than orphaning
    /// it. The equipped sets are unioned, so no model the user could previously
    /// run disappears.
    ///
    /// On-device providers are exempt: every one of them shares the literal
    /// endpoint `"on-device"`, so matching on it would collapse the whole local
    /// catalogue into a single record.
    @discardableResult
    func addProvider(_ provider: Provider) -> UUID {
        if !provider.isLocal,
           let index = providers.firstIndex(where: {
               !$0.isLocal && Self.endpointKey($0.endpoint) == Self.endpointKey(provider.endpoint)
           }), providers[index].id != provider.id {
            let existing = providers[index]
            var merged = provider
            merged.id = existing.id
            var models = existing.equipped
            for model in provider.equipped where !models.contains(model) { models.append(model) }
            merged.equippedModels = models
            providers[index] = merged
            logger.info("""
                [providers] folded a second record for an already-configured endpoint into \
                \(existing.name, privacy: .public)
                """)
            return existing.id
        }
        if !providers.contains(where: { $0.id == provider.id }) {
            providers.append(provider)
        }
        mergeDuplicateMachines()
        // The merge may have dropped this record into an existing machine, in
        // which case the survivor is what the caller must key.
        return providers.first {
            Self.endpointKey($0.endpoint) == Self.endpointKey(provider.endpoint) && !$0.isLocal
        }?.id ?? provider.id
    }


    /// Saves the API key to the keychain, registers the provider, and makes it
    /// current if none is selected yet. Used by onboarding.
    func connectProvider(_ provider: Provider, apiKey: String) throws {
        // Register FIRST: the endpoint may already have a record, and the key
        // has to be written under the id that survives, not the one minted here.
        let savedID = addProvider(provider)
        // Keyed by ENDPOINT, so it does not matter which record id survived the upsert.
        if let account = Self.keyAccount(for: provider) {
            try Keychain.save(apiKey, for: account)
        }
        if currentProviderID == nil {
            currentProviderID = savedID.uuidString
        }
    }

    /// Removes the provider **and its stored key**. Without the second half every
    /// add/delete cycle left an orphaned secret in the keychain under a UUID
    /// nothing referenced any more — unreachable, unremovable, and still a secret.
    func removeProvider(_ provider: Provider) {
        providers.removeAll { $0.id == provider.id }
        // Both accounts: the endpoint one this record uses, and any legacy UUID copy
        // that never got migrated. Leaving either behind is an unreachable secret.
        if let account = Self.keyAccount(for: provider) { try? Keychain.delete(for: account) }
        try? Keychain.delete(for: provider.id.uuidString)
        if currentProviderID == provider.id.uuidString {
            currentProviderID = providers.first?.id.uuidString
        }
    }

    /// Equips `modelID` on `provider`, makes it that provider's active model,
    /// and selects the provider. The one call a "pick this model" tap needs —
    /// so no view has to know that activating a model means writing two
    /// separate pieces of state.
    func activate(modelID: String, on provider: Provider) {
        let updated = provider.equipping(modelID)
        updateProvider(updated)
        currentProviderID = updated.id.uuidString
    }

    /// Removes a model from a provider's equipped set. Deletes the provider
    /// outright when it was the last one: a connection with nothing to run
    /// can't be rendered, and leaving it would be a row the picker has to
    /// invent a model for.
    ///
    /// Returns true when the whole provider went.
    @discardableResult
    /// Removes a model from a server's equipped set. Returns whether the server is
    /// now empty — NOT whether it was deleted, because it never is.
    ///
    /// Unequipping the last model used to delete the provider, and `removeProvider`
    /// deletes its Keychain entry: one swipe silently destroyed an api key the user
    /// had pasted from somewhere else. The server is not the models on it (§2.1),
    /// and `ConfigSnapshot` already stores the two separately — a `Server` with no
    /// `EquippedModel` rows is a normal state that round-trips fine.
    ///
    /// Deleting a setup is still possible; it is just an explicit action now
    /// ("forget this machine", "delete setup") rather than a side effect of tidying
    /// a list.
    func unequip(modelID: String, from provider: Provider) -> Bool {
        let updated = provider.unequipping(modelID)
        updateProvider(updated)
        return updated.equipped.isEmpty
    }

    /// Removes a model from a setup AND from its history — `ready now` and
    /// `recently used` both.
    ///
    /// `unequip` alone leaves the row: the projection deliberately keeps retired
    /// rows because `lastUsedAt` is the only thing `recently used` is built
    /// from. That is correct for a model that fell out of use and wrong for one
    /// the user swiped away, who watched it vanish from one section and reappear
    /// in another.
    ///
    /// NEVER TOUCHES THE SERVER OR ITS KEY. A model is a thing a place can run;
    /// removing one says nothing about the place, and the Keychain entry hangs
    /// off the endpoint, not off anything here.
    @discardableResult
    func forget(modelID: String, on provider: Provider) -> Bool {
        let emptied = unequip(modelID: modelID, from: provider)
        if persists { config.forget(serverID: provider.id, modelID: modelID) }
        return emptied
    }

    func updateProvider(_ provider: Provider) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
            // Editing the ACTIVE provider in place (its model, endpoint, …)
            // changes what attestation must verify, but never touches
            // currentProviderID — so without this the change hook stays
            // silent and the previous model's attestation lingers on screen
            // (observed: switching GLM-5.2 → 5.1 in Settings kept showing
            // 5.2 until an unrelated refresh ran).
            if provider.id.uuidString == currentProviderID {
                onActiveProviderChanged?(activeProvider)
            }
        }
    }

    // MARK: Persistence

    /// Normalizes the list into the stored schema and replaces the file.
    ///
    /// Hands the current snapshot back in as `previous` — that is what carries
    /// the facts a `Provider` cannot express (a probed `ServerKind`, the
    /// capabilities of models that are equipped but not active, `addedAt`,
    /// `lastUsedAt`, each row's id) across a write.
    private func save() {
        guard persists, !isLoading else { return }
        config.write(
            ProviderConfigProjection.snapshot(
                providers: providers,
                currentProviderID: selectedProviderID,
                previous: config.snapshot
            )
        )
    }

    private func load() {
        let snapshot = config.load()
        loadFailure = config.loadFailure
        let projected = ProviderConfigProjection.providers(from: snapshot)

        isLoading = true
        selectedProviderID = projected.currentProviderID
        providers = projected.providers
        isLoading = false

        // Order matters: the flag is what makes a machine recognisable, so it
        // has to be right before anything tries to match on it.
        healSelfHostedKeyFlags()
        // Before the merges, so two records of one machine are compared by the
        // names they will keep.
        healAutoLabels()
        // Heals a store that already has duplicates — they were writable before
        // this existed, so the fix cannot only be preventive. Assigning
        // `providers` inside it writes, which is also what persists a migration.
        mergeDuplicateMachines()
        // Same argument, for the records a re-entered key used to create.
        mergeDuplicateEndpoints()
        // …unless there was nothing to merge, in which case a migration still
        // has to be written down. Skipped when the load failed: overwriting data
        // we could not read is the one move that makes the failure permanent.
        if config.didMigrate && loadFailure == nil { save() }
    }
}
