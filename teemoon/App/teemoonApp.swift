//
//  teemoonApp.swift
//  teemoon
//
//  Created by Jordan Singer on 10/4/24.
//

import SwiftData
import SwiftUI
import os.log

@main
struct TeemoonApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    @State private var appSettings: AppSettings
    @State private var providerStore: ProviderStore
    @State private var confidentialSession: ConfidentialSession
    @State private var llm: ChatGeneration
    @State private var downloadCenter = OllamaDownloadCenter()

    init() {
        #if DEBUG
        // Armed by -scrollTrace, like the traces. When the main thread stops
        // answering, this writes its actual stacks to Documents/hangstacks.log
        // — the instrument that ends "reproduces under a thumb, never under
        // XCUI". See MainThreadHangReporter.
        // SIGPROF from the watchdog has crashed UI-test launches
        // (recursive unfair-lock abort in Swift metadata init). The
        // reporter exists for device hangs, not XCUI.
        if !ProcessInfo.processInfo.arguments.contains("--uitesting") {
            MainThreadHangReporter.startIfRequested()
        }
        // A harness must be able to wear the user's configuration: the
        // developer-mode debug panel changes the hand-off layout, and a gate
        // that runs with it OFF verifies a different app than the phone runs.
        if ProcessInfo.processInfo.arguments.contains("--uitesting"),
           ProcessInfo.processInfo.environment["UITEST_DEVELOPER_MODE"] == "1" {
            UserDefaults.standard.set(true, forKey: "developerModeEnabled")
        }
        #endif
        let settings = AppSettings()
        // A UI TEST MUST NOT TOUCH REAL PROVIDERS EITHER: test seeding calls
        // `providers.removeAll()`, whose didSet saves — run against a real
        // config it REPLACES it. In-memory under --uitesting, DEBUG-only.
        // The incident and its pins live in `UITestIsolationTests`.
        let store = ProviderStore(inMemory: Self.usesEphemeralProviderStore())
        let session = ConfidentialSession(providers: store)
        // Re-attest whenever the active provider changes, without ProviderStore
        // depending on the attestation layer.
        store.onActiveProviderChanged = { [weak session] provider in
            session?.refreshAttestation()
            // Picking a model is the earliest honest signal that it is about to be
            // used, and a cold self-hosted model costs ~11s to load. Start that now
            // so it overlaps with the user typing their message instead of landing
            // on the first token. No-op for cloud and on-device providers.
            OllamaAdapter.warmUp(for: provider)
        }
        // "Recently used" means used — stamped when a model first produces
        // output, not when it is picked in the Where sheet. Same shape as the
        // hook above: ChatGeneration stays unaware of where the fact lands.
        //
        // ONE writer now. This called `WhereRecentsStore.shared.record` as well,
        // into a second UserDefaults blob of the same event; §2.6 collapsed the
        // pair into `EquippedModel.lastUsedAt`, which the sheet reads directly.
        let generation = ChatGeneration()
        generation.onFirstToken = { [weak store] provider in
            store?.recordUse(of: provider)
        }
        // A finished download becomes something you can run, with no second
        // "use" tap: the Where sheet starts the download in the `get` list and
        // the model appears under `ready now` when it lands.
        LocalModelDownloader.shared.onInstalled = { [weak store] model in
            guard let store else { return }
            guard !store.providers.contains(where: { $0.localModelID == model.id }) else { return }
            store.addProvider(.local(model))
        }
        _appSettings = State(initialValue: settings)
        _providerStore = State(initialValue: store)
        _confidentialSession = State(initialValue: session)
        _llm = State(initialValue: generation)
    }

    let sharedModelContainer: ModelContainer = {
        // SavedPlace was excised 2026-08-30 (feature parked on
        // archive/saved-places; restore = revert that commit). Dropping the
        // empty standalone table is the schema shape the wiki experiment
        // device-verified as a safe lightweight migration (2026-08-21).
        let schema = Schema([Thread.self, Message.self])

        // A UI TEST MUST NOT SEE, OR TOUCH, REAL CONVERSATIONS: in-memory
        // under --uitesting, DEBUG-only and flag-gated, so no real launch can
        // silently run without persistence. Pinned by `UITestIsolationTests`.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            // REAL CONTENT, SANDBOXED. `UITEST_COPY_REAL_STORE=1` copies the
            // app's own store into tmp and opens THE COPY — a UI test drives
            // the user's actual conversations (the content that matters)
            // while every write lands in a file that evaporates. Exists
            // because a full day of synthetic seeds failed to reproduce
            // freezes that real threads hit in seconds (2026-08-07). The
            // real store is read for the copy and never opened by the test.
            if ProcessInfo.processInfo.environment["UITEST_COPY_REAL_STORE"] == "1" {
                do {
                    let fm = FileManager.default
                    let realDir = URL.applicationSupportDirectory
                    let tmpDir = fm.temporaryDirectory.appending(path: "uitest-store")
                    try? fm.removeItem(at: tmpDir)
                    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                    for suffix in ["", "-shm", "-wal"] {
                        let src = realDir.appending(path: "default.store" + suffix)
                        if fm.fileExists(atPath: src.path) {
                            try fm.copyItem(at: src, to: tmpDir.appending(path: "default.store" + suffix))
                        }
                    }
                    let copy = ModelConfiguration(url: tmpDir.appending(path: "default.store"))
                    return try ModelContainer(for: schema, configurations: [copy])
                } catch {
                    fatalError("Could not copy the real store for a UI test: \(error)")
                }
            }
            let ephemeral = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                let container = try ModelContainer(for: schema, configurations: ephemeral)
                UITestStoreSeeding.seedFixtureThreadsIfRequested(into: container)
                return container
            } catch {
                fatalError("Could not create in-memory ModelContainer: \(error)")
            }
        }
        #endif

        // Keep the default store location so existing conversations aren't orphaned.
        let configuration = ModelConfiguration(schema: schema)
        let container: ModelContainer
        do {
            // Opened THROUGH the migration plan (SchemaVersioning.swift):
            // every future schema change is a versioned stage, not a leap of
            // faith. SchemaMigrationFixtureTests pins that pre-plan stores
            // open here unchanged.
            container = try ModelContainer(
                for: Schema(versionedSchema: TeemoonSchemaV1.self),
                migrationPlan: TeemoonMigrationPlan.self,
                configurations: configuration)
        } catch {
            // THE STORE IS NEVER THE CASUALTY OF AN OPEN FAILURE. This path
            // used to fatalError — an unmigratable store crash-looped the app
            // until a reinstall wiped every conversation. Now the file stays
            // untouched on disk, the app boots on an empty in-memory
            // container, and ContentView says so (storeOpenFailure).
            // conversationStoreURL stays nil on this path: no search sidecar
            // gets built beside a store we could not open.
            TeemoonApp.storeOpenFailure = String(describing: error)
            Logger(subsystem: "ai.teemoon", category: "store")
                .fault("store open FAILED, running in-memory: \(String(describing: error), privacy: .public)")
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: fallback)
            } catch {
                fatalError("Could not create even the in-memory fallback: \(error)")
            }
        }
        // Conversation content (every user + assistant message) lives in this
        // store. Keep it out of iCloud/iTunes backups and encrypt it at rest so
        // chat history can't be recovered from a device backup or a lost/locked
        // device.
        TeemoonApp.hardenConversationStore(at: configuration.url)
        // The URL is recorded, NOT used to build the search index here.
        //
        // This is a lazy `static let`: its initialiser runs on whichever thread
        // touches it first, so hopping to the main actor from inside it — which
        // is what an earlier version did, via `MainActor.assumeIsolated` —
        // deadlocks whenever that first touch is a background thread already
        // waiting on the main one. It hung `UITestIsolationTests` indefinitely.
        // `ChatSearchService` is configured from ContentView's `.task`, which is
        // on the main actor by construction and cannot deadlock here.
        TeemoonApp.conversationStoreURL = configuration.url
        return container
    }()

    /// Whether the provider config should be ephemeral for this launch.
    ///
    /// True only for a DEBUG build running under `--uitesting`. Kept as a named
    /// function rather than inlined so the rule can be tested — see
    /// `UITestIsolationTests`, which is the regression that stops this being
    /// re-broken by someone adding a launch flag.
    static func usesEphemeralProviderStore(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        #if DEBUG
        return arguments.contains("--uitesting")
        #else
        return false
        #endif
    }

    /// Excludes the SwiftData store (and its SQLite `-wal`/`-shm` sidecars) from
    /// device backups and sets at-rest file protection.
    ///
    /// macOS IS INCLUDED, which it was not before. The protection call was gated
    /// to iOS/visionOS on the assumption that data-protection classes are an iOS
    /// concept. They are not: on an Apple Silicon Mac the class is honoured, and
    /// the default a file gets is `.completeUntilFirstUserAuthentication` —
    /// readable from the moment the user first unlocks after boot until
    /// shutdown. Measured, not assumed: setting `.completeUnlessOpen` on macOS
    /// succeeds and reads back as `.completeUnlessOpen`.
    ///
    /// So the Mac was silently the weakest platform for chat history at rest,
    /// and closing that costs one `#if` term.
    ///
    /// Uses `.completeUnlessOpen` — deliberately *not* `.complete`. The store stays
    /// open for the app's lifetime; `.complete` would make it unreadable the moment
    /// the device locks (e.g. mid-stream while a reply is arriving), crashing
    /// SwiftData. `.completeUnlessOpen` still encrypts the file at rest once it is
    /// closed, without that availability risk. Re-run on every launch so sidecars
    /// created since last launch are covered.
    /// Where the conversation store ended up, for anything that needs to sit
    /// beside it (the search sidecar). Written once during container creation.
    nonisolated(unsafe) static var conversationStoreURL: URL?

    /// Non-nil when the persistent store could not be opened and the app is
    /// running on the empty in-memory fallback. The store file itself is
    /// untouched on disk. Written once during container creation.
    nonisolated(unsafe) static var storeOpenFailure: String?

    static func hardenConversationStore(at storeURL: URL) {
        let sidecars = ["-wal", "-shm"].map { URL(fileURLWithPath: storeURL.path + $0) }
        for url in [storeURL] + sidecars {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableURL.setResourceValues(values)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: url.path
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            // DesignTour must NOT inherit the live `confidentialSession` /
            // `providerStore`. Those were applied outside the tour branch and
            // overwrote the fixture session (previewSession's GLM-5.1 AWQ/FP8
            // quant-drift), so captures showed whatever the seeded sim had —
            // e.g. live GLM-5.2 with "sending paused" — instead of the fixture.
            #if DEBUG && os(iOS)
            if let tour = DesignTour.current {
                // Fixture environments only — see comment above.
                tour.view
                    .modelContainer(sharedModelContainer)
                    .environment(appSettings)
                    .environment(downloadCenter)
            } else {
                ContentView()
                    .modelContainer(sharedModelContainer)
                    .environment(appSettings)
                    .environment(providerStore)
                    .environment(confidentialSession)
                    .environment(llm)
                    .environment(downloadCenter)
                    .task { Self.runResidentMaintenance() }
            }
            #else
            ContentView()
                .modelContainer(sharedModelContainer)
                .environment(appSettings)
                .environment(providerStore)
                .environment(confidentialSession)
                .environment(llm)
                .environment(downloadCenter)
                #if os(iOS)
                .task { Self.runResidentMaintenance() }
                #endif
                // No global pinned banner — it blocked the nav bar. In-flight pulls
                // surface as a disabled row in the provider's model list instead.
                #if os(macOS) || os(visionOS)
                .frame(minWidth: 640, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                #if os(macOS)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                }
                #endif
                #endif
            #endif
        }
        #if os(visionOS)
        .windowResizability(.contentSize)
        #endif
        #if os(macOS)
        .defaultSize(width: 1000, height: 640)
        #endif
        #if os(macOS)
        .commands {
            // FILE ▸ NEW CHAT, in the slot it belongs in.
            //
            // This group previously REPLACED `.newItem` with "Show Main Window",
            // which had two costs. The File menu lost New entirely — and an empty
            // File menu is the single fastest way a Mac app reads as an iPad port
            // — while "Show Main Window", which is a window command, sat in the
            // File menu where nobody looks for it.
            //
            // ⌘N was not broken before, but it was only reachable through the
            // sidebar's toolbar button, so it worked only while that view held the
            // responder chain. A menu command works from anywhere in the app,
            // which is what a keyboard shortcut is supposed to mean.
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    NotificationCenter.default.post(name: .teemoonNewChat, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            // ⌘F — FIND, WHICH DID NOTHING AT ALL.
            //
            // The sidebar has a search field and no keyboard route to it: ⌘F was
            // unbound, so the reflex every Mac user has for "filter this list"
            // typed into whatever had focus. Measured, not assumed — a test
            // pressed ⌘F, typed, and found the text nowhere near search.
            //
            // Placed after `.textEditing`, which is where Find lives in a Mac
            // Edit menu.
            CommandGroup(after: .textEditing) {
                Button("find") {
                    NotificationCenter.default.post(name: .teemoonFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            // HELP ▸ SOMETHING THAT EXISTS.
            //
            // AppKit adds "<App> Help" to the Help menu whether or not there is
            // a help book. teemoon's Info.plist has no `CFBundleHelpBookName`,
            // so that item opened Help Viewer onto "Help isn't available for
            // teemoon.ai" — a dead end the app was advertising in its own menu
            // bar, and worse than having no item, because the user has to go
            // find out it is empty.
            //
            // Replaced with the place the documentation actually lives. No help
            // book is being invented here: pointing at the repository is honest
            // about where the answers are.
            CommandGroup(replacing: .help) {
                Button("teemoon on GitHub") {
                    if let url = URL(string: "https://github.com/teemoonai/teemoon-ios") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            // ⌘I ▸ WHO CAN READ THIS?
            //
            // A Mac feature reachable only by clicking a 22pt toolbar chip is
            // not finished. The Window scene above owns the shortcut; this is
            // the discoverable route to the same thing.
            CommandGroup(after: .toolbar) {
                Button("who can read this?") {
                    MacAttestationInspector.open()
                }
                .keyboardShortcut("i", modifiers: .command)
                Divider()
            }
            // VIEW ▸ HIDE SIDEBAR, because View had exactly one item in it.
            //
            // Measured from the menu-bar transcript: View contained only "Enter
            // Full Screen", which AppKit supplies for free — so the app had
            // contributed nothing to it. Every Mac app with a sidebar puts the
            // toggle here on ⌃⌘S (Notes, Mail, Music, Finder), and teemoon's
            // sidebar could only be collapsed by hitting the toolbar button.
            //
            // `toggleSidebar:` is the responder-chain action NavigationSplitView
            // already implements, so this adds the menu route to existing
            // behaviour rather than a second implementation of it.
            CommandGroup(after: .sidebar) {
                // `NSApp.sendAction(to: nil)` and not
                // `keyWindow?.firstResponder?.tryToPerform(...)`. The first
                // version compiled, put the item in the menu, and did nothing:
                // while a menu is closing there is no key window, so the chain
                // it walked started from nil. Passing `to: nil` lets AppKit find
                // the responder that implements the action — the same one the
                // toolbar's own sidebar button reaches.
                Button("hide sidebar") {
                    NSApp.sendAction(
                        #selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
            // ...and "Show Main Window" moves to the Window menu, next to the
            // other window commands.
            CommandGroup(after: .windowArrangement) {
                Button("Show Main Window") {
                    if let mainWindow = NSApp.windows.first {
                        mainWindow.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
        #endif

        #if os(macOS)
        // THE ATTESTATION INSPECTOR — a Window, not a WindowGroup.
        //
        // `Window` gives exactly one instance. That is the design: attestation
        // varies by model, not by thread, so one inspector that follows the
        // frontmost conversation beats n windows for n threads on one model.
        Window("who can read this?", id: MacAttestationInspector.windowID) {
            MacAttestationInspectorView()
                .modelContainer(sharedModelContainer)
                .environment(appSettings)
                .environment(providerStore)
                .environment(confidentialSession)
                .environment(llm)
                .environment(downloadCenter)
        }
        .keyboardShortcut("i", modifiers: .command)
        #endif

        // ⌘, — THE SETTINGS SCENE.
        //
        // On iOS settings is a sheet, which is correct there. On macOS a sheet is
        // the wrong container and, more concretely, ⌘, did nothing: the standard
        // Settings item only appears in the app menu when a `Settings` scene
        // exists. Every Mac user tries ⌘, first.
        //
        // Takes the same environment as the main window — a scene does not
        // inherit it, and SettingsView reads AppSettings, ProviderStore and
        // ChatGeneration.
        #if os(macOS)
        Settings {
            // MacSettingsView, not SettingsView — the phone screen pushed rows
            // and carried its own "close" button next to the window's real one.
            // See the header of MacSettingsView.swift.
            MacSettingsView(
                // `currentThread` is write-only here, and the write matters:
                // "delete all chats" sets it to nil so the chat view stops
                // showing a thread that no longer exists. A Settings scene has no
                // access to ContentView's state, and `.constant(nil)` would drop
                // that reset on the floor — leaving the main window displaying a
                // deleted Thread. Forwarding it as the same new-chat signal keeps
                // the two windows consistent.
                currentThread: Binding(
                    get: { nil },
                    set: { if $0 == nil {
                        NotificationCenter.default.post(name: .teemoonNewChat, object: nil)
                    } }
                ),
                // Deep-link intents, set by chips in the chat UI to open settings
                // ON a specific page. Opening Settings directly has no such
                // intent, so it lands on the index.
                openToProviders: .constant(false),
                openToSearch: .constant(false)
            )
                .modelContainer(sharedModelContainer)
                .environment(appSettings)
                .environment(providerStore)
                .environment(confidentialSession)
                .environment(llm)
                .environment(downloadCenter)
                // No .frame here. MacSettingsView sizes each tab itself, and a
                // second frame out here fought it: the window stayed at this
                // 480 while the tab asked for 460, leaving a band of dead space
                // no amount of tuning inside the tab could remove.
        }
        #endif
    }

    #if os(iOS)
    /// On-device weight reclamation — only for normal launches, not DesignTour.
    private static func runResidentMaintenance() {
        LocalMemoryPressure.startObserving()
        LocalModelStorage.reclaimRetiredMLXWeights()
        LocalModelStorage.reclaimUncatalogedBundles()
    }
    #endif
}

extension Notification.Name {
    /// Posted by File ▸ New Chat (Mac) and the chats-list + (iOS). A
    /// notification rather than a binding because the command / button does
    /// not own ChatView's draft.
    static let teemoonNewChat = Notification.Name("ai.teemoon.newChat")

    #if os(macOS)
    /// Posted by Edit ▸ find (⌘F). Same reason as above: the command lives in
    /// the `App` scene, which has no path to the sidebar's focus state.
    static let teemoonFocusSearch = Notification.Name("ai.teemoon.focusSearch")
    #endif
}

#if os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var closedWindowsStack = [NSWindow]()
    private var becameMainObserver: (any NSObjectProtocol)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // TEEMOON IS A DARK APP, AND macOS HAS TO BE TOLD SEPARATELY.
        //
        // Info.plist sets `UIUserInterfaceStyle: Dark`, and the comment there is
        // emphatic about why: light mode "was never designed, only inherited" —
        // the ML tokens are black-first, every design card is drawn dark, and the
        // default `monochrome` tint resolves to BLACK, which turned the Where chip
        // into the heaviest object on the screen and bled through translucent
        // sheets as a smudge.
        //
        // `UIUserInterfaceStyle` is a UIKit key. macOS ignores it completely, so
        // until now a Mac in light appearance rendered the exact combination the
        // design explicitly rejected — and nothing failed, because there is no
        // error state for "looks wrong."
        //
        // Set on NSApp rather than per-window so system-supplied UI follows too:
        // alerts, the open panel, menus, the appearance of sheets teemoon does not
        // own. That is the same reason iOS sets it in Info.plist instead of using
        // `.preferredColorScheme`.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // TRACK THE CONTENT WINDOW, WHENEVER IT SHOWS UP.
        //
        // This was `NSApp.windows.first?.delegate = self`, which quietly depended
        // on how the process was started. Measured at this point: launched by
        // LaunchServices the app already owns 1 window and it is the content
        // window, so this worked; launched by a direct `exec` it owns 0 and the
        // assignment was a no-op, so `windowWillClose` never fired and the
        // reopen-restore below could never run.
        //
        // With `presentInitialWindow()` the window now always arrives *after*
        // this callback, so waiting for it is the only correct time. The first
        // window to become main is the content window.
        becameMainObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            window.delegate = self
            if let becameMainObserver {
                NotificationCenter.default.removeObserver(becameMainObserver)
                self.becameMainObserver = nil
            }
        }

        presentInitialWindow()
    }

    /// THE FIRST WINDOW IS CREATED BY AN APPLE EVENT, NOT BY LAUNCHING.
    ///
    /// AppKit creates a `WindowGroup`'s initial window in response to the
    /// LaunchServices open/reopen Apple Event, not as part of process startup. A
    /// process that is `exec`'d directly never receives that event — and XCUITest
    /// launches macOS apps by exec'ing the binary. So under test the app came up
    /// with a menu bar, five AppKit-owned windows, and no content window at all:
    /// never created, not merely invisible to accessibility.
    ///
    /// Established by elimination — a direct exec produces no window with or
    /// without `--uitesting`, with the sandbox disabled, and after an explicit
    /// `NSRunningApplication.activate` (which raises the menu bars and nothing
    /// else). Then `open -a` against that *same already-running process*, which
    /// changes nothing but deliver the event, produces the window immediately.
    ///
    /// So the fix is to send that event to ourselves. This is the same event
    /// LaunchServices sends, dispatched through the same path, which is why it
    /// lands on the same AppKit default that creates the window.
    ///
    /// Unconditional and idempotent on purpose. It is tempting to first check
    /// "do I have a content window?", but that means guessing which of AppKit's
    /// windows counts as content — the guess this method exists to remove. A
    /// second reopen with a window already on screen is a no-op: AppKit's default
    /// with visible windows only unhides and activates. At launch nothing has
    /// been closed or minimized yet, so `applicationShouldHandleReopen` below
    /// takes neither restore path and defers to that default.
    private func presentInitialWindow() {
        let reopen = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        guard let event = reopen.aeDesc else { return }
        // No reply: the event is queued and dispatched on the main run loop,
        // after this launch callback returns. Waiting for a reply from ourselves
        // would deadlock.
        let status = AESendMessage(event, nil, AESendMode(kAENoReply), kAEDefaultTimeout)
        if status != noErr {
            Logger(subsystem: "ai.teemoon", category: "app")
                .error("reopen event to self failed: \(status)")
        }
    }

    /// THE RETURN VALUE IS A CLAIM, AND IT USED TO BE A FALSE ONE.
    ///
    /// `false` means "I have handled this, AppKit do nothing." This method
    /// returned `false` unconditionally — including down the path where it did
    /// nothing at all. With no closed window to restore and nothing minimized,
    /// teemoon told AppKit to stand down and then stood down itself, so the
    /// default behaviour that creates a window for a `WindowGroup` never ran.
    ///
    /// The symptom was that clicking the Dock icon with no windows open did
    /// nothing. This was also suspected of causing the empty XCUITest launch, and
    /// it did not — that is `presentInitialWindow()` above, and the two were only
    /// ever related by both involving this event.
    ///
    /// Now it only claims to have handled the event when it actually did.
    ///
    /// NOT COVERED BY A UI TEST, AND THAT IS A HARNESS LIMIT, NOT AN OVERSIGHT.
    /// A test for this would close the last window and then do what the Dock icon
    /// does. `XCUIApplication.activate()` is not that: instrumenting this method
    /// showed exactly one reopen event across a full run — the launch one — and
    /// none after `activate()`. So XCUITest cannot deliver the event this method
    /// exists to answer, and a test built on it would assert the harness.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // if there’s a recently closed window, bring that back
        if let lastClosed = closedWindowsStack.popLast() {
            lastClosed.makeKeyAndOrderFront(self)
            return false
        }

        // otherwise, un-minimize any minimized windows
        let miniaturized = sender.windows.filter(\.isMiniaturized)
        if !miniaturized.isEmpty {
            miniaturized.forEach { $0.deminiaturize(nil) }
            return false
        }

        // Nothing to restore, so nothing was handled: let AppKit do its default,
        // which is to present a window.
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            closedWindowsStack.append(window)
        }
    }
}
#endif
