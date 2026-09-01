//
//  ChatView.swift
//  teemoon
//
//  Created by Jordan Singer on 12/3/24.
//

import SwiftUI


struct ChatView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProviderStore.self) private var providerStore
    @Environment(ConfidentialSession.self) private var confidentialSession
    @Environment(\.modelContext) var modelContext
    @Binding var currentThread: Thread?
    @Environment(ChatGeneration.self) var llm
    @Namespace var bottomID
    @State private var viewModel: ChatViewModel = {
        let vm = ChatViewModel()
        vm.onPlayHaptic = { Haptics.play() }
        vm.onBatchUpdate = { work in
            withAnimation(.spring(duration: 0.35, bounce: 0.1), work)
        }
        return vm
    }()
    @State private var showNoProviderAlert = false
    @State private var showE2EEDegradedAlert = false
    @State private var e2eeRetrying = false
    /// Where sheet — option B chip above the composer.
    @State private var showWhereSheet = false
    /// Detail for the model currently answering, raised by long-pressing the
    /// Where chip.
    @State private var showActiveModelDetail = false
    #if os(macOS)
    /// The everyday rung, in a popover hanging off the toolbar trust chip.
    @State private var showTrustPopover = false
    @Environment(\.openWindow) private var openWindow
    #endif
    /// Observed so the composer un-gates the moment a download finishes, with
    /// no trip back through settings to "use" the model.
    @State private var downloader = LocalModelDownloader.shared
    /// Server-side pulls, so a home model still landing on its machine blocks the
    /// send for the same reason a phone model still downloading does. Optional
    /// because not every host injects it.
    @Environment(OllamaDownloadCenter.self) private var pullCenter: OllamaDownloadCenter?
    /// Raised when send is pressed while the selected model is still arriving.
    @State private var showDownloadingAlert = false
    /// Measured height of the whole bottom inset (note + chip + composer + padding).
    @State private var bottomInsetHeight: CGFloat = 96
    /// The Where chip's frame in the inset's own coordinate space. Both edges
    /// matter: the transcript stays crisp above the chip's TOP, and is fully
    /// hidden below its BOTTOM — including the gap before the composer, which is
    /// where text kept bleeding through.
    @State private var chipFrameInInset = CGRect(x: 0, y: 16, width: 0, height: 44)
    /// Names the inset's coordinate space so the chip can be measured inside it.
    private static let insetSpace = "chatBottomInset"
    /// Shape of the transcript's bottom fade. See `ChatFadeBand`.
    private var fadeBand: ChatFadeBand {
        ChatFadeBand(chipTop: chipFrameInInset.minY,
                     chipBottom: chipFrameInInset.maxY,
                     insetHeight: bottomInsetHeight)
    }
    /// Deep link empty setups into Get (add provider), not Settings.
    @State private var whereOpenToGet = false
    /// When the degraded-send alert is raised by a message RETRY (not a fresh
    /// send), the message to retry — so the same gate covers both paths.
    @State private var pendingRetryMessage: Message?
    @FocusState.Binding var isPromptFocused: Bool
    @Binding var showChats: Bool
    @Binding var showSettings: Bool
    @Binding var showSettingsProviders: Bool
    /// Raised before `showSettings` so the sheet opens on search. See the web
    /// chip's unconfigured action.
    @Binding var showSettingsSearch: Bool

    /// Incremented when the offer card is declined, so the chip can point at
    /// itself once. A token rather than a Bool: two declines in a row must
    /// produce two pulses, and a Bool that is already true produces none.
    @State private var webChipPointToken = 0

    /// The web chip's three states, derived — never stored. A key with the
    /// toggle off is a real and distinct state from no key at all: the first
    /// is a choice the user made and can undo in one tap, the second is a
    /// setup they have not done. Collapsing them would send someone who
    /// deliberately turned search off back into settings to turn it on.
    ///
    /// The catalogue entry for the model currently answering.
    ///
    /// Prefers real published metadata — the on-device catalogue, then the
    /// provider's — and falls back to identity alone rather than to nil.
    private var activeKnownModel: KnownModel? {
        guard let provider = providerStore.activeProvider else { return nil }
        if let local = LocalModelCatalog.model(id: provider.model) { return .onDevice(local) }
        if let known = WhereProviderPresentation.browseModels(for: provider)
            .first(where: { $0.id == provider.model }) { return known }
        // NEVER NIL FOR A REAL PROVIDER, or the menu renders EMPTY and the long
        // press looks broken. The catalogue consulted here is the shipped
        // snapshot, which is always behind — `deepseek-v4-flash-0731` was the
        // model answering while the table only knew the undated one, so the chip
        // naming it had no menu at all. Identity needs no catalogue; the page
        // opens with what is certain and fills in from `liveLoader`.
        return KnownModel(
            id: provider.model,
            displayName: ModelCatalog.compactName(forID: provider.model),
            vendor: WhereProviderPresentation.canonicalName(for: provider),
            price: "",
            capabilities: provider.modelCapabilities,
            confidentialityNote: WhereProviderPresentation.placeCaption(for: provider))
    }

    /// The live catalogue entry for the active model — the same fetch the model
    /// browser makes, against the provider that is actually answering.
    private func activeModelLiveLoader() -> (() async -> KnownModel?)? {
        guard let provider = providerStore.activeProvider,
              // ONE loader, shared with the Where sheet — including the
              // both-lookup key rule, which this reimplemented and got wrong.
              let loader = WhereProviderPresentation.liveModelsLoader(
                  for: provider,
                  apiKey: providerStore.browseCredential(for: provider),
                  homeKind: providerStore.storedKind(of: provider))
        else { return nil }
        let id = provider.model
        return { await loader()?.first { $0.id == id } }
    }

    /// What the where chip's menu offers. Two items deliberately: iOS renders a
    /// lone entry as an oversized pill, and a single-item menu is better as a
    /// direct action than as a menu.
    @ViewBuilder
    private var chipMenuItems: some View {
        if let model = activeKnownModel {
            Button {
                showActiveModelDetail = true
            } label: {
                Label("model info", systemImage: "info.circle")
            }
            // The id is what goes on the wire, and the detail page already
            // treats it as the thing worth copying.
            Button {
                #if os(iOS)
                UIPasteboard.general.string = model.id
                #endif
                Haptics.play()
            } label: {
                Label("copy model id", systemImage: "square.on.square")
            }
        }
    }

    private var webSearchState: WebSearchChip.State {
        // NOTHING EQUIPPED means grounding cannot run whatever the setting
        // says, and this is the only state that dims. It is what frees the dim
        // to mean "you cannot tap this" — while anything else is using it, the
        // signal is spent.
        guard providerStore.activeProvider != nil else { return .disabled }
        if settings.braveSearchKey.isEmpty { return .unconfigured }
        return settings.braveGroundingEnabled ? .on : .off
    }

    var chatInput: some View {
        ChatComposer(viewModel: viewModel, isPromptFocused: $isPromptFocused, onSend: generate)
    }

    var chatTitle: String {
        if let currentThread, let first = currentThread.sortedMessages.first {
            #if os(macOS)
            // A WINDOW TITLE IS NOT A PLACE TO PUT A PARAGRAPH.
            //
            // This returned the entire first message. In the title bar that
            // truncates and looks survivable, which is why it lasted — but the
            // same string is the app's identity in the Window menu, in Mission
            // Control, under the Dock icon when minimised, and in ⌘` switching.
            // A three-line question becomes a menu item wider than the menu.
            //
            // `Thread.title` exists and would be the right source, but nothing
            // in the app ever writes it — the only assignment is the UI-test
            // fixture seeder — so using it would just render empty. Truncating
            // the message is the honest fix until titles are generated.
            //
            // Cut on a word boundary: "what exactly am I…" reads as an
            // abbreviation, "what exactly am I trus…" reads as a bug.
            return Self.windowTitle(from: first.content)
            #else
            return first.content
            #endif
        }
        return "chat"
    }

    #if os(macOS)
    /// First line, clipped to a word boundary near 48 characters.
    static func windowTitle(from content: String, limit: Int = 48) -> String {
        let firstLine = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? content
        guard firstLine.count > limit else { return firstLine }

        let clipped = firstLine.prefix(limit)
        // Back up to the last space so a word is never cut in half. If there is
        // no space — one very long token — take the hard cut rather than
        // returning the whole thing, which is the case this exists for.
        let stem = clipped.lastIndex(of: " ").map { clipped[clipped.startIndex..<$0] } ?? clipped
        return stem.trimmingCharacters(in: .whitespaces) + "…"
    }
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if let currentThread {
                    ConversationView(messages: currentThread.sortedMessages, threadID: currentThread.id, generatingThreadID: viewModel.generatingThreadID, onRetry: retry, onSetUpWebSearch: {
                        // Same destination as the composer chip's unconfigured
                        // tap. Two entry points, one screen — if they diverged,
                        // the card would be teaching a route the chip doesn't use.
                        showSettingsSearch = true
                        showSettings = true
                    }, onRetryAfterSetup: { userMessage in
                        // Brave already accepted the key inside the card, so
                        // there is nothing to wait for — re-ask immediately.
                        // `retry(from:)` deletes the refusal along with
                        // everything after it, which is what stops the model
                        // copying it on the new turn.
                        retry(from: userMessage)
                    }, onDeclineWebSearch: {
                        // The offer does not just vanish — it MOVES. The card
                        // is transient, the chip is permanent, so declining
                        // hands the idea to the control that will still be
                        // there tomorrow.
                        webChipPointToken += 1
                    }, fadeBand: fadeBand)
                } else {
                    VStack {
                        Spacer()
                        // DECORATIVE, AND IT WAS SAYING SO OUT LOUD.
                        //
                        // With no label, an `Image(systemName:)` announces its
                        // SF Symbol name — a VoiceOver user opening an empty
                        // chat heard "moonphase.waning.gibbous". The glyph is
                        // branding: it carries no information a person needs,
                        // and the pane's actual content is the composer below.
                        //
                        // Hidden rather than labelled, because a label here
                        // would be inventing meaning for a decoration. Caught by
                        // MacAccessibilityAuditUITests, which reads the same
                        // tree VoiceOver does — none of this is visible to the
                        // eye, so nothing else could have caught it.
                        Image(systemName: MoonPhase.currentSymbolName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32, height: 32)
                            .foregroundStyle(.quaternary)
                            .accessibilityHidden(true)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            #if os(macOS)
            // The inspector is opened from a toolbar popover and from a menu
            // command, neither of which carries the scene environment reliably —
            // so both post, and this is the one place holding `openWindow`.
            .onReceive(NotificationCenter.default.publisher(for: .teemoonOpenAttestation)) { _ in
                openWindow(id: MacAttestationInspector.windowID)
            }
            #endif
            // NEW CHAT HAS TO EMPTY THE COMPOSER, AND IT DID NOT.
            //
            // ContentView answers this notification by dropping the thread and
            // refocusing the composer, but the draft lives here — `viewModel` is
            // this view's private state, so nothing out there could clear it.
            // The result was that ⌘N (and iOS +) carried the half-written
            // message from the old thread into the new one. Cleared here
            // rather than by widening `viewModel`'s reach, because each view
            // already answers this notification for the state it owns.
            .onReceive(NotificationCenter.default.publisher(for: .teemoonNewChat)) { _ in
                viewModel.prompt = ""
            }
            .chatScrollEdgeEffects()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    // Option B: model·place chip opens Where; title stays trust.
                    HStack {
                        #if os(macOS)
                        WhereChip(
                            provider: providerStore.activeProvider,
                            // nil unless the selected model's weights are still
                            // arriving — the chip is the only place that says so
                            // now, and the send button is disabled to match.
                            progress: arrivingAnywhere?.fraction,
                            // A HOME pull with no fraction yet has started and is
                            // simply pre-bytes, so it must not read as "needs
                            // download" — that badge means the weights aren't
                            // coming, which for a phone model is true and here
                            // isn't.
                            needsDownload: arrivingModel != nil && arrivingModel?.fraction == nil,
                            action: {
                                Haptics.play()
                                showWhereSheet = true
                            }
                        )
                        // A POPUP BUTTON OPENS A POPOVER, NOT A MODAL.
                        //
                        // This chip is a popup button in everything but name: it
                        // shows the current value, carries the up/down chevron
                        // that means "there is a list behind this", and its whole
                        // job is picking one item from that list.
                        //
                        // It was opening a modal sheet — a card centred in the
                        // window, dimming everything behind it, anchored to
                        // nothing. On a Mac that is the vocabulary of a
                        // consequential interruption: a save panel, a
                        // confirmation. Choosing which model answers your next
                        // message is neither. Safari's downloads, Xcode's scheme
                        // picker, the Notes format menu — all popovers hanging
                        // off the control you clicked.
                        //
                        // The anchoring is the point, not the chrome. A popover
                        // points at its source, so the list is visibly ABOUT the
                        // chip; the modal made the connection something you had
                        // to remember. It also stops dimming a conversation the
                        // user is likely re-reading while they choose.
                        .popover(isPresented: $showWhereSheet,
                                 attachmentAnchor: .rect(.bounds),
                                 arrowEdge: .top) {
                            WhereSheetView(openToGet: whereOpenToGet)
                                .onDisappear { whereOpenToGet = false }
                        }
                        #else
                        // A MENU, NOT A CONTEXT MENU.
                        //
                        // `.contextMenu` LIFTS its source out of the layout for
                        // as long as it is open, and this HStack then re-centres
                        // around the hole — pressing the where chip visibly slid
                        // the web chip to the middle of the screen. `.fixedSize()`
                        // was tried and did nothing: the chip's size was never
                        // the problem, its ABSENCE was.
                        //
                        // `Menu(primaryAction:)` anchors a popover instead of
                        // lifting anything, so nothing moves. It is also the
                        // right control for a chip rather than a content row:
                        // tap still opens Where — switching models is what this
                        // is for and stays one tap — and a long press gets the
                        // menu.
                        Menu {
                            chipMenuItems
                        } label: {
                            WhereChip(
                                provider: providerStore.activeProvider,
                                // nil unless the selected model's weights are
                                // still arriving — the chip is the only place
                                // that says so now, and the send button is
                                // disabled to match.
                                progress: arrivingAnywhere?.fraction,
                                // A HOME pull with no fraction yet has started
                                // and is simply pre-bytes, so it must not read as
                                // "needs download" — that badge means the weights
                                // aren't coming, which for a phone model is true
                                // and here isn't.
                                needsDownload: arrivingModel != nil && arrivingModel?.fraction == nil,
                                // The chip's own button never fires: `Menu` owns
                                // the gestures now, and hit testing is off below
                                // so the inner Button cannot swallow the tap.
                                action: {}
                            )
                            .allowsHitTesting(false)
                        } primaryAction: {
                            Haptics.play()
                            showWhereSheet = true
                        }
                        .buttonStyle(.plain)
                        #endif
                        // WEB ANSWERS, second — never first. The Where chip
                        // answers "who is replying", which has no default and
                        // gates send; this one answers "may it look things up",
                        // which has a working default either way. Reading order
                        // is the priority order.
                        WebSearchChip(
                            state: webSearchState,
                            pointHereToken: webChipPointToken,
                            action: {
                                Haptics.play()
                                if settings.braveSearchKey.isEmpty {
                                    // Nothing to toggle — send them to the one
                                    // screen that can change that, deep-linked
                                    // so they land ON search, not on an index.
                                    showSettingsSearch = true
                                    showSettings = true
                                } else {
                                    settings.braveGroundingEnabled.toggle()
                                }
                            }
                        )
                        Spacer(minLength: 0)
                    }
                    // The fade band starts HERE — at the chip's top edge, not at
                    // the top of the inset. Measured in the inset's own coordinate
                    // space rather than derived from padding constants, so it
                    // can't drift when the padding or the note changes.
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(Self.insetSpace))
                    } action: { frame in
                        chipFrameInInset = frame
                    }
                    HStack(alignment: .bottom) { chatInput }
                }
                    .padding()
                    #if os(macOS)
                    // Same 720pt column as the transcript above (see
                    // ConversationView). Capping only the transcript would leave
                    // the composer and the chips running the full window width
                    // under a centred column of text — the two would visibly
                    // fail to line up, which reads worse than either choice
                    // applied consistently.
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity, alignment: .center)
                    #endif
                    .coordinateSpace(.named(Self.insetSpace))
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        bottomInsetHeight = height
                    }
                    // A GRADIENT SCRIM, drawn from inside the inset.
                    //
                    // The inset had no backing at all, on the theory that
                    // `chatBottomScrollFade` kept the transcript out of the
                    // capsules' gaps. It cannot: that mask is laid out in the
                    // SCROLL VIEW's bounds, which end where this chrome begins,
                    // so it has no reach over the area the chips occupy. This is
                    // exactly what `ChatFadeBandTests`'
                    // `theHiddenRegionCoversTheGapBetweenTheCapsules` has been
                    // failing about — "the mask ENDS where the chrome BEGINS" —
                    // and what a device photo showed: an answer running straight
                    // through both chips.
                    //
                    // The `.bar` shelf that was tried and reverted failed for two
                    // reasons, and both are avoidable. Its HARD TOP EDGE sliced
                    // glyphs mid-line — so this ramps from fully clear over the
                    // top 40%, and text dissolves instead of being cut. And it
                    // read as a GREY SLAB on the keyboard's grey — so this is
                    // `systemBackground`, the same black as the transcript, not a
                    // material.
                    //
                    // Height comes from the top padding below: the ramp needs
                    // room ABOVE the chips to finish in, or the dissolve lands on
                    // the capsules themselves.
                    .padding(.top, 22)
                    // No shelf on iOS: the collection view's glass overlays are
                    // the dissolve; an extra `systemBackground` gradient here is
                    // the black band that fights Liquid Glass. A comments-only
                    // branch breaks the postfix-#if parse — keep this one-sided.
                    #if os(macOS)
                    .background {
                        LinearGradient(
                            stops: [
                                .init(color: PlatformColors.background.opacity(0), location: 0),
                                .init(color: PlatformColors.background, location: 0.2),
                                .init(color: PlatformColors.background, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        .ignoresSafeArea(edges: .bottom)
                        .allowsHitTesting(false)
                    }
                    #endif
            }
            .sheet(isPresented: $showActiveModelDetail) {
                if let model = activeKnownModel {
                    NavigationStack {
                        ModelDetailView(
                            model: model,
                            // Same rule as the Where sheet: the entry says what
                            // it knows, this view does not decide.
                            confidentiality: model.confidentialityNote,
                            liveLoader: activeModelLiveLoader()
                        )
                    }
                    .presentationDetents([.large])
                }
            }
            // iOS keeps the sheet; the popover above replaces it on macOS.
            #if !os(macOS)
            .sheet(isPresented: $showWhereSheet, onDismiss: {
                whereOpenToGet = false
            }) {
                WhereSheetView(openToGet: whereOpenToGet)
            }
            #endif
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #elseif os(visionOS)
            .navigationTitle(chatTitle)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .navigationTitle(chatTitle)
            #endif
                .alert("still downloading", isPresented: $showDownloadingAlert) {
                    // Restarting is offered HERE, not only in the Where sheet: an
                    // interrupted download is discovered at the moment of sending,
                    // and making the user navigate away to fix it is a detour
                    // through a screen that would tell them the same thing.
                    if let arriving = arrivingModel, arriving.fraction == nil {
                        Button("restart download") {
                            downloader.start(arriving.model)
                        }
                    }
                    Button("choose another", role: .cancel) { showWhereSheet = true }
                    Button("wait", role: .cancel) {}
                } message: {
                    Text(downloadingAlertMessage)
                }
                .alert("no provider configured", isPresented: $showNoProviderAlert) {
                    // One way in, and it is the same one the chip offers — no
                    // "open settings" button, which is the route this redesign
                    // demotes. Deep-links into Get rather than dropping the
                    // user on a list that is empty by definition.
                    Button("add a provider") {
                        whereOpenToGet = true
                        showWhereSheet = true
                    }
                    Button("cancel", role: .cancel) {}
                } message: {
                    // PHONE, COMPUTER, CLOUD — the app's one ordering for the
                    // three tiers, and it was inverted here. Everywhere else
                    // (the Where sheet's `get` section, the first-run sheet)
                    // runs local, home, cloud; this alert put cloud second, so
                    // the one surface a stuck user is guaranteed to see taught
                    // a different order from the sheet it sends them to.
                    //
                    // The order is also an argument, which is why it is fixed:
                    // it runs cheapest-and-most-private first. The phone needs
                    // no key and no other machine; a computer needs a machine
                    // but still no account; the cloud needs both a key and
                    // trusting someone else with the text.
                    Text("download a model to this phone, connect a computer, or add a cloud key — then send again.")
                }
                .alert(e2eeAlertTitle, isPresented: $showE2EEDegradedAlert) {
                    Button("retry verification") {
                        retryE2EEAndGenerate()
                    }
                    // HARD integrity break (tamper / MITM / replay / unbound key):
                    // no bypass. Sending is blocked, not merely confirmed — you
                    // cannot send into a compromised or unverified enclave; only
                    // re-verify or cancel. The send option appears ONLY for soft
                    // degrades, and with an honest label per mode: when E2EE is
                    // intact and only provenance failed, a send is still sealed
                    // end-to-end, so "send unencrypted" would be false and scarier
                    // than the truth (unverified image inside the enclave, not
                    // plaintext on the wire).
                    if !confidentialSession.degradeIsHardFailure {
                        Button(confidentialSession.provenanceBlockedButE2EEIntact
                               ? "send anyway (still encrypted)"
                               : "send unencrypted") {
                            generateBypassing()
                        }
                    }
                    Button("cancel", role: .cancel) { pendingRetryMessage = nil }
                } message: {
                    Text(e2eeAlertMessage)
                }
                .toolbar {
                    #if os(macOS)
                    // THE MAC'S ROUTE INTO THE PROOF, WHICH DID NOT EXIST.
                    //
                    // iOS puts this in the navigation title. A Mac window has no
                    // navigation title, so the whole trust ladder — the app's
                    // central claim — was unreachable on the platform even
                    // though the engine behind it was running.
                    //
                    // State only: the composer chip already carries the model
                    // name, and the same fact twice in one frame is noise.
                    ToolbarItem(placement: .navigation) {
                        MacTrustChip(
                            state: confidentialSession.attestationState,
                            isHardFailure: confidentialSession.degradeIsHardFailure,
                            unpublishedButSealed: confidentialSession.unpublishedOnlyButE2EEIntact,
                            provider: providerStore.activeProvider
                        ) { showTrustPopover.toggle() }
                        .popover(isPresented: $showTrustPopover,
                                 attachmentAnchor: .rect(.bounds),
                                 arrowEdge: .bottom) {
                            MacTrustPopover {
                                showTrustPopover = false
                                MacAttestationInspector.open(rung: .expert)
                            }
                        }
                    }
                    #endif
                    #if os(iOS) || os(visionOS)
                    if DeviceLayout.current == .phone {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                Haptics.play()
                                showChats.toggle()
                            } label: { Image(systemName: "list.bullet") }
                        }
                    }
                    #if os(iOS)
                    ToolbarItem(placement: .principal) {
                        E2EETitleBlock(
                            title: chatTitle,
                            state: confidentialSession.attestationState,
                            provider: providerStore.activeProvider,
                            // Surface the RED states the plain attestationState can't:
                            // a hard integrity break (sending blocked) and a reply
                            // signature mismatch — so the header never reads greener
                            // than the sheet's hero.
                            isHardFailure: confidentialSession.degradeIsHardFailure,
                            unpublishedButSealed: confidentialSession.unpublishedOnlyButE2EEIntact,
                            mismatchCount: confidentialSession.effectiveMismatchCount,
                            // The WhereChip above the composer owns the model
                            // name. Two copies on one screen was the cost of
                            // adding the chip; this is where it gets paid.
                            showsModel: false
                        )
                    }
                    #endif
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Haptics.play()
                            showSettings.toggle()
                        } label: { Image(systemName: "gear") }
                            .accessibilityIdentifier("chat.settings")
                    }
                    #elseif os(macOS)
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Haptics.play()
                            showSettings.toggle()
                        } label: { Label("settings", systemImage: "gear") }
                    }
                    #endif
                }
                // FRAME 6's trigger. Fires when the settings sheet CLOSES,
                // which is the moment the user is back in the thread and a key
                // either exists or does not.
                .onChange(of: showSettings) { _, isShown in
                    guard !isShown else { return }
                    runPendingSearchRetryIfReady()
                }
        }
    }

    /// Alert title per degrade mode — a hard integrity break is a blocked send,
    /// not merely "E2EE unavailable"; a provenance-only gap is about unverified
    /// code, not encryption.
    private var e2eeAlertTitle: String {
        if confidentialSession.degradeIsHardFailure { return "verification failed — sending blocked" }
        if confidentialSession.provenanceBlockedButE2EEIntact { return "couldn't verify the running code" }
        return "end-to-end encryption unavailable"
    }

    private var e2eeAlertMessage: String {
        if confidentialSession.provenanceBlockedButE2EEIntact {
            return "your message would still be sealed to the model's verified hardware key — but one running image on this server couldn't be verified as published code. re-verifying may reach a different server of this model."
        }
        let cause = confidentialSession.e2eeDegradedReason ?? "E2EE could not be established for this provider."
        // Hard break: name the cause AND state the policy — there is no bypass.
        if confidentialSession.degradeIsHardFailure {
            return "\(cause) Sending is blocked until this re-verifies — this could mean the enclave was tampered with or the connection intercepted."
        }
        return cause
    }

    private var arrivingModel: (model: LocalModel, fraction: Double?)? {
        guard let localID = providerStore.activeProvider?.localModelID,
              let model = LocalModelCatalog.model(id: localID),
              !LocalModelStorage.isInstalled(model) else { return nil }
        return (model, downloader.progress(localID))
    }

    private var arrival: ChatViewModel.Arrival? {
        if let phone = arrivingModel {
            return .init(
                name: phone.model.displayName.lowercased(),
                fraction: phone.fraction,
                kind: .phone
            )
        }
        guard let provider = providerStore.activeProvider,
              WhereLocality.of(provider) == .home,
              let base = provider.openAIBaseURL,
              let pull = pullCenter?.inProgress.first(where: {
                  $0.id == provider.model && $0.baseURL == base
              })
        else { return nil }
        return .init(
            name: provider.model,
            fraction: pull.fraction,
            kind: pull.fraction == nil ? .homeManifest : .home
        )
    }

    private var arrivingAnywhere: (name: String, fraction: Double?)? {
        arrival.map { ($0.name, $0.fraction) }
    }

    private var downloadingAlertMessage: String { arrival?.alertMessage ?? "" }

    /// FRAME 6. The user tapped "set it up", went and got a key, and came back.
    /// Re-ask the question that was waiting, so setup ends in the answer it
    /// promised rather than in the refusal that prompted it.
    ///
    /// Runs on the sheet CLOSING rather than on the key changing: the key is
    /// written on every keystroke while typing, and re-generating mid-paste
    /// would fire against a half-entered key.
    private func runPendingSearchRetryIfReady() {
        guard let pending = llm.pendingSearchRetry else { return }
        // Consumed either way. If they backed out without a key, the offer has
        // been dismissed and re-asking on some later, unrelated sheet close
        // would be a jump scare.
        llm.pendingSearchRetry = nil

        guard !settings.braveSearchKey.isEmpty, settings.braveGroundingEnabled,
              let thread = currentThread, thread.id == pending.threadID,
              let message = thread.sortedMessages.first(where: { $0.id == pending.userMessageID })
        else { return }

        retry(from: message)
    }

    private func generate() {
        presentSend(viewModel.prepareSend(
            hasProvider: providerStore.activeProvider != nil,
            isDownloading: arrival != nil,
            trust: confidentialSession.sendPolicy
        )) { performGenerate() }
    }

    /// Present the matching alert, or run `ready`.
    private func presentSend(_ prep: ChatViewModel.SendPrep, ready: () -> Void) {
        switch prep {
        case .blockedEmptyPrompt: return
        case .blockedNoProvider: showNoProviderAlert = true
        case .blockedDownloading: showDownloadingAlert = true
        case .confirmE2EE, .blockedE2EE: showE2EEDegradedAlert = true
        case .ready: ready()
        }
    }

    private func performGenerate() {
        viewModel.generate(
            currentThread: &currentThread,
            modelContext: modelContext,
            settings: settings,
            providers: providerStore,
            session: confidentialSession,
            llm: llm
        )
        isPromptFocused = false
    }

    /// The user chose to proceed from the degraded alert (soft degrades only —
    /// the hard-failure alert offers no bypass). Runs the pending retry if the
    /// alert was raised by one, else a fresh send.
    private func generateBypassing() {
        if let message = pendingRetryMessage {
            pendingRetryMessage = nil
            performRetry(from: message)
        } else {
            performGenerate()
        }
    }

    private func retryE2EEAndGenerate() {
        // C2: after a HARD integrity break, never auto-send when verification
        // "clears." refreshAttestation resets the async verdicts (recipe/DCAP/
        // NRAS/TLS) to nil, and attestationState reads pending as `.ok`, so
        // attestationOutcome can return before the failed check re-runs — a send
        // here would slip through in that window. Re-verify and require the user
        // to re-initiate against the SETTLED state.
        let wasHardBlock = confidentialSession.degradeIsHardFailure
        let pending = pendingRetryMessage
        e2eeRetrying = true
        confidentialSession.refreshAttestation()
        Task {
            await confidentialSession.attestationOutcome(waitingUpTo: .seconds(10))
            e2eeRetrying = false
            if wasHardBlock || confidentialSession.requiresE2EEConfirmation {
                // Still (or was) blocked → don't auto-send; surface the state.
                // Keep the pending retry so a subsequent confirm still targets it.
                pendingRetryMessage = pending
                showE2EEDegradedAlert = true
            } else if let message = pending {
                pendingRetryMessage = nil
                performRetry(from: message)
            } else {
                performGenerate()
            }
        }
    }

    /// C1: a message RETRY must pass the same send-gate as a fresh send — the
    /// message row must not be a hole that resends the whole thread into a
    /// compromised/unverified enclave.
    private func retry(from message: Message) {
        let prep = viewModel.prepareSend(
            hasProvider: providerStore.activeProvider != nil,
            isDownloading: arrival != nil,
            trust: confidentialSession.sendPolicy,
            requirePrompt: false
        )
        if prep == .confirmE2EE || prep == .blockedE2EE {
            pendingRetryMessage = message
        }
        presentSend(prep) { performRetry(from: message) }
    }

    private func performRetry(from message: Message) {
        viewModel.retry(
            from: message,
            currentThread: &currentThread,
            modelContext: modelContext,
            settings: settings,
            providers: providerStore,
            session: confidentialSession,
            llm: llm
        )
    }
}

