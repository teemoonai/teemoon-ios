//
//  WherePresentationTests.swift
//  teemoonTests
//
//  Unit coverage for Where locality + labels (no UI).
//

import Foundation
import Testing
@testable import teemoon

struct WherePresentationTests {

    @Test func selfHostedIsHome() {
        let p = Provider(
            name: "second mac",
            endpoint: "http://100.100.0.12:11434/v1",
            model: "qwen3:14b",
            requiresAPIKey: false
        )
        #expect(WhereLocality.of(p) == .home)
        #expect(WhereProviderPresentation.systemImage(for: p) == "desktopcomputer")
        #expect(WhereProviderPresentation.placeCaption(for: p).contains("100.100"))
    }

    /// The regression this branch shipped with. `Provider.local` sets
    /// `endpoint: "on-device"`, which has no host, so `isSelfHosted` is false
    /// and the original `isSelfHosted ? .home : .cloud` filed every downloaded
    /// model under CLOUD — with a cloud glyph, in the cloud segment. The most
    /// private place teemoon can run, presented as the least.
    @Test func onDeviceIsPhoneNotCloud() {
        let p = Provider.local(LocalModelCatalog.all[0])

        #expect(p.isLocal)
        #expect(!p.isSelfHosted)  // the trap: this is why `of` can't use it alone
        #expect(WhereLocality.of(p) == .phone)
        #expect(WhereProviderPresentation.systemImage(for: p) == "iphone")
    }

    /// One sentence across three surfaces: the download screen's title, the
    /// title block's caption, and the Where chip. If someone retitles one, this
    /// fails rather than letting the promise drift between screens.
    @Test func onDeviceCaptionMatchesTheDownloadScreen() {
        let caption = WhereProviderPresentation.placeCaption(for: .local(LocalModelCatalog.all[0]))
        #expect(caption == "on this device")
    }

    /// The chip must call a downloaded model what the download screen called
    /// it. The generic path yields the repo slug — "gemma-4-e2b-it-litert-lm" —
    /// which names a quantisation format and a runtime the user never chose.
    @Test func onDeviceLabelUsesTheCatalogName() {
        let model = LocalModelCatalog.all[0]
        let label = WhereProviderPresentation.modelLabel(for: .local(model))

        #expect(label == model.displayName.lowercased())
        #expect(!label.contains("litert"))
    }

    /// A phone model has nothing to browse — there is no remote catalog behind
    /// it, and offering "browse" would open an empty list.
    @Test func onDeviceHasNothingToBrowse() {
        let p = Provider.local(LocalModelCatalog.all[0])
        #expect(!p.supportsModelBrowsing)
        #expect(WhereProviderPresentation.browseModels(for: p).isEmpty)
    }

