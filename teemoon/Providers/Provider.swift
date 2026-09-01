//
//  Provider.swift
//  teemoon
//
//  Public API for a configured place + model. Disk persistence is ConfigStore
//  (Server + EquippedModel); this type is what the rest of the app speaks.
//

import Foundation

struct Provider: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var endpoint: String
    var model: String
    /// nil → "Authorization: Bearer <key>"; set → use as-is, e.g. "X-Subscription-Token"
    var authHeaderName: String?

    /// Endpoint identity, for asking "is this saved record the same server as
    /// that preset?".
    ///
    /// THE SAME SERVER CAN BE SPELLED SEVERAL WAYS and every spelling is one a
    /// user can legitimately end up with: `openAIBaseURL` already accepts an
    /// endpoint with or without a trailing `/chat/completions`, so both forms
    /// are stored and both work. Compared literally they are different servers.
    ///
    /// Observed: the Where sheet showed "browse grok · add key" for a grok setup
    /// that had a key and equipped models, because its row matched the preset
    /// with a raw `==` while the key lookup normalised. The row asked one
    /// question with two different rules and disagreed with itself.
    ///
    /// Deliberately NOT a host-only comparison: two presets can share a host and
    /// differ by path, and collapsing those would match the wrong one.
    /// NOT `ProviderStore.endpointKey`, and the difference is deliberate.
    ///
    /// That one addresses the KEYCHAIN ACCOUNT (`"endpoint:" + key`) and must
    /// never change: rewriting it relocates every stored key and costs users a
    /// trip to a vendor console. This one answers a softer question — "are these
    /// two records the same server?" — so it can also forgive the
    /// `/chat/completions` suffix, which `openAIBaseURL` already treats as
    /// optional.
    static func presetMatchKey(_ endpoint: String) -> String {
        var s = endpoint.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasSuffix("/chat/completions") {
            s = String(s.dropLast("/chat/completions".count))
        }
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    var presetMatchKey: String { Self.presetMatchKey(endpoint) }

    /// Whether two records point at the same server, however each is spelled.
    func sameEndpoint(as other: Provider) -> Bool { presetMatchKey == other.presetMatchKey }

    /// Base URL for the chat-completions endpoint ("chat/completions" is appended
    /// per request). Strips a trailing "/chat/completions" from `endpoint` if present.
    var openAIBaseURL: URL? {
        var s = endpoint
        if s.hasSuffix("/chat/completions") {
            s = String(s.dropLast("/chat/completions".count))
        }
        return URL(string: s)
    }

    /// True when the endpoint points at a **private / self-hosted** host — a
    /// laptop/server on the LAN, over Tailscale, `.local`, or loopback — rather
    /// than a public cloud provider. Drives: api key *optional*, http allowed
    /// without a scary warning (not forced — Tailscale serve is https), and the
    /// self-hosted identity mark. Classified by **host**, never by the literal
    /// string "localhost": on a real device the inference server is always a
    /// remote address (Tailscale / LAN); loopback only appears in the simulator.
    var isSelfHosted: Bool {
        guard let host = openAIBaseURL?.host?.lowercased() else { return false }
        return Self.isPrivateHost(host)
    }

    /// Identity of the MACHINE this provider points at, for collapsing duplicate
    /// records of the same self-hosted server.
    ///
    /// A cloud key is legitimately configurable twice — same endpoint, two
    /// different keys, "work" and "personal" — so identity there is the record,
    /// not the URL. A keyless self-hosted server has no such dimension: the
    /// endpoint *is* the thing, and `syncHomeEquipped` makes both records list
    /// the same models, so a second one renders as an exact duplicate row the
    /// user cannot tell apart or choose between.
    ///
    /// nil for anything that isn't a keyless self-hosted endpoint, which is what
    /// keeps this from ever merging two cloud providers that share a host.
    ///
    /// Host + port + path, so one machine can run Ollama on 11434 and llama.cpp
    /// on 8080 and stay two providers. Case-folded and trailing-slash-stripped
    /// because `…:11434/v1` and `…:11434/v1/` are the same server typed twice.
    var machineIdentity: String? {
        guard isSelfHosted, !requiresAPIKey, let url = openAIBaseURL, let host = url.host else {
            return nil
        }
        let port = url.port.map(String.init) ?? ""
        var path = url.path.lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        return "\(host.lowercased()):\(port)\(path)"
    }

    /// Host classification for `isSelfHosted`. Matches loopback, RFC1918 private
    /// ranges, link-local, the Tailscale CGNAT range (100.64.0.0/10), and the
    /// `.local` / `.ts.net` / `localhost` name suffixes.
    static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1"
            || host.hasSuffix(".local") || host.hasSuffix(".ts.net") { return true }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }   // not an IPv4 literal
        let (a, b) = (octets[0], octets[1])
        switch a {
        case 127:                              return true   // 127.0.0.0/8 loopback
        case 10:                               return true   // 10.0.0.0/8
        case 192 where b == 168:               return true   // 192.168.0.0/16
        case 172 where (16...31).contains(b):  return true   // 172.16.0.0/12
        case 169 where b == 254:               return true   // 169.254.0.0/16 link-local
        case 100 where (64...127).contains(b): return true   // 100.64.0.0/10 CGNAT (Tailscale)
        default:                               return false
        }
    }

    /// Validates the provider has the minimum required configuration.
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !endpoint.trimmingCharacters(in: .whitespaces).isEmpty &&
        !model.trimmingCharacters(in: .whitespaces).isEmpty &&
        openAIBaseURL != nil
    }

    var requiresAPIKey: Bool
    var supportsModelBrowsing: Bool
    /// Merged into request body. Values auto-coerced: "true"→Bool, numbers→Double, else String.
    var extraParams: [String: String]
    /// When set, only the last N messages are sent. Handles APIs like Brave Answers that only
    /// accept a single message in the messages array.
    var maxMessages: Int?
    /// True when the provider performs its own web search grounding (e.g. Brave Answers).
    /// `BraveWebSearchTool` will not be attached for these providers.
    var hasBuiltInGrounding: Bool
    /// When true, the system prompt (.instructions entry) is omitted from the transcript.
    /// Required for providers that do not accept a system role message (e.g. Brave Answers).
    var omitSystemPrompt: Bool
    /// Short description shown in the preset picker. Not persisted to user data.
    var presetDescription: String?
    /// URL for signing up / getting an API key. Not persisted to user data.
    var signupURL: String?
    /// Capabilities of the *selected* `model`, captured when the user picks it from
    /// the fetched catalog (adapter-supplied, e.g. Ollama `/api/show`). **nil =
    /// unknown** (a generic endpoint that exposes no capability metadata, or a
    /// provider saved before this field existed). Optional → Codable-safe: old
    /// stored JSON decodes to nil, never wiping saved providers. See `ModelCapabilities`.
    var modelCapabilities: ModelCapabilities?

    /// When set, this provider runs **on this device** and the value is the
    /// HuggingFace repo id of the local weights (e.g.
    /// `mlx-community/Qwen3-0.6B-4bit`). `endpoint` is then a display-only
    /// placeholder — there is no server.
    ///
    /// Optional → Codable-safe: providers saved before this existed decode to
    /// nil and stay remote, which is the correct default.
    var localModelID: String?

    /// True when inference happens on-device. The single thing callers should
    /// branch on — never test the endpoint string.
    var isLocal: Bool { localModelID != nil }

    /// The service's name, independent of what the row's label was auto-filled
    /// with. Falls back to the label for endpoints teemoon doesn't ship a preset
    /// for, where the user's own name is the best available answer.
    ///
    /// CANONICAL, not `name`. That label is auto-generated as "<place> <model>"
    /// when a key is saved and never refreshed, so a record called
    /// "fireworks Qwen3.7 Plus" still says so after the user equips
    /// deepseek-v4-flash. Surfaces that report where a request went
    /// (`LastRequestDebugInfo.providerName`, Where rows, places-&-keys) must
    /// use this, not the stored name.
    var canonicalName: String {
        if let preset = Provider.presets.first(where: { $0.sameEndpoint(as: self) }) {
            return preset.name.lowercased()
        }
        // A HOME machine is its HOST, not its record label. Same auto-label
        // bug the cloud presets had, surviving here because a self-hosted
        // endpoint matches no preset.
        if isSelfHosted, let host = openAIBaseURL?.host {
            return HostLabel.friendly(host).lowercased()
        }
        return name.lowercased()
    }

    /// Every model equipped on this connection, of which `model` is the one
    /// currently active. A provider is a place plus a credential; a model is a
    /// thing that place can run. Conflating them meant one Ollama host with
    /// three models pulled showed as a single row.
    ///
    /// `model` deliberately stays the active id rather than becoming an index
    /// into this array: it is read in 44 places, including the whole inference
    /// and attestation chain, and none of them should have to learn about
    /// equipping.
    ///
    /// Optional → Codable-safe: providers saved before this existed decode to
    /// nil and are read as `[model]`, so nothing migrates on write.
    var equippedModels: [String]?

    /// The equipped set, always non-empty for a valid provider. Reading `nil`
    /// as `[model]` is the whole migration — old JSON needs no rewrite, and a
    /// provider mid-edit with no models still yields its active one.
    var equipped: [String] {
        guard let equippedModels, !equippedModels.isEmpty else {
            return model.isEmpty ? [] : [model]
        }
        // The active model counts as equipped even if an older write dropped
        // it, so it can never vanish from the list that renders it.
        return equippedModels.contains(model) || model.isEmpty
            ? equippedModels
            : [model] + equippedModels
    }

    /// Adds `modelID` to the equipped set and makes it active. Idempotent.
    func equipping(_ modelID: String) -> Provider {
        var copy = self
        var set = equipped
        if !set.contains(modelID) { set.append(modelID) }
        copy.equippedModels = set
        copy.model = modelID
        return copy
    }

    /// Removes `modelID`. Returns nil when it was the last one — the caller
    /// must delete the provider instead, because a connection with nothing to
    /// run is not a state the picker can render.
    func unequipping(_ modelID: String) -> Provider {
        let remaining = equipped.filter { $0 != modelID }
        var copy = self
        // EMPTY IS A VALID STATE, and returning nil for it was the bug: the caller
        // read nil as "nothing left, so delete the whole provider", which took the
        // Keychain entry with it. A server exists independently of what is equipped
        // on it — the endpoint, the key and the machine are all still there, and
        // pulling or equipping another model is the next thing you'd do.
        //
        // `ConfigSnapshot` already stores it this way: a `Server` with no
        // `EquippedModel` rows round-trips to a `Provider` with an empty `model`
        // and nil `equippedModels`, so nothing below this needed changing.
        copy.equippedModels = remaining.isEmpty ? nil : remaining
        // Unequipping the ACTIVE model has to move `model`, or the provider keeps
        // running something it no longer claims to have. With nothing left there is
        // nothing to move to, and empty means "this server has no model selected".
        if copy.model == modelID { copy.model = remaining.first ?? "" }
        return copy
    }

    /// Whether the selected model can call tools. **Unknown (nil) → optimistic
    /// `true`**: we only *withhold* tools when we positively know the model can't
    /// use them (e.g. Ollama reported no `tools` capability). Gates `BraveWebSearchTool`
    /// at attach time so a non-tool model never receives one (no hot-path 400 retry).
    var modelSupportsTools: Bool {
        modelCapabilities?.contains(.tools) ?? true
    }

    /// What this provider can do. The single source of truth for behavior gating —
    /// never test the endpoint string or a preset UUID to decide behavior.
    ///
    /// Computed (not stored) so it works for providers saved before a capability existed.
    var capabilities: Capabilities {
        var caps: Capabilities = []
        // near.ai runs SOME models in TEEs (its own fleet + attested third-party)
        // but PROXIES others (Claude, GPT-5.x, Gemini) with no enclave. Claim
        // attestation/E2EE only for the model actually running confidentially —
        // else the UI implies proof that isn't there. Tier comes from the live
        // /v1/models `owned_by` (cached), with an id heuristic before it loads.
        // teeOwn ONLY: near.ai exposes no confidential endpoint for the
        // `attested 3p` tier (Chutes), so there is no E2EE path *via near.ai*
        // and nothing teemoon can attest end-to-end on that route. (Chutes'
        // own stack runs TDX with per-instance keys — the limitation is the
        // routing, not the hardware.) Claiming either capability here would
        // still be an overclaim.
        if endpoint.contains("near.ai"),
           NearAIModelCatalog.confidentiality(forID: model) == .teeOwn {
            caps.insert([.attestation, .endToEndEncryption])
        }
        if hasBuiltInGrounding { caps.insert(.builtInGrounding) }
        if supportsModelBrowsing { caps.insert(.modelBrowsing) }
        return caps
    }

    struct Capabilities: OptionSet {
        let rawValue: Int
        /// Inference runs inside a TEE and serves a verifiable TDX attestation quote.
        static let attestation         = Capabilities(rawValue: 1 << 0)
        /// Request/response bodies can be encrypted end-to-end to the enclave.
        static let endToEndEncryption  = Capabilities(rawValue: 1 << 1)
        /// The provider performs its own web-search grounding; no search tool is attached.
        static let builtInGrounding    = Capabilities(rawValue: 1 << 2)
        /// The model browser sheet can list this provider's models.
        static let modelBrowsing       = Capabilities(rawValue: 1 << 3)
    }

    init(
        id: UUID = UUID(),
        name: String,
        endpoint: String,
        model: String,
        authHeaderName: String? = nil,
        requiresAPIKey: Bool = true,
        supportsModelBrowsing: Bool = false,
        extraParams: [String: String] = [:],
        maxMessages: Int? = nil,
        hasBuiltInGrounding: Bool = false,
        omitSystemPrompt: Bool = false,
        presetDescription: String? = nil,
        signupURL: String? = nil,
        modelCapabilities: ModelCapabilities? = nil,
        localModelID: String? = nil,
        equippedModels: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.model = model
        self.authHeaderName = authHeaderName
        self.requiresAPIKey = requiresAPIKey
        self.supportsModelBrowsing = supportsModelBrowsing
        self.extraParams = extraParams
        self.maxMessages = maxMessages
        self.hasBuiltInGrounding = hasBuiltInGrounding
        self.omitSystemPrompt = omitSystemPrompt
        self.presetDescription = presetDescription
        self.signupURL = signupURL
        self.modelCapabilities = modelCapabilities
        self.localModelID = localModelID
        self.equippedModels = equippedModels
    }

    /// A provider that runs `model` on this device.
    ///
    /// No key, no endpoint, no browsing. The endpoint string is a human-readable
    /// placeholder so anything that displays it has something sane to show; it is
    /// never dialled, because `isLocal` short-circuits first.
    static func local(_ model: LocalModel) -> Provider {
        Provider(
            name: model.displayName,
            endpoint: "on-device",
            model: model.id,
            requiresAPIKey: false,
            supportsModelBrowsing: false,
            modelCapabilities: model.supportsTools ? [.tools] : [],
            localModelID: model.id
        )
    }
}

