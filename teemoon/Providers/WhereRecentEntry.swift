//
//  WhereRecentEntry.swift
//  teemoon
//
//  One row of "recently used": the provider instance with `model` set to the
//  id that answered, and when it last produced output.
//
//  This used to come with a store. `WhereRecentsStore` kept its own UserDefaults
//  blob of picks — record / visible / activate / save / load — and the
//  argument for deleting it stands: the
//  config file holds the same fact on the row that owns it
//  (`EquippedModel.lastUsedAt`), written by the same event, and that row OUTLIVES
//  the unequip which a recent is mostly made of. Two stores of one fact disagree
//  eventually, and this pair had already started: the blob's rows carried
//  snapshot copies of labels the app had since stopped printing.
//
//  So the store is gone and what remains is the pick. Labels are computed by
//  Presentation from the live provider — not stored here — because a cached
//  caption is a description of how the app talked about a place in the past.
//  `ProviderStore.recentlyUsed()` builds these from the snapshot, the sheet's
//  `visibleRecents` applies the display rules that were always view concerns
//  (`all` only, three rows), and `ConfigStore.migrateFromLegacy` still reads the
//  old blob once — through its own `LegacyRecent`, not this type — so nobody's
//  history left with the class.
//
//  Related: ProviderStore.recentlyUsed, ConfigStore.stampUse, WhereSheetView.
//

import Foundation

/// One past pick: a provider with `model` set to the id that answered then.
struct WhereRecentEntry: Identifiable, Equatable {
    /// Stable identity for list diffs: provider + model.
    var id: String { "\(provider.id.uuidString)|\(modelID)" }

    /// Live provider, `model` already pointed at the used id.
    let provider: Provider
    let recordedAt: Date

    var providerID: UUID { provider.id }
    var modelID: String { provider.model }
    var locality: WhereLocality { WhereLocality.of(provider) }

    init(provider: Provider, recordedAt: Date = .now) {
        self.provider = provider
        self.recordedAt = recordedAt
    }
}