#Preview("No Security") {
    @FocusState var isPromptFocused: Bool
    let store = ProviderStore()
    ChatView(currentThread: .constant(nil), isPromptFocused: $isPromptFocused, showChats: .constant(false), showSettings: .constant(false), showSettingsProviders: .constant(false), showSettingsSearch: .constant(false))
        .environment(AppSettings())
        .environment(store)
        .environment(ConfidentialSession(providers: store))
        .environment(ChatGeneration())
}

#Preview("Encrypted") {
    @FocusState var isPromptFocused: Bool
    let store: ProviderStore = {
        let s = ProviderStore()
        s.providers = [.nearAI]
        s.currentProviderID = Provider.nearAI.id.uuidString
        return s
    }()
    let session: ConfidentialSession = {
        let c = ConfidentialSession(providers: store)
        c.attestation = .preview
        c.lastRequestUsedE2EE = true
        return c
    }()
    ChatView(currentThread: .constant(nil), isPromptFocused: $isPromptFocused, showChats: .constant(false), showSettings: .constant(false), showSettingsProviders: .constant(false), showSettingsSearch: .constant(false))
        .environment(AppSettings())
        .environment(store)
        .environment(session)
        .environment(ChatGeneration())
}

#Preview("Loading") {
    @FocusState var isPromptFocused: Bool
    let store: ProviderStore = {
        let s = ProviderStore()
        s.providers = [.nearAI]
        s.currentProviderID = Provider.nearAI.id.uuidString
        return s
    }()
    ChatView(currentThread: .constant(nil), isPromptFocused: $isPromptFocused, showChats: .constant(false), showSettings: .constant(false), showSettingsProviders: .constant(false), showSettingsSearch: .constant(false))
        .environment(AppSettings())
        .environment(store)
        .environment(ConfidentialSession(providers: store))
        .environment(ChatGeneration())
}