// MARK: - Known models (struct; data lives in Provider+Presets.swift)

struct KnownModel: Identifiable, Equatable, Hashable {
    let id: String          // exact API identifier
    let displayName: String
    let vendor: String      // used for section grouping
    /// Input and output price per 1M tokens, e.g. "$1.05/$3.10"
    let price: String
    // `var` with a default from here down, not `let`.
    //
    // Swift only gives a synthesised memberwise initialiser a DEFAULT VALUE for
    // a `var` that declares one — a `let` with an initial value is considered
    // already initialised and is dropped from the initialiser entirely. So the
    // choice is between `var` here and hand-writing the initialiser again.
    // Nothing in the app mutates a `KnownModel` after construction (checked), so
    // the immutability these `let`s advertised was never load-bearing, and the
    // compiler-maintained initialiser is worth more than the annotation.

    /// Context window size, e.g. "2M", "256K", "132K"; empty if unknown
    var contextWindow: String = ""
    /// Show a "New" badge in the model browser
    var isNew: Bool = false
    /// Base URL for NEAR AI direct completions mode.
    /// When set, inference connects straight to the model's TEE, bypassing the gateway.
    /// nil means the model is only accessible via the gateway (e.g. third-party models).
    var directBaseURL: String? = nil
    /// What this model can do (tools/vision/uploads). **nil = unknown** — the
    /// source exposed no capability metadata (a generic `/v1/models` endpoint).
    /// Non-nil = known (adapter-supplied, e.g. Ollama `/api/show`). See `ModelCapabilities`.
    var capabilities: ModelCapabilities? = nil

