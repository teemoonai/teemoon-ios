//
//  WhereSheetPreviews.swift
//  teemoon
//

import SwiftUI

#if os(iOS)

// The prototype's preview set, rebuilt against real `ProviderStore` fixtures
// instead of a mock catalog — same names, same states, so the two can be
// compared side by side. `where · downloading` is the one that did not survive
// the port: progress lives in `LocalModelDownloader.shared`, a singleton with
// no seam, so an in-progress pull can't be staged from a preview yet.

/// A phone model, a machine with three models pulled, and two cloud keys — one
/// of which has two models equipped.
///
/// Eight rows from four providers. The sheet used to render four, because a
/// provider WAS a model; this fixture is the shape the prototype was drawn
/// against and is the reason the two now look alike.
/// `usedThenUnequipped` seeds "recently used" — see `seedRecentlyUsed`.
@MainActor private func whereFixture(
    usedThenUnequipped: [(Provider, String)] = []
) -> ProviderStore {
    // `config: .inMemory()`, NOT `inMemory: true`. Both keep the canvas off disk,
    // but the second sets `persists` false, which makes `recordUse` and every
    // save a no-op — and "recently used" is read out of what those write. A
    // preview that can't record a use can't render the section.
    let store = ProviderStore(config: .inMemory())
    var machine = Provider(
        name: "second mac",
        endpoint: "http://100.100.0.12:11434/v1",
        model: "qwen3:14b",
        requiresAPIKey: false
    )
    machine.supportsModelBrowsing = true
    machine.equippedModels = ["qwen3:14b", "deepseek-r1:32b", "gemma4:e2b"]

    let near = Provider.nearAI.equipping("qwen3-235b-a22b-thinking")

    store.providers = [.local(LocalModelCatalog.all[0]), machine, near, .grok]
    store.currentProviderID = near.id.uuidString
    seedRecentlyUsed(store, usedThenUnequipped)
    return store
}

/// Seeds `recently used` the way the app does: equip, use, unequip.
///
/// There is no shortcut, and that is the point of §2.6 — the section reads
/// `EquippedModel.lastUsedAt`, only a model that produced output has one, and the
/// rows worth showing are the ones that have since left the equipped set (anything
/// still equipped is already up in `ready now`). So the fixture performs the
/// sequence rather than writing the answer.
///
/// It replaces `whereRecentsFixture`, which built a `WhereRecentsStore` — a store
/// nothing has read since recents moved to the config file. Every preview passed
/// one and every preview rendered the section EMPTY, which is how the fixture that
/// existed to make this section visible ended up hiding it.
@MainActor private func seedRecentlyUsed(
    _ store: ProviderStore, _ retired: [(Provider, String)]
) {
    let selected = store.currentProviderID
    // Oldest first, so the first pair listed ends up the most recent.
    for (provider, modelID) in retired.reversed() {
        // The LIVE record, not the value passed in: `activate` writes the whole
        // provider, so equipping from a stale copy would drop whatever else the
        // fixture had equipped on it.
        guard let live = store.providers.first(where: { $0.id == provider.id }) else { continue }
        store.activate(modelID: modelID, on: live)
        var used = live
        used.model = modelID
        store.recordUse(of: used)
        if let equipped = store.providers.first(where: { $0.id == provider.id }) {
            store.unequip(modelID: modelID, from: equipped)
        }
    }
    store.currentProviderID = selected
}


/// The probe result for `whereFixture`'s machine — seeded, so no preview makes
/// a network call.
///
/// Every preview needs this, not just the home ones: without it `homeProbe`
/// defaults to the real shared instance, which in a canvas tries to reach the
/// fixture's invented Tailscale address, fails, and leaves home rows showing an
/// IP with no server name, no warm marker and no "add a model" row. The sheet
/// looks un-updated because it IS un-probed.
///
/// TWO warm models, and the second one is the machine's LAST configured model on
/// purpose — that is what makes the warm-before-cold ordering visible here. With
/// only `qwen3:14b` warm the fixture proved nothing about order, because it is
/// also the first model configured, so a broken sort and a working one render
/// the same list. Ollama holds several models resident at once, so this is a
/// state a real server reaches.
@MainActor private func whereProbeFixture(for store: ProviderStore) -> HomeServerProbe {
    guard let machine = store.providers.first(where: { WhereLocality.of($0) == .home }) else {
        return .previewing([])
    }
    return .previewing([(machine.id, HomeServerProbe.Info(
        kind: .ollama,
        models: machine.equipped,
        warm: ["qwen3:14b", "gemma4:e2b"]
    ))])
}

