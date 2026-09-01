//
//  ContentView.swift
//  teemoon
//
//  Created by Jordan Singer on 10/4/24.
//

import SwiftData
import SwiftUI
import os

struct ContentView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProviderStore.self) private var providerStore
    @Environment(\.modelContext) var modelContext
    @Environment(ChatGeneration.self) var llm
    @State var showSettings = false
    @State var showSettingsProviders = false
    /// Set by the web-answers chip before it opens settings, so the sheet lands
    /// on search rather than on the settings index.
    @State var showSettingsSearch = false
    /// Medium for the settings index, large when we deep-link past it.
    ///
    /// A fixed `.medium` cut the search screen off at the api key field — its
    /// keychain footer, which says the key is not synced, was not on screen at
    /// all. The index is a short list and looks right at half height; anything
    /// reached by a deep link is a full screen of content and is not.
    @State var settingsDetent: PresentationDetent = .medium
    @State var showChats = false
    @State var currentThread: Thread?
    @FocusState var isPromptFocused: Bool
    /// The store-open failure banner: shown once at launch when the app is
    /// running on the in-memory fallback (see `TeemoonApp.storeOpenFailure`).
    @State private var showStoreFailure = TeemoonApp.storeOpenFailure != nil

    #if DEBUG
    /// Once-per-process guard for UI-test seeding — see the .task below.
    @MainActor static var didSeedForUITests = false

    static func seededCloudProvider(preset: String, env: [String: String]) -> Provider? {
        var seeded: Provider
        switch preset.lowercased() {
        case "nearai", "near.ai", "near":
            seeded = .nearAI
            if let model = env["UITEST_SEED_MODEL"] ?? env["UITEST_SEED_NEARAI_MODEL"] {
                seeded.model = model
            }
        case "grok", "xai":
            seeded = .grok
            if let model = env["UITEST_SEED_MODEL"] { seeded.model = model }
        case "fireworks":
            seeded = .fireworks
            if let model = env["UITEST_SEED_MODEL"] { seeded.model = model }
        case "brave", "braveanswers":
            seeded = .braveAnswers
        default:
            return nil
        }
        return seeded
    }
    #endif

    var body: some View {
        Group {
            if DeviceLayout.current == .pad || DeviceLayout.current == .mac || DeviceLayout.current == .vision {
                // iPad
                NavigationSplitView {
                    ChatsListView(currentThread: $currentThread, isPromptFocused: $isPromptFocused)
                    #if os(macOS)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 320)
                    #endif
                } detail: {
                    ChatView(currentThread: $currentThread, isPromptFocused: $isPromptFocused, showChats: $showChats, showSettings: $showSettings, showSettingsProviders: $showSettingsProviders, showSettingsSearch: $showSettingsSearch)
                }
            } else {
                // iPhone
                ChatView(currentThread: $currentThread, isPromptFocused: $isPromptFocused, showChats: $showChats, showSettings: $showSettings, showSettingsProviders: $showSettingsProviders, showSettingsSearch: $showSettingsSearch)
            }
        }
        .environment(llm)
        #if os(macOS)
        // File ▸ New Chat. Same effect as the sidebar's "+": drop the current
        // thread so the next message starts a fresh one, and put the caret in
        // the composer — a menu command that left focus elsewhere would make the
        // user click before typing, which is exactly what ⌘N exists to avoid.
        .onReceive(NotificationCenter.default.publisher(for: .teemoonNewChat)) { _ in
            currentThread = nil
            isPromptFocused = true
        }
        #endif
        .alert("couldn't open your conversations", isPresented: $showStoreFailure) {
            Button("ok", role: .cancel) {}
        } message: {
            Text("your chat history is still on this device — nothing was deleted — "
                + "but this build couldn't open it, so it is running without "
                + "history. error: \(TeemoonApp.storeOpenFailure ?? "unknown")")
        }
        .task {
            let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")
            // The chat index reconciles here and not from a hook, because the
            // reconciler is what makes hooks optional: Siri appends, a crash
            // mid-write, or an older build all leave the index stale, and a full
            // rebuild of the reference store costs 0.23 s.
            // Configure HERE and not during container creation: that is a lazy
            // static initialiser, and hopping to the main actor from inside one
            // deadlocks if a background thread got there first. This closure is
            // already main-actor, and a UI-test run leaves `storeURL` nil so no
            // sidecar is created at all.
            if let storeURL = TeemoonApp.conversationStoreURL, !isUITesting {
                ChatSearchService.shared.configure(storeURL: storeURL,
                                                   isStoredInMemoryOnly: false)
            }
            await ChatSearchService.shared.reconcile(in: modelContext)
            // Re-harden AFTER reconcile, never before: the sqlite is created
            // lazily by the first index write, so on the sidecar's first launch
            // an earlier reharden finds no file and no-ops — shipping a session
            // of plaintext history into backups before the second launch.
            ChatSearchService.shared.rehardenIfNeeded()
            #if DEBUG
            // UI-test seeding: boot straight into a configured near.ai provider
            // so end-to-end tests can drive the real attestation flow without
            // onboarding. DEBUG-only, gated on --uitesting.
            if isUITesting,
               !Self.didSeedForUITests {
                let env = ProcessInfo.processInfo.environment
                let presetName = env["UITEST_SEED_PRESET"]
                    ?? (env["UITEST_SEED_NEARAI_MODEL"] != nil ? "nearai" : nil)
                if let presetName,
                   let seeded = Self.seededCloudProvider(preset: presetName, env: env) {
                    // Authoritative in test mode: replace whatever a previous
                    // simulator run persisted, so every test starts from its own
                    // declared state. Once per process — .task can re-fire on
                    // appearance changes (e.g. after a sheet dismisses), and
                    // re-seeding mid-test would silently revert edits the test
                    // itself made (observed: a saved model change snapped back).
                    Self.didSeedForUITests = true
                    os_log(.error, "[uitest] seeding %{public}@ model=%{public}@",
                           presetName, seeded.model)
                    providerStore.providers.removeAll()
                    providerStore.addProvider(seeded)
                    providerStore.currentProviderID = seeded.id.uuidString
                    // Key from a host file the runner staged (or a path-only
                    // home env), never from a process-environment secret.
                    // Overwrite so a stale Keychain slot cannot 401.
                    os_log(.error,
                           "[uitest] key lookup preset=%{public}@ staged=%{public}@ teemoonHome=%{public}@ simHome=%{public}@",
                           presetName,
                           UITestHostSecrets.stagedKeysDirectory ?? "nil",
                           UITestHostSecrets.teemoonHostHome ?? "nil",
                           UITestHostSecrets.simulatorHostHome ?? "nil")
                    if let fromFile = UITestHostSecrets.keyFromHostFile(preset: presetName) {
                        do {
                            try providerStore.setCredential(fromFile, forEndpoint: seeded.endpoint,
                                                            legacyID: seeded.id)
                            os_log(.error, "[uitest] seeded %{public}@ key from host file", presetName)
                        } catch {
                            os_log(.error, "[uitest] could not write %{public}@ key from host file", presetName)
                        }
                    } else {
                        os_log(.error, "[uitest] no host-file key for %{public}@", presetName)
                    }
                }
            }
            // The same door for a LOCAL provider, so the self-hosted surfaces —
            // the machine glyph, "on your own machine", the trust sheet that
            // replaces the ladder — can be driven without hand-entering an
            // endpoint. Keyless and non-attested, exactly as a user's would be.
            if isUITesting,
               !Self.didSeedForUITests,
               let endpoint = ProcessInfo.processInfo.environment["UITEST_SEED_LOCAL_ENDPOINT"] {
                Self.didSeedForUITests = true
                let model = ProcessInfo.processInfo.environment["UITEST_SEED_LOCAL_MODEL"] ?? "local-model"
                os_log(.error, "[uitest] seeding LOCAL provider endpoint=%{public}@ model=%{public}@",
                       endpoint, model)
                var seeded = Provider(name: "local", endpoint: endpoint, model: model,
                                      requiresAPIKey: false)
                // A second equipped model on the same endpoint, so Where has two
                // rows a test can switch between without a second server.
                if let other = ProcessInfo.processInfo.environment["UITEST_SEED_LOCAL_MODEL_B"],
                   !other.isEmpty {
                    seeded.equippedModels = [model, other]
                }
                providerStore.providers.removeAll()
                providerStore.addProvider(seeded)
                providerStore.currentProviderID = seeded.id.uuidString
            }
            // And the same door for an ON-DEVICE provider (MLX), so a UI test can
            // drive real local inference — including the tool round — without
            // tapping through Settings to download and select a model. The
            // weights must already be present; the test skips if they are not.
            if isUITesting,
               !Self.didSeedForUITests,
               let repoID = ProcessInfo.processInfo.environment["UITEST_SEED_ONDEVICE_MODEL"] {
                Self.didSeedForUITests = true
                os_log(.error, "[uitest] seeding ON-DEVICE provider model=%{public}@", repoID)
                // Catalog entries only: a model now carries a pinned revision
                // and checksum, so there is nothing sensible to invent for a
                // repo id that is not in the catalog.
                if let catalogEntry = LocalModelCatalog.model(id: repoID) {
                    let seeded = Provider.local(catalogEntry)
                    providerStore.providers.removeAll()
                    providerStore.addProvider(seeded)
                    providerStore.currentProviderID = seeded.id.uuidString
                } else {
                    os_log(.error, "[uitest] %{public}@ is not in the catalog — not seeding", repoID)
                }
            }
            // Grounding is a separate Keychain slot (`brave-grounding`), not a
            // provider credential. Opt-in so ordinary Product E2E does not
            // flip the sim's web-search switch.
            if isUITesting,
               ProcessInfo.processInfo.environment["UITEST_SEED_GROUNDING"] == "1" {
                if let key = UITestHostSecrets.braveGroundingKeyFromHostFile() {
                    do {
                        try settings.connectBraveGrounding(apiKey: key)
                        os_log(.error, "[uitest] seeded brave grounding key from host file")
                    } catch {
                        os_log(.error, "[uitest] could not write brave grounding key")
                    }
                } else {
                    os_log(.error, "[uitest] no host-file brave grounding key")
                }
            }
            #endif
            // No first-run gate. An empty provider list is an ordinary state
            // now: the composer works, the Where chip says "choose where", and
            // the sheet behind it leads with a free on-device model.
            //
            // What used to be here presented a five-screen flow as a
            // fullScreenCover with `interactiveDismissDisabled` while nothing
            // was configured — so a new user could not look at the app before
            // committing to a vendor signup. For an audience that chose teemoon
            // over walled gardens, that was the wrong first impression, and it
            // was also the only surface still teaching near.ai-then-brave as
            // the shape of the product.
            // Focus the composer ONLY if something can answer.
            //
            // With no provider, the composer cannot send — so raising the
            // keyboard covers the bottom half of a screen whose only affordance
            // is the chip above it, and then has to dismiss again the moment the
            // user taps that chip. That produced the keyboard sliding down while
            // the Where sheet slid up: two vertical animations in opposite
            // directions, in the same region, for no reason.
            isPromptFocused = !providerStore.providers.isEmpty
        }
        .gesture(DeviceLayout.current == .phone ?
            DragGesture()
                .onChanged { gesture in
                    if !showChats && gesture.startLocation.x < 20 && gesture.translation.width > 100 {
                        Haptics.play()
                        showChats = true
                    }
                }
            : nil
        )
        .sheet(isPresented: $showChats, onDismiss: {
            // Only auto-focus for new empty threads — existing conversations
            // don't warrant assuming the user wants to type immediately.
            if currentThread?.messages.isEmpty != false { isPromptFocused = true }
        }) {
            ChatsListView(currentThread: $currentThread, isPromptFocused: $isPromptFocused)
                // Same reason as the settings sheet below: the composer chips
                // are directly behind every sheet this app presents, and the
                // default material is translucent enough to show them.
                .presentationBackground(PlatformColors.background)
                .presentationDragIndicator(.visible)
                .presentationDetents(DeviceLayout.current == .phone ? [.medium, .large] : [.large])
        }
        .onChange(of: showChats) { _, isShowing in
            // Resign focus when the sheet opens so iOS doesn't automatically
            // restore the TextField as first responder during the dismiss animation.
            if isShowing { isPromptFocused = false }
        }
        .onChange(of: showSettings) { _, isShown in
            // Read BEFORE SettingsView consumes the flags in its onAppear. The
            // deep-link bindings are set by the caller immediately before
            // `showSettings`, so they are already true by the time this fires.
            guard isShown else { return }
            settingsDetent = (showSettingsSearch || showSettingsProviders) ? .large : .medium
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(currentThread: $currentThread, openToProviders: $showSettingsProviders,
                         openToSearch: $showSettingsSearch)
                .environment(llm)
                // OPAQUE. The default sheet material is translucent, and the
                // composer chips sat right behind this one — the Where chip
                // bled through as an orange smear across "places & keys" and
                // the web chip showed at the bottom edge. Exactly the bug
                // WhereSheetView already fixed this way; settings never got it.
                .presentationBackground(PlatformColors.background)
                .presentationDragIndicator(.hidden)
                // Both detents offered on phone, so a user who lands on the
                // index can still drag up — the selection just picks the right
                // starting height.
                .presentationDetents(DeviceLayout.current == .phone
                                     ? [.medium, .large] : [.large],
                                     selection: $settingsDetent)
        }
        #if !os(visionOS)
        .tint(settings.appTintColor.getColor())
        #endif
        .fontDesign(settings.appFontDesign.getFontDesign())
        .environment(\.dynamicTypeSize, settings.appFontSize.getFontSize())
        .fontWidth(settings.appFontWidth.getFontWidth())
        .onAppear {
            settings.incrementNumberOfVisits()
        }
    }
}


#Preview {
    ContentView()
}
