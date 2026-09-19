//
//  CloudKeyProviderPickerView.swift
//  teemoon
//
//  Step one of "add cloud key": pick the provider. Step two is the provider's
//  own key form, the same sheet the Where sheet opens from its `get` rows.
//  The two never share a screen — a form that is already filled in for a
//  provider nobody has chosen yet is the thing this replaces.
//

import SwiftUI

struct CloudKeyProviderPickerView: View {
    @Environment(ProviderStore.self) private var providerStore
    @Environment(\.dismiss) private var dismiss
    @State private var addingPreset: Provider?
    @State private var addingCustom = false
    @State private var idsBeforeAdd: Set<UUID> = []

    var body: some View {
        let offered = providerStore.presetsWithoutKey()
        Form {
            Section {
                if offered.isEmpty {
                    Text("every provider here already has a key — change one from its own row in places & keys.")
                        .foregroundStyle(.secondary).textCase(.lowercase)
                }
                ForEach(offered) { preset in
                    Button {
                        idsBeforeAdd = Set(providerStore.providers.map(\.id))
                        addingPreset = preset
                    } label: {
                        WhereRow(
                            glyph: WhereLocality.cloud.systemImage,
                            glyphTint: Color.accentColor,
                            title: preset.name.lowercased(),
                            showsE2EETag: preset.capabilities.contains(.endToEndEncryption),
                            caption: WhereProviderPresentation.presetCaption(for: preset),
                            captionLineLimit: 2
                        )
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("the next screen asks for that provider's key.")
                    .textCase(.lowercase)
            }

            Section {
                Button {
                    idsBeforeAdd = Set(providerStore.providers.map(\.id))
                    addingCustom = true
                } label: {
                    WhereRow(
                        glyph: "server.rack",
                        glyphTint: Color.accentColor,
                        title: "custom",
                        caption: "any endpoint serving /v1/chat/completions"
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("add cloud key")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // PUSHED, not presented: the key form is the next step of this flow,
        // and a sheet rising from the bottom after a push from the side read
        // as a different task. Like Mail's add-account, the form hides the
        // back button so cancel is the one way out.
        .navigationDestination(isPresented: Binding(
            get: { addingPreset != nil },
            set: { if !$0 { addingPreset = nil } }
        )) {
            if let preset = addingPreset {
                AddEditProviderView(mode: .add, initialPreset: preset)
                    .navigationBarBackButtonHidden(true)
            }
        }
        .navigationDestination(isPresented: $addingCustom) {
            AddEditProviderView(mode: .add, startsCustom: true, customStart: .cloudKey)
                .navigationBarBackButtonHidden(true)
        }
        .onAppear(perform: popIfAdded)
    }

    /// The form pops back here on save AND on cancel. A saved setup is the end
    /// of this screen's job: back to the list, where the new row is. A cancel
    /// leaves the picker up. `idsBeforeAdd` is empty on first appearance, so
    /// nothing counts as added then.
    private func popIfAdded() {
        guard !idsBeforeAdd.isEmpty else { return }
        let added = providerStore.providers.contains { !idsBeforeAdd.contains($0.id) }
        idsBeforeAdd = []
        if added { dismiss() }
    }
}

#Preview("add cloud key — pick a provider") {
    NavigationStack {
        CloudKeyProviderPickerView()
            .environment(ProviderStore(inMemory: true))
    }
}