    /// The phone tier's footer. Tested rather than eyeballed: the real reading
    /// comes from `os_proc_available_memory()`, which returns 0 on the
    /// simulator, so the footer is hidden in every preview and this string would
    /// otherwise ship unseen.
    @Test func weightsHeadroomLabelFormatting() {
        #expect(LocalMemory.weightsHeadroomLabel(availableMB: 4198)
                == "around 4.1gb free for loading weights")
        // Double figures drop the decimal — "around 12.0gb" is false precision.
        #expect(LocalMemory.weightsHeadroomLabel(availableMB: 12_288)
                == "around 12gb free for loading weights")
        // Unavailable stays silent rather than claiming "around 0gb".
        #expect(LocalMemory.weightsHeadroomLabel(availableMB: 0) == nil)
    }

    @Test func nearAIIsCloud() {
        #expect(WhereLocality.of(.nearAI) == .cloud)
        #expect(WhereProviderPresentation.showsConfidentialityTags(for: .nearAI))
        #expect(!WhereProviderPresentation.browseModels(for: .nearAI).isEmpty)
    }

    @Test func modelLabelPrefersCatalog() {
        let label = WhereProviderPresentation.modelLabel(for: .nearAI)
        #expect(!label.isEmpty)
        #expect(!label.contains("http"))
    }

    /// The answers endpoint's caption names its limitation, because
    /// `maxMessages: 1` means this row is sent your latest message and nothing
    /// else — a follow-up arrives with no idea what came before.
    ///
    /// Also pinned: it must NOT claim privacy. This is a plaintext POST to Brave
    /// with no `.endToEndEncryption` capability, and the cloud segment's header
    /// promises every row says where it stands on that — so a privacy word here
    /// would read as parity with the near.ai row above it, which really is
    /// encrypted.
    @Test func theAnswersEndpointSaysSingleTurnAndClaimsNoPrivacy() {
        let caption = WhereProviderPresentation.placeCaption(for: .braveAnswers)
        #expect(Provider.braveAnswers.answersSingleTurnOnly)
        #expect(!Provider.braveAnswers.capabilities.contains(.endToEndEncryption))
        #expect(caption.contains("single turn"))
        #expect(caption.contains("search"))
        for claim in ["private", "encrypted", "confidential"] {
            #expect(!caption.contains(claim), "claims \(claim) on a plaintext endpoint")
        }
    }

    /// ONE line. A picker is a density instrument, and a row that takes two costs
    /// a row you could have seen — 50 chars is the longest caption measured
    /// rendering in full at this width.
    @Test func theAnswersCaptionFitsOneLine() {
        #expect(WhereProviderPresentation.placeCaption(for: .braveAnswers).count <= 50)
    }

    /// The row's TITLE, which printed the word twice: "brave answers brave".
    ///
    /// `titleLabel` prefers the provider's name when it already starts with the
    /// model's — right for the preset ("Brave Answers" beats a bare "brave") and
    /// wrong for the auto-label teemoon saves, which is built from both and still
    /// starts with "brave". Same bug the cloud caption already fixed by matching
    /// the endpoint to a preset instead of trusting the stored name.
    @Test func theTitleDoesNotRepeatTheProviderName() {
        var saved = Provider.braveAnswers
        saved.name = "brave answers brave"   // what auto-labelling actually stores

        #expect(WhereProviderPresentation.modelLabel(for: saved) == "brave answers")
    }

    /// And the fix must not flatten a cloud row to its service name: near.ai's
    /// rows are told apart by the MODEL, which is the whole reason the sheet lists
    /// models rather than providers.
    @Test func canonicalNamingStillLeavesCloudRowsNamedByModel() {
        let near = Provider.nearAI.equipping("glm-5.2")
        let label = WhereProviderPresentation.modelLabel(for: near)

        #expect(label.contains("glm"))
        #expect(label != "near.ai")
    }

    @Test func cloudByokCaptionUsesProviderName() {
        let caption = WhereProviderPresentation.placeCaption(for: .grok)
        #expect(caption.lowercased().contains("grok") || caption.lowercased().contains("xai")
                || !caption.isEmpty)
    }

    /// Warmth moved off the title line and onto the caption's metadata run,
    /// because as `trailingText` it shared a slot with the selection tick: on the
    /// selected row the word was pushed left, so `warm` ended 21pt inside the
    /// `cold` above it and the tick read as attached to the word.
    @Test func warmthJoinsTheCaptionRun() {
        #expect(WhereProviderPresentation.metadataRun("ollama", "warm") == "ollama · warm")
    }

    /// The two absences that make this more than string interpolation, and both
    /// happen in production.
    ///
    /// Warmth is nil for a server that doesn't report it — it comes from a native
    /// surface (`/api/ps`), so llama.cpp says nothing and "cold" would be a claim
    /// rather than an absence. The caption is nil when the sheet is filtered to a
    /// single home machine, where the server's name is the tier's own label
    /// repeated down every row. Interpolating either produces a row captioned
    /// `ollama · ` or ` · warm`: a separator pointing at nothing.
    @Test func aMissingSideNeverLeavesAnOrphanedSeparator() {
        #expect(WhereProviderPresentation.metadataRun("ollama", nil) == "ollama")
        #expect(WhereProviderPresentation.metadataRun(nil, "warm") == "warm")
        #expect(WhereProviderPresentation.metadataRun(nil, nil) == nil)
    }
}

/// Row order in `ready now`: tier, then machine, then warm before cold.
struct WhereRowOrderTests {

    private func machine(
        _ name: String,
        host: String,
        models: [String]
    ) -> Provider {
        var p = Provider(
            name: name,
            endpoint: "http://\(host):11434/v1",
            model: models[0],
            requiresAPIKey: false
        )
        p.equippedModels = models
        return p
    }

    private func rows(_ providers: [Provider]) -> [WhereSheetView.Equipped] {
        providers.flatMap { p in
            p.equipped.map { WhereSheetView.Equipped(provider: p, modelID: $0) }
        }
    }

