//
//  AddEditProviderModel.swift
//  teemoon
//
//  State and policy for the add/edit provider screen: the probe, preset
//  switching, the soft-gated save, and server-side model delete.
//  AddEditProviderView and its section views are layout over this type — new
//  branching belongs here, not in the views. No SwiftUI import: animation,
//  haptics, and focus dismissal are injected closures, the way ChatViewModel
//  does it.
//

import Foundation
import Observation

@Observable
@MainActor
final class AddEditProviderModel {

    /// The screen's configuration vocabulary lives on the MODEL — the policy
    /// type must not import the view's nested names (the view typealiases
    /// these, so call sites read the same either way).
    enum Mode {
        case add
        case edit(Provider)
    }

    /// How much of the setup this screen is for.
    ///
    /// `places & keys` manages PLACES: an endpoint and the credential that opens it.
    /// Opening the full screen there handed the user a model editor with a key field
    /// in it — fetch models, pick one, "use this provider" — which is the same
    /// conflation the row copy had. Feedback: "that page saves a model. what we want is
    /// just a page that saves server and api key."
    ///
    /// `.serverAndKey` drops the model half. It does NOT drop the model: `save()`
    /// writes back what `setupForEdit` loaded, so the equipped set and the active id
    /// survive untouched — the model is simply not this screen's business. Choosing
    /// one is the Where chip's job, which both footers here already say.
    enum Scope { case full, serverAndKey }

    /// What a custom start is FOR.
    ///
    /// Two rows use custom mode and they ask different questions: a machine on
    /// your own network, and a hosted endpoint teemoon ships no preset for. Same
    /// form either way — an address and maybe a key — so it was only a title
    /// string for a while. It is not: they want opposite default SCHEMES, and
    /// deciding that by comparing the title text would be the same magic-string
    /// coupling that had a view checking `vendor == "on this device"`.
    enum CustomStart {
        case computer, cloudKey

        var title: String {
            switch self {
            case .computer: return "connect a computer"
            case .cloudKey: return "add a cloud key"
            }
        }

        /// A box on your own network is almost never behind TLS, so starting a
        /// computer on https means the first thing the user does is change it.
        /// A hosted endpoint is the exact opposite — https is what it will be,
        /// and http on a public host is a mistake worth not suggesting.
        var defaultScheme: EndpointScheme {
            switch self {
            case .computer: return .http
            case .cloudKey: return .https
            }
        }
    }

    enum ConnState: Equatable {
        case idle
        case testing
        case connected
        case failed(EndpointModelCatalog.FailureKind)
    }

    // MARK: Configuration (fixed at creation by AddEditProviderView)

    let mode: Mode
    let scope: Scope
    let startsCustom: Bool
    let customStart: CustomStart
    let initialPreset: Provider?
    /// Preview/test seam — see `AddEditProviderView.keyOverride`, which passes it in.
    let keyOverride: String?

    /// Wired by the view before `loadInitialValues()` — nil only before first appear.
    @ObservationIgnored weak var providerStore: ProviderStore?

    init(
        mode: Mode,
        scope: Scope = .full,
        keyOverride: String? = nil,
        startsCustom: Bool = false,
        customStart: CustomStart = .computer,
        initialPreset: Provider? = nil
    ) {
        self.mode = mode
        self.scope = scope
        self.keyOverride = keyOverride
        self.startsCustom = startsCustom
        self.customStart = customStart
        self.initialPreset = initialPreset
    }

    // MARK: View wiring (injected — this type must not import SwiftUI)

    /// Soft tap. Wired by the view — this type must not import Haptics.
    @ObservationIgnored var onPlayHaptic: (() -> Void)?
    /// Wraps a state change so the view can animate it (`withAnimation`).
    /// Defaults to running the work immediately.
    @ObservationIgnored var onAnimatedChange: (() -> Void) -> Void = { $0() }
    /// Drops the endpoint field's focus — `@FocusState` lives on the view.
    @ObservationIgnored var onDismissEndpointFocus: (() -> Void)?

