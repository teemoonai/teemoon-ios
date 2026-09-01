//
//  ProviderEditActionsSection.swift
//  teemoon
//
//  Edit-mode only: activate + remove key + delete.
//

import SwiftUI

struct ProviderEditActionsSection: View {
    @Environment(ProviderStore.self) private var providerStore
    let form: AddEditProviderModel

    var body: some View {
        if let pid = form.editingProviderID {
            // "use this provider" SELECTS — it makes this setup the one that answers
            // the next message, which is a model-level act and lives on the Where
            // chip. In a server-and-key screen it is the one button that changes what
            // your next question goes to, sitting under a form about an endpoint.
            if form.scope == .full {
                Section {
                    Button {
                        providerStore.currentProviderID = pid.uuidString
                        Haptics.play()
                    } label: {
                        HStack {
                            Text(providerStore.currentProviderID == pid.uuidString
                                 ? "active provider" : "use this provider")
                            Spacer()
                            if providerStore.currentProviderID == pid.uuidString {
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                            }
                        }
                    }
                    .tint(.primary)
                    #if os(macOS)
                    .buttonStyle(.borderless)
                    #endif
                }
            }
            // TWO destructive actions, because they are different sizes and the
            // screen only offered the larger one. Revoking a key at the vendor means
            // clearing it here; that used to require emptying the field and saving,
            // which reads as an edit rather than a removal — so the only obvious
            // button deleted the whole setup, taking the equipped models with it.
            if !form.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    Button(role: .destructive) { form.apiKey = "" } label: {
                        Text("remove key")
                    }
                    #if os(macOS)
                    .buttonStyle(.borderless)
                    #endif
                } footer: {
                    Text("clears the key and keeps the setup — save to apply.")
                        .textCase(.lowercase)
                }
            }
            Section {
                Button(role: .destructive) { form.showDeleteConfirm = true } label: {
                    // Names what LEAVES. "delete provider" is a data-model word for a
                    // row the user thinks of as a key or a computer.
                    Text(form.isSelfHosted ? "forget this computer" : "delete this setup")
                }
                #if os(macOS)
                .buttonStyle(.borderless)
                #endif
            } footer: {
                Text(form.isSelfHosted
                     ? "removes it from teemoon. the machine and its models are untouched."
                     : "removes the endpoint, its key, and the models equipped on it.")
                    .textCase(.lowercase)
            }
        }
    }
}