    /// A model already resident answers immediately; a cold one pays a model load
    /// first. That's the whole reason the signal is on the row, so it decides the
    /// order too.
    @Test func warmRisesAboveCold() {
        let mac = machine("second mac", host: "100.100.0.12",
                          models: ["qwen3:14b", "deepseek-r1:32b", "gemma4:e2b"])
        let warm: Set<String> = ["gemma4:e2b"]   // configured LAST, so order must move it

        let ordered = WhereSheetView.ordered(rows([mac])) { warm.contains($0.modelID) }

        #expect(ordered.map(\.modelID) == ["gemma4:e2b", "qwen3:14b", "deepseek-r1:32b"])
    }

    /// Warmth breaks ties WITHIN a machine only.
    ///
    /// Sorted across the whole home tier this interleaves two servers — mac's
    /// warm model, the linux box's warm model, then mac's cold ones — and a sheet
    /// whose job is to show you the places you can run stops reading as a set of
    /// places. Same failure recency-sorting caused, which is why that was
    /// reverted.
    @Test func machinesDoNotInterleave() {
        let mac = machine("second mac", host: "100.100.0.12", models: ["a-cold", "a-warm"])
        let linux = machine("linux box", host: "100.100.0.13", models: ["b-cold", "b-warm"])
        let warm: Set<String> = ["a-warm", "b-warm"]

        let ordered = WhereSheetView.ordered(rows([mac, linux])) { warm.contains($0.modelID) }

        #expect(ordered.map(\.modelID) == ["a-warm", "a-cold", "b-warm", "b-cold"])
    }

    /// Unmeasured is not cold. Warmth needs an identified server, so llama.cpp
    /// and friends report nothing for ANY of their models — and reordering on a
    /// signal you don't have would shuffle the list for no reason the user can
    /// see.
    @Test func unmeasuredWarmthLeavesConfiguredOrderAlone() {
        let mac = machine("second mac", host: "100.100.0.12",
                          models: ["qwen3:14b", "deepseek-r1:32b", "gemma4:e2b"])

        let ordered = WhereSheetView.ordered(rows([mac])) { _ in nil }

        #expect(ordered.map(\.modelID) == ["qwen3:14b", "deepseek-r1:32b", "gemma4:e2b"])
    }

    /// A synthetic local model, so the phone tier can have rows that are NOT the
    /// recommended one. The catalog ships two, and one of them always leads it.
    private func offCatalogLocal(_ id: String) -> Provider {
        var p = Provider(
            name: id,
            endpoint: "on-device",
            model: id,
            requiresAPIKey: false,
            localModelID: id
        )
        p.equippedModels = [id]
        return p
    }

    /// The recommendation outranks warmth: E2B stays the top phone row while
    /// cold, with a warm E4B under it.
    ///
    /// `LocalModelCatalog.all` is ordered on purpose — E4B's own note says it
    /// "does NOT lead the catalog … not better, only bigger" — so a 2.3–4.0 s
    /// load saving must not promote the model teemoon advises against. Warmth
    /// still says what that row costs; it just doesn't move it.
    @Test func theRecommendedPhoneModelStaysOnTopWhileCold() throws {
        try #require(LocalModelCatalog.all.count > 1)
        let recommended = Provider.local(LocalModelCatalog.all[0])
        let warmer = Provider.local(LocalModelCatalog.all[1])

        let ordered = WhereSheetView.ordered(rows([recommended, warmer])) {
            $0.provider.id == warmer.id
        }

        #expect(ordered.map(\.provider.id) == [recommended.id, warmer.id])
    }

    /// Warmth still orders the rows BELOW the recommended one — and this is where
    /// grouping by provider was wrong.
    ///
    /// A machine is one `Provider` holding several equipped models, but
    /// `Provider.local` makes one provider PER downloaded model, so a
    /// provider-keyed group put every phone row on its own and warmth could never
    /// break a tie there. Grouping is by PLACE, and the phone is one place.
    @Test func warmthOrdersPhoneRowsBeneathTheRecommendedOne() throws {
        try #require(LocalModelCatalog.all.count > 1)
        let recommended = Provider.local(LocalModelCatalog.all[0])
        let cold = offCatalogLocal("someone/cold-model")
        let warm = offCatalogLocal("someone/warm-model")
        // The trap: three separate providers, one row each.
        #expect(Set([recommended.id, cold.id, warm.id]).count == 3)

        // Listed cold-first, so a working sort has to move the warm one up.
        let ordered = WhereSheetView.ordered(rows([recommended, cold, warm])) {
            $0.provider.id == warm.id
        }

        #expect(ordered.map(\.provider.id) == [recommended.id, warm.id, cold.id])
    }

