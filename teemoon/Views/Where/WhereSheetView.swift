//
//  WhereSheetView.swift
//  teemoon
//
//  Daily picker for *where* inference runs. Ready now = configured Providers
//  (equipped setups). Recently used = last picks (bounded). Get = add / browse.
//  Browse = ModelBrowserView or search-first for OpenRouter-scale catalogs.
//
//  Chat chrome: WhereChip presents this sheet. Title stays on E2EETitleBlock.
//

import SwiftUI

struct WhereSheetView: View {
    @Environment(ProviderStore.self) var providerStore
    @Environment(\.dismiss) var dismiss

    /// When true, scroll emphasis is on Get (add / browse) — e.g. no-provider deep link.
    var openToGet: Bool = false

    @State var filter: WhereLocality?
    /// What the add sheet is being opened FOR.
    ///
    /// One value, not a bool plus a flag. It was `showAddProvider` alongside
    /// `addingSelfHosted`, and two separate @State writes in one action are not
    /// guaranteed to be visible together when the sheet's content closure is
    /// built — so "connect a computer" could present with `startsCustom` still
    /// false, fall through to the default-preset heuristic, and open on near.ai:
    /// a cloud provider, for a row that exists to add a machine on your network.
    /// An item-based sheet can't come apart that way, because the thing that
    /// triggers presentation IS the thing that describes it.
    @State var addTarget: AddTarget?
    /// Presented to pull a model onto a home server — the affordance lives in
    /// the provider's own edit sheet.
    @State var editingProvider: Provider?
    /// Machine to pull a model onto — presents the pull sheet directly, with no
    /// detour through the provider's settings form.
    @State var pullingOnProvider: Provider?
    /// Home model queued for deletion ON the machine. Confirmed: the weights go,
    /// and getting them back is another multi-gigabyte pull.
    /// EVERY confirmation and failure this sheet shows, as one value.
    ///
    /// Four separate `@State` optionals each drove their own `.alert` modifier, and
    /// SwiftUI presents at most one alert per view — so two of the four silently
    /// never fired. One item, one modifier, no shadowing.
    enum PendingAlert: Identifiable {
        /// Delete a downloaded model's weights from this phone.
        case deleteWeights(LocalModel)
        /// Delete a model from the machine serving it.
        case deleteFromServer(Equipped)
        /// The machine refused a delete, so the row reappearing has a reason.
        case deleteFailed(String)

        var id: String {
            switch self {
            case .deleteWeights(let m):    return "weights#\(m.id)"
            case .deleteFromServer(let r): return "server#\(r.id)"
            case .deleteFailed(let m):     return "failed#\(m)"
            }
        }
    }
    @State var pendingAlert: PendingAlert?
    @State var browseProvider: Provider?
    /// The row whose detail page is open — PROVIDER AND MODEL, never the model
    /// alone.
    ///
    /// The provider is on the row already. Inferring it back from the id meant
    /// searching every configured place for one whose catalogue happened to
    /// contain that id, which answers a different question and gets the wrong
    /// place the moment two of them serve the same model — a state this app
    /// actively encourages (`deepseek-v4-flash` on near.ai, `-0731` on
    /// fireworks) and which decides both the live fetch and the price.
    @State var detailTarget: ModelDetailTarget?
    /// Preset whose key the user is about to enter — the add sheet opens on it.
    @State var addingPreset: Provider?
    /// Provider ids as they were before an add sheet opened, so the one that came
    /// back can be identified without the sheet having to report it.
    @State var idsBeforeAdd: Set<UUID> = []
    /// Row to scroll to — the setup that was just added.
    @State var scrollTarget: String?
    enum AddTarget: String, Identifiable {
        case selfHosted, cloudKey
        var id: String { rawValue }
    }
    @State var browseSelectedModel = ""

    /// Plain property, not `@State`: it is `@Observable`, so the view tracks it
    /// either way, and this one has to be injectable.
    let pathObserver: NetworkPathObserver