    // MARK: Network seams (production defaults; tests inject)

    @ObservationIgnored var probeCatalog: EndpointProbe.Catalog = .live
    /// Server-side Ollama delete. A seam so `performDelete`'s failure path is
    /// testable offline — see AddEditProviderModelTests.
    @ObservationIgnored var deleteModelFromServer: (String, URL) async throws -> Void = {
        try await OllamaAdapter.deleteModel($0, baseURL: $1)
    }

    // MARK: Form fields

    var name = ""
    /// The last label `autofillLabel` generated. Used to distinguish an
    /// auto-generated label (safe to refresh when the model changes) from one the
    /// user typed (never overwrite).
    var autoLabel = ""
    var scheme: EndpointScheme = .https
    var endpointHost = ""
    var model = ""
    var apiKey = ""
    var showAPIKey = false
    var apiKeyCopied = false

    // Preset + hidden fields round-tripped through save/edit.
    var selectedPresetName = ""
    var authHeaderName = ""
    var supportsModelBrowsing = false
    var extraParamsList: [(key: String, value: String)] = []
    var maxMessages: Int? = nil
    var hasBuiltInGrounding = false
    var omitSystemPrompt = false
    /// Keys typed per preset name but not yet saved, so switching preset tiles
    /// doesn't discard them (see `applyPresetChange`). Session-only — never
    /// persisted; the keychain is the only store for a key.
    var typedKeys: [String: String] = [:]
    /// Set when the keychain write fails on save, so the failure is visible
    /// instead of dismissing the screen as though the key were stored.
    var keySaveError: String?
    /// Set when a confirmed server-side model delete fails. The confirmation
    /// promised "this frees disk and can't be undone" — swallowing the failure
    /// left a reappearing row with no explanation. Same surfacing as
    /// `keySaveError`.
    var modelDeleteError: String?
    // Saved "none" state — restored when the user returns to the none preset.
    var savedNoneName = ""
    var savedNoneEndpoint = ""
    var savedNoneModel = ""
    var savedNoneAPIKey = ""

    // MARK: Connection state (verify-first)

    var conn: ConnState = .idle
    var fetchedModels: [KnownModel] = []
    var showModelBrowser = false
    var showDeleteConfirm = false
    /// Set by `probe()` when the endpoint is detected as Ollama — enables native
    /// capability listing and the server-side "download a model" affordance.
    var localKind: LocalServerKind = .unknown
    /// Ollama-only affordances: the server-side pull button and swipe-to-delete.
    var isOllama: Bool { localKind == .ollama }
    var showDownloadSheet = false
    /// Ollama model queued for a confirmed server-side delete (swipe → confirm).
    var pendingDelete: KnownModel?
    /// Ollama models currently loaded in the server's memory (warm). From /api/ps.
    var loadedModelIDs: Set<String> = []
    /// The model id loaded in `.edit` mode, so `save()` can preserve the stored
    /// `modelCapabilities` when the model is unchanged and not re-fetched.
    var loadedModel = ""

    /// Whether the endpoint requires an api key. Only the *definitive* signal is
    /// trusted: a 401 from `/models` means a key is required. We do NOT infer
    /// "keyless" from a 200 — `/models` is often public even when `/chat` is gated.
    enum AuthRequirement { case unknown, needed }
    var authRequirement: AuthRequirement = .unknown