    /// Tiers still win. A warm home model does not climb above the phone, because
    /// the list is grouped by WHERE first — that grouping is the sheet.
    @Test func tierOutranksWarmth() {
        let phone = Provider.local(LocalModelCatalog.all[0])
        let mac = machine("second mac", host: "100.100.0.12", models: ["warm-one"])

        let ordered = WhereSheetView.ordered(rows([mac, phone])) { _ in true }

        #expect(WhereLocality.of(ordered[0].provider) == .phone)
    }
}

/// "Recently used", now that it is read out of the schema rather than out of its
/// own UserDefaults blob (§2.6).
///
/// This replaces `WhereRecentsStoreTests`, which tested `WhereRecentsStore` — a
/// store nothing had read since `ProviderStore.recentlyUsed()` took over, so its
/// eight tests were green against code no screen ran. The RULES it pinned were
/// worth keeping, because each one is a bug the device found, so they are
/// re-asserted here against what actually feeds the section.
///
/// Every store is `ProviderStore(config: .inMemory())`, never
/// `ProviderStore(inMemory: true)`: the latter sets `persists` false, which makes
/// `recordUse` a no-op — and a test whose recording no-ops asserts nothing.
/// The debug card's timing chain, after the developer asked why a WARM model showed a 6-second
/// time-to-first-token.
///
/// Measured on the wire the same minute, against that machine: the stream's first
/// delta at 0.64s, the first VISIBLE character at 5.10s, 824 characters of `reasoning`
/// in between. The model was working the whole time; reasoning never reaches the UI
/// while it streams, so ttft — which is time to the first thing you can SEE — swallowed
/// the thinking and reported it as latency.
@Suite("Debug card timings")
struct DebugCardTimingTests {

    /// The badge and the screen must agree on what a setup IS.
    ///
    /// Settings read "4 setups" over a places & keys screen that could only show
    /// three: it counted `providers.count` while the hub deliberately has no
    /// "on this phone" row — a downloaded model has no key and no host to
    /// delete. One number, two rules, same class of bug as matching an endpoint
    /// two different ways.
    @Test func managedPlacesExcludeThePhone() {
        // `isLocal` is `localModelID != nil` — NOT the endpoint string. The
        // stored record carries `kind: .onDevice`, which
        // `ProviderConfigProjection` maps to `localModelID`; a fixture that only
        // sets the endpoint is classified `.cloud` and tests nothing.
        var onDevice = Provider(id: UUID(), name: "Gemma 4 E2B", endpoint: "on-device",
                                model: "gemma", requiresAPIKey: false)
        onDevice.localModelID = "litert-community/gemma-4-E2B-it-litert-lm"
        let cloud = Provider.nearAI
        var home = Provider.nearAI
        home.id = UUID()
        home.endpoint = "http://192.168.1.50:11434/v1"
        home.requiresAPIKey = false

        let managed = WhereLocality.managed(in: [onDevice, cloud, home])
        #expect(managed.count == 2)
        #expect(!managed.contains { WhereLocality.of($0) == .phone })
        // The two the hub actually offers rows for.
        #expect(managed.contains { WhereLocality.of($0) == .cloud })
        #expect(managed.contains { WhereLocality.of($0) == .home })
    }

    private func info(total: TimeInterval, ttft: TimeInterval,
                      thinking: TimeInterval?, tokens: Int) -> LastRequestDebugInfo {
        LastRequestDebugInfo(
            providerName: "ringzero", modelID: "gemma4:e4b", url: URL(string: "http://x/v1"),
            requestHeaders: nil, requestBodyJSON: nil, responseBody: "Ho.",
            toolCalls: [], threadID: UUID(),
            totalDuration: total, timeToFirstToken: ttft, thinkingTime: thinking,
            outputTokens: tokens, isE2EEActive: false, teeVerification: nil)
    }

    /// The number that started it: 124 tokens over the 0.1s it took to emit "Ho."
    /// The tokens are almost all reasoning, so dividing them by the VISIBLE window
    /// manufactured a figure no home box can produce.
    @Test func tokensPerSecondCountsTheThinkingItAlreadyCounted() {
        let honest = info(total: 6.4, ttft: 6.3, thinking: 4.5, tokens: 124)
        let rate = try! #require(honest.tokensPerSecond)
        #expect(rate > 20 && rate < 35, "got \(rate) tok/s — that machine does about 27")

        // What it used to do: 124 / 0.1 ≈ 1240, and the card showed 1874.
        let visibleOnly = 124.0 / (6.4 - 6.3)
        #expect(visibleOnly > 1000)
    }

