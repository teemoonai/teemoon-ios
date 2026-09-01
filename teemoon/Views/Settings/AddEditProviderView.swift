//
//  AddEditProviderView.swift
//  teemoon
//

import SwiftUI

enum EndpointScheme: String, CaseIterable {
    case https
    case http

    var prefix: String { "\(rawValue)://" }
    var isSecure: Bool { self == .https }
}

/// Verify-first add / edit provider flow. Enter an endpoint, one "fetch models"
/// action tests the connection AND pulls the model list into a picker, self-hosted
/// endpoints (Tailscale / LAN / .local) are detected and treated correctly, and
/// save soft-gates (you can save before a successful test — teemoon retries on the
/// first send). `.add` shows the connect flow; `.edit` shows a provider-detail page
/// with an identity tile, the model picker, and delete.
///
/// Layout only: every field, derivation, and action lives on
/// `AddEditProviderModel`, and the sections are standalone views over it.
struct AddEditProviderView: View {
    typealias Mode = AddEditProviderModel.Mode

    typealias Scope = AddEditProviderModel.Scope
    let scope: Scope

    @Environment(ProviderStore.self) var providerStore
    @Environment(OllamaDownloadCenter.self) var downloadCenter: OllamaDownloadCenter?
    @Environment(\.dismiss) var dismiss

    let mode: Mode

    /// Preview/test seam: the key the sheet opens with, instead of reading the
    /// Keychain. A canvas has no Keychain, so `remove key` — which only exists when a
    /// key is present — could not be looked at, and neither could a filled field with
    /// its reveal and copy buttons. That is the state this screen is mostly used in.
    let keyOverride: String?

    /// Preview/test seam: the connection state to open in. A canvas cannot make a
    /// request, so every `failureMessage` — nine strings, each the only explanation a
    /// user gets for a setup that won't connect — has shipped unreviewed.
    let connOverride: ConnState?

    var navTitle: String {
        if form.isEditing, scope == .serverAndKey { return form.isSelfHosted ? "computer" : "cloud key" }
        if form.isEditing { return "provider" }
        if let initialPreset { return "add \(initialPreset.name.lowercased()) key" }
        if startsCustom { return customStart.title }
        return "add provider"
    }

    /// Open straight into custom-endpoint mode, for "connect a computer".
    ///
    /// The cloud preset grid is the wrong first question for a machine on your
    /// own network: none of the presets are it, and the thing being asked for is
    /// an address. Custom mode already focuses the endpoint field — this just
    /// stops the sheet defaulting to a cloud preset before the user gets there.
    let startsCustom: Bool

    typealias CustomStart = AddEditProviderModel.CustomStart

    let customStart: CustomStart

    /// Open straight into the server-side "download a model" sheet.
    ///
    /// Where's "add a model to ollama" row promises one thing — pull a model
    /// onto the machine — and landing on the provider's settings instead makes
    /// the user find the button the row already named. The pull sheet only
    /// exists once the endpoint is detected as Ollama, so this waits for the
    /// probe rather than firing on appear.
    let startsPullingModel: Bool

    /// Preset to arrive pre-filled on, in `.add` mode.
    ///
    /// Where's `get` list names each provider individually — "brave answers ·
    /// add key" — so the sheet has to open ON brave answers. Landing on a blank
    /// provider picker would make the user choose the thing they just tapped.
    let initialPreset: Provider?
    let embedInNavigationStack: Bool

    typealias ConnState = AddEditProviderModel.ConnState

    /// Every field, derivation, and action on this screen. Created per
    /// presentation; the store and the view-only closures (haptics, animation,
    /// focus dismissal) are wired in `onAppear`.
    @State private var form: AddEditProviderModel

    /// Applied once, on appear — `conn` is screen state and the override is a
    /// seam, not a binding.
    @State private var appliedConnOverride = false

    @FocusState var endpointFocused: Bool

