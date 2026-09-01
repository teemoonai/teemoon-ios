//
//  ProviderIdentitySection.swift
//  teemoon
//
//  Edit-mode header for the add/edit provider screen: identity tile + name/host.
//  Quiet "open console" for cloud presets only — setup's "get api key" stays on add.
//

import SwiftUI

struct ProviderIdentitySection: View {
    let form: AddEditProviderModel

    var body: some View {
        Section {
            HStack(spacing: 14) {
                ProviderIdentityTile(name: form.name.isEmpty ? "?" : form.name,
                                     isSelfHosted: form.isSelfHosted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(form.name).font(.title2.weight(.semibold)).textCase(.lowercase)
                    Text(form.fullEndpointURL?.host ?? form.endpointHost)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            if let url = form.providerConsoleURL {
                // Named so VoiceOver / multi-provider skimming isn't just "open console".
                let vendor = form.consoleDisplayName
                Link(destination: url) {
                    Label("\(vendor) console", systemImage: "arrow.up.right.square")
                        .font(.subheadline)
                        .textCase(.lowercase)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}
