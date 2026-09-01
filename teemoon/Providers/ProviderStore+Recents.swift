//
//  ProviderStore+Recents.swift
//  teemoon
//
//  What has answered lately, and what a probe last saw on a machine.
//  Kept off ProviderStore.swift so CRUD is not also usage history.
//

import Foundation

extension ProviderStore {

    /// Records that a model actually produced output. The only writer of
    /// `EquippedModel.lastUsedAt` — "recently used" means used, not picked.
    func recordUse(of provider: Provider) {
        guard persists, !provider.model.isEmpty else { return }
        config.stampUse(serverID: provider.id, modelID: provider.model)
    }

    /// What has actually ANSWERED lately, newest first — the config file's own
    /// answer to what `WhereRecentsStore` kept in a second UserDefaults blob (§2.6).
    ///
    /// Read from `EquippedModel.lastUsedAt`, which `stampUse` already writes when a
    /// model produces output. Two things this has to get right, both of which the
    /// old store learned the hard way:
    ///
    /// - EQUIPPED ROWS COUNT. Filtering them out empties the list, because the model
    ///   you just used is equipped by definition. The overlap with `ready now` is
    ///   deliberate — a short list in the order you ran things answers "what was I
    ///   using yesterday", which no sorting of the full list does.
    /// - A ROW WHOSE SERVER IS GONE DOESN'T. It can't be activated, so it would be a
    ///   slot spent on something untappable. Dropped before the limit, not after, so
    ///   deleted setups don't silently eat the slots.
    ///
    /// Labels come from the provider as it is NOW rather than from a stored snapshot
    /// — the old entries carried copies that went stale when a model was renamed.
    func recentlyUsed(limit: Int = 3) -> [WhereRecentEntry] {
        let byID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        return config.snapshot.equipped
            .compactMap { row -> (WhereRecentEntry, Date)? in
                guard let stamp = row.lastUsedAt, let provider = byID[row.serverID],
                      Self.stillRunnable(modelID: row.modelID, on: provider,
                                         served: config.servedModels(serverID: row.serverID))
                else { return nil }
                var named = provider
                named.model = row.modelID
                return (WhereRecentEntry(provider: named, recordedAt: stamp), stamp)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Forgets a model entirely — equipped row, usage history and the server's
    /// record of serving it. For a model whose weights are GONE, not one merely
    /// unequipped: see `ConfigStore.forgetModel`.
    func forgetModel(_ modelID: String, on provider: Provider) {
        guard persists else { return }
        config.forgetModel(serverID: provider.id, modelID: modelID)
    }

    /// Whether tapping this recent could actually run it, without first fetching
    /// gigabytes.
    ///
    /// The three tiers answer differently, and only cloud keeps a model it no longer
    /// has equipped:
    ///
    /// - CLOUD: always. Unequipping is a curation choice; the model is still at the
    ///   provider and re-equipping it costs one request. These are what the section
    ///   is mostly made of.
    /// - PHONE: only while the weights are on disk. Deleting them returns the model
    ///   to `get`, and a recent pointing at it would select something the send gate
    ///   then has to refuse.
    /// - HOME: only while the machine still serves it. Deleting it there — from
    ///   teemoon or at the Ollama CLI — makes the row a 404 waiting to happen.
    ///
    /// Nil `served` means the machine hasn't been probed this launch, and the answer
    /// is then the last persisted list rather than "nothing" — otherwise every home
    /// recent would disappear until a probe landed.
    static func stillRunnable(
        modelID: String, on provider: Provider, served: [String]?
    ) -> Bool {
        switch WhereLocality.of(provider) {
        case .cloud:
            return true
        case .phone:
            guard let localID = provider.localModelID,
                  let model = LocalModelCatalog.model(id: localID) else { return false }
            return LocalModelStorage.isInstalled(model)
        case .home:
            guard let served else { return true }
            return served.contains(modelID)
        }
    }

    /// Stores what a probe observed about a machine, WITHOUT touching what the user
    /// has equipped on it. See `ConfigStore.recordProbe` for why those must be two
    /// different writes (§2.3).
    func recordProbe(of provider: Provider, kind: ServerKind?, servedModels: [String]?) {
        guard persists else { return }
        config.recordProbe(serverID: provider.id, kind: kind, servedModels: servedModels)
    }

    /// What this machine was last seen serving — survives a failed refresh, unlike
    /// the in-memory probe cache.
    func servedModels(of provider: Provider) -> [String]? {
        config.servedModels(serverID: provider.id)
    }

    /// What a probe last determined this machine to be, as the live probe's own
    /// enum. Nil when nothing was ever established — which is different from
    /// "generic OpenAI-compatible" and must stay different: the first means try
    /// again, the second means don't offer `/api/pull`.
    func storedKind(of provider: Provider) -> LocalServerKind? {
        switch config.kind(serverID: provider.id) {
        case .ollama:   return .ollama
        case .lmStudio: return .lmStudio
        // `.openAICompatible` is the decode fallback for an unrecognised kind as
        // well as a real classification, so it maps to the probe's `.unknown`.
        case .openAICompatible, .onDevice, nil: return nil
        }
    }
}
