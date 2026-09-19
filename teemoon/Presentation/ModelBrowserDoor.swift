//
//  ModelBrowserDoor.swift
//  teemoon
//
//  What a browser is opened onto: the saved rows to show first, how to fetch
//  fresh ones, and what this catalogue can say about itself. Built once per
//  setup here, so the three screens that open a browser hand it one value
//  instead of assembling the same arguments by hand.
//

import Foundation

struct ModelBrowserDoor {
    /// What this server last answered with, shown immediately.
    var models: [KnownModel] = []
    /// Fetches the current list; on failure whatever was saved stays on screen.
    var liveLoader: (() async -> [KnownModel]?)? = nil
    /// near.ai only: its models carry a trust tier.
    var showsConfidentialityTags = false
    /// Offers the typed text as a model id when nothing matches. Never for
    /// near.ai: an unknown id there classifies as own-fleet, which would claim
    /// an encryption teemoon cannot check.
    var allowsCustomID = false
    /// Who can serve a given model, for the model card. nil for a catalogue
    /// that publishes no such list — an empty table would imply it does.
    var offersLoader: ((String) async -> [ModelOffer])? = nil

    /// The Where sheet's door: a setup's whole catalogue.
    @MainActor
    static func browsing(_ provider: Provider, apiKey: String, homeKind: LocalServerKind?) -> ModelBrowserDoor {
        ModelBrowserDoor(
            models: WhereProviderPresentation.browseModels(for: provider, apiKey: apiKey),
            liveLoader: WhereProviderPresentation.liveModelsLoader(for: provider, apiKey: apiKey, homeKind: homeKind),
            showsConfidentialityTags: WhereProviderPresentation.showsConfidentialityTags(for: provider),
            allowsCustomID: !provider.isNearAI,
            offersLoader: WhereProviderPresentation.offersLoader(for: provider, apiKey: apiKey))
    }

    /// The trust ladder's door: near.ai filtered to what teemoon can seal —
    /// own-fleet models with a published confidential host.
    @MainActor
    static func encryptedPicker(for provider: Provider, apiKey: String) -> ModelBrowserDoor {
        ModelBrowserDoor(
            models: NearAIModelCatalog.encryptedChoices(from: LiveCatalogStore.shared.models(for: provider, apiKey: apiKey)),
            liveLoader: {
                guard let rows = await LiveCatalogStore.shared.refresh(provider, apiKey: apiKey, maxAge: 3600) else { return nil }
                let choices = NearAIModelCatalog.encryptedChoices(from: rows)
                return choices.isEmpty ? nil : choices
            },
            showsConfidentialityTags: true)
    }
}