    /// A probe cannot succeed: this endpoint has already answered 401, and the
    /// key field is empty. Greys out the controls that would run one.
    ///
    /// LEARNED, not hardcoded. The silent automatic probe is what discovers
    /// `.needed` — no table of which vendors gate their model list, which would
    /// be wrong the first time one changes. Measured today: near.ai's
    /// /v1/models answers 200 unauthenticated while x.ai's and fireworks' both
    /// 401, so near.ai never reaches `.needed` and its buttons stay live, which
    /// is correct — its catalogue really is fetchable without a key.
    var probeBlockedOnMissingKey: Bool {
        guard apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // Either LEARNED from a 401 this session, or KNOWN from the measured
        // table. The table exists so the very first probe is skipped too —
        // learning alone still costs one visible request per sheet, which is
        // the failure mode actually observed.
        if authRequirement == .needed { return true }
        guard let host = fullEndpointURL?.host()?.lowercased() else { return false }
        return Provider.modelListRequiresKeyHosts.contains(host)
    }

    /// A probe has run to completion at least once for this endpoint.
    ///
    /// Gates the manual model field. That field is a fallback for endpoints that
    /// serve no list — but shown before anything has been ASKED, it is an empty
    /// row inviting you to type a model id you have no way to know yet, on a
    /// screen where you have not finished entering the address. It only makes
    /// sense as an answer to "we looked, and there is nothing to pick from".
    var hasProbed = false

    // MARK: Computed

    var editingProvider: Provider? {
        if case .edit(let p) = mode { return p } else { return nil }
    }
    var editingProviderID: UUID? { editingProvider?.id }
    var isEditing: Bool { editingProviderID != nil }

    var fullEndpoint: String {
        let trimmed = endpointHost.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return "\(scheme.prefix)\(trimmed)"
    }
    var fullEndpointURL: URL? {
        fullEndpoint.isEmpty ? nil : URL(string: fullEndpoint)
    }
    /// Base URL for probing — the entered endpoint minus a trailing
    /// "/chat/completions" if the user pasted a full completions URL, plus
    /// "/v1" if they gave only a host and port.
    ///
    /// THE BARE HOST:PORT CASE IS THE COMMON ONE and it used to fail silently.
    /// A user entered `https://ringzero.tailnet-name.ts.net:11434` — the address you
    /// would naturally copy for an Ollama box — and the form sat on "waiting for
    /// the endpoint to answer". Measured against that host:
    ///
    ///     :11434/api/tags   200
    ///     :11434/v1/models  200
    ///     :11434/models     404   ← what the probe was asking for
    ///
    /// The server was answering perfectly; the app was asking one path up.
    /// OpenAI-compatible servers put the API under /v1, so an entered URL with
    /// no path at all is missing it rather than declaring a different one.
    ///
    /// Only when the path is EMPTY. A user who typed a path meant it — including
    /// the reverse proxies that mount the API somewhere else entirely — and
    /// second-guessing that would break the case this is trying to help.
    var probeBaseURL: URL? {
        normalisedBase.flatMap(URL.init(string:))
    }