    // MARK: Detail — everything below is OPTIONAL and shown only when the
    // provider actually returned it.
    //
    // The rule is the price table's: a blank field, never an invented one. These
    // all arrive on the wire already — near.ai's /v1/models carries a real prose
    // description, its supported features and its supported sampling
    // parameters; the fireworks control plane carries a description plus
    // huggingFaceUrl / githubUrl. teemoon fetched them and dropped them on the
    // floor, so a model browser could say what a model COSTS but nothing about
    // what it IS.

    /// The vendor's own prose.
    var summary: String? = nil
    /// Feature names as the provider spells them — `tools`, `reasoning`,
    /// `json_mode`, `structured_outputs`. Kept as strings rather than mapped to
    /// `ModelCapabilities` because the point of the detail view is to report
    /// what was said, not teemoon's interpretation of it.
    var features: [String] = []
    /// Request parameters this model accepts. near.ai publishes these per model,
    /// which is a catalogue teemoon would otherwise have to probe for.
    var samplingParameters: [String] = []
    /// Largest completion the model will produce, when stated.
    var maxOutputTokens: Int? = nil
    /// What it accepts and emits — `text`, `image`.
    var inputModalities: [String] = []
    /// Where the weights and the code live, when the provider says.
    var huggingFaceURL: String? = nil
    var githubURL: String? = nil
    /// The vendor's own model page.
    var modelPageURL: String? = nil
    /// Set when the provider has announced a retirement date.
    ///
    /// FIREWORKS ONLY, as of today. near.ai's `/v1/models` carries no such
    /// field (checked live: no deprecation, retire, sunset or eol key) and
    /// xAI's language-model list is ids, prices, context and aliases. So an
    /// absent date means "not published", never "not retiring".
    var deprecationDate: Date? = nil

