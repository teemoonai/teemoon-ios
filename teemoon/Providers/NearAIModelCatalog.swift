//
//  NearAIModelCatalog.swift
//  teemoon
//
//  near.ai's model list, built from the LIVE `/v1/models` — the only source.
//  Direct TEE hosts come from `EndpointDirectory`; tiers come from `owned_by`
//  and are what every E2EE claim rests on. When the fetch fails, the caller
//  falls back to the last saved answer (`LiveCatalogStore`), never to a list
//  compiled into the app.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "catalog")

enum NearAIModelCatalog {

    // MARK: - Confidentiality tier
    //
    // near.ai serves models in three tiers, distinguished by `/v1/models`'
    // `owned_by`: its own attested GPU fleet, an attested third party (Chutes),
    // and a plain proxy to an upstream vendor (Anthropic / OpenAI / Google) that
    // runs in NO enclave. Only the first two are attestable — claiming
    // attestation for a proxied model would be proof that isn't there.

    enum Confidentiality: String, Codable, Equatable {
        case teeOwn          // near.ai's own attested enclave
        case teeThirdParty   // attested, third-party hardware (Chutes)
        case proxied         // passthrough to an upstream API — no enclave

        /// Whether a model in this tier can present a verifiable attestation.
        var isAttestable: Bool { self != .proxied }

        /// ONE VOCABULARY for the tier, so a section header, a row tag and the
        /// model detail page cannot describe the same guarantee three ways.
        /// It was a private helper in the model browser, which is why nothing
        /// else could say it without restating it.
        var label: String {
            switch self {
            case .teeOwn:        return "end-to-end encrypted"
            case .teeThirdParty: return "attested on third-party hardware"
            case .proxied:       return "proxied"
            }
        }
    }

    /// Cache of authoritative tiers keyed off the live `/v1/models` `owned_by`,
    /// so the (synchronous) capability gate can consult the catalog once it has
    /// loaded. Before then, `classify` provides an id-based fallback.
    private static let tierCache = OSAllocatedUnfairLock(initialState: [String: Confidentiality]())

    static func recordTiers(_ tiers: [String: Confidentiality]) {
        guard !tiers.isEmpty else { return }
        tierCache.withLock { cache in
            for (id, tier) in tiers { cache[id.lowercased()] = tier }
        }
    }

    /// What the catalogue has actually said about these ids, for saving
    /// beside a list. Only ids near.ai answered for: an id the guess merely
    /// assumed must not be written down as though it were told to us.
    static func knownTiers(forIDs ids: [String]) -> [String: Confidentiality] {
        tierCache.withLock { cache in
            var out: [String: Confidentiality] = [:]
            for id in ids {
                if let tier = cache[id.lowercased()] { out[id.lowercased()] = tier }
            }
            return out
        }
    }

    /// Test hook: clear the authoritative cache so `classify` is exercised.
    static func resetTierCache() { tierCache.withLock { $0.removeAll() } }

    /// The confidentiality tier for a model id — authoritative cache first
    /// (populated from the live catalog's `owned_by`), else the id heuristic.
    static func confidentiality(forID id: String) -> Confidentiality {
        // THE ID VETOES THE CATALOGUE, one way only: down.
        //
        // `owned_by` is near.ai's own claim and it is not always right. Observed
        // live 2026-08-02: `anthropic/claude-sonnet-5` came back
        // `owned_by: "nearai"` while `claude-sonnet-4-5` and `-4-6` came back
        // `"anthropic"`. The cache is consulted before the heuristic, so that
        // one field promoted a PROXIED Anthropic model to `.teeOwn` and teemoon
        // told the user "end-to-end encrypted" about a passthrough to a closed
        // frontier API.
        //
        // Anthropic, OpenAI and Google do not release these weights, so no
        // third party can be running them in its own enclave. When the id names
        // one of those vendors, no upstream field may upgrade the tier —
        // teemoon must never claim a stronger guarantee than the evidence
        // supports, and a wrong "end-to-end encrypted" is the worst thing this
        // app can say.
        //
        // Downgrades still work: the cache can move a model teemoon guessed was
        // own-fleet to third-party or proxied. Only the promotion is refused.
        let byID = classify(id)
        if byID == .proxied { return .proxied }
        if let cached = tierCache.withLock({ $0[id.lowercased()] }) { return cached }
        return byID
    }