#Preview("Degraded (no E2EE key)") {
    @FocusState var isPromptFocused: Bool
    let store: ProviderStore = {
        let s = ProviderStore()
        s.providers = [.nearAI]
        s.currentProviderID = Provider.nearAI.id.uuidString
        return s
    }()
    let session: ConfidentialSession = {
        let c = ConfidentialSession(providers: store)
        c.attestation = .previewDegraded
        return c
    }()
    ChatView(currentThread: .constant(nil), isPromptFocused: $isPromptFocused, showChats: .constant(false), showSettings: .constant(false), showSettingsProviders: .constant(false), showSettingsSearch: .constant(false))
        .environment(AppSettings())
        .environment(store)
        .environment(session)
        .environment(ChatGeneration())
}

/// Brave answers one question at a time (its API 422s on a second message), so
/// the composer says so once a conversation exists — otherwise a context-free
/// follow-up reads as the model losing the thread.
#Preview("Single-turn provider note") {
    @FocusState var isPromptFocused: Bool
    let store: ProviderStore = {
        let s = ProviderStore(inMemory: true)
        s.providers = [.braveAnswers]
        s.currentProviderID = Provider.braveAnswers.id.uuidString
        return s
    }()
    let thread: Thread = {
        let t = Thread()
        t.messages = [
            Message(role: .user, content: "what is the capital of france", thread: t),
            Message(role: .assistant, content: "**Paris** is the capital and most populous city of France.", thread: t),
        ]
        return t
    }()
    ChatView(currentThread: .constant(thread), isPromptFocused: $isPromptFocused,
             showChats: .constant(false), showSettings: .constant(false),
             showSettingsProviders: .constant(false), showSettingsSearch: .constant(false))
        .environment(AppSettings())
        .environment(store)
        .environment(ConfidentialSession(providers: store))
        .environment(ChatGeneration())
}

