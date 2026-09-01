//
//  WhereSheetView+Actions.swift
//  teemoon
//

import SwiftUI

extension WhereSheetView {
    // MARK: - Actions

    /// Picking a row means "run THIS model on THIS connection" — two writes,
    /// which `activate` keeps together.
    ///
    /// Deliberately does NOT record a recent. Recents are what you've *used*,
    /// and selecting is a statement of intent that a dead key or a sleeping host
    /// may never make good on. `ChatGeneration.onFirstToken` records it when the
    /// model actually answers.
    func select(_ row: Equipped) {
        providerStore.activate(modelID: row.modelID, on: row.provider)
        Haptics.play()
        dismiss()
    }

    /// Tapping a model in `get` is a choice, not a chore: it becomes a provider
    /// and the ACTIVE one straight away, then the bytes follow. The row moves up
    /// to `ready now` with a progress bar, the chip in chat names it, and
    /// sending is gated until the weights land — after which it just works,
    /// with no second trip through settings to "use" it.
    ///
    /// Selecting before the download completes is the whole point. Downloading
    /// first and selecting after would leave the user watching a bar with
    /// nothing decided at the end of it.
    func startAndSelect(_ model: LocalModel) {
        let provider = providerStore.providers.first { $0.localModelID == model.id }
            ?? Provider.local(model)
        if !providerStore.providers.contains(where: { $0.id == provider.id }) {
            providerStore.addProvider(provider)
        }
        providerStore.activate(modelID: provider.model, on: provider)
        downloader.start(model)
        Haptics.play()
        dismiss()
    }

    /// Cancel an in-flight download AND remove the provider it was added for.
    ///
    /// The provider only exists because the download started, so keeping it
    /// after a cancel would leave a row in "ready now" that can never answer.
    /// `removeProvider` also re-points `currentProviderID`, so the user doesn't
    /// end up with a selected setup that isn't there.
    /// Deletes a downloaded model's weights and drops its provider, which is
    /// what returns the row to `get` — `downloadableModels` is "catalog entries
    /// with no provider", so removing the provider puts it back automatically.
    func deleteWeights(_ model: LocalModel) {
        // CANCEL FIRST. Deleting under a live download left the task running
        // against a destination that no longer existed; it died on the next write
        // and reported itself as "network error (-1005)" — a connection failure
        // for a connection that was fine, blamed on the network for something the
        // user did on purpose. Cancelling also clears the stored failure, so the
        // row doesn't keep an error from a download nobody wants any more.
        downloader.cancel(model.id)
        downloader.clearFailure(model.id)
        // The whole model, not its id: the id-only form removes an MLX snapshot
        // directory that a `.litertlm` model doesn't have, so it would report
        // success and leave gigabytes on disk. Same trap the download screen
        // documents.
        try? LocalModelStorage.delete(model)
        for provider in providerStore.providers where provider.localModelID == model.id {
            providerStore.removeProvider(provider)
        }
        Haptics.play()
    }

    /// Makes a home provider's equipped set BE the server's model list.
    ///
    /// Every model on the machine can already run — the user pulled it, on that
    /// machine, deliberately. Asking them to then "add" it here was a step whose
    /// only purpose was feeding a data model that couldn't hold more than one
    /// model per provider. With the set synced, `ready now` for a home server is
    /// simply what the server has, and `get` is free to mean the only thing
    /// that's actually missing: a model the server doesn't have yet.
    ///
    /// Two-way: a model deleted on the server leaves the list too, rather than
    /// lingering as a row that 404s on send.
    func syncHomeEquipped() {
        for provider in providerStore.providers
        where WhereLocality.of(provider) == .home {
            guard let info = homeProbe.info(for: provider), let served = info.models,
                  !served.isEmpty else { continue }
            // The OBSERVATION goes to the server, as a server fact. This is the
            // §2.3 fix: it used to be written into `equippedModels` — the user's
            // selection — so every probe overwrote a choice with an observation.
            providerStore.recordProbe(of: provider,
                                      kind: info.kind.stored,
                                      servedModels: served)

            // For a home machine the runnable set IS what it serves, and that is a
            // product decision rather than a data-model concession: nothing is
            // "added" to a server you already own, so making the user equip models
            // they demonstrably have would be a step that exists for no one.
            //
            // So this still mirrors served → equipped, and it PRUNES as well as
            // grows: a model deleted on the machine — by teemoon or by someone at
            // the Ollama CLI — should leave the list, and only mirroring can notice
            // that. Not pruning would leak rows that can no longer answer.
            //
            // The revert bug was never this mirroring. It was mirroring a STALE
            // observation: `refresh` skips a provider already `inFlight`, so a probe
            // overlapping a delete left the pre-delete list in the cache and it got
            // written back. That is fixed at the source — `HomeServerProbe.forget`
            // updates the cache when teemoon deletes — and mirroring a correct
            // observation is correct.
            //
            // In-flight pulls are unioned in because the server genuinely doesn't
            // serve them yet, and dropping them would delete the row a download is
            // rendering its progress into.
            let arriving = (pullCenter?.inProgress ?? [])
                .filter { $0.baseURL == provider.openAIBaseURL }
                .map(\.id)
            let target = served + arriving.filter { !served.contains($0) }
            guard Set(target) != Set(provider.equipped) else { continue }
            var updated = provider
            updated.equippedModels = target
            // Keep running what it was running, unless the machine no longer has it
            // AND it isn't on its way — then fall back rather than point at
            // something absent.
            if updated.model.isEmpty || !target.contains(updated.model) {
                updated.model = target[0]
            }
            providerStore.updateProvider(updated)
        }
    }