    init(scope: Scope = .full,
         mode: Mode,
         keyOverride: String? = nil,
         connOverride: ConnState? = nil,
         startsCustom: Bool = false,
         customStart: CustomStart = .computer,
         startsPullingModel: Bool = false,
         initialPreset: Provider? = nil,
         embedInNavigationStack: Bool = true) {
        self.scope = scope
        self.mode = mode
        self.keyOverride = keyOverride
        self.connOverride = connOverride
        self.startsCustom = startsCustom
        self.customStart = customStart
        self.startsPullingModel = startsPullingModel
        self.initialPreset = initialPreset
        self.embedInNavigationStack = embedInNavigationStack
        _form = State(initialValue: AddEditProviderModel(
            mode: mode,
            scope: scope,
            keyOverride: keyOverride,
            startsCustom: startsCustom,
            customStart: customStart,
            initialPreset: initialPreset))
    }

    /// In-flight pulls for THIS endpoint. Lives on the view (not the model)
    /// because it reads the injected download center; the count is also watched
    /// below so a finished pull re-probes into an installed, selectable row.
    var downloadingHere: [OllamaDownloadCenter.Download] {
        guard let dc = downloadCenter, let host = form.probeBaseURL?.host else { return [] }
        return dc.inProgress.filter { $0.baseURL.host == host }
    }

    // MARK: - Body

    var body: some View {
        if embedInNavigationStack {
            NavigationStack { formView }
        } else {
            formView
        }
    }

    /// Split from `formView` deliberately: the sheets/dialogs/tasks below make one
    /// long modifier chain, which the type-checker solves as a SINGLE expression.
    /// Adding the keychain-failure alert tipped it past the budget and previews
    /// stopped compiling ("unable to type-check this expression in reasonable
    /// time") while the app build still succeeded. Two smaller expressions.
    @ViewBuilder
    var formView: some View {
        @Bindable var form = form
        formCore
            .modifier(ProviderSheets(
                showModelBrowser: $form.showModelBrowser,
                showDownloadSheet: $form.showDownloadSheet,
                selectedModel: $form.model,
                models: form.fetchedModels,
                showsConfidentialityTags: form.browsablePreset?.id == Provider.nearAI.id,
                downloadBaseURL: form.probeBaseURL,
                onSelectModel: { form.autofillLabel(from: $0) },
                onDownloadCompleted: { pulled in Task { await form.probe(select: pulled) } },
                // SELECTED THE MOMENT IT STARTS, which is how the phone tier and the
                // Where sheet already behave: tapping a model to get it means you
                // want to use it, so the row is chosen while the bytes are still
                // arriving rather than after. Settings alone waited for completion,
                // so a multi-gigabyte pull left the screen looking untouched and the
                // previously selected model still current.
                //
                // `probe(select:)` still runs on completion and reconciles: an hf.co
                // ref can install under a name the server spells differently, and
                // that is the id chat has to use.
                // A pull in flight IS the selection — and it makes the form
                // saveable, so the label has to exist by now too. Belt and
                // braces with the `.connected` call above: this fires even if
                // the user started a download before the probe settled.
                onDownloadStarted: { ref in
                    form.model = ref
                    form.autofillPlaceLabel()
                }))
            .modifier(ProviderConfirmations(
                showDeleteConfirm: $form.showDeleteConfirm,
                pendingDelete: $form.pendingDelete,
                keySaveError: $form.keySaveError,
                modelDeleteError: $form.modelDeleteError,
                onDeleteProvider: { if form.deleteProvider() { dismiss() } },
                onDeleteModel: { m in Task { await form.performDelete(m) } }))
            .onAppear {
                form.providerStore = providerStore
                form.onPlayHaptic = { Haptics.play() }
                form.onAnimatedChange = { change in withAnimation { change() } }
                form.onDismissEndpointFocus = { endpointFocused = false }
                form.loadInitialValues()
            }
            .onChange(of: form.localKind) { _, kind in
                // The probe has to land first: `downloadModelButton` is gated on
                // Ollama being detected, so presenting before that shows a sheet
                // for a capability not yet known to exist.
                if startsPullingModel, kind == .ollama, !form.showDownloadSheet {
                    form.showDownloadSheet = true
                }
            }
            // A pull for this endpoint finished/left → re-probe so it appears as an
            // installed, selectable model instead of a downloading row.
            .onChange(of: downloadingHere.count) { oldCount, newCount in
                if newCount < oldCount { Task { await form.probe() } }
            }
            // Auto-probe as soon as the endpoint looks complete (has a path like /v1)
            // and typing settles: one call populates the model picker AND detects auth
            // (401 → reveal the key field) — no manual "fetch models" needed. Restarts
            // whenever the endpoint changes; "fetch models" is then just a refresh.
            .task(id: form.fullEndpoint) {
                // A canvas with an overridden state must not have it overwritten by a
                // real request the canvas can't make anyway — the two rendered on top
                // of each other, "connecting…" showing through the failure.
                guard connOverride == nil else { return }
                guard form.probeBaseURL != nil, form.endpointHost.contains("/") else { return }
                // DON'T ASK A QUESTION WHOSE ANSWER IS ALREADY KNOWN. Silence
                // was the previous fix and was not enough: the request still
                // went out, still 401'd, and was merely not reported. Skipping
                // it means the empty state is genuinely idle rather than
                // quietly failing.
                guard !form.probeBlockedOnMissingKey else { return }
                try? await Task.sleep(for: .seconds(0.6))          // debounce typing
                guard !Task.isCancelled, form.probeBaseURL != nil else { return }
                await form.probe()
            }
            // Add mode: start with the cursor in the url field — you type the url
            // first, and the label auto-fills from the model.
            .task {
                guard !form.isEditing else { return }
                try? await Task.sleep(for: .seconds(0.4))
                if form.selectedPresetName.isEmpty { endpointFocused = true }   // only focus the url in custom mode
            }
            .onAppear {
                guard let connOverride, !appliedConnOverride else { return }
                appliedConnOverride = true
                form.conn = connOverride
            }
    }