    /// The entered address reduced to an OpenAI-compatible BASE — no
    /// "/chat/completions", no trailing slash, and "/v1" supplied when the user
    /// gave only a host and port.
    ///
    /// Shared by the probe and by `save()`, and that sharing is the point. The
    /// first version of this normalised only the probe, so the model list loaded
    /// and then inference 404'd — the app found the models at
    /// `:11434/v1/models` and posted the message to `:11434/chat/completions`,
    /// which does not exist. Two places deriving a URL from one field is how a
    /// screen ends up disagreeing with itself.
    var normalisedBase: String? {
        guard var s = fullEndpointURL?.absoluteString else { return nil }
        if s.hasSuffix("/chat/completions") { s = String(s.dropLast("/chat/completions".count)) }
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        // Only when the path is EMPTY. A typed path is a decision — reverse
        // proxies mount the API anywhere — and second-guessing it would break
        // the case this exists to help.
        if let u = URL(string: s), u.path.isEmpty { s += "/v1" }
        return s
    }
    /// Self-hosted detection on the *current* input (LAN / Tailscale / .local).
    var isSelfHosted: Bool {
        guard let host = fullEndpointURL?.host?.lowercased() else { return false }
        return Provider.isPrivateHost(host)
    }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !endpointHost.trimmingCharacters(in: .whitespaces).isEmpty &&
        fullEndpointURL != nil &&
        !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `isValid` requires a model, and in `.serverAndKey` nothing on screen shows one —
    /// so a disabled `save` needs a reason here that the model section used to give by
    /// existing. A preset carries a default and a successful probe resolves one, so
    /// this only appears while an endpoint has yet to answer.
    var awaitingFirstModel: Bool {
        scope == .serverAndKey && !isEditing && fullEndpointURL != nil
            && model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The preset whose endpoint matches what's currently entered, if any.
    var browsablePreset: Provider? {
        Provider.presets.first { $0.endpoint == scheme.prefix + endpointHost }
    }

    struct EndpointSuggestion: Identifiable {
        var id: String { hostPath }
        let scheme: EndpointScheme
        let hostPath: String
    }
    /// Saved endpoints whose host+path contains the typed text, so typing "ring"
    /// surfaces "ringzero…ts.net/v1". Excludes an exact match and the provider
    /// being edited.
    var endpointSuggestions: [EndpointSuggestion] {
        let typed = endpointHost.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { return [] }
        var seen = Set<String>()
        return (providerStore?.providers ?? []).compactMap { p -> EndpointSuggestion? in
            guard p.id != editingProviderID else { return nil }
            let (s, hp) = AddEditProviderView.splitEndpoint(p.endpoint)
            let key = hp.lowercased()
            guard key.contains(typed), key != typed, seen.insert(key).inserted else { return nil }
            return EndpointSuggestion(scheme: s, hostPath: hp)
        }.prefix(4).map { $0 }
    }

    /// Matching cloud preset for the current endpoint / selected tile, if any.
    var matchedCloudPreset: Provider? {
        Provider.presets.first { $0.endpoint == fullEndpoint }
            ?? Provider.presets.first { $0.name == selectedPresetName }
    }

    /// Console / keys URL for a matching cloud preset. nil for custom / self-hosted.
    var providerConsoleURL: URL? {
        guard let signup = matchedCloudPreset?.signupURL else { return nil }
        return URL(string: signup)
    }

    /// Short vendor name for console CTAs ("near.ai"), not a free-form user label.
    var consoleDisplayName: String {
        matchedCloudPreset?.name
            ?? (name.isEmpty ? "provider" : name)
    }

    var apiKeyPlaceholder: String {
        authRequirement == .needed ? "api key — required" : "api key"
    }

    /// Whether the SAVED provider should claim it needs a key.
    ///
    /// This used to be hardcoded `true` at the save site, which was wrong for
    /// every keyless self-hosted box and not merely cosmetic: `machineIdentity`
    /// is nil whenever `requiresAPIKey` is true, so a Tailscale-served Ollama
    /// added twice could never be recognised as one machine, and the Where sheet
    /// rendered the whole server twice with identical rows.
    ///
    /// Same predicate the key field is shown by — a key is entered, the probe
    /// proved auth is required, or it is a cloud endpoint. The endpoint's
    /// validity is already guaranteed by `isValid` at the save site.
    var requiresAPIKey: Bool {
        if !apiKey.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if authRequirement == .needed { return true }
        return !isSelfHosted
    }

    /// Show the api-key field only when it's plausibly needed: a key is already
    /// entered, the probe proved auth is required, or it's a cloud endpoint we
    /// haven't probed yet. Hidden for self-hosted-until-proven and for
    /// confirmed-keyless endpoints.
    var showKeyField: Bool {
        // Show only when: a key is entered, the probe proved auth is required, or
        // it's a valid CLOUD endpoint. Empty & self-hosted → hidden, so no
        // SecureField sits in the view triggering iOS's password affordance, and
        // a 401 still reveals it. We never hide on a 200 (public /models ≠ keyless).
        if !apiKey.isEmpty || authRequirement == .needed { return true }
        return fullEndpointURL != nil && !isSelfHosted
    }

    /// " — and sent only to api.near.ai", when the endpoint is far enough along to
    /// name a host. Nothing is promised about a destination we can't print.
    var keyDestinationClause: String {
        guard let host = fullEndpointURL?.host?.lowercased(), !host.isEmpty else { return "" }
        return " — and sent only to \(host)"
    }

    /// The model id this endpoint is pinned to, when it exposes no model list at
    /// all (Brave Answers: one answers endpoint, `.fixed` rule, no `/models`).
    /// Such a provider gets a connection check instead of a model section —
    /// there is nothing to pick, fetch, or refresh.
    var fixedModelID: String? {
        guard let preset = Provider.presets.first(where: { $0.endpoint == fullEndpoint }),
              case .fixed(let id) = preset.defaultModelRule ?? .first else { return nil }
        return id
    }

    /// Inline model list. For a cloud provider with a default RULE (near.ai) show only
    /// the rule-chosen default — the rest live behind "all N models". Otherwise show
    /// the first few (installed ollama models, etc.).
    var recommendedModels: [KnownModel] {
        if browsablePreset?.defaultModelRule != nil {
            // Only the resolved default — no fallback, so a not-yet-resolved preset id
            // doesn't flash a different model before the rule sets it.
            return fetchedModels.first { $0.id == model }.map { [$0] } ?? []
        }
        return Array(fetchedModels.prefix(3))
    }

    /// The model this provider's rule would pick from the live catalogue — the
    /// actual recommendation, as opposed to `recommendedModels`, which is the
    /// currently-selected row. Nil for providers with no rule (ollama et al).
    var recommendedModelID: String? {
        guard let rule = browsablePreset?.defaultModelRule else { return nil }
        return rule.resolve(from: fetchedModels)
    }

    /// near.ai rows carry the confidentiality tier badge, matching the browser.
    var showsInlineTiers: Bool {
        fullEndpointURL?.host?.lowercased().hasSuffix("near.ai") == true
    }

    // MARK: - Copy

    func failureMessage(_ kind: EndpointModelCatalog.FailureKind) -> String {
        EndpointProbe.failureMessage(kind)
    }

    // MARK: - Actions

    /// Unused `KnownModel` is load-bearing: callers used to pass the model so the
    /// label could include it. `PlaceLabel` never reads it.
    func autofillLabel(from _: KnownModel) { autofillPlaceLabel() }

    func autofillPlaceLabel() {
        guard let next = PlaceLabel.proposed(
            currentName: name,
            lastAuto: autoLabel,
            presetName: selectedPresetName,
            host: fullEndpointURL?.host
        ) else { return }
        name = next
        autoLabel = next
    }

    func probe(select preferred: String? = nil, userInitiated: Bool = false) async {
        guard let base = probeBaseURL else { return }
        defer { hasProbed = true }
        let preset = Provider.presets.first(where: { $0.endpoint == fullEndpoint })
        let request = EndpointProbe.Request(
            baseURL: base,
            host: fullEndpointURL?.host,
            apiKey: apiKey,
            authHeaderName: authHeaderName.isEmpty ? nil : authHeaderName,
            isSelfHosted: isSelfHosted,
            stickyKind: localKind,
            currentModel: model,
            preferredModel: preferred,
            userInitiated: userInitiated,
            existingModels: fetchedModels,
            defaultModelRule: preset?.defaultModelRule,
            keyValidationEndpoint: preset?.keyValidationEndpoint
        )
        if EndpointProbe.needsNetwork(request) {
            onAnimatedChange { self.conn = .testing }
        }
        let result = await EndpointProbe.run(request, catalog: probeCatalog)
        onAnimatedChange { self.applyProbe(result) }
    }

    private func applyProbe(_ result: EndpointProbe.Result) {
        localKind = result.kind
        loadedModelIDs = result.loaded
        fetchedModels = result.models
        model = result.selectedModel
        if result.authNeeded { authRequirement = .needed }
        if result.dismissEndpointFocus { onDismissEndpointFocus?() }
        if result.shouldAutofillLabel { autofillPlaceLabel() }
        switch result.outcome {
        case .idle: conn = .idle
        case .connected: conn = .connected
        case .failed(let kind): conn = .failed(kind)
        }
    }

    /// Every edit of the endpoint field lands here (the connection section's
    /// onChange): peel a pasted scheme into the chip, invalidate everything the
    /// previous endpoint taught us, and drop a preset tile the edit walked away
    /// from.
    func endpointEdited(_ newValue: String) {
        if newValue.hasPrefix("https://") {
            endpointHost = String(newValue.dropFirst("https://".count)); scheme = .https
        } else if newValue.hasPrefix("http://") {
            endpointHost = String(newValue.dropFirst("http://".count)); scheme = .http
        }
        conn = .idle                  // endpoint changed —
        authRequirement = .unknown    // invalidate prior probe + auth detection
        hasProbed = false             // a new endpoint has not been asked yet
        localKind = .unknown          // re-detect server kind for the new endpoint
        loadedModelIDs = []
        // Editing the endpoint away from the selected preset makes the tile
        // a lie ("provider: near.ai" with a different url) — move to custom.
        // apply(preset:) sets a matching endpoint, so it never trips this.
        if !selectedPresetName.isEmpty,
           Provider.presets.first(where: { $0.name == selectedPresetName })?.endpoint != fullEndpoint {
            selectedPresetName = ""
        }
    }

    /// Picking a saved endpoint brings its saved key with it — the same endpoint
    /// needs the same credential, and typing it again from a password manager is
    /// the annoyance the suggestion list exists to remove. Never overwrites a key
    /// already typed here.
    func applySuggestion(_ sug: EndpointSuggestion) {
        scheme = sug.scheme
        endpointHost = sug.hostPath
        conn = .idle
        if apiKey.trimmingCharacters(in: .whitespaces).isEmpty,
           let saved = providerStore?.credential(
            forEndpoint: sug.scheme.prefix + sug.hostPath) {
            apiKey = saved
        }
    }

    func copyKey() {
        // Credential copy — local-only, self-expiring. See `Clipboard.copySensitive`.
        Clipboard.copySensitive(apiKey)
        apiKeyCopied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); self.apiKeyCopied = false }
    }

    /// True when the provider was removed and the screen should dismiss.
    func deleteProvider() -> Bool {
        guard case .edit(let provider) = mode, let providerStore else { return false }
        providerStore.removeProvider(provider)
        return true
    }

    /// Server-side delete of an Ollama model (from a confirmed swipe). Clears the
    /// selection if the deleted model was selected, then re-probes to refresh the
    /// list.
    ///
    /// The confirmation said "this frees disk and can't be undone" — so a FAILED
    /// delete must say so too, through the same alert mechanism as a keychain
    /// failure on save, not `try?` its way to a silently reappearing row. The
    /// selection is kept (the model is still on the server) and the re-probe
    /// still runs so the UI reflects the true state.
    func performDelete(_ m: KnownModel) async {
        pendingDelete = nil
        guard let base = probeBaseURL else { return }
        do {
            try await deleteModelFromServer(m.id, base)
        } catch {
            modelDeleteError = "“\(m.displayName)” is still on the server — \(error.localizedDescription)"
            await probe()
            return
        }
        if model == m.id { model = "" }
        onPlayHaptic?()
        await probe()
    }

    // MARK: - Preset / load / save (soft-gate)

    func applyPresetChange(old oldName: String, new newName: String) {
        // Hold on to whatever key was typed for the preset being left, so tapping
        // another tile and coming back doesn't lose it. A typed key belongs to the
        // preset it was typed under — it must never follow the user to a different
        // provider, which is why this is keyed, not carried.
        if !oldName.isEmpty { typedKeys[oldName] = apiKey }

        if newName.isEmpty {
            name = savedNoneName
            let (s, h) = AddEditProviderView.splitEndpoint(savedNoneEndpoint)
            scheme = s; endpointHost = h
            model = savedNoneModel; apiKey = savedNoneAPIKey
            authHeaderName = ""; supportsModelBrowsing = false; extraParamsList = []
            maxMessages = nil; hasBuiltInGrounding = false; omitSystemPrompt = false
            conn = .idle; fetchedModels = []
        } else if let preset = Provider.presets.first(where: { $0.name == newName }) {
            if oldName.isEmpty {
                savedNoneName = name; savedNoneEndpoint = fullEndpoint
                savedNoneModel = model; savedNoneAPIKey = apiKey
            }
            apply(preset: preset)
        }
    }

    func apply(preset: Provider) {
        name = preset.name.lowercased()
        autoLabel = name   // treat the preset name as auto-generated so model selection can refresh it
        let (s, h) = AddEditProviderView.splitEndpoint(preset.endpoint)
        scheme = s; endpointHost = h
        model = preset.model
        authHeaderName = preset.authHeaderName ?? ""
        supportsModelBrowsing = preset.supportsModelBrowsing
        extraParamsList = preset.extraParams.map { ($0.key, $0.value) }.sorted { $0.key < $1.key }
        // Key, in order of authority: what the user typed for this preset in this
        // session → the key already saved for a provider on this endpoint → the
        // one onboarding stored under the preset's own id. Endpoint-matching is
        // what makes a key added from Settings show up again: `save()` stores it
        // under a fresh provider UUID, not the preset's.
        apiKey = typedKeys[preset.name]
            ?? providerStore?.credential(forEndpoint: preset.endpoint)
            ?? providerStore?.credential(for: preset)
            ?? ""
        maxMessages = preset.maxMessages
        hasBuiltInGrounding = preset.hasBuiltInGrounding
        omitSystemPrompt = preset.omitSystemPrompt
        conn = .idle; fetchedModels = []
        // Seed the label as "provider model" on load from the curated display name, so
        // it reads right immediately — the live catalogue refreshes it if the name differs.
        if !preset.model.isEmpty {
            let known = KnownModel.models(for: preset.id).first { $0.id == preset.model }
                ?? KnownModel(id: preset.model,
                              displayName: preset.model.split(separator: "/").last.map(String.init) ?? preset.model,
                              vendor: "", price: "")
            autofillLabel(from: known)
        }
    }

    func loadInitialValues() {
        guard case .edit(let provider) = mode else {
            // Fresh add: default to a preset (cloud) rather than custom — that's
            // what users reach for when they want a big model they can't run
            // locally. Selecting the preset fills the fields and kicks off the probe.
            //
            // Prefer the first preset NOT already configured. Adding a provider is
            // rare and each add is nearly always a *different* provider, so landing
            // on one already in the list is the least useful default there is.
            // Falls back to near.ai once they all exist.
            // An explicit request wins over the heuristic below: the caller named
            // a provider, so guessing a different one would override a choice
            // the user has already made.
            if let initialPreset {
                selectedPresetName = initialPreset.name
                apply(preset: initialPreset)
                return
            }
            // Custom mode: leave the preset unselected so the endpoint field is
            // the focus, and take the scheme from what this start is FOR — see
            // `CustomStart.defaultScheme`. It was `.http` for both, which is
            // right for a computer and wrong for a cloud key: a hosted endpoint
            // is https, and offering http on a public host suggests a mistake.
            if startsCustom {
                scheme = customStart.defaultScheme
                return
            }
            if selectedPresetName.isEmpty && endpointHost.isEmpty {
                let configured = Set((providerStore?.providers ?? []).map { $0.name.lowercased() })
                selectedPresetName = Provider.presets
                    .first { !configured.contains($0.name.lowercased()) }?.name
                    ?? Provider.nearAI.name
            }
            return
        }
        name = provider.name
        let (s, h) = AddEditProviderView.splitEndpoint(provider.endpoint)
        scheme = s; endpointHost = h
        model = provider.model
        loadedModel = provider.model
        authHeaderName = provider.authHeaderName ?? ""
        supportsModelBrowsing = provider.supportsModelBrowsing
        extraParamsList = provider.extraParams.map { ($0.key, $0.value) }.sorted { $0.key < $1.key }
        // BOTH lookups, the way `hasKey` and the places-&-keys row already do it.
        // Keys are stored per provider INSTANCE, so a key saved from a different
        // screen lives under a different id for the same endpoint — and reading only
        // this record's id showed an EMPTY field for a provider that has a key. The
        // row one screen back says "key set", so the two disagreed; worse, saving
        // from that blank field is what revokes the key it failed to display.
        if let keyOverride {
            apiKey = keyOverride
        } else {
            let byID = providerStore?.credential(for: provider) ?? ""
            apiKey = byID.isEmpty
                ? (providerStore?.credential(forEndpoint: provider.endpoint) ?? "")
                : byID
        }
        maxMessages = provider.maxMessages
        hasBuiltInGrounding = provider.hasBuiltInGrounding
        omitSystemPrompt = provider.omitSystemPrompt
    }

    /// Capabilities to persist for the selected model. A fresh fetch wins; else,
    /// on edit with the model unchanged, preserve what was stored; else unknown
    /// (nil) — never carry the OLD model's caps onto a newly-typed model.
    func capabilitiesToSave(for trimmedModel: String) -> ModelCapabilities? {
        if let fetched = fetchedModels.first(where: { $0.id == trimmedModel }) {
            return fetched.capabilities
        }
        return trimmedModel == loadedModel ? editingProvider?.modelCapabilities : nil
    }

    /// True when everything saved and the screen should dismiss. False keeps the
    /// screen up — the keychain refused the key and `keySaveError` says why.
    func save() -> Bool {
        guard let providerStore else { return false }
        let id = editingProviderID ?? UUID()
        let extraParams = Dictionary(uniqueKeysWithValues: extraParamsList.filter { !$0.key.isEmpty })
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)

        let provider = Provider(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            // The NORMALISED base, not the raw field. Saving what was typed is
            // what made a working "connect a computer" 404 at inference time.
            endpoint: normalisedBase.map { $0 + "/chat/completions" } ?? fullEndpoint,
            model: trimmedModel,
            authHeaderName: authHeaderName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : authHeaderName.trimmingCharacters(in: .whitespaces),
            requiresAPIKey: requiresAPIKey,
            supportsModelBrowsing: supportsModelBrowsing,
            extraParams: extraParams,
            maxMessages: maxMessages,
            hasBuiltInGrounding: hasBuiltInGrounding,
            omitSystemPrompt: omitSystemPrompt,
            modelCapabilities: capabilitiesToSave(for: trimmedModel)
        )

        // The id the setup ACTUALLY lands on. Adding an endpoint that is already
        // configured folds into that record rather than minting a second one, so
        // the key must be written where the store put it — otherwise rotating a
        // key writes the new secret into a slot nothing reads.
        let savedID: UUID
        if editingProviderID != nil {
            providerStore.updateProvider(provider)
            savedID = id
        } else {
            savedID = providerStore.addProvider(provider)
        }
        // Unconditional: an EMPTIED field must delete the stored key, not leave
        // the old one in place. Guarding on non-empty made the clear path
        // unreachable, so a removed key kept being sent.
        do {
            try providerStore.setCredential(apiKey, forProviderID: savedID)
        } catch {
            // Everything else is saved; only the secret failed. Stay on screen
            // with the reason rather than dismissing into a broken provider.
            keySaveError = error.localizedDescription
            return false
        }
        // Adding a provider activates it (you added it to use it); editing leaves
        // the active provider unchanged unless none is set.
        if editingProviderID == nil || providerStore.currentProviderID == nil {
            providerStore.currentProviderID = savedID.uuidString
        }
        return true
    }
}
