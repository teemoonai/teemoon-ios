//
//  ProviderConfigProjection.swift
//  teemoon
//
//  Translates between the persisted schema (`Server` + `EquippedModel`) and
//  the `Provider` struct the rest
//  of the app still reads.
//
//  This seam is deliberate. The schema change is worth having on disk NOW —
//  keys keyed by the server, capabilities keyed by the model, one row per model
//  — but `Provider.model` is read in the whole inference and attestation chain,
//  and rewriting those call sites in the same change as the storage would make
//  a data migration and a refactor fail as one thing. Storage moves first;
//  §3's "what collapses" table is what removes this file.
//
//  Related: ConfigStore (the file), ProviderStore (the API the app uses).
//

import Foundation

enum ProviderConfigProjection {

    /// Identity of one equipped row, for matching a save against what is stored.
    static func rowKey(_ serverID: UUID, _ modelID: String) -> String {
        "\(serverID.uuidString)|\(modelID)"
    }

    // MARK: - Provider → schema

    /// Normalizes the in-memory provider list into the stored schema.
    ///
    /// `previous` is what is already on disk, and it is not optional decoration:
    /// it carries every fact `Provider` has nowhere to put — a probed
    /// `ServerKind`, the capabilities of models that are equipped but not
    /// active, `addedAt`, `lastUsedAt`, and each row's stable id. Without it
    /// every save would flatten the normalized data back down to what the flat
    /// struct can express, which is the bug this schema exists to fix.
    /// How many retired rows to keep. `WhereRecentsStore` capped its own list for
    /// the same reason and at the same order of magnitude; the section shows a
    /// handful, and a config file's job is to stay small.
    static let retiredRowLimit = 12

    static func snapshot(
        providers: [Provider],
        currentProviderID: String?,
        previous: ConfigSnapshot = .empty,
        lastUsed: [String: Date] = [:]
    ) -> ConfigSnapshot {
        var priorServers: [UUID: Server] = [:]
        for server in previous.servers { priorServers[server.id] = server }
        var priorRows: [String: EquippedModel] = [:]
        for row in previous.equipped { priorRows[rowKey(row.serverID, row.modelID)] = row }

        var servers: [Server] = []
        var equipped: [EquippedModel] = []
        var currentEquippedID: UUID?

        for provider in providers {
            let prior = priorServers[provider.id]
            servers.append(
                Server(
                    // §4: the SAME id. The Keychain entry hangs off this string.
                    id: provider.id,
                    name: provider.name,
                    endpoint: provider.endpoint,
                    // A local provider is on-device by definition; anything else
                    // keeps whatever a probe has already established, because
                    // `Provider` has no field that could tell us otherwise.
                    kind: provider.isLocal ? .onDevice : (prior?.kind ?? .openAICompatible),
                    requiresAPIKey: provider.requiresAPIKey,
                    authHeaderName: provider.authHeaderName,
                    extraParams: provider.extraParams,
                    maxMessages: provider.maxMessages,
                    hasBuiltInGrounding: provider.hasBuiltInGrounding,
                    omitSystemPrompt: provider.omitSystemPrompt,
                    supportsModelBrowsing: provider.supportsModelBrowsing,
                    activeModelID: provider.model.isEmpty ? nil : provider.model,
                    presetDescription: provider.presetDescription,
                    signupURL: provider.signupURL,
                    servedModels: prior?.servedModels
                )
            )

            for modelID in provider.equipped {
                let key = rowKey(provider.id, modelID)
                var row = priorRows[key] ?? EquippedModel(serverID: provider.id, modelID: modelID)

                // §2.2, the capabilities overwrite. A `Provider` carries exactly
                // one `modelCapabilities`, and it describes its ACTIVE model —
                // so that is the only row it may speak for. Every other row
                // keeps what it already knew, which is what stops equipping a
                // second model from erasing the first one's capabilities.
                if modelID == provider.model, let caps = provider.modelCapabilities {
                    row.capabilities = caps
                }
                // Never clears knowledge: nil means "unknown", and a provider
                // re-saved from a screen that does not fetch capabilities would
                // otherwise wipe a real answer.

                if let stamp = lastUsed[key], row.lastUsedAt == nil || row.lastUsedAt! < stamp {
                    row.lastUsedAt = stamp
                }

                if provider.id.uuidString == currentProviderID, modelID == provider.model {
                    currentEquippedID = row.id
                }
                // Re-equipping something retired clears the mark, so it leaves
                // `recently used` and goes back to `ready now` rather than
                // appearing in both.
                row.unequippedAt = nil
                equipped.append(row)
            }
        }

        // RETIRED ROWS SURVIVE. A row whose model is no longer equipped is kept and
        // marked, not dropped — its `lastUsedAt` is the only fact `recently used` is
        // built from (§2.6), and anything still equipped is already in `ready now`,
        // so dropping these would empty the section it exists for.
        //
        // Kept only when the model was actually USED and its server still exists,
        // and capped, because this list would otherwise grow forever on a store
        // whose whole job is to be small. Newest first.
        let liveServerIDs = Set(servers.map(\.id))
        let keptKeys = Set(equipped.map { rowKey($0.serverID, $0.modelID) })
        let retired = previous.equipped
            .filter { !keptKeys.contains(rowKey($0.serverID, $0.modelID)) }
            .filter { $0.lastUsedAt != nil && liveServerIDs.contains($0.serverID) }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .prefix(Self.retiredRowLimit)
            .map { row -> EquippedModel in
                var copy = row
                // Stamped once, on the save that retires it, so re-saving doesn't
                // keep pushing the date forward and make an old model look recent.
                if copy.unequippedAt == nil { copy.unequippedAt = .now }
                return copy
            }
        equipped.append(contentsOf: retired)

        return ConfigSnapshot(
            servers: servers,
            equipped: equipped,
            currentEquippedID: currentEquippedID
        ).validated()
    }