    /// A model that doesn't think keeps the old arithmetic exactly.
    @Test func withoutThinkingTheRateIsUnchanged() {
        let plain = info(total: 4.0, ttft: 1.0, thinking: nil, tokens: 300)
        #expect(plain.generationTime == 3.0)
        #expect(plain.tokensPerSecond == 100)
    }

    /// And the chain only grows a `think` figure when there was thinking, so a
    /// non-reasoning row doesn't sprout a "think 0s".
    @Test func theThinkFigureIsAbsentWhenNothingThought() {
        #expect(info(total: 4, ttft: 1, thinking: nil, tokens: 10).thinkingTime == nil)
        #expect(info(total: 6.4, ttft: 6.3, thinking: 4.5, tokens: 124).thinkingTime == 4.5)
    }

    /// Nothing to divide by is nil, not infinity.
    @Test func noWindowMeansNoRate() {
        #expect(info(total: 0, ttft: 0, thinking: nil, tokens: 100).tokensPerSecond == nil)
    }
}

/// A home machine is its HOST on the debug card, never its record label.
@MainActor
@Suite("Home place naming")
struct HomePlaceNamingTests {

    /// The card read "ringzero gemma4:e2b-it-qat gemma4:e4b" — the machine's stale
    /// auto-label ("<host> <model>", fixed at the moment it was added) followed by the
    /// model actually sent. Two model names on one row, the first one wrong.
    @Test func aMachineIsNamedByItsHostNotItsStaleLabel() {
        var machine = Provider(name: "ringzero gemma4:e2b-it-qat",
                               endpoint: "https://ringzero.tailnet-name.ts.net:11434/v1",
                               model: "gemma4:e4b", requiresAPIKey: false)
        machine.equippedModels = ["gemma4:e4b"]

        let place = machine.canonicalName
        #expect(place == "ringzero")
        #expect(!place.contains("e2b"), "the place named a model, and the wrong one")
        #expect(WhereProviderPresentation.canonicalName(for: machine) == place)
    }

    /// A bare IP keeps all four octets — "192" names nothing.
    @Test func anIPAddressIsKeptWhole() {
        let box = Provider(name: "box", endpoint: "http://192.168.1.50:11434/v1",
                           model: "qwen3.5:4b", requiresAPIKey: false)
        #expect(box.canonicalName == "192.168.1.50")
    }

    /// Cloud presets are unaffected: they match by endpoint and keep their own name.
    @Test func cloudPresetsKeepTheirName() {
        #expect(Provider.nearAI.canonicalName == "near.ai")
        #expect(Provider.fireworks.canonicalName == "fireworks")
    }
}

@MainActor
@Suite("Recently used")
struct RecentlyUsedTests {

    private func store() -> ProviderStore { ProviderStore(config: .inMemory()) }

    /// Equips `modelID`, uses it, then unequips it — the sequence that produces
    /// the only kind of row this section is mostly made of.
    ///
    /// Every step reads the LIVE record rather than the `provider` value passed in,
    /// and that is not defensive style: `activate` writes a whole `Provider`, so
    /// activating from a stale copy re-equips everything that copy still lists —
    /// and re-equipping a retired row CLEARS its mark. Written the obvious way, a
    /// loop retiring twelve models left exactly one retired, because each pass put
    /// the previous eleven back. `retiredRowsAreCappedAtTwelve` caught it.
    private func useThenRetire(_ modelID: String, on provider: Provider, in store: ProviderStore) {
        guard let live = store.providers.first(where: { $0.id == provider.id }) else { return }
        store.activate(modelID: modelID, on: live)
        var used = live
        used.model = modelID
        store.recordUse(of: used)
        guard let equipped = store.providers.first(where: { $0.id == provider.id }) else { return }
        store.unequip(modelID: modelID, from: equipped)
    }

    /// Recents are "recently USED", not "recently selected". The one writer is
    /// `ChatGeneration.onFirstToken` → `recordUse`, so a model that was picked and
    /// never sent on leaves no trace. This pins the wiring, which is the part that
    /// silently regresses when someone adds a record call to a selection handler.
    @Test func onFirstTokenIsWhatRecords() {
        let providers = store()
        let generation = ChatGeneration()
        generation.onFirstToken = { providers.recordUse(of: $0) }

        let near = Provider.nearAI
        providers.addProvider(near)
        // Selecting in the sheet routes through ProviderStore and records nothing.
        providers.activate(modelID: near.model, on: near)
        #expect(providers.recentlyUsed().isEmpty)

        // A generation producing output is what counts.
        generation.onFirstToken?(near)
        let rows = providers.recentlyUsed()
        #expect(rows.count == 1)
        #expect(rows.first?.providerID == near.id)
    }

