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
            // Provider marks — one labelled line above the fields it fills. No menu to
            // open and no pseudo-value to keep truthful: the filled tile IS the selection,
            // and editing the endpoint moves it to custom. Monograms are placeholders
            // until real provider logos land.
            // A wrapping grid so every mark — including "custom" — is always visible;
            // it flows to as many rows as the width needs instead of clipping off-screen.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 14) {
                ForEach(Provider.presets) { preset in
                    presetTile(logo: logoAsset(for: preset.name),
                               mark: String(preset.name.prefix(1)).lowercased(), name: preset.name,
                               systemImage: nil, selected: form.selectedPresetName == preset.name) {
                        if form.selectedPresetName != preset.name { form.selectedPresetName = preset.name }
                    }
                }
                presetTile(mark: nil, name: "custom", systemImage: "server.rack",
                           selected: form.selectedPresetName.isEmpty) {
                    if !form.selectedPresetName.isEmpty { form.selectedPresetName = "" }
                }
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .onChange(of: form.selectedPresetName) { oldName, newName in
                form.applyPresetChange(old: oldName, new: newName)
                // Picking custom means the user is entering their own endpoint — put the
                // cursor in the url field and open the keyboard.
                endpointFocused.wrappedValue = newName.isEmpty
            }
            // The "get {vendor} api key" CTA moved OUT of this section and next
            // to the key field, so it also reaches the Where path — which
            // preselects a preset and therefore never renders this section.
        } footer: {
            if let preset = Provider.presets.first(where: { $0.name == form.selectedPresetName }),
               let desc = preset.presetDescription {
                Text(desc)
            } else {
                Text("\(PointerVerb.act) a provider to fill the fields below, or enter any endpoint serving /v1/chat/completions")
            }
        }
    }

    /// Asset-catalog logo for a preset, or nil to fall back to a monogram.
    private func logoAsset(for presetName: String) -> String? {
        switch presetName {
        case "near.ai":       return "logo-nearai"
        case "Grok":          return "logo-grok"
        case "Fireworks":     return "logo-fireworks"
        case "Brave Answers": return "logo-brave"
        default:              return nil
        }
    }

    /// One provider mark in the preset row — a real logo when we have one, else a
    /// monogram (or icon) — plus the name below.
    @ViewBuilder
    private func presetTile(logo: String? = nil, mark: String?, name: String, systemImage: String?,
                            selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action(); Haptics.play()
        } label: {
            VStack(spacing: 6) {
                let hasLogo = logo.map(namedAssetExists) ?? false
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(hasLogo ? AnyShapeStyle(.white) : AnyShapeStyle(Color(.secondarySystemFill)))
                        .frame(width: 56, height: 56)
                        .overlay {
                            // ONE selection indicator for every tile — an accent ring — so
                            // custom reads as selected the same way the logo tiles do. The
                            // hairline (unselected logo tiles) keeps the white edge visible
                            // against a white Form section in light mode.
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(selected ? Color.accentColor
                                                       : (hasLogo ? PlatformColors.separator : .clear),
                                              lineWidth: selected ? 3 : 1)
                        }
                    if hasLogo, let logo {
                        // Brand marks fill the white tile (app-icon) — big and legible in
                        // both light and dark; the heterogeneous assets read uniformly.
                        Image(logo).resizable().scaledToFit()
                            .frame(width: 38, height: 38)
                    } else if let mark {
                        Text(mark).font(.title2.weight(.semibold))
                            .foregroundStyle(selected ? .primary : .secondary)
                    } else if let systemImage {
                        Image(systemName: systemImage).font(.title3)
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                }
                Text(name).font(.caption2).textCase(.lowercase).lineLimit(1)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