    /// True when a near.ai model runs in an attested enclave (own or third-party)
    /// rather than a plain proxy. The single gate for claiming attestation/E2EE.
    static func isAttestable(_ id: String) -> Bool { confidentiality(forID: id).isAttestable }

    /// Maps `/v1/models` `owned_by` to a tier. `nearai` → own fleet; a marker of
    /// third-party attestation (Chutes) → third-party; any real upstream vendor
    /// name → proxied. nil when `owned_by` is absent (caller keeps the heuristic).
    static func tierFromOwnedBy(_ ownedBy: String?) -> Confidentiality? {
        guard let o = ownedBy?.lowercased(), !o.isEmpty else { return nil }
        if o == "nearai" || o == "near" || o == "near.ai" { return .teeOwn }
        if o.contains("chutes") || o.contains("3p") || o.contains("attested") { return .teeThirdParty }
        return .proxied
    }

    /// Id-based fallback tier, used before the live catalog has loaded. near.ai
    /// proxies the closed frontier APIs (Claude, GPT-5.x/4.x/o-series, Gemini,
    /// Qwen-Max); everything else it lists is open-weight and self-hosted in a
    /// TEE. gpt-oss and gemma are open-weight and checked first so the broader
    /// vendor rules don't misfile them as proxied.
    static func classify(_ id: String) -> Confidentiality {
        let l = id.lowercased()
        // Known third-party "attested" ids (Chutes — anonymous; near.ai exposes
        // no confidential endpoint for them, so no E2EE path via near.ai).
        // An exact-id set because their lowercased ids collide with the
        // own-fleet namespace (`qwen/…` vs `Qwen/…`).
        if KnownModel.nearAIAttestedThirdPartyIDs.contains(where: { $0.lowercased() == l }) {
            return .teeThirdParty
        }
        if l.contains("gpt-oss") || l.contains("gemma") { return .teeOwn }
        if l.contains("claude") || l.contains("anthropic") { return .proxied }
        if l.contains("gemini") { return .proxied }
        if l.contains("openai/") || l.contains("gpt-") || l.hasPrefix("gpt") { return .proxied }
        if l.hasPrefix("o3") || l.hasPrefix("o4") || l.contains("/o3") || l.contains("/o4") { return .proxied }
        if l.contains("-max") || l.contains(".max") { return .proxied }
        // Vendor namespaces near.ai only proxies. `deepseek/…` is proxied,
        // `deepseek-ai/…` is a near.ai node — keep the Python mirror in step.
        if l.hasPrefix("x-ai/") || l.hasPrefix("deepseek/") { return .proxied }
        return .teeOwn
    }

    // Identity/formatting helpers are catalog-generic — see `ModelCatalog`,
    // which every adapter shares. Kept here as forwarders so near.ai call sites
    // (and its tests) read as before.

    static func isNonChat(_ id: String) -> Bool { ModelCatalog.isNonChat(id) }

    /// Display vendor label for a model id (`vendor/name` namespace, else family).
    static func vendorLabel(forID id: String) -> String { ModelCatalog.vendorLabel(forID: id) }

    /// The last path component of the id, used as a display name for models
    /// the curated list doesn't cover.
    static func displayName(forID id: String) -> String { ModelCatalog.displayName(forID: id) }

    /// Whether two model ids belong to DIFFERENT vendors (both must resolve; a
    /// nil id yields false — can't tell). Vendor labels normalize namespace
    /// aliases (`z-ai`/`zai-org` → Z.ai), so alias spellings of the same model
    /// are NOT a mismatch. Used to reject a reused near.ai node whose
    /// compose-manager action log's latest `compose_up` points at a DIFFERENT
    /// model's YAML than the one requested (the DeepSeek-host-shows-Qwen bug).
    static func differentVendor(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return vendorLabel(forID: a).caseInsensitiveCompare(vendorLabel(forID: b)) != .orderedSame
    }

    /// Slug = last path component, lowercased, minus a quant suffix — the
    /// vendor-agnostic model key used to match live ids to curated metadata.
    /// (A curated "glm-5.1-fp8" and a live "glm-5.1" must produce the SAME slug;
    /// that drift is what made the default model flicker.) See `ModelCatalog`.
    static func slug(_ id: String) -> String { ModelCatalog.slug(id) }