    // MARK: - Schema → Provider

    /// Rebuilds the flat provider list. One `Provider` per `Server`, its
    /// `equippedModels` the server's rows in stored order, and its
    /// `modelCapabilities` the ACTIVE row's — which is the only model a
    /// `Provider` can describe.
    static func providers(
        from snapshot: ConfigSnapshot
    ) -> (providers: [Provider], currentProviderID: String?) {
        var rowsByServer: [UUID: [EquippedModel]] = [:]
        // EQUIPPED ONLY. Retired rows are kept in the snapshot so `recently used`
        // has something to read (§2.6), and projecting them back into
        // `equippedModels` would put every model the user ever removed back in
        // `ready now` — undoing the unequip on the next launch.
        for row in snapshot.equipped where row.isEquipped {
            rowsByServer[row.serverID, default: []].append(row)
        }

        let providers: [Provider] = snapshot.servers.map { server in
            let rows = rowsByServer[server.id] ?? []
            let modelIDs = rows.map(\.modelID)
            let active = server.activeModelID ?? modelIDs.first ?? ""
            let activeRow = rows.first { $0.modelID == active }
            return Provider(
                id: server.id,
                name: server.name,
                endpoint: server.endpoint,
                model: active,
                authHeaderName: server.authHeaderName,
                requiresAPIKey: server.requiresAPIKey,
                supportsModelBrowsing: server.supportsModelBrowsing,
                extraParams: server.extraParams,
                maxMessages: server.maxMessages,
                hasBuiltInGrounding: server.hasBuiltInGrounding,
                omitSystemPrompt: server.omitSystemPrompt,
                presetDescription: server.presetDescription,
                signupURL: server.signupURL,
                modelCapabilities: activeRow?.capabilities,
                // `.onDevice` is the stored fact; `localModelID` is how the rest
                // of the app still asks the question. `isLocal` is what callers
                // branch on, so this must never be nil for an on-device server.
                localModelID: server.kind == .onDevice ? (active.isEmpty ? nil : active) : nil,
                equippedModels: modelIDs.isEmpty ? nil : modelIDs
            )
        }

        let current = snapshot.currentEquippedID.flatMap { id in
            snapshot.equipped.first { $0.id == id }
        }
        return (providers, current?.serverID.uuidString)
    }
}