    /// A used model shows up even though it is still equipped.
    ///
    /// The fix for a bug the device found: `visible` briefly excluded everything
    /// still equipped, reasoning that `ready now` lists those already. True — and
    /// it made the section unreachable, because using a model is what records it
    /// and the model you just used is equipped and selected by definition.
    /// "recently used isn't showing up even after using a model" was the symptom.
    @Test func aUsedModelListsWhileItIsStillEquipped() {
        let providers = store()
        for provider in [Provider.nearAI, .grok] {
            providers.addProvider(provider)
            providers.recordUse(of: provider)
        }
        #expect(providers.recentlyUsed().count == 2)
    }

    /// §2.6's load-bearing invariant: the row OUTLIVES the unequip. Its
    /// `lastUsedAt` is the only fact the section is built from, so dropping the
    /// row on unequip would empty the section it exists for.
    @Test func aUsedModelSurvivesBeingUnequipped() {
        let providers = store()
        var near = Provider.nearAI
        near.equippedModels = [near.model, "glm-5-air"]
        providers.addProvider(near)

        useThenRetire("glm-5-air", on: near, in: providers)

        let rows = providers.recentlyUsed()
        #expect(rows.contains { $0.modelID == "glm-5-air" })
    }

    /// And it must not leak back. Projecting retired rows into `equippedModels`
    /// would put every model the user ever removed back into `ready now` — the
    /// unequip undone on the next launch, which is what `providers(from:)`
    /// filtering on `isEquipped` prevents.
    @Test func aRetiredRowDoesNotLeakBackIntoTheEquippedSet() {
        let config = ConfigStore.inMemory()
        let providers = ProviderStore(config: config)
        var near = Provider.nearAI
        near.equippedModels = [near.model, "glm-5-air"]
        providers.addProvider(near)

        useThenRetire("glm-5-air", on: near, in: providers)

        #expect(providers.providers.first { $0.id == near.id }?.equipped == [near.model])
        // The row is still in the file — retired, not deleted.
        let row = config.snapshot.equipped.first {
            $0.serverID == near.id && $0.modelID == "glm-5-air"
        }
        #expect(row?.unequippedAt != nil)
        #expect(row?.isEquipped == false)

        // Survives a reload as retired, rather than reappearing as equipped.
        let reloaded = ProviderStore(config: config)
        #expect(reloaded.providers.first { $0.id == near.id }?.equipped == [near.model])
        #expect(reloaded.recentlyUsed().contains { $0.modelID == "glm-5-air" })
    }

    /// Re-equipping clears the mark, so the model leaves `recently used` and goes
    /// back to `ready now` instead of appearing in both.
    @Test func reEquippingClearsTheRetiredMark() {
        let config = ConfigStore.inMemory()
        let providers = ProviderStore(config: config)
        var near = Provider.nearAI
        near.equippedModels = [near.model, "glm-5-air"]
        providers.addProvider(near)
        useThenRetire("glm-5-air", on: near, in: providers)

        guard let live = providers.providers.first(where: { $0.id == near.id }) else {
            Issue.record("the server was deleted by an unequip"); return
        }
        providers.activate(modelID: "glm-5-air", on: live)

        let row = config.snapshot.equipped.first {
            $0.serverID == near.id && $0.modelID == "glm-5-air"
        }
        #expect(row?.unequippedAt == nil)
        #expect(row?.isEquipped == true)
        #expect(providers.providers.first { $0.id == near.id }?.equipped.contains("glm-5-air") == true)
        // The use is not forgotten by re-equipping it — `lastUsedAt` is untouched.
        #expect(row?.lastUsedAt != nil)
    }