    /// Downloads are started and cancelled from the `get` list, so their
    /// progress has to be observed here.
    let downloader: LocalModelDownloader
    /// Model queued for a confirmed weights deletion (swipe → confirm).
    /// Provider queued for deletion. Confirmed because it takes the api key with
    /// it, and a key is not something the app can put back.
    /// What each home endpoint is running, how many models it has, which are warm.
    let homeProbe: HomeServerProbe
    /// Which downloaded model has an engine built — phone warmth.
    let residency: LocalEngineResidency
    /// Server-side pulls, so a model added on an Ollama box shows progress here.
    @Environment(OllamaDownloadCenter.self) var pullCenter: OllamaDownloadCenter?

    /// Whether a model's weights are on disk. Injectable because the real check
    /// stats the filesystem, so in a preview every downloaded model reads as
    /// missing — which made the one state this segment exists to show
    /// (downloaded and ready) the one state that couldn't be reviewed.
    let isInstalled: (LocalModel) -> Bool

    /// Preview override for "does this provider have a key". The real check
    /// reads the Keychain, which is empty in a canvas — so without this every
    /// cloud provider looks unconfigured and the browse rows disappear, hiding
    /// the tier's main affordance from review.
    let keyOverride: ((Provider) -> Bool)?

    /// Everything after `openToGet` exists so a state can be LOOKED at.
    ///
    /// This sheet's states are otherwise reachable only by owning the right
    /// models, pulling gigabytes, or switching off the wifi — and every state
    /// that couldn't be previewed here turned out to contain a bug: a segment
    /// that could never appear, copy promising a runtime that had shipped, a
    /// progress bar drawn at 0% for a download that wasn't running.
    init(
        openToGet: Bool = false,
        startingAt filter: WhereLocality? = nil,
        pathObserver: NetworkPathObserver = .shared,
        downloader: LocalModelDownloader = .shared,
        // Defaulted to a shared instance rather than a fresh one: the init is
        // nonisolated, and `HomeServerProbe` is @MainActor.
        homeProbe: HomeServerProbe = .shared,
        residency: LocalEngineResidency = .shared,
        isInstalled: @escaping (LocalModel) -> Bool = LocalModelStorage.isInstalled,
        hasKey: ((Provider) -> Bool)? = nil
    ) {
        self.openToGet = openToGet
        self.pathObserver = pathObserver
        self.downloader = downloader
        self.homeProbe = homeProbe
        self.residency = residency
        self.isInstalled = isInstalled
        self.keyOverride = hasKey
        _filter = State(initialValue: filter)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
            List {
                if !pathObserver.isSatisfied {
                    airplaneBanner
                }
                mergeNoticeBanner
                if showsFirstRun {
                    firstRunSections
                } else {
                    localityPicker
                    readySection
                    if pathObserver.isSatisfied {
                        recentsSection
                        WhereGetSection(
                            policy: getPolicy,
                            openToGet: openToGet,
                            downloader: downloader,
                            hasKey: hasKey,
                            sectionHeader: sectionHeader,
                            idsBeforeAdd: $idsBeforeAdd,
                            addTarget: $addTarget,
                            addingPreset: $addingPreset,
                            pullingOnProvider: $pullingOnProvider,
                            detailTarget: $detailTarget,
                            openBrowse: openBrowse,
                            startAndSelect: startAndSelect
                        )
                    } else {
                        offlineGetSection
                    }
                }
            }
            .groupedListStyle()
            // The list adds ~35pt above its first section, which under a nav bar
            // put the segmented control most of an inch below the title with
            // nothing in between. The picker is the sheet's primary control —
            // it belongs against the title, not adrift below it.
            .contentMargins(.top, 0, for: .scrollContent)
            // Same chrome as the settings sheet: an inline navigation title and
            // a plain tinted ✕ on the leading side.
            //
            // This sheet had a hand-drawn header for a while — the design draws
            // one, and a nav bar on an iOS 26 sheet renders glass that looked
            // like a grey slab. But teemoon already has a sheet convention, and
            // matching the design against the app's own settings sheet is the
            // wrong trade: two sheets in one app that dismiss differently is a
            // worse inconsistency than either header is a win.
            // A POPOVER CARRIES NO TITLE AND NO CLOSE BUTTON.
            //
            // Both exist because this was a modal. A modal has to say what it is
            // and offer a way out. A popover does neither: it is anchored to the
            // control that opened it, so it is self-evidently about that
            // control, and it dismisses by clicking anywhere else.
            //
            // Left in place, they did visible damage. The title reserved a
            // navigation bar's worth of height — about 150pt of empty space
            // above the filter in a 460pt popover — and the ✕ was hoisted out of
            // the popover entirely and drawn in the WINDOW's toolbar, next to
            // the chat title, where it looked like a control for closing the
            // conversation.
            #if !os(macOS)
            .navigationTitle("where")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .barLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("close")
                }
            }
            #endif
            // Both add paths report back the same way: whatever provider appeared
            // while the sheet was up is the one the user just made, and it is why
            // they opened it.
            .sheet(item: $addTarget, onDismiss: adoptNewlyAdded) { target in
                // BOTH paths skip the cloud preset grid, for the same reason.
                //
                // "connect a computer" wants an address; the grid's four options
                // are all things that row isn't. And every preset already has its
                // OWN row in `get` — "browse near.ai · add key" — which opens the
                // sheet on that preset via `initialPreset`. So the generic "add a
                // cloud key" row is by elimination the one for an endpoint teemoon
                // ships no preset for, and defaulting it to near.ai answered a
                // question the user had already answered by not tapping near.ai's
                // own row.
                AddEditProviderView(
                    mode: .add,
                    startsCustom: true,
                    customStart: target == .selfHosted ? .computer : .cloudKey
                )
            }
            .sheet(item: $browseProvider) { provider in
                browseSheet(for: provider)
            }
            .sheet(item: $detailTarget) { target in
                NavigationStack {
                    ModelDetailView(
                        model: target.model,
                        // The entry says what it knows; this view does not
                        // decide. On-device carries its own note, near.ai falls
                        // back to its tier, and anything else says nothing.
                        confidentiality: target.model.confidentialityNote,
                        // THE SAME FETCH THE BROWSER MAKES, so the two surfaces
                        // cannot describe one model differently. Without it a
                        // Where row falls back to the shipped snapshot, which
                        // is always behind.
                        liveLoader: liveModelLoader(for: target.provider,
                                                    id: target.model.id)
                    )
                }
            }
            .sheet(item: $editingProvider) { provider in
                AddEditProviderView(mode: .edit(provider))
            }
            .sheet(item: $pullingOnProvider) { provider in
                if let base = provider.openAIBaseURL {
                    OllamaModelDownloadView(
                        baseURL: base,
                        onCompleted: { _ in
                            // Re-probe so the row stops showing progress and starts
                            // showing warmth, and so the server's real id replaces
                            // the ref we equipped optimistically if they differ.
                            Task {
                                await homeProbe.refresh(providerStore.providers) {
                                    providerStore.credential(for: $0)
                                }
                                syncHomeEquipped()
                            }
                        },
                        onStarted: { ref in
                            // SAME as tapping a phone model in `get`: the row exists
                            // from the moment the download starts, showing its own
                            // progress, and it is selected so "send when it lands"
                            // works. A server-side pull had neither — the model
                            // appeared only once some later probe noticed it, and
                            // closing the pull sheet made gigabytes in flight
                            // invisible.
                            equipArriving(ref, on: provider)
                        },
                        // What this machine already serves, so the sheet stops
                        // offering a model it has had for weeks.
                        installed: homeProbe.info(for: provider)?.models ?? []
                    )
                }
            }
            .sheet(item: $addingPreset, onDismiss: adoptNewlyAdded) { preset in
                AddEditProviderView(mode: .add, initialPreset: preset)
            }
            // ONE alert for the whole sheet, dispatched on an enum.
            //
            // There were FOUR stacked `.alert` modifiers here, and SwiftUI presents
            // at most one per view: the two innermost never fired, which is exactly
            // the reported bug — tapping "delete" on a home model set the state, no
            // confirmation appeared, and nothing happened. Stacking alerts is the
            // class of bug, so the fix is to stop stacking rather than to reorder
            // them and hope.
            .alert(item: $pendingAlert) { pending in
                switch pending {
                case .deleteFromServer(let row):
                    return Alert(
                        title: Text("delete \(row.modelID) from that machine?"),
                        // Names the machine so a two-server setup can tell WHICH
                        // one, and says the cost: this frees disk over there and
                        // getting it back is another pull, not a re-equip.
                        message: Text("removes the weights from \(WhereProviderPresentation.canonicalName(for: row.provider)). teemoon can pull it again, which downloads it to the machine from scratch."),
                        primaryButton: .destructive(Text("delete")) { deleteFromServer(row) },
                        secondaryButton: .cancel(Text("keep"))
                    )
                case .deleteFailed(let message):
                    return Alert(title: Text("couldn't delete"), message: Text(message),
                                 dismissButton: .default(Text("ok")))
                case .deleteWeights(let model):
                    return Alert(
                        title: Text("delete \(model.displayName)?"),
                        message: Text("frees \(model.sizeLabel). it moves back to get, and you can download it again."),
                        primaryButton: .destructive(Text("delete")) { deleteWeights(model) },
                        secondaryButton: .cancel(Text("keep"))
                    )
                }
            }
            .task {
                // Persisted facts FIRST, so a machine that answered before is named
                // and listed on the first frame instead of after the network agrees
                // — and stays that way if this refresh fails.
                homeProbe.seed(from: providerStore)
                // Names the server, lists its models, and finds which are warm.
                await homeProbe.refresh(providerStore.providers) { provider in
                    providerStore.credential(for: provider)
                }
                syncHomeEquipped()
            }
            .onAppear {
                // NO cloud override.
                //
                // This used to force `filter = .cloud` when arriving from the
                // send-blocked alert with nothing configured, "to prefer showing
                // cloud get path when empty". Two things were wrong with it.
                //
                // The alert's own text names the phone FIRST — "download a model
                // to this phone, connect a computer, or add a cloud key" — and
                // then its button dropped the user on a screen showing "no cloud
                // keys" and a list of vendors wanting API keys, with the free
                // on-device option hidden behind a tab. The recommendation and
                // the destination disagreed.
                //
                // And it silently bypassed first run: `showsFirstRun` requires
                // `filter == nil`, so the one entry point where the user has
                // demonstrated intent got the old seven-row `get` list instead
                // of "start here". Verified by capture, not by reading.
                //
                // `openToGet` still scrolls to `get` for someone who already has
                // setups; it just no longer picks a tier on their behalf.
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                // Animated, so the movement itself shows that the list changed
                // and where the new row landed. Cleared after, or returning to
                // the sheet later would jump to a row for no reason.
                withAnimation { scroller.scrollTo(target, anchor: .center) }
                scrollTarget = nil
            }
            }
        }
        // Dynamic Type still applies — clamped. Uncapped, `accessibility5`
        // turns a seven-row picker into a two-row one, which is not a bigger
        // version of the design, it's a different screen.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // The detent follows the JOB, not the screen.
        //
        // Medium is right for the sheet's normal use — switching model
        // mid-conversation, where you want the transcript visible behind you
        // and a clipped row is a fine "scroll for more" affordance.
        //
        // First run is a different job: a decision, not a pick. At medium the
        // gemma hero fills the sheet and `use a cloud api` falls below the
        // fold, so a third of the choice is hidden from someone who has never
        // seen the app — and it is the row for a user who already holds a key
        // and could be running in thirty seconds. The usual argument for medium
        // does not apply either: it exists to keep context visible behind the
        // sheet, and at first run the thing behind is a blank screen.
        //
        // One clipped row also reads as a layout error rather than as scroll.
        // Several clipped rows say "there is more"; exactly one says "this
        // ended badly".
        //
        // But .large overshoots, which I only saw by capturing the screen:
        // the content ends about two-thirds down and the remaining third is
        // dead space, so a near-full-screen sheet arrives mostly empty and
        // reads as the takeover that deleting the old flow was meant to avoid.
        // .fraction(0.76) clears the last row and its footer with a little
        // slack, and stays visibly short of full. `.large` is kept in the set
        // so larger Dynamic Type still has somewhere to go.
        // DETENTS ARE A PHONE CONCEPT, AND macOS SILENTLY IGNORED THEM.
        //
        // These two lines shipped ungated, so on the Mac the sheet had no size
        // instruction that AppKit honours and fell back to its content's ideal
        // height. The content is a ScrollView, whose ideal height is nearly
        // nothing — measured: the sheet settled at 470x80pt. Eighty points. The
        // title and the all/phone/home/cloud filter fitted; every model row was
        // below the fold of an 80pt sheet, so the app's most designed surface
        // was, on the Mac, a sliver you could not pick a model from.
        //
        // It looked like a mid-animation capture, which is how it survived a
        // baseline pass. It is not: the height is stable, and the rows are all
        // present in the accessibility tree — laid out, just nowhere visible.
        //
        // A drag indicator is the same category of mistake: a grabber is how a
        // finger resizes a sheet, and there is no finger.
        #if os(macOS)
        // POPOVER PROPORTIONS, NOT SHEET PROPORTIONS.
        //
        // 520x590 was a sheet's size and it does not survive the move: anchored
        // to a chip that sits just above the composer, a 590pt popover runs off
        // the top of a 640pt window. 380 is the width CD's control study assumed
        // and it is the right order for a popover — wide enough for a two-line
        // row, narrow enough to read as attached to the chip rather than as a
        // second window.
        .frame(width: 380, height: 545)
        #else
        .presentationDetents(showsFirstRun ? [.fraction(0.76), .large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        // OPAQUE, not the default material.
        //
        // A sheet's default background is translucent, so whatever sits behind
        // it blurs through — and what sits directly behind this one is the
        // Where chip, 44pt of saturated accent. It rendered as an orange smear
        // across `other places`, which reads as a rendering fault rather than
        // depth. The same thing happened in light mode when the chip was filled
        // with `.primary`: a black smudge in the same spot.
        //
        // `systemBackground` rather than `systemGroupedBackground`: the list is
        // `.insetGrouped`, so its rows are `secondarySystemGroupedBackground`
        // (#1c1c1e) and need a darker plate behind them to read as raised.
        .presentationBackground(PlatformColors.background)
    }

    /// The design's row box: 11pt vertical, 14pt horizontal.
    ///
    /// Type was already at the specified 16pt — the rows still read oversized
    /// because List's default insets are considerably taller than the design's,
    /// so seven rows needed the space the design gives nine. The excess was
    /// never the font.
    static let rowInsets = EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14)

    /// Section headers, per the design: 15pt semibold in the secondary colour,
    /// lowercase, NOT the system's small uppercase grouped-list header.
    ///
    /// A near-body-size header reads as a label on the card below it rather than
    /// a category above it, which is what these are — "ready now" and "get" are
    /// the two halves of one answer, not chapters.
    func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: ControlMetrics.sheetSectionHeaderSize, weight: .semibold))
            // `.secondary` inside a List header gets dimmed AGAIN by the list's
            // own header treatment, landing well under the design's 0.6 and
            // reading as disabled. An explicit opacity survives it.
            .foregroundStyle(Color.primary.opacity(0.55))
            .textCase(nil)
            .padding(.bottom, 2)
    }

    // MARK: - Get (rows live in WhereGetSection.swift; these members are shared
    // with the sibling section files or with this sheet's own modifiers)

    var getPolicy: WhereGetPolicy {
        var home: [UUID: WhereGetPolicy.HomeInfo] = [:]
        for p in providerStore.providers {
            if let info = homeProbe.info(for: p) {
                home[p.id] = .init(kind: info.kind, modelCount: info.modelCount, warm: info.warm)
            }
        }
        return WhereGetPolicy(
            filter: filter,
            providers: providerStore.providers,
            networkSatisfied: pathObserver.isSatisfied,
            home: home,
            credentialFor: { self.providerStore.credential(for: $0) },
            credentialForEndpoint: { self.providerStore.credential(forEndpoint: $0) ?? "" }
        )
    }

    func hasKey(_ provider: Provider) -> Bool {
        if let keyOverride { return keyOverride(provider) }
        return getPolicy.hasKey(provider)
    }

    /// Selects and scrolls to whatever was just added.
    ///
    /// Saving a key left the sheet exactly where it was — scrolled to the bottom
    /// of `get`, looking at the row that had just stopped being relevant, while
    /// the thing the user came for sat off-screen above and unselected. Adding a
    /// provider from here is not bookkeeping: it is the last step of choosing
    /// one, so it finishes the choice.
    func adoptNewlyAdded() {
        guard let added = providerStore.providers.first(where: { !idsBeforeAdd.contains($0.id) })
        else { return }
        idsBeforeAdd = []

        // A filter that excludes the new row would scroll to something that
        // isn't rendered, so widen to the tier it belongs to.
        let locality = WhereLocality.of(added)
        if let filter, filter != locality { self.filter = locality }

        providerStore.activate(modelID: added.model, on: added)
        scrollTarget = Equipped(provider: added, modelID: added.model).id
    }

    /// Offline: can't add cloud keys usefully; keep a quiet note.
    var offlineGetSection: some View {
        Section {
            Text("connect to a network to add cloud keys or reach home servers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.lowercase)
        } header: {
            sectionHeader("get")
        }
    }

    func liveCatalogLoader(for provider: Provider) -> (() async -> [KnownModel]?)? {
        WhereProviderPresentation.liveModelsLoader(
            for: provider,
            apiKey: browseKey(for: provider),
            homeKind: nil
        )
    }

    func browseKey(for provider: Provider) -> String {
        providerStore.browseCredential(for: provider)
    }

    @ViewBuilder
    func rowDestructiveActions(_ row: Equipped) -> some View {
        switch getPolicy.destruction(for: row.provider) {
        case .deleteLocalWeights:
            if let localID = row.provider.localModelID,
               let model = LocalModelCatalog.model(id: localID) {
                Button(role: .destructive) {
                    pendingAlert = .deleteWeights(model)
                } label: {
                    Label("delete", systemImage: "trash")
                }
            }
        case .deleteFromServer:
            Button(role: .destructive) {
                pendingAlert = .deleteFromServer(row)
            } label: {
                Label("delete", systemImage: "trash")
            }
        case .unequipCloud:
            Button(role: .destructive) {
                providerStore.forget(modelID: row.modelID, on: row.provider)
                Haptics.play()
            } label: {
                Label("unequip", systemImage: "minus.circle")
            }
        case .none:
            EmptyView()
        }
    }

    /// The catalogue entry behind a row, for the detail page.
    ///
    /// Two different sources: a downloaded model is a `LocalModel` (size,
    /// pinned revision, checksum — provenance no cloud row has), everything else
    /// is a `KnownModel` from the provider's catalogue. nil when neither knows
    /// the id, and the menu item is then omitted rather than opening a page with
    /// one field on it.
    /// Resolves one model from THAT provider's live catalogue — the same source
    /// the browser renders. nil when there is nothing live to fetch (no key, a
    /// custom endpoint, on-device).
    func liveModelLoader(for provider: Provider, id: String) -> (() async -> KnownModel?)? {
        guard let loader = WhereProviderPresentation.liveModelsLoader(
            for: provider,
            apiKey: providerStore.browseCredential(for: provider),
            homeKind: providerStore.storedKind(of: provider)
        ) else { return nil }
        return { await loader()?.first { $0.id == id } }
    }

    func knownModel(for row: Equipped) -> KnownModel {
        if let local = LocalModelCatalog.model(id: row.modelID) {
            return .onDevice(local)
        }
        if let known = WhereProviderPresentation.browseModels(for: row.provider)
            .first(where: { $0.id == row.modelID }) {
            return known
        }
        // NOT NIL — every row gets the menu item.
        //
        // The catalogue consulted here is the SHIPPED SNAPSHOT, and a snapshot
        // is always behind: `deepseek-v4-flash-0731` is equipped and answering
        // while the table only knows the undated `deepseek-v4-flash`, so the
        // row the user was actually looking at was the one with no "model info"
        // on it. The same staleness that blanked its price this morning.
        //
        // Identity is knowable without any catalogue — the id is on the row, the
        // place is on the provider — so the page opens with what is certain and
        // simply has fewer sections. That is the rule this view already follows
        // everywhere else: say less, never nothing, and never guess.
        return KnownModel(
            id: row.modelID,
            displayName: ModelCatalog.compactName(forID: row.modelID),
            vendor: WhereProviderPresentation.canonicalName(for: row.provider),
            price: "",
            capabilities: row.provider.modelCapabilities,
            confidentialityNote: WhereProviderPresentation.placeCaption(for: row.provider))
    }

    /// Puts an arriving server-side pull on the list immediately, and selects it.
    ///
    /// Mirrors what tapping a phone model in `get` does — `startAndSelect` — so the
    /// two tiers behave alike: a row you can watch, and a selection that means the
    /// next message goes to it once the bytes land. `pullFraction` finds the
    /// progress by matching this ref against `OllamaDownloadCenter`, so the row
    /// renders its own bar with no further wiring.
    func equipArriving(_ ref: String, on provider: Provider) {
        let updated = provider.equipping(ref)
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
    }

    /// Deletes the model on the machine, then re-probes.
    ///
    /// The local equipped set is trimmed FIRST so the row leaves immediately
    /// instead of lingering until the probe returns — and trimmed by hand rather
    /// than through `providerStore.unequip`, which deletes the whole provider when
    /// the last model goes. Deleting a machine's only model must not delete the
    /// machine: it is still there, and pulling another model onto it is the next
    /// thing you would do.
    func deleteFromServer(_ row: Equipped) {
        guard let base = row.provider.openAIBaseURL else { return }
        var updated = row.provider
        updated.equippedModels = row.provider.equipped.filter { $0 != row.modelID }
        if updated.model == row.modelID {
            updated.model = updated.equippedModels?.first ?? ""
        }
        providerStore.updateProvider(updated)
        Haptics.play()
        Task {
            do {
                try await OllamaAdapter.deleteModel(row.modelID, baseURL: base)
                // Tell the PROBE CACHE, don't re-probe. `syncHomeEquipped`
                // reconciles `equippedModels` against this cache, and the cache
                // outlives the delete — so the previous version, which re-probed
                // and then synced, put the row straight back whenever the refresh
                // was skipped (`refresh` ignores a provider already `inFlight`,
                // which an overlapping sheet probe makes likely). The delete
                // succeeded; the cache should reflect that without a round trip.
                homeProbe.forget(modelID: row.modelID, on: row.provider)
                // And from the CONFIG: the row, its usage history, and the
                // server's record of serving it. Without this the model stayed in
                // `recently used` — the persisted `servedModels` still listed it,
                // so the runnable check passed — and tapping it would re-equip
                // something the machine no longer has.
                providerStore.forgetModel(row.modelID, on: row.provider)
            } catch {
                // Put the row BACK, then say why. It was removed optimistically so
                // the list would respond immediately, and leaving it gone after a
                // failed delete would mean teemoon and the machine disagree with
                // nothing on screen to explain it.
                providerStore.updateProvider(row.provider)
                pendingAlert = .deleteFailed(
                    "\(row.modelID) is still on \(WhereProviderPresentation.canonicalName(for: row.provider)) — \(error.localizedDescription)")
            }
        }
    }
}
