//
//  ProviderPresetSection.swift
//  teemoon
//
//  Add-mode preset picker (cloud providers with known endpoints).
//

import SwiftUI

struct ProviderPresetSection: View {
    let form: AddEditProviderModel
    var endpointFocused: FocusState<Bool>.Binding

    var body: some View {
        Section {
            // Rows, like every other list of things to pick in the app — the
            // Where sheet's `get` section in particular, which offers the same
            // presets. The tile grid this replaces was the one surface that
            // looked like a different app. Tapping a row fills the fields
            // below; editing the endpoint moves the selection to custom.
            ForEach(Provider.presets) { preset in
                Button {
                    if form.selectedPresetName != preset.name { form.selectedPresetName = preset.name }
                } label: {
                    WhereRow(
                        glyph: glyph(for: preset),
                        glyphTint: Color.accentColor,
                        title: preset.name.lowercased(),
                        showsE2EETag: preset.capabilities.contains(.endToEndEncryption),
                        caption: WhereProviderPresentation.presetCaption(for: preset),
                        isSelected: form.selectedPresetName == preset.name
                    )
                }
                .buttonStyle(.plain)
            }
            Button {
                if !form.selectedPresetName.isEmpty { form.selectedPresetName = "" }
            } label: {
                WhereRow(
                    glyph: "server.rack",
                    glyphTint: Color.accentColor,
                    title: "custom",
                    caption: "any endpoint serving /v1/chat/completions",
                    isSelected: form.selectedPresetName.isEmpty
                )
            }
            .buttonStyle(.plain)
            .onChange(of: form.selectedPresetName) { oldName, newName in
                form.applyPresetChange(old: oldName, new: newName)
                // Picking custom means the user is entering their own endpoint — put the
                // cursor in the url field and open the keyboard.
                endpointFocused.wrappedValue = newName.isEmpty
            }
            // The "get {vendor} api key" CTA lives next to the key field, so it
            // also reaches the Where path — which preselects a preset and
            // therefore never renders this section.
        } footer: {
            if let preset = Provider.presets.first(where: { $0.name == form.selectedPresetName }),
               let desc = preset.presetDescription {
                Text(desc)
            } else {
                Text("\(PointerVerb.act) a provider to fill the fields below, or enter any endpoint serving /v1/chat/completions")
            }
        }
    }

    /// The same glyphs the Where sheet gives these rows: the cloud tier's
    /// symbol, and the answer-service mark for a preset with no catalogue.
    private func glyph(for preset: Provider) -> String {
        preset.isFixedAnswerService ? "sparkle.magnifyingglass" : WhereLocality.cloud.systemImage
    }
}