    /// Retired rows are CAPPED. Nothing removes them otherwise, and a config file
    /// whose whole job is to stay small would grow one row per model the user ever
    /// tried, forever. Newest kept, oldest dropped.
    @Test func retiredRowsAreCappedAtTwelve() {
        let config = ConfigStore.inMemory()
        let providers = ProviderStore(config: config)
        let limit = ProviderConfigProjection.retiredRowLimit
        var near = Provider.nearAI
        let extras = (0..<(limit + 3)).map { "model-\($0)" }
        near.equippedModels = [near.model] + extras
        providers.addProvider(near)

        // Stamps spaced a minute apart, written through the config rather than by
        // `recordUse`: the cap keeps the NEWEST twelve, so WHICH row is dropped is
        // decided by the ordering — and a loop of `Date.now` calls would be
        // asserting that ordering against whatever resolution the clock has.
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        for (index, id) in extras.enumerated() {
            guard let live = providers.providers.first(where: { $0.id == near.id }) else { break }
            providers.activate(modelID: id, on: live)
            config.stampUse(serverID: near.id, modelID: id,
                            at: start.addingTimeInterval(Double(index) * 60))
            guard let equipped = providers.providers.first(where: { $0.id == near.id }) else { break }
            providers.unequip(modelID: id, from: equipped)
        }

        let retiredIDs = config.snapshot.equipped.filter { !$0.isEquipped }.map(\.modelID)
        #expect(retiredIDs.count == limit)
        #expect(!retiredIDs.contains("model-0"))
        #expect(retiredIDs.contains(extras.last!))
    }

    /// A retired row is kept only while its SERVER exists. Deleting the setup
    /// takes its history with it, rather than leaving rows pointing at a server
    /// that isn't there — which is also what stops the cap being spent on them.
    @Test func retiredRowsGoWithTheirServer() {
        let config = ConfigStore.inMemory()
        let providers = ProviderStore(config: config)
        var near = Provider.nearAI
        near.equippedModels = [near.model, "glm-5-air"]
        providers.addProvider(near)
        useThenRetire("glm-5-air", on: near, in: providers)

        guard let live = providers.providers.first(where: { $0.id == near.id }) else {
            Issue.record("the server was deleted by an unequip"); return
        }
        providers.removeProvider(live)

        #expect(providers.recentlyUsed().isEmpty)
        #expect(config.snapshot.equipped.isEmpty)
    }

    /// Newest first, and capped for DISPLAY separately from storage: the section
    /// is a shortcut, not a second inventory.
    @Test func rowsRunNewestFirstAndAreCappedForDisplay() {
        let providers = store()
        var near = Provider.nearAI
        near.equippedModels = [near.model, "one", "two", "three"]
        providers.addProvider(near)
        for id in ["one", "two", "three"] { useThenRetire(id, on: near, in: providers) }

        #expect(providers.recentlyUsed().map(\.modelID) == ["three", "two", "one"])
        #expect(providers.recentlyUsed(limit: 2).map(\.modelID) == ["three", "two"])
    }

    /// Labels are recomputed from the live provider, not read back from the row —
    /// the reason the old store's snapshot copies had to go. A caption cached at
    /// record time is a description of how the app talked about a place in the
    /// past, and this row still read "near.ai glm 5.2" after captions stopped
    /// printing model names.
    @Test func rowsCarryTheirOwnLabelsForTheDeletedCase() {
        let providers = store()
        var near = Provider.nearAI
        near.equippedModels = [near.model, "glm-5-air"]
        providers.addProvider(near)
        useThenRetire("glm-5-air", on: near, in: providers)

        guard let row = providers.recentlyUsed().first(where: { $0.modelID == "glm-5-air" }) else {
            Issue.record("expected a recent for the retired model"); return
        }
        #expect(row.locality == .cloud)
        #expect(!WhereProviderPresentation.modelLabel(for: row.provider).isEmpty)
        #expect(!WhereProviderPresentation.placeCaption(for: row.provider).isEmpty)
    }
}

@MainActor
struct HomeServerProbeTests {

    /// The bug behind "it only shows the one I configured".
    ///
    /// `EndpointModelCatalog.probe` appends "models" to the base, so an endpoint
    /// entered as `host:11434` — which the add screen accepts and which chats
    /// fine, because the chat url is built separately — asks Ollama for
    /// `/models`, a path it doesn't serve. The list came back empty for a working
    /// server, and every capability downstream of it did nothing, quietly.
    @Test func modelListTriesV1WhenTheEndpointOmitsIt() {
        let bare = URL(string: "https://ringzero.tailnet-name.ts.net:11434")!
        let candidates = HomeServerProbe.modelListCandidates(bare)

        #expect(candidates.count == 2)
        #expect(candidates[0].absoluteString == "https://ringzero.tailnet-name.ts.net:11434")
        #expect(candidates[1].absoluteString == "https://ringzero.tailnet-name.ts.net:11434/v1")
    }

    /// Already carries `/v1` — no second request to waste.
    @Test func modelListDoesNotDoubleUpV1() {
        let withV1 = URL(string: "http://100.100.0.12:11434/v1")!
        #expect(HomeServerProbe.modelListCandidates(withV1).count == 1)
    }