    /// A retirement date read for display: "retiring in 4 months", or
    /// "retired" once it is past. nil when the provider published nothing.
    ///
    /// The raw field is an ISO date, which is precise and unreadable — the
    /// decision it informs is "should I pick this one", and that turns on how
    /// SOON, not on which Tuesday.
    var deprecationLabel: String? {
        guard let date = deprecationDate else { return nil }
        if date <= Date() { return "retired" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        return "retiring \(fmt.localizedString(for: date, relativeTo: Date()))"
    }

    /// Parses a provider's date string ONCE, at the wire boundary.
    ///
    /// It used to be stored as the raw string and re-parsed inside
    /// `deprecationLabel`, which is the wrong end: a type that models a date as
    /// `String` cannot be compared, sorted or arithmetic'd without every reader
    /// redoing the parse, and each reader gets to disagree about the format.
    /// Parse at the edge, store a `Date`, format for display — the same shape
    /// Foundation uses everywhere.
    ///
    /// `en_US_POSIX` is not optional on a FIXED-FORMAT formatter. Without it the
    /// user's locale supplies the calendar, and under a non-Gregorian one
    /// (Buddhist, Japanese — both reachable from iOS Settings) "2026-12-01"
    /// fails to parse or parses to the wrong year. It is Apple's own stated rule
    /// for `dateFormat`, and the previous code did not follow it.
    ///
    /// Returns nil for an unparseable string, which merges it with "the provider
    /// published nothing". That loses the old behaviour of echoing an
    /// unrecognised value verbatim — deliberately: a retirement notice teemoon
    /// cannot read is one it cannot compare against today either, so it could
    /// never say whether the model is already retired, and "retiring 12/2026-Q4"
    /// is not a thing to put in front of someone choosing a model.
    static func deprecationDate(fromProvider raw: String?) -> Date? {
        guard let raw = raw?.nilIfBlank else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.dateFormat = "yyyy-MM-dd"
        plain.timeZone = TimeZone(identifier: "UTC")
        return plain.date(from: raw)
    }

    /// Whether this model is on its way out — for a row badge, where there is
    /// room for a word and not a sentence.
    var isRetiring: Bool { deprecationDate != nil }
    /// Weight precision as the server reports it — `Q4_K_M`, `FP8`, `Q2_0`.
    ///
    /// A field of its own, not a fragment of the context string. Ollama already
    /// read it from `/api/show` and then joined it into `contextWindow` as
    /// "256k · Q4_K_M", which reads fine on one list row and is unusable
    /// anywhere that wants either fact alone — a detail page cannot say
    /// "context 256k" without also saying the quantisation twice.
    var quantization: String? = nil
    /// Parameter count as the server reports it — "4.7B". Ollama's
    /// `details.parameter_size`.
    var parameterSize: String? = nil
    /// Bytes on disk, for a model teemoon downloads. Real blob metadata, not an
    /// estimate from the parameter count.
    var downloadSize: String? = nil
    /// The git revision the weights are PINNED to.
    ///
    /// An on-device model is the one case teemoon can say exactly which bytes
    /// it runs: the catalogue pins a revision and a sha256 together, because a
    /// digest against a moving branch rejects a legitimate update as corruption
    /// and a revision without a digest trusts whatever arrives. The revision is
    /// the half a person can act on — it is what you would open on the Hub.
    var pinnedRevision: String? = nil
    /// What can be said about confidentiality, WHEN THE SOURCE KNOWS.
    ///
    /// Set by whoever built the entry, never decided by a view. An on-device
    /// model's claim needs no catalogue to back it; near.ai's comes from its
    /// tier. A view that picked between them on `vendor == "on this device"`
    /// was coupling two layers with a magic string.
    var confidentialityNote: String? = nil

    /// Identity is the id — it is the exact API identifier and already unique
    /// within a catalogue. Synthesised conformance would drag in every field
    /// (and `ModelCapabilities` is not Hashable), which is both wrong and
    /// fragile: adding a display-only field would change a model's identity.
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Formatted as "$input/$output per 1M tokens"
    var priceLabel: String { "\(price) / 1M tokens" }

    /// The quiet right-hand line in a model row: "$1.40/$4.40 · 1m" for a cloud
    /// model, "128k · Q4_K_XL" for a local one, "" when nothing is known. Joins
    /// only the parts that exist — a local model has no price, and rendering it
    /// as "\(price) · \(context)" put a leading "· " on every free model.
    var metaLabel: String {
        [price, contextWindow.lowercased()]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // NO HAND-WRITTEN MEMBERWISE INIT.
    //
    // There was one, with 22 parameters, reproducing exactly what Swift
    // synthesises for free — and its parameter order had already drifted out of
    // step with the property declarations above it (`downloadSize` and
    // `pinnedRevision` came before `deprecationDate` in the signature and after
    // it in the body). Every argument-order mistake this type produced came from
    // hand-maintaining a list the compiler will maintain perfectly. Adding a
    // property now updates the initialiser by definition instead of by memory.
}

extension KnownModel {
    /// The catalogue entry for a model that runs ON THIS DEVICE.
    ///
    /// `LocalModel` is a different type with different facts — there is no price
    /// and no vendor endpoint, but there IS a download size, a pinned revision
    /// and a checksum, which is provenance no cloud row can show. The detail
    /// page renders whatever is present, so the same view serves both without
    /// inventing a cloud shape for a phone model.
    static func onDevice(_ model: LocalModel) -> KnownModel {
        KnownModel(
            id: model.id,
            displayName: model.displayName,
            vendor: "on this device",
            // No price and no context window: the model is free and teemoon does
            // not publish a token budget for it. Blank, never a guess.
            price: "",
            capabilities: model.supportsTools ? [.tools] : [],
            summary: model.blurb.nilIfBlank,
            features: model.supportsTools ? ["tools"] : [],
            inputModalities: ["text"],
            // `LocalModel.id` IS the Hugging Face repo id, so this is the
            // repo itself rather than a guess — and the revision below pins
            // which commit of it teemoon actually downloaded.
            huggingFaceURL: "https://huggingface.co/" + model.id,
            downloadSize: model.sizeLabel,
            pinnedRevision: model.revision,
            // The one confidentiality claim that needs nothing to verify it.
            confidentialityNote: "runs on this device — nothing leaves it")
    }
}

extension String {
    /// nil when there is nothing but whitespace — so an adapter's empty string
    /// field becomes an absent one rather than a blank row.
    var nilIfBlank: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
