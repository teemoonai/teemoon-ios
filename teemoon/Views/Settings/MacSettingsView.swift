//
//  MacSettingsView.swift
//  teemoon
//
//  SETTINGS AS A MAC WINDOW, NOT AN iOS SHEET.
//
//  What ⌘, opened was `SettingsView` — the phone screen, unchanged: a
//  `NavigationStack` over a grouped `Form`, rows that push with disclosure
//  chevrons, and a "close" button floating in the toolbar. Every part of that
//  is an iOS sheet convention, and on a Mac each one reads as a port:
//
//  - The window already has a close button. It is red, it is top-left, and the
//    user has been closing windows with it since before this app existed. A
//    second "close" control inside the content is the single clearest tell.
//  - Settings that PUSH are a phone idiom. On a Mac, preferences are tabs —
//    System Settings, Safari, Mail, Notes, Xcode. You can see every section at
//    once and jump straight to one, instead of drilling and backing out.
//  - ⌘, is a window command, so it also has to survive being reopened, moved,
//    and closed with ⌘W like any other window.
//
//  So macOS gets this instead, and iOS keeps `SettingsView` untouched — the
//  phone idiom is correct on the phone. The tab CONTENT is shared: each tab
//  hosts the same section view the iOS list pushes to, so there is one
//  implementation of appearance, chats, search and places & keys, and this file
//  only decides arrangement.
//
//  Lowercase labels are deliberate and match the rest of the app.
//

#if os(macOS)

import SwiftUI

struct MacSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProviderStore.self) private var providerStore

    /// Write-only, and the write matters: "delete all chats" sets this to nil
    /// so the chat window stops showing a thread that no longer exists.
    @Binding var currentThread: Thread?

    /// Deep links from chat. A chip that names one capability must land ON that
    /// capability, so these select the tab rather than opening an index.
    @Binding var openToProviders: Bool
    @Binding var openToSearch: Bool

    /// Which tab is showing. Deep links write to it; the tab bar owns it
    /// otherwise.
    @State private var selection: Tab = .appearance

    enum Tab: Hashable {
        case appearance, chats, search, places, app
    }

    var body: some View {
        TabView(selection: $selection) {
            AppearanceSettingsView()
                .macSettingsTab()
                .tabItem { Label("appearance", systemImage: "paintpalette") }
                .tag(Tab.appearance)

            ChatsSettingsView(currentThread: $currentThread)
                .macSettingsTab()
                .tabItem { Label("chats", systemImage: "message") }
                .tag(Tab.chats)

            SearchSettingsView()
                .macSettingsTab()
                .tabItem { Label("search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            PlacesKeysHubView()
                .macSettingsTab()
                .tabItem { Label("places & keys", systemImage: "key") }
                .tag(Tab.places)
                .accessibilityIdentifier("settings.providers")

            MacAppSettingsTab()
                .macSettingsTab()
                .tabItem { Label("app", systemImage: "hammer") }
                .tag(Tab.app)
        }
        .onAppear { applyDeepLink() }
        .onChange(of: openToProviders) { _, _ in applyDeepLink() }
        .onChange(of: openToSearch) { _, _ in applyDeepLink() }
        .tint(settings.appTintColor.getColor())
        .environment(\.dynamicTypeSize, settings.appFontSize.getFontSize())
    }

    /// Deep links select a tab and then clear themselves, so reopening settings
    /// normally lands where the user left it rather than replaying an old jump.
    private func applyDeepLink() {
        if openToProviders {
            selection = .places
            openToProviders = false
        }
        if openToSearch {
            selection = .search
            openToSearch = false
        }
    }
}

/// The last tab: things that belong to the app rather than to a conversation.
///
/// On iOS these are two rows in the "app" section — a developer-mode toggle and
/// a `credits` row that pushes. There is nothing left to push to here, so
/// credits is simply part of the tab.
private struct MacAppSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(isOn: $settings.developerModeEnabled) {
                    Label("developer mode", systemImage: "hammer")
                }
                .accessibilityIdentifier("settings.developerMode")
            } footer: {
                Text("shows the raw request, response and attestation detail in chat.")
                    .textCase(.lowercase)
            }

            Section {
                CreditsView()
            }
        }
        .formStyle(.grouped)
    }
}

private extension View {
    /// Fixed size, content pinned to the TOP.
    ///
    /// Two measured corrections, both visible only in a capture:
    ///
    /// 1. A `minHeight` of 420 left the two-row appearance tab sitting in a
    ///    window with hundreds of points of dead space.
    /// 2. Removing it and asking for a content-sized height did not shrink the
    ///    window — it left the height alone and CENTRED the form in it, so
    ///    `font` floated in the middle of the window with gaps above and below.
    ///    That is the worse of the two: a Mac settings pane always starts at the
    ///    top, and vertically-centred content reads as a layout accident.
    ///
    /// So: one fixed size for every tab, and an explicit bottom spacer to hold
    /// content at the top. Empty space below a short pane is what System
    /// Settings does; empty space above it is not. Long panes (places & keys
    /// grows with the number of hosts) scroll inside their form.
    func macSettingsTab() -> some View {
        VStack(spacing: 0) {
            self
            Spacer(minLength: 0)
        }
        .frame(width: 560, height: 460)
    }
}

#endif