@MainActor private func whereCloudOnlyFixture() -> ProviderStore {
    let store = ProviderStore(inMemory: true)
    store.providers = [.nearAI, .grok]
    store.currentProviderID = Provider.nearAI.id.uuidString
    return store
}

/// `.grok` has answered before but isn't current, so it appears under recently
/// used — the one combination that section exists to show.


#Preview("where · all", traits: .fixedLayout(width: 402, height: 1500)) {
    let store = whereFixture(usedThenUnequipped: [(.nearAI, "glm-5-air")])
    return WhereSheetView(
        homeProbe: whereProbeFixture(for: store),
        isInstalled: { _ in true },
        hasKey: { _ in true }
    )
    .environment(store)
}

/// `all`'s `get`, on screen rather than below the fold: one ready row, so the
/// whole list fits. Ordered by what it costs — phone models first (nothing), a
/// machine you own, a key, then the catalogs behind keys. near.ai is configured
/// and shows its count; the rest offer "add key".
#Preview("where · all, get", traits: .fixedLayout(width: 402, height: 1150)) {
    let store = ProviderStore(inMemory: true)
    store.providers = [.nearAI]
    store.currentProviderID = Provider.nearAI.id.uuidString
    return WhereSheetView(
        homeProbe: whereProbeFixture(for: store),
        isInstalled: { _ in false },
        hasKey: { $0.endpoint == Provider.nearAI.endpoint }
    )
    .environment(store)
}

/// Brave Answers keyed and selected — a select-only cloud row, per the
/// prototype: no browse chevron, and its caption states the constraint
/// (single question, no conversation) alongside the compensation (citations).
#Preview("where · brave answers selected", traits: .fixedLayout(width: 402, height: 950)) {
    let store = ProviderStore(inMemory: true)
    store.providers = [.nearAI, .braveAnswers]
    store.currentProviderID = Provider.braveAnswers.id.uuidString
    return WhereSheetView(
        startingAt: .cloud,
        homeProbe: whereProbeFixture(for: store),
        isInstalled: { _ in true },
        hasKey: { _ in true }
    )
    .environment(store)
}

/// Brave Answers not yet keyed: `get` offers "add key", never a fake browse row,
/// and names the key trap — its own key, not the grounding one.
#Preview("where · brave needs key", traits: .fixedLayout(width: 402, height: 1050)) {
    let store = ProviderStore(inMemory: true)
    store.providers = [.nearAI]
    store.currentProviderID = Provider.nearAI.id.uuidString
    return WhereSheetView(
        startingAt: .cloud,
        homeProbe: whereProbeFixture(for: store),
        isInstalled: { _ in true },
        hasKey: { $0.endpoint == Provider.nearAI.endpoint }
    )
    .environment(store)
}

#Preview("where · this phone", traits: .fixedLayout(width: 402, height: 850)) {
    let store = whereFixture()
    return WhereSheetView(
        startingAt: .phone,
        homeProbe: whereProbeFixture(for: store),
        isInstalled: { _ in true },
        hasKey: { _ in true }
    )
    .environment(store)
}

/// TWO downloaded models with ONE resident, and the recommendation winning.
///
/// E4B is the warm one, so warmth alone would put it first — and it must not.
/// E2B leads the catalog deliberately, so it stays the top row even while cold,
/// and warmth is left to say what the other row costs: 2.3–4.0 s before the first
/// token (`measuresWhatAColdStartCosts`). Only one model CAN be warm; the engine
/// cache evicts every other engine before building.
#Preview("where · phone, one warm", traits: .fixedLayout(width: 402, height: 850)) {
    let e2b = LocalModelCatalog.all[0]
    let e4b = LocalModelCatalog.all[1]
    let store = ProviderStore(inMemory: true)
    // Built ONCE and reused. `Provider.local` mints a fresh `UUID` per call, so
    // `currentProviderID = Provider.local(e2b).id` names a third instance that
    // was never in the store — the row renders unselected and the tick silently
    // never appears. Selection matters here: it has to be legible on the COLD
    // row while the warm one sits above it.
    let current = Provider.local(e2b)
    store.providers = [current, .local(e4b)]
    store.currentProviderID = current.id.uuidString

    return WhereSheetView(
        startingAt: .phone,
        residency: .previewing([LocalModelStorage.file(for: e4b)]),
        isInstalled: { _ in true },
        hasKey: { _ in true }
    )
    .environment(store)
    .preferredColorScheme(.dark)
}