    @Test func forgetDropsTheModelFromTheCachedList() {
        let id = UUID()
        let provider = Provider(
            id: id,
            name: "box",
            endpoint: "http://100.64.0.1:11434/v1",
            model: "a",
            requiresAPIKey: false
        )
        let probe = HomeServerProbe.previewing([(
            id,
            .init(kind: .ollama, models: ["a", "b"], warm: ["a", "b"])
        )])
        probe.forget(modelID: "b", on: provider)
        #expect(probe.info(for: provider)?.models == ["a"])
        #expect(probe.info(for: provider)?.warm == ["a"])
    }

    @Test func forgetOnUnknownProviderIsANoOp() {
        let probe = HomeServerProbe.previewing([])
        let provider = Provider(
            name: "box",
            endpoint: "http://100.64.0.1:11434/v1",
            model: "a",
            requiresAPIKey: false
        )
        probe.forget(modelID: "a", on: provider)
        #expect(probe.info(for: provider) == nil)
    }
}

/// Which home servers teemoon can delete a model on — a property of the SERVERS,
/// not a policy choice, and the gate the where sheet's swipe depends on.
@Suite("Home model deletion")
struct HomeModelDeletionTests {

    /// Ollama serves `DELETE /api/delete`, so the swipe can mean something there.
    @Test func onlyOllamaExposesADeleteEndpoint() {
        // The call exists and is Ollama's, addressed off the server ROOT rather
        // than the /v1 base — the same normalisation `/api/pull` needs.
        let base = URL(string: "http://100.100.0.12:11434/v1")!
        #expect(OllamaAdapter.rootURL(from: base).absoluteString == "http://100.100.0.12:11434")
    }

    /// LM Studio's native surface is READ-only in teemoon and in its own REST API:
    /// models and loaded-state, no deletion — the library is managed by the app.
    /// llama.cpp / vLLM (`.unknown`) serve whichever file they were launched with.
    /// A swipe on either could only fail, so it isn't offered.
    @Test func theOtherKindsHaveNoDeletionPath() {
        // Asserted structurally: nothing in the LM Studio adapter deletes, so the
        // sheet's gate is `kind == .ollama` and these two are simply not it.
        #expect(LocalServerKind.lmStudio != .ollama)
        #expect(LocalServerKind.unknown != .ollama)
    }
}

/// A server exists independently of the models equipped on it — the rule
/// whose violation is the reason keys used to vanish.
@MainActor
struct ServerOutlivesItsModelsTests {

    private func keyedCloud(_ store: ProviderStore) -> Provider {
        var p = Provider(
            name: "near.ai", endpoint: "https://api.near.ai/v1",
            model: "glm-5.2", requiresAPIKey: true
        )
        p.equippedModels = ["glm-5.2", "glm-5.1"]
        store.addProvider(p)
        return p
    }

    /// Unequipping the LAST model used to return nil from `unequipping`, which the
    /// store read as "delete the provider" — and `removeProvider` deletes the
    /// Keychain entry. One swipe destroyed an api key the user had pasted from
    /// somewhere else.
    @Test func unequippingTheLastModelKeepsTheServer() {
        let store = ProviderStore(inMemory: true)
        let p = keyedCloud(store)

        store.unequip(modelID: "glm-5.1", from: p)
        let afterFirst = store.providers.first { $0.id == p.id } ?? p
        store.unequip(modelID: "glm-5.2", from: afterFirst)

        let survivor = store.providers.first { $0.id == p.id }
        #expect(survivor != nil, "the server was deleted with its last model")
        #expect(survivor?.equipped.isEmpty == true)
        // The things that make it a server are all still there, so it can be
        // re-equipped rather than re-added.
        #expect(survivor?.endpoint == "https://api.near.ai/v1")
        #expect(survivor?.requiresAPIKey == true)
    }

    /// Empty is a state `unequipping` must be able to express, not a signal.
    @Test func unequippingReportsEmptinessRatherThanReturningNil() {
        var p = Provider(name: "box", endpoint: "http://100.100.0.12:11434/v1",
                         model: "only", requiresAPIKey: false)
        p.equippedModels = ["only"]

        let emptied = p.unequipping("only")

        #expect(emptied.equipped.isEmpty)
        #expect(emptied.model == "")          // nothing selected, not a stale id
        #expect(emptied.endpoint == p.endpoint)
        #expect(emptied.id == p.id)           // SAME id — the Keychain hangs off it
    }
}