    @ViewBuilder
    var formCore: some View {
        Form {
            if form.isEditing { ProviderIdentitySection(form: form) }
            // No preset grid when the caller already named the provider.
            //
            // Arriving from Where's "brave answers · add key", the place is
            // chosen — the grid would ask the user to pick it a second time, and
            // worse, offers them the chance to pick a different one, so the row
            // they tapped and the screen they landed on disagree about what is
            // being configured. The key field is the whole job here.
            if !form.isEditing, initialPreset == nil, !startsCustom {
                ProviderPresetSection(form: form, endpointFocused: $endpointFocused)
            }
            ProviderConnectionSection(form: form, endpointFocused: $endpointFocused)
            // Progressive disclosure — and never in `.serverAndKey`, where the models
            // are exactly what this screen is not for.
            //
            // Safe in ADD mode too, which is where it looks riskiest: nothing visible
            // picks a model, but nothing visible picked one before either. A preset
            // carries its own default, `.task(id: fullEndpoint)` probes the endpoint on
            // its own (debounced, independent of this section), and `probe()` resolves
            // the model from `defaultModelRule` or the first one served. The section
            // only ever DISPLAYED that choice — and displaying it here is what made
            // "add cloud key" a model picker.
            if scope == .full, form.fullEndpointURL != nil {
                ProviderModelSection(form: form,
                                     downloads: downloadingHere,
                                     onCancelDownload: { downloadCenter?.cancel(ref: $0.id) })
            }
            if form.isEditing { ProviderEditActionsSection(form: form) }
        }
        .formStyle(.grouped)
        // A grouped Form reserves header room above its first section even when
        // that section has no header, which left a conspicuous gap under the nav
        // bar — the sheet read as top-heavy. The preset grid is its own label.
        #if os(iOS) || os(visionOS)
        .contentMargins(.top, 8, for: .scrollContent)
        #endif
        // "add near.ai key" when the provider is already decided, so the title
        // answers the same question the row that opened it asked.
        .navigationTitle(navTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS) || os(visionOS)
            ToolbarItem(placement: .topBarLeading) {
                Button("cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("save") { if form.save() { dismiss() } }
                    .fontWeight(.semibold)
                    .disabled(!form.isValid)
            }
            #elseif os(macOS)
            ToolbarItem(placement: .cancellationAction) {
                Button("cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("save") { if form.save() { dismiss() } }
                    .disabled(!form.isValid)
            }
            #endif
        }
    }

    /// Split a full endpoint URL string into (scheme, host+path).
    static func splitEndpoint(_ endpoint: String) -> (EndpointScheme, String) {
        if endpoint.hasPrefix("http://") {
            return (.http, String(endpoint.dropFirst("http://".count)))
        } else if endpoint.hasPrefix("https://") {
            return (.https, String(endpoint.dropFirst("https://".count)))
        } else {
            return (.https, endpoint)
        }
    }
}
