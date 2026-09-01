//
//  SettingsView.swift
//  teemoon
//
//  Created by Jordan Singer on 10/4/24.
//
//  Garage: you (prefs) · places & keys (manage) · app.
//  Daily model switching is the Where chip in chat, not this list.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProviderStore.self) private var providerStore
    @Environment(\.dismiss) var dismiss
    @Binding var currentThread: Thread?
    /// Deep link from older call sites / UI tests — opens places & keys hub.
    @Binding var openToProviders: Bool
    /// Deep link from the web-answers chip, which names one capability and so
    /// must land on that capability rather than on a settings index.
    @Binding var openToSearch: Bool
    @State private var navigateToPlaces = false
    @State private var navigateToSearch = false

    private var placesSummary: String {
        // What the destination can actually show — see `WhereLocality.managed`.
        let n = WhereLocality.managed(in: providerStore.providers).count
        if n == 0 { return "none" }
        return n == 1 ? "1 setup" : "\(n) setups"
    }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    NavigationLink(destination: AppearanceSettingsView()) {
                        Label("appearance", systemImage: "paintpalette")
                    }

                    NavigationLink(destination: ChatsSettingsView(currentThread: $currentThread)) {
                        Label("chats", systemImage: "message")
                    }

                    NavigationLink(destination: SearchSettingsView()) {
                        Label("search", systemImage: "magnifyingglass")
                    }
                } header: {
                    Text("you")
                        .textCase(.lowercase)
                }

                Section {
                    NavigationLink(destination: PlacesKeysHubView()) {
                        HStack {
                            Label("places & keys", systemImage: "key")
                            Spacer()
                            Text(placesSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textCase(.lowercase)
                        }
                    }
                    .accessibilityIdentifier("settings.providers")
                } header: {
                    Text("places & keys")
                        .textCase(.lowercase)
                } footer: {
                    Text("manage hosts and keys here. to switch model mid-chat, use the chip above the message field.")
                        .textCase(.lowercase)
                }

                Section {
                    Toggle(isOn: $settings.developerModeEnabled) {
                        Label("developer mode", systemImage: "hammer")
                    }
                    .accessibilityIdentifier("settings.developerMode")

                    NavigationLink(destination: CreditsView()) {
                        Text("credits")
                            .textCase(.lowercase)
                    }
                } header: {
                    Text("app")
                        .textCase(.lowercase)
                }

            }
            .formStyle(.grouped)
            .navigationTitle("settings")
            .navigationDestination(isPresented: $navigateToPlaces) {
                PlacesKeysHubView()
            }
            .navigationDestination(isPresented: $navigateToSearch) {
                // DEEP-LINKED, so it exits with "done" straight back to the
                // thread. The NavigationLink in the list above passes no
                // handler and keeps its back chevron.
                SearchSettingsView(onDone: { dismiss() })
            }
            .onAppear {
                if openToProviders {
                    navigateToPlaces = true
                    openToProviders = false
                }
                if openToSearch {
                    navigateToSearch = true
                    openToSearch = false
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS) || os(visionOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("close settings")
                    .accessibilityIdentifier("settings.close")
                }
                #elseif os(macOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Text("close")
                    }
                }
                #endif
            }
        }
        #if !os(visionOS)
        .tint(settings.appTintColor.getColor())
        #endif
        .environment(\.dynamicTypeSize, settings.appFontSize.getFontSize())
    }
}

#Preview {
    let store = ProviderStore(inMemory: true)
    store.providers = [.nearAI, .grok]
    return SettingsView(currentThread: .constant(nil), openToProviders: .constant(false),
                        openToSearch: .constant(false))
        .environment(AppSettings())
        .environment(store)
        .environment(ConfidentialSession(providers: store))
}