/// A conversation long enough to run off the bottom of the screen, so the edge
/// where the list meets the composer is actually visible. What to look for: text
/// passing this edge should blur into the glass, not stay crisp (which ghosts it
/// through the capsule) and not fade to black (which erases it). Claude iOS is
/// the reference: frost + a dim, text still faintly readable through the chrome.
/// Both fades, top and bottom, are intentional. Note the preview cannot raise a
/// keyboard — the stranded-line case this guards against only reproduces on device.
#Preview("Long answer (bottom edge)") {
    @FocusState var isPromptFocused: Bool
    let store: ProviderStore = {
        let s = ProviderStore(inMemory: true)
        s.providers = [.nearAI]
        s.currentProviderID = Provider.nearAI.id.uuidString
        return s
    }()
    let thread: Thread = {
        let t = Thread()
        t.messages = [
            Message(role: .user, content: "why does the list crash on refresh", thread: t),
            Message(role: .assistant, content: """
            The crash is a **nil unwrap**: the view caches its data source on first \
            load, the refresh path replaces the underlying array, and the cached \
            reference now points at a value that no longer exists.

            The fix is one line: read the source through the accessor on every load.

            **One important distinction:** the bug is in the *caching*, not the \
            refresh. The refresh is entitled to swap the array; a cache that assumes \
            otherwise is holding state it never owned. Patching the refresh instead \
            would paper over it and break again the next time anything else swaps \
            the array.

            Three places to check before calling it fixed:
            - the first load, which populates the cache
            - the refresh, which invalidates it
            - the empty state, which never had a cache at all

            The distinction matters because the two fixes fail differently. Patching \
            the refresh hides the crash until a new call site appears; fixing the \
            cache removes the stale reference entirely, so there is nothing left \
            to go stale.
            """, thread: t),
        ]
        return t
    }()
    ChatView(currentThread: .constant(thread), isPromptFocused: $isPromptFocused,
             showChats: .constant(false), showSettings: .constant(false),
             showSettingsProviders: .constant(false), showSettingsSearch: .constant(false))
        .environment(AppSettings())
        .environment(store)
        .environment(ConfidentialSession(providers: store))
        .environment(ChatGeneration())
}