    /// The rows an "end-to-end encrypted" pick may offer: near.ai's own fleet
    /// only, and only where near.ai publishes a direct host — that host is
    /// where the Ed25519 key binding comes from, so it IS "E2EE works".
    /// Attested third-party (Chutes) hardware passes `isAttestable` and has no
    /// confidential endpoint, which is the overclaim that screen exists to
    /// avoid.
    static func encryptedChoices(from models: [KnownModel]) -> [KnownModel] {
        // The directory answers for a row built while it was cold.
        models.filter {
            ($0.directBaseURL != nil || EndpointDirectory.persistedBase(forModel: $0.id) != nil)
                && confidentiality(forID: $0.id) == .teeOwn
                && !isNonChat($0.id)
        }
    }

    /// Live ids → rows, ordered for a person reading the list: what teemoon
    /// can seal first, then what near.ai attests on someone else's hardware,
    /// then the plain proxies; newest first inside each tier.
    static func ordered(_ models: [KnownModel]) -> [KnownModel] {
        func rank(_ m: KnownModel) -> Int {
            switch confidentiality(forID: m.id) {
            case .teeOwn: return 0
            case .teeThirdParty: return 1
            case .proxied: return 2
            }
        }
        return models.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            switch (a.element.created, b.element.created) {
            case let (x?, y?) where x != y: return x > y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.offset < b.offset      // keep the server's order
            }
        }.map(\.element)
    }

    // MARK: - /v1/models wire contract
    //
    // near.ai's `/v1/models` is an OpenAI-compatible list, EXTENDED with the metadata
    // teemoon needs — pricing, context, capabilities, tier — so the live response is
    // the whole row. The one thing it does not give is the direct TEE host, which
    // comes from `/endpoints`.
    // The endpoint is PUBLIC (no key required). Full shape modeled per project rule.
    // Docs: https://docs.near.ai — GET https://cloud-api.near.ai/v1/models.

    struct ModelsResponse: Decodable {
        let object: String?
        let data: [Model]

        struct Model: Decodable {
            let id: String
            let object: String?
            let created: Int?
            let owned_by: String?
            let name: String?
            let description: String?
            let pricing: Pricing?
            let context_length: Int?
            let max_output_length: Int?
            let architecture: Architecture?
            let input_modalities: [String]?
            let output_modalities: [String]?
            let supported_sampling_parameters: [String]?
            let supported_features: [String]?
            /// near.ai publishes both, and teemoon rendered neither: the weights'
            /// precision, and the repo they came from.
            let quantization: String?
            let hugging_face_id: String?
            let is_ready: Bool?
            let top_provider: TopProvider?

            /// `created` is a unix timestamp; 0/absent means no date was reported,
            /// and `ModelCatalog.isNew` then declines to badge rather than guessing.
            /// Same shape and same treatment as xAI's — see `XAIAdapter.Entry`.
            var createdDate: Date? {
                guard let created, created > 0 else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(created))
            }
        }
        /// Per-1M-token prices as Doubles (`input`/`output`), plus the raw per-token
        /// strings near.ai also returns.
        struct Pricing: Decodable {
            let input: Double?
            let output: Double?
            let prompt: String?
            let completion: String?
            let image: String?
            let request: String?
            let input_cache_read: String?
        }
        struct Architecture: Decodable {
            let inputModalities: [String]?
            let outputModalities: [String]?
        }
        struct TopProvider: Decodable {
            let context_length: Int?
            let max_completion_tokens: Int?
            let is_moderated: Bool?
        }
    }

    /// Fetches `/v1/models` and builds the browser list from LIVE metadata (price,
    /// context, capabilities, tier), or nil if unavailable. No key required —
    /// sends one only if the caller has it.
    static func fetchLive(apiKey: String = "", session: URLSession = .shared) async -> [KnownModel]? {
        var request = URLRequest(url: URL(string: ProviderKeyValidator.nearAIModelsURL)!)
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 10

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            logger.warning("[catalog] /v1/models unavailable")
            return nil
        }
        guard let list = try? JSONDecoder().decode(ModelsResponse.self, from: data), !list.data.isEmpty else {
            logger.warning("[catalog] /v1/models decode failed")
            return nil
        }
        // Record authoritative confidentiality tiers from `owned_by` so the capability
        // gate stops claiming attestation for proxied models.
        var tiers: [String: Confidentiality] = [:]
        for model in list.data {
            if let tier = tierFromOwnedBy(model.owned_by) { tiers[model.id.lowercased()] = tier }
        }
        recordTiers(tiers)
        logger.info("[catalog] recorded \(tiers.values.filter { $0 == .proxied }.count) proxied / \(tiers.values.filter { $0 != .proxied }.count) attestable tier(s)")

        let models = await buildModels(from: list.data)
        logger.info("[catalog] live model list — \(models.count) chat model(s)")
        return models.isEmpty ? nil : models
    }

    /// Builds `KnownModel`s straight from the live `/v1/models` metadata. The only
    /// thing the endpoint doesn't provide is the E2EE `directBaseURL`, which comes
    /// from near.ai's endpoints directory.
    ///
    /// `now` is injectable so the recency badge can be tested against a captured
    /// response instead of drifting with the clock.
    static func buildModels(
        from live: [ModelsResponse.Model], now: Date = Date()
    ) async -> [KnownModel] {
        var seen = Set<String>()
        var result: [KnownModel] = []
        for m in live where !isNonChat(m.id) {
            let key = m.id.lowercased()
            guard seen.insert(key).inserted else { continue }
            // The directory, never a rule. These are deployment hostnames:
            // `deepseek-ai/DeepSeek-V4-Flash` is served by `dsv4-flash`, and one
            // host serves two ids, so nothing can compute them.
            var direct: String?
            if confidentiality(forID: m.id) == .teeOwn {
                direct = (await EndpointDirectory.shared.directBase(forModel: m.id))?.absoluteString
            }
            result.append(KnownModel(
                id: m.id,
                displayName: m.name ?? displayName(forID: m.id),
                vendor: vendorLabel(forID: m.id),
                price: priceLabel(m.pricing),
                contextWindow: contextLabel(m.context_length),
                // Derived from near.ai's own `created`, so the badge expires by
                // itself — the same rule grok and fireworks already use. It was
                // simply never read: the field was modelled and unused, so the
                // live picker showed NO near.ai badge at all, while Where's browse
                // rendered the curated snapshot's frozen ones.
                isNew: ModelCatalog.isNew(created: m.createdDate, now: now),
                created: m.createdDate,
                directBaseURL: direct,
                capabilities: capabilities(from: m),
                // Straight through, unedited. near.ai already writes a real
                // description (it even names the serving stack and the CVM) and
                // publishes the features and sampling parameters each model
                // accepts — the latter being a params catalogue teemoon would
                // otherwise have to probe a 400 for.
                summary: m.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfBlank,
                features: m.supported_features ?? [],
                samplingParameters: m.supported_sampling_parameters ?? [],
                maxOutputTokens: m.max_output_length,
                inputModalities: m.input_modalities ?? [],
                huggingFaceURL: m.hugging_face_id?.nilIfBlank
                    .map { "https://huggingface.co/" + $0 },
                quantization: m.quantization?.nilIfBlank,
                // The tier, resolved where the catalogue is — not in a view.
                confidentialityNote: confidentiality(forID: m.id).label))
        }
        return ordered(result)
    }

    /// "$1/$5" (whole) or "$1.40/$4.40" from per-1M-token input/output prices.
    static func priceLabel(_ p: ModelsResponse.Pricing?) -> String {
        ModelCatalog.priceLabel(inputPerMillion: p?.input, outputPerMillion: p?.output)
    }

    /// "262k" / "1M" / "1.1M" from a token count.
    static func contextLabel(_ n: Int?) -> String { ModelCatalog.contextLabel(n) }

    /// Capabilities straight from the live model: `supported_features` → tools
    /// and reasoning, input modalities → vision and audio. Authoritative for
    /// near.ai (no more guessing).
    ///
    /// near.ai says `reasoning` where Ollama says `thinking`; both mean the
    /// model reasons before answering, so both land on `.thinking`.
    ///
    /// Deliberately NOT mapped: `structured_outputs`, `json_mode` and
    /// `logprobs`. Those describe the shape of a REQUEST the endpoint will
    /// accept, not something the model can do — a different axis, and one
    /// nothing in teemoon gates on. Recording them here would put two kinds of
    /// fact in one set.
    static func capabilities(from m: ModelsResponse.Model) -> ModelCapabilities {
        var caps: ModelCapabilities = []
        let features = m.supported_features ?? []
        if features.contains("tools") { caps.insert(.tools) }
        if features.contains("reasoning") { caps.insert(.thinking) }
        let modalities = (m.input_modalities ?? []) + (m.architecture?.inputModalities ?? [])
        if modalities.contains("image") { caps.insert(.vision) }
        if modalities.contains("audio") { caps.insert(.audio) }
        return caps
    }
}