/// The whole phone segment at once: one model downloading in `ready now` with a
/// live bar and a cancel, one already downloaded below it, and one still in
/// `get` with its size.
///
/// E2B is mid-download and selected — the state a tap in `get` produces — which
/// is exactly what "select it now, send when it lands" looks like. Both row
/// states are on screen together, which is the only way to tell whether they
/// share a geometry.
#Preview("where · phone, downloading", traits: .fixedLayout(width: 402, height: 850)) {
    let e2b = LocalModelCatalog.all[0]
    let store = ProviderStore(inMemory: true)
    // Only E2B is a provider — it was just tapped in `get`, so it is selected
    // and arriving. E4B has no provider, which is what keeps it in `get` and
    // makes both row states visible at once.
    store.providers = [.local(e2b)]
    store.currentProviderID = Provider.local(e2b).id.uuidString

    return WhereSheetView(
        startingAt: .phone,
        downloader: .previewing([(e2b, 0.42)]),
        // Nothing on disk yet: E2B's bytes are still coming.
        isInstalled: { _ in false },
        hasKey: { _ in true }
    )
    .environment(store)
}

/// Home, with the server identified: `ollama`, three models, one of them warm.
/// `pulling` adds a server-side pull in flight.
@MainActor private func whereHomePreview(pulling: Bool) -> some View {
    let store = whereFixture()
    let machine = store.providers.first { WhereLocality.of($0) == .home }!
    // SELECTED while it arrives, which is the state `equipArriving` produces and the
    // one the pulling preview existed to show without showing: starting a pull equips
    // the model and makes it current, exactly as tapping a phone model in `get` does,
    // so "send when it lands" works. Seeding the pull without the selection rendered a
    // progress bar on a row nobody had chosen.
    if pulling {
        store.activate(modelID: "deepseek-r1:32b", on: machine)
    }
    let pulls: [OllamaDownloadCenter.Download] = pulling
        ? [.init(id: "deepseek-r1:32b",
                 baseURL: machine.openAIBaseURL!,
                 status: "pulling",
                 fraction: 0.42,
                 bytes: "1.2 / 19.8 gb",
                 phase: .active)]
        : []
    return WhereSheetView(
        startingAt: .home,
        // Everything the server has — which is exactly what `ready now` lists,
        // so there is nothing to "browse" to. qwen3:14b is loaded; the rest are
        // cold, and both words appear on the rows.
        homeProbe: whereProbeFixture(for: store),
        isInstalled: { _ in true },
        hasKey: { _ in true }
    )
    .environment(store)
    .environment(OllamaDownloadCenter.seeded(pulls))
}

#Preview("where · home", traits: .fixedLayout(width: 402, height: 950)) {
    whereHomePreview(pulling: false)
}

/// A model being pulled BY THE SERVER, shown on the row the user just chose.
/// The bytes are Ollama's; the wait is the user's.
#Preview("where · home, pulling", traits: .fixedLayout(width: 402, height: 950)) {
    whereHomePreview(pulling: true)
}

/// A server pull that FAILED, on the row that was equipped for it.
///
/// This state had nowhere to appear until the download sheet started dismissing on
/// start: the failure card lives in that sheet, so once it closes itself the row is
/// the only thing left holding the news. Without this the row reads as installed and
/// the first symptom is a 404 on send.
#Preview("where · home, pull failed", traits: .fixedLayout(width: 402, height: 950)) {
    let store = whereFixture()
    let machine = store.providers.first { WhereLocality.of($0) == .home }!
    store.activate(modelID: "deepseek-r1:32b", on: machine)
    return WhereSheetView(
        startingAt: .home,
        homeProbe: whereProbeFixture(for: store),
        isInstalled: { _ in true },
        hasKey: { _ in true }
    )
    .environment(store)
    .environment(OllamaDownloadCenter.seeded([
        .init(id: "deepseek-r1:32b", baseURL: machine.openAIBaseURL!,
              status: "failed", fraction: nil, bytes: nil,
              phase: .failed("pull model manifest: file does not exist"))
    ]))
}

#Preview("where · cloud", traits: .fixedLayout(width: 402, height: 1250)) {
    let store = whereFixture(usedThenUnequipped: [(.nearAI, "glm-5-air")])
    return WhereSheetView(
        startingAt: .cloud,
        homeProbe: whereProbeFixture(for: store),
        isInstalled: { _ in true },
        hasKey: { _ in true }
    )
    .environment(store)
}

/// The tier the user owns nothing in — the screen that has to sell the
/// download. Unreachable while the segment was gated, so its copy went
/// unreviewed until there was a way to look at it.
#Preview("where · empty phone", traits: .fixedLayout(width: 402, height: 850)) {
    WhereSheetView(startingAt: .phone)
        .environment(whereCloudOnlyFixture())
}

