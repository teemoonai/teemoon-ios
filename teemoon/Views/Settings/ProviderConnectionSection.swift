//
//  ProviderConnectionSection.swift
//  teemoon
//
//  Name / endpoint (+ lock chip) / api key, with saved-endpoint suggestions and
//  the "get {vendor} api key" CTA. Also home of the scheme chip.
//

import SwiftUI

struct ProviderConnectionSection: View {
    @Bindable var form: AddEditProviderModel
    var endpointFocused: FocusState<Bool>.Binding

    var body: some View {
        Section {
            TextField("label", text: $form.name)
                .textCase(.lowercase)
                .autocorrectionDisabled()

            HStack(spacing: 8) {
                SchemeChipView(scheme: $form.scheme)
                TextField("api.example.com/v1", text: $form.endpointHost)
                    .autocorrectionDisabled()
                    .focused(endpointFocused)
                    #if !os(macOS)
                    .keyboardType(.URL)
                    .textContentType(.URL)   // a URL, not a credential — no password autofill
                    .autocapitalization(.none)
                    #endif
                    .onChange(of: form.endpointHost) { _, newValue in
                        form.endpointEdited(newValue)
                    }
            }
            if !form.endpointHost.trimmingCharacters(in: .whitespaces).isEmpty && form.fullEndpointURL == nil {
                Text("that doesn't look like a valid url")
                    .font(.caption).foregroundStyle(.red)
            }
            // Autocomplete from previously-saved endpoints.
            if endpointFocused.wrappedValue {
                ForEach(form.endpointSuggestions) { sug in
                    Button {
                        form.applySuggestion(sug)
                        Haptics.play()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(sug.hostPath).tint(.primary).textCase(.lowercase)
                            Spacer()
                        }
                    }
                    #if os(macOS)
                    .buttonStyle(.borderless)
                    #endif
                }
            }

            if form.showKeyField {
                HStack {
                    Group {
                        if form.showAPIKey {
                            TextField(form.apiKeyPlaceholder, text: $form.apiKey, axis: .vertical).lineLimit(1...4)
                                .textContentType(.none)
                        } else {
                            // A SecureField is treated as a login password by iOS
                            // (isSecureTextEntry) regardless of textContentType, which
                            // triggers Passwords autofill/save. `.oneTimeCode` reclassifies
                            // it as an OTP field → no password autofill. teemoon stores the
                            // key in its own keychain, so this is purely cosmetic.
                            SecureField(form.apiKeyPlaceholder, text: $form.apiKey)
                                .textContentType(.oneTimeCode)
                        }
                    }
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .autocapitalization(.none)
                    #endif
                    if !form.apiKey.isEmpty {
                        Button { form.copyKey() } label: {
                            Image(systemName: form.apiKeyCopied ? "checkmark" : "square.on.square")
                                .foregroundStyle(.secondary)
                        }
                        #if os(macOS)
                        .buttonStyle(.borderless)
                        #endif
                    }
                    Button { form.showAPIKey.toggle() } label: {
                        Image(systemName: form.showAPIKey ? "eye.slash" : "eye").foregroundStyle(.secondary)
                    }
                    #if os(macOS)
                    .buttonStyle(.borderless)
                    #endif
                }

                // WHERE TO GET THE VALUE, next to the field asking for it.
                //
                // This used to live only in the preset section, which renders on
                // `!isEditing, initialPreset == nil, !startsCustom` — so it was
                // there when you added a provider from Settings and picked a
                // tile, and GONE when Where sent you here with the preset
                // already chosen. That is the common path: the sheet is titled
                // "add near.ai key", shows a key field, and offered no way to
                // go get one.
                //
                // Beside the field rather than in the picker, so it appears
                // once and always in the same place.
                //
                // Gated on the FIELD BEING EMPTY, not on adding. "No key → show
                // me how to get one" is the real rule, and `!isEditing` only
                // approximated it: a saved provider whose key was removed —
                // `remove key` is a first-class action on the cloud-key screen —
                // opens in edit mode with an empty field and would have been
                // offered nothing. With a key present the identity tile's
                // quieter "{vendor} console" takes over, which is the right
                // destination by then: billing and usage, not signup.
                if form.apiKey.trimmingCharacters(in: .whitespaces).isEmpty,
                   let url = form.providerConsoleURL {
                    Link(destination: url) {
                        Label("get \(form.consoleDisplayName) api key", systemImage: "arrow.up.right.square")
                            .textCase(.lowercase)
                    }
                    .foregroundStyle(.tint)
                }
            }
        } footer: {
            connectionFooter
        }
    }

    @ViewBuilder
    private var connectionFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if form.scheme == .http {
                Text("http is unencrypted — use only on a trusted network")
            }
            // WHERE THE SECRET GOES, said at the moment it is pasted.
            //
            // The screen asked for an api key and named no destination, which on a
            // BYOK app is the one question worth answering unprompted. Every clause is
            // checked against `Keychain.swift` rather than reassuring by default:
            //
            //   "ios keychain"      kSecClassGenericPassword, service ai.teemoon.apikeys
            //   "not in teemoon's
            //    own files"         nothing writes it to ConfigStore or UserDefaults;
            //                       the config file stores a Server, never a secret
            //   "sent only to X"    it is attached as the auth header for requests to
            //                       this endpoint and nowhere else
            //
            // Deliberately NOT claimed: "never leaves this device". The item is
            // `kSecAttrAccessibleAfterFirstUnlock` without `ThisDeviceOnly`, so it is
            // absent from iCloud Keychain (nothing sets `kSecAttrSynchronizable`) but
            // CAN come back from an encrypted device backup. That is a defensible
            // default — restoring a phone keeps your keys — and it is not the same
            // sentence, so it doesn't get said.
            if form.showKeyField {
                Text("the key is stored in the ios keychain, not in teemoon's own files\(form.keyDestinationClause).")
            }
            if form.awaitingFirstModel {
                Text("waiting for the endpoint to answer — teemoon picks a model from what it serves, and saves once it has one.")
            }
        }
    }
}

// MARK: - Scheme chip

struct SchemeChipView: View {
    @Binding var scheme: EndpointScheme

    var body: some View {
        Menu {
            if scheme.isSecure {
                Button {
                    scheme = .http
                } label: {
                    Label("use http (insecure)", systemImage: "lock.open")
                }
            } else {
                Button {
                    scheme = .https
                } label: {
                    Label("switch back to https", systemImage: "lock.fill")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: scheme.isSecure ? "lock.fill" : "lock.open")
                    .font(.system(size: 10))
                    .foregroundStyle(scheme.isSecure ? .green : .secondary)
                Text("\(scheme.rawValue)://")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.85))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(Color(.systemFill), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}