    func cancelArriving(_ provider: Provider) {
        if let localID = provider.localModelID {
            downloader.cancel(localID)
        }
        providerStore.removeProvider(provider)
        Haptics.play()
    }

    /// Re-EQUIPS as well as re-points, because a recent can name a model that has
    /// since left the equipped set — tapping it has to put it back or the row
    /// vanishes and nothing runs. `activate` does both, and re-equipping clears the
    /// row's `unequippedAt`, so it moves out of `recently used` and into `ready now`
    /// rather than showing in both.
    ///
    /// Deliberately does not stamp `lastUsedAt`: that happens when a model produces
    /// output, and stamping here would reinstate the recently-SELECTED behaviour
    /// this list stopped implementing.
    func selectRecent(_ entry: WhereRecentEntry) {
        guard let provider = providerStore.providers.first(where: { $0.id == entry.providerID })
        else { return }
        providerStore.activate(modelID: entry.modelID, on: provider)
        Haptics.play()
        dismiss()
    }

    func openBrowse(_ provider: Provider) {
        browseSelectedModel = provider.model
        browseProvider = provider
    }

    @ViewBuilder
    func browseSheet(for provider: Provider) -> some View {
        if provider.prefersSearchFirstBrowse {
            SearchFirstModelBrowser(
                provider: provider,
                apiKey: providerStore.credential(for: provider),
                onSelect: { known in
                    applyBrowseSelection(provider: provider, model: known)
                }
            )
        } else {
            // LIVE first for near.ai, snapshot only as the offline fallback.
            //
            // This sheet used to render `KnownModel.nearAIModels` unconditionally
            // while settings' own browser fetched `/v1/models` — so the same
            // provider's catalog looked different depending on which door you came
            // through, and this door was the stale one. Measured 2026-07-29: it
            // showed a "new" badge on two models published 55 days earlier and no
            // badge on six that qualified, plus snapshot prices and context windows.
            //
            // The fallback keeps its place: with no key or no network there is
            // nothing live to show, and a curated list beats an empty sheet.
            // `ModelBrowserView` already had the seam for this — `liveLoader`,
            // built for settings' near.ai browser and simply never passed here.
            ModelBrowserView(
                selectedModel: $browseSelectedModel,
                models: WhereProviderPresentation.browseModels(for: provider),
                onSelect: { known in
                    applyBrowseSelection(provider: provider, model: known)
                },
                liveLoader: liveCatalogLoader(for: provider),
                showsConfidentialityTags: WhereProviderPresentation.showsConfidentialityTags(for: provider)
            )
        }
    }

    /// Browse EQUIPS. It used to replace `provider.model`, so picking a second
    /// model from the same key silently discarded the first — the connection
    /// could only ever hold one, which is the conflation this split undoes.
    /// Equipping is additive and makes the new one active, so the immediate
    /// behaviour a user sees is unchanged; the difference is that the previous
    /// model is still in the list when they come back.
    func applyBrowseSelection(provider: Provider, model: KnownModel) {
        var updated = provider.equipping(model.id)
        if let caps = model.capabilities {
            updated.modelCapabilities = caps
        }
        // MATERIALISE THE RECORD IF THERE ISN'T ONE.
        //
        // `updateProvider` only ever updates — it has no insert branch, so a
        // selection made against a keyed preset with no `servers` row would be
        // dropped on the floor and `currentProviderID` left pointing at an id
        // that does not exist. `addProvider` folds by endpoint, so it cannot
        // produce a second record for a server already configured.
        let equippedID: UUID
        if providerStore.providers.contains(where: { $0.id == updated.id }) {
            providerStore.updateProvider(updated)
            equippedID = updated.id
        } else {
            equippedID = providerStore.addProvider(updated)
        }
        providerStore.currentProviderID = equippedID.uuidString
        // No recent recorded here either — equipping a model is the strongest
        // possible statement of intent and still isn't use.
        Haptics.play()
        browseProvider = nil
        dismiss()
    }

}