/// Offline with a local model: cloud and home rows drop out, the phone answers.
/// Recents are suppressed too — a recent that can't run isn't ready.
#Preview("where · airplane", traits: .fixedLayout(width: 402, height: 950)) {
    let store = whereFixture(usedThenUnequipped: [(.nearAI, "glm-5-air")])
    return WhereSheetView(
        pathObserver: NetworkPathObserver(simulatingSatisfied: false),
        homeProbe: whereProbeFixture(for: store),
        isInstalled: { _ in true },
        hasKey: { _ in true }
    )
    .environment(store)
}

/// Offline with NOTHING local — the one dead end in this sheet. The way out is
/// a download, which needs the network the user hasn't got.
#Preview("where · airplane, nothing local", traits: .fixedLayout(width: 402, height: 850)) {
    WhereSheetView(
        pathObserver: NetworkPathObserver(simulatingSatisfied: false)
    )
    .environment(whereCloudOnlyFixture())
}

/// Deep-linked from the send-blocked alert, with nothing configured at all.
#Preview("where · open to get", traits: .fixedLayout(width: 402, height: 850)) {
    WhereSheetView(openToGet: true)
        .environment(ProviderStore(inMemory: true))
}

/// FIRST RUN — nothing configured, `all`, online. The one state where the sheet
/// has an opinion instead of a list.
///
/// Note this is NOT the same as "open to get", directly above: that one forces
/// `.cloud` and so deliberately misses this branch. Nothing configured plus a
/// tier filter is an ordinary empty tier, not a first run.
#Preview("where · first run", traits: .fixedLayout(width: 402, height: 900)) {
    WhereSheetView()
        .environment(ProviderStore(inMemory: true))
}

/// First run on a phone that ALREADY has the bundle — an emptied provider list,
/// or an install over an existing container. The hero must offer the model, not
/// offer to fetch 2.4 GB that is already on disk.
#Preview("where · first run, already downloaded", traits: .fixedLayout(width: 402, height: 900)) {
    WhereSheetView(isInstalled: { _ in true })
        .environment(ProviderStore(inMemory: true))
}

/// Full-length export render.
///
/// A device-sized preview clips at one screen, so the sections below the fold —
/// `get` in a populated `all`, the tail of a long ready list — can only be seen
/// by shrinking the fixture until it fits, which shows the design at a density
/// no real user has. An explicit tall frame asks the renderer for the whole
/// sheet at once instead.
///
/// Height is chosen to just fit the content: the render is scaled so its output
/// is 1500px tall whatever the frame, so effective resolution is 1500/height.
/// 1500pt gives 1:1; a 2200pt frame with the same content renders the identical
/// sheet at 0.68x, soft and 274px wide, paying for empty space at the bottom.
#Preview("export · all, full length", traits: .fixedLayout(width: 402, height: 1500)) {
    let store = whereFixture(usedThenUnequipped: [(.nearAI, "glm-5-air")])
    return WhereSheetView(
        homeProbe: whereProbeFixture(for: store),
        isInstalled: { _ in true },
        hasKey: { _ in true }
    )
    .environment(store)
}

/// The two states that only a broken or duplicated store can produce, and which
/// therefore never got reviewed: a config file that wouldn't decode, and the
/// notice that a merge dropped records.
///
/// Both are reachable in production and neither was previewable before —
/// `simulate(loadFailure:mergeNotice:)` exists for exactly this.
#Preview("where · couldn't read setups", traits: .fixedLayout(width: 402, height: 700)) {
    let store = ProviderStore(inMemory: true)
    // Empty on purpose: this IS the dangerous case — the list is empty because
    // the file failed to decode, not because nothing is configured.
    store.simulate(loadFailure: "The data couldn’t be read because it isn’t in the correct format.")
    return WhereSheetView(
        homeProbe: whereProbeFixture(for: store),
        isInstalled: { _ in false },
        hasKey: { _ in false }
    )
    .environment(store)
}

#Preview("where · merged duplicates", traits: .fixedLayout(width: 402, height: 900)) {
    let store = whereFixture()
    store.simulate(mergeNotice: "teemoon merged one duplicate setup — one connection was saved more than once. nothing you could run has been lost.")
    return WhereSheetView(
        homeProbe: whereProbeFixture(for: store),
        isInstalled: { _ in true },
        hasKey: { _ in true }
    )
    .environment(store)
}

// These last three previews used to sit BELOW the `#endif`, outside the iOS-only
// block, while the fixtures they call (`whereFixture`, `whereProbeFixture`) sit
// inside it. iOS never noticed — everything was in scope there. macOS compiled
// the previews without the fixtures and failed with "cannot find 'whereFixture'
// in scope". They were appended after the guard by accident, not placed outside
// it on purpose, so the guard now closes at the end of the preview set.
#endif
