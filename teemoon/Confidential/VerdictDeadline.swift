//
//  VerdictDeadline.swift
//  teemoon
//
//  near.ai's tier ends in a verdict within 20 s (formal/ TierTimeout). The tier only: every other verifier ends at
//  its own network bound (the maintainer 2026-11-14, option i); do not arm this for them. Owned by `ConfidentialSession`.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "verdict-deadline")

@Observable
@MainActor
final class VerdictDeadline {

    /// the maintainer 2026-11-14: near.ai's tier ends in a verdict within 20 s.
    static let twentySeconds: Duration = .seconds(20)

    /// DRAFT (verify-deadline): the degrade reason when near.ai's tier list never arrived.
    nonisolated static let tierReason = "near.ai's model list didn't load, so teemoon couldn't confirm this model runs on its own hardware."

    let after: Duration
    /// Fetches near.ai's public tier list (no key); true when a list arrived.
    @ObservationIgnored let loadTierList: @MainActor (Provider) async -> Bool
    @ObservationIgnored let tierRetryDelays: [Duration]

    /// The model whose tier was still unknown at the deadline.
    private(set) var tierGaveUpOn: String?
    /// Bumped when a tier list lands: the tier lives in a lock, so this is what re-renders a reader.
    private(set) var tierListArrivals = 0

    @ObservationIgnored private var tierModel: String?
    @ObservationIgnored private var tierLoad: Task<Void, Never>?
    @ObservationIgnored private var tierTimer: Task<Void, Never>?

    init(after: Duration = VerdictDeadline.twentySeconds,
         tierRetryDelays: [Duration] = [.seconds(2), .seconds(4)],
         loadTierList: (@MainActor (Provider) async -> Bool)? = nil) {
        self.after = after
        self.tierRetryDelays = tierRetryDelays
        self.loadTierList = loadTierList ?? VerdictDeadline.publicTierList(from: .shared)
    }

    /// near.ai answers `/v1/models` without a key; never send one here.
    static func publicTierList(from store: LiveCatalogStore) -> @MainActor (Provider) async -> Bool {
        { provider in await store.refresh(provider, apiKey: "", maxAge: 0) != nil }
    }

    /// The tier, read so a late tier list re-renders whoever asked.
    func tier(for model: String) -> NearAIModelCatalog.Confidentiality {
        _ = tierListArrivals
        return NearAIModelCatalog.confidentiality(forID: model)
    }

    func tierGaveUp(on model: String) -> Bool {
        tierGaveUpOn == model && tier(for: model) == .unknown
    }

    /// Loads near.ai's tier list for an unknown tier and starts its deadline. Independent of a key, the heal and
    /// `--uitesting`: without it the tier stays unknown and the chat reads "verifying…" forever.
    func watchTier(_ provider: Provider) {
        guard provider.isNearAI, tier(for: provider.model) == .unknown else { return }
        let model = provider.model
        if tierModel != model {
            tierLoad?.cancel(); tierTimer?.cancel()
            tierLoad = nil; tierTimer = nil
            tierGaveUpOn = nil
            tierModel = model
        }
        if tierLoad == nil {
            tierLoad = Task { [weak self] in
                await self?.loadTiers(provider)
                if self?.tierModel == model { self?.tierLoad = nil }
            }
        }
        // Once given up, a re-verify reloads the list but the chip does not go back to "verifying…".
        guard tierTimer == nil, tierGaveUpOn != model else { return }
        let after = after
        tierTimer = Task { [weak self] in
            try? await Task.sleep(for: after)
            guard !Task.isCancelled, let self, self.tierModel == model else { return }
            if NearAIModelCatalog.confidentiality(forID: model) == .unknown {
                logger.warning("[tier] \(model, privacy: .public) still unknown after the deadline — can't check")
                self.tierGaveUpOn = model
            }
            self.tierTimer = nil
        }
    }

    private func loadTiers(_ provider: Provider) async {
        for attempt in 0...tierRetryDelays.count {
            if attempt > 0 {
                try? await Task.sleep(for: tierRetryDelays[attempt - 1])
            }
            if Task.isCancelled { return }
            if await loadTierList(provider) {
                tierListArrivals += 1
                return
            }
            logger.warning("[tier] near.ai tier list attempt \(attempt + 1) failed")
        }
    }
}
