//
//  OpenRouterAdapter.swift
//  teemoon
//
//  OpenRouter model catalogue, contained in one file.
//  Inference is OpenAI-compat at `https://openrouter.ai/api/v1/*`, and the
//  `/api/v1/models` list is RICHER than the OpenAI shape: per-token prices,
//  context window, modalities, supported parameters, a description and the
//  Hugging Face id. It is public — no key needed to read it — which is why a
//  keyless OpenRouter row can show a live model count the way near.ai's does.
//
//  Why native, not the generic probe: the generic probe keeps ids only, so
//  every row would render with no price and no context. OpenRouter is the one
//  catalogue that prices EVERY model it lists, including the frontier vendors,
//  so it is also the source of `ListPriceSnapshot` for custom first-party
//  endpoints (regenerated from this same list before every release).
//
//  Wire contract — https://openrouter.ai/docs/api-reference/list-available-models
//   GET /api/v1/models — prices are USD per TOKEN as decimal strings
//   ("0.0000025" = $2.50 per 1M); "0" on both means a free model; a negative
//   value means dynamic (the auto router) and is not a price.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "openrouter-adapter")

enum OpenRouterAdapter {

    /// Hosts this adapter serves.
    static func handles(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "openrouter.ai" || host.hasSuffix(".openrouter.ai")
    }

    // MARK: - List models

    /// Lists the chat models, doubling as the connection test. The list is
    /// public, so the key is sent only when there is one — a keyless probe
    /// still lists, and a bad key is only discovered at the first request.
    static func listModels(
        baseURL: URL,
        apiKey: String,
        session: URLSession = .shared
    ) async -> EndpointModelCatalog.ProbeResult {
        let list: ModelsResponse
        switch await EndpointModelCatalog.fetchList(ModelsResponse.self, from: baseURL.appendingPathComponent("models"),
                                                    apiKey: apiKey, session: session) {
        case .failure(let kind): return .failed(kind)
        case .success(let decoded): list = decoded
        }
        let models = buildModels(from: list.data)
        guard !models.isEmpty else { return .failed(.badResponse) }
        logger.info("[list] \(models.count) openrouter chat model(s) from \(list.data.count) record(s)")
        return .connected(models)
    }

    /// Pure (no network) so it is unit-testable against a captured payload.
    /// Newest first by OpenRouter's `created`; the browser groups by vendor.
    static func buildModels(from records: [ModelsResponse.Model], now: Date = Date()) -> [KnownModel] {
        var seen = Set<String>()
        return records
            .filter { $0.isChatModel }
            .sorted { $0.created ?? 0 > $1.created ?? 0 }
            .compactMap { record -> KnownModel? in
                guard seen.insert(record.id.lowercased()).inserted else { return nil }
                return row(record, now: now)
            }
    }

    /// One catalogue record as a row. A named function, not an inline closure:
    /// OpenRouter fills nearly every field teemoon has, and the type checker
    /// gives up on an initialiser that long inside a `compactMap`.
    static func row(_ record: ModelsResponse.Model, now: Date) -> KnownModel {
        let vendor = ModelCatalog.vendorLabel(forID: record.id)
        var caps: ModelCapabilities = []
        if record.supported_parameters?.contains("tools") == true { caps.insert(.tools) }
        if record.architecture?.input_modalities?.contains("image") == true { caps.insert(.vision) }
        let (price, isFree) = priceLabel(record.pricing)
        let summary = record.description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let huggingFace: String? = record.hugging_face_id?.nilIfBlank.map { "https://huggingface.co/" + $0 }

        var model = KnownModel(
            id: record.id,
            displayName: productName(record.name, id: record.id, vendor: vendor),
            vendor: vendor,
            price: price,
            contextWindow: ModelCatalog.contextLabel(record.context_length),
            isNew: ModelCatalog.isNew(created: record.createdDate, now: now),
            created: record.createdDate,
            capabilities: caps,
            summary: summary,
            features: features(from: record),
            samplingParameters: record.supported_parameters ?? [],
            maxOutputTokens: record.top_provider?.max_completion_tokens,
            inputModalities: record.architecture?.input_modalities ?? [],
            huggingFaceURL: huggingFace,
            // The model page is the id verbatim under the site root.
            modelPageURL: "https://openrouter.ai/" + record.id,
            deprecationDate: ModelCatalog.parseISO8601(record.expiration_date),
            isFree: isFree)
        model.openWeights = huggingFace != nil
        model.extraCosts = extraCosts(record.pricing)
        model.knowledgeCutoff = record.knowledge_cutoff?.nilIfBlank
        model.aliasOf = record.alias_target?.slug?.nilIfBlank
        model.reasoningEfforts = record.reasoning?.supported_efforts ?? []
        return model
    }

    /// "$2.50/$15" from per-token decimal strings, or ("", true) for a model
    /// OpenRouter serves at zero. A negative or missing rate is NOT a price —
    /// the auto router quotes -1 — and renders blank rather than "$-1".
    static func priceLabel(_ p: ModelsResponse.Model.Pricing?) -> (label: String, isFree: Bool) {
        guard let input = perMillion(p?.prompt), let output = perMillion(p?.completion),
              input >= 0, output >= 0 else { return ("", false) }
        if input == 0 && output == 0 { return ("", true) }
        return (ModelCatalog.priceLabel(inputPerMillion: input, outputPerMillion: output), false)
    }

    /// "0.0000025" (USD per token) → 2.5 (USD per 1M tokens). Rounded to the
    /// cent so binary float noise can't print "$2.4999".
    static func perMillion(_ perToken: String?) -> Double? {
        guard let perToken, let v = Double(perToken) else { return nil }
        return (v * 1_000_000 * 100).rounded() / 100
    }

    /// Capability chips from the public card: what the model can be asked to
    /// DO. Sampling knobs (temperature, seed) are not features and stay on
    /// `samplingParameters`.
    ///
    /// Nothing is invented: `is_moderated: false` is silence, not a badge, and
    /// mandatory reasoning says so because the payload does.
    static func features(from record: ModelsResponse.Model) -> [String] {
        var out: [String] = []
        let params = Set(record.supported_parameters ?? [])
        if params.contains("tools") { out.append("tools") }
        if params.contains("reasoning") || record.reasoning != nil {
            out.append(record.reasoning?.mandatory == true ? "reasoning (required)" : "reasoning")
        }
        if params.contains("structured_outputs") { out.append("structured outputs") }
        if params.contains("response_format") { out.append("response format") }
        if record.top_provider?.is_moderated == true { out.append("moderated") }
        return out
    }

    /// Everything priced besides prompt and completion. Zero, negative and
    /// missing rates are dropped — the same rule the row's price follows.
    ///
    /// A time-window override needs a clock to be true, so it is skipped; a
    /// `min_prompt_tokens` override is a long-context rate that always applies
    /// past that length, and is shown.
    static func extraCosts(_ pricing: ModelsResponse.Model.Pricing?) -> [KnownModel.ExtraCost] {
        guard let pricing else { return [] }
        var rows: [KnownModel.ExtraCost] = []
        func perMillion(_ raw: String?, _ label: String) {
            guard let value = Self.perMillion(raw), value > 0 else { return }
            rows.append(.init(label: label, perMillion: value))
        }
        func perCall(_ raw: String?, _ label: String) {
            guard let raw, let value = Double(raw), value > 0 else { return }
            rows.append(.init(label: label, perCall: value))
        }
        perMillion(pricing.input_cache_read, "cache read")
        perMillion(pricing.input_cache_write, "cache write")
        perMillion(pricing.internal_reasoning, "reasoning tokens")
        perMillion(pricing.image, "image input")
        perMillion(pricing.image_output, "image output")
        perMillion(pricing.audio, "audio input")
        perCall(pricing.web_search, "web search")
        perCall(pricing.request, "per request")
        for override in pricing.overrides ?? [] {
            guard override.utc_start == nil, override.utc_end == nil, override.utc_days == nil,
                  let from = override.min_prompt_tokens,
                  let input = Self.perMillion(override.prompt ?? pricing.prompt),
                  let output = Self.perMillion(override.completion ?? pricing.completion),
                  input > 0 || output > 0 else { continue }
            rows.append(.init(label: "past \(ModelCatalog.contextLabel(from).lowercased())",
                              perMillion: input, perMillionOutput: output))
        }
        return rows
    }

    /// OpenRouter names every model "Vendor: Product" ("OpenAI: GPT-5.4",
    /// "SpaceXAI: Grok 4.5"). The vendor half is the section header, so it
    /// goes; the product half is then read like every other catalogue name.
    static func productName(_ raw: String?, id: String, vendor: String) -> String {
        guard let raw = raw?.nilIfBlank else { return ModelCatalog.displayName(forID: id) }
        let product: String
        if let colon = raw.range(of: ": ") {
            product = String(raw[colon.upperBound...])
        } else {
            product = raw
        }
        let named = ModelCatalog.productName(product, vendor: vendor)
        return named.nilIfBlank ?? ModelCatalog.displayName(forID: id)
    }
}

// MARK: - Wire contract — https://openrouter.ai/docs/api-reference/list-available-models

extension OpenRouterAdapter {

    struct ModelsResponse: Decodable {
        let data: [Model]

        struct Model: Decodable {
            let id: String
            let canonical_slug: String?
            let hugging_face_id: String?
            let name: String?
            let created: Int?
            let description: String?
            let context_length: Int?
            let architecture: Architecture?
            let pricing: Pricing?
            let supported_parameters: [String]?
            let top_provider: TopProvider?
            let knowledge_cutoff: String?
            let alias_target: AliasTarget?
            let expiration_date: String?
            let reasoning: Reasoning?

            struct Architecture: Decodable {
                let modality: String?
                let input_modalities: [String]?
                let output_modalities: [String]?
            }

            /// An alias row points at the model that actually answers.
            struct AliasTarget: Decodable {
                let name: String?
                let slug: String?
            }

            struct TopProvider: Decodable {
                let context_length: Int?
                let max_completion_tokens: Int?
                let is_moderated: Bool?
            }

            struct Reasoning: Decodable {
                var mandatory: Bool? = nil
                var default_enabled: Bool? = nil
                var supported_efforts: [String]? = nil
                var default_effort: String? = nil
            }

            /// USD per TOKEN as decimal strings, except `web_search` and
            /// `request`, which are per call. The two text rates make the
            /// picker row; the rest are the model card's cost lines.
            /// `var` with defaults so a test can build one from two prices.
            struct Pricing: Decodable {
                let prompt: String?
                let completion: String?
                var request: String? = nil
                var image: String? = nil
                var image_output: String? = nil
                var audio: String? = nil
                var web_search: String? = nil
                var internal_reasoning: String? = nil
                var input_cache_read: String? = nil
                var input_cache_write: String? = nil
                var overrides: [PricingOverride]? = nil
            }

            /// A rate that replaces the headline one past a prompt length, or
            /// inside a time window (which teemoon does not show — it would
            /// read as always-on).
            struct PricingOverride: Decodable {
                var min_prompt_tokens: Int? = nil
                var utc_start: Int? = nil
                var utc_end: Int? = nil
                var utc_days: [String]? = nil
                var prompt: String? = nil
                var completion: String? = nil
            }

            var createdDate: Date? {
                guard let created, created > 0 else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(created))
            }

            /// Chat models only: text out, not an embedding/media family, and
            /// not a `:batch` variant — batch is asynchronous and cannot answer
            /// a chat turn.
            var isChatModel: Bool {
                guard !ModelCatalog.isNonChat(id), !id.lowercased().hasSuffix(":batch") else { return false }
                guard let out = architecture?.output_modalities else { return true }
                return out.contains("text")
            }
        }
    }
}

// MARK: - Who can serve a model

extension OpenRouterAdapter {

    /// The vendor-neutral shape lives in `ModelOffer`; this name is what the
    /// adapter's own tests and mappers use.
    typealias ProviderOffer = ModelOffer

    /// `GET {base}/models/{author}/{slug}/endpoints`. The id's slash has to be
    /// a path separator: `appendingPathComponent("openai/gpt-5.4")` escapes it
    /// and 404s.
    static func offersURL(modelID: String, baseURL: URL) -> URL? {
        let parts = modelID.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return baseURL.appendingPathComponent("models")
            .appendingPathComponent(String(parts[0]))
            .appendingPathComponent(String(parts[1]))
            .appendingPathComponent("endpoints")
    }

    /// Who OpenRouter can route this model to. Empty on any failure: the card
    /// already carries the catalogue's own facts, and a missing table is
    /// absence, not an error worth a banner.
    ///
    /// The key is sent because latency and throughput are null without one;
    /// the list itself is public either way.
    static func listOffers(
        modelID: String,
        baseURL: URL,
        apiKey: String,
        authHeaderName: String? = nil,
        session: URLSession = .shared
    ) async -> [ProviderOffer] {
        guard let url = offersURL(modelID: modelID, baseURL: baseURL) else { return [] }
        let response: OffersResponse
        switch await EndpointModelCatalog.fetchList(
            OffersResponse.self, from: url, apiKey: apiKey,
            authHeaderName: authHeaderName, session: session
        ) {
        case .failure: return []
        case .success(let decoded): response = decoded
        }
        let zdr = await zeroDataRetentionOffers(
            baseURL: baseURL, apiKey: apiKey, authHeaderName: authHeaderName, session: session)
        let offers = buildOffers(from: response.data.endpoints, zeroDataRetention: zdr)
        logger.info("[offers] \(offers.count) provider(s) for \(modelID, privacy: .public)")
        return offers
    }

    /// Pure, so a captured payload pins the table without a network.
    static func buildOffers(
        from records: [OffersResponse.Endpoint],
        zeroDataRetention: Set<String> = []
    ) -> [ProviderOffer] {
        records.compactMap { record in
            guard let provider = record.provider_name?.nilIfBlank,
                  let tag = record.tag?.nilIfBlank else { return nil }
            let (price, isFree) = priceLabel(record.pricing)
            let quant = record.quantization?.nilIfBlank
            var offer = ProviderOffer(providerName: provider, tag: tag, price: price, isFree: isFree)
            offer.contextTokens = record.context_length
            offer.maxOutputTokens = record.max_completion_tokens
            // OpenRouter writes "unknown" where it means nothing; a row saying
            // "quantization: unknown" is worse than no row.
            offer.quantization = quant?.lowercased() == "unknown" ? nil : quant
            offer.uptimePercent = record.uptime_last_1d
            offer.latencyMilliseconds = record.latency_last_30m?.p50
            offer.throughputTokensPerSecond = record.throughput_last_30m?.p50
            offer.isZeroDataRetention = zeroDataRetention.contains(zdrKey(modelID: record.model_id, tag: tag))
            offer.supportsImplicitCaching = record.supports_implicit_caching == true
            return offer
        }
    }

    /// A model can appear on one provider under several tags, so the pair is
    /// the identity.
    static func zdrKey(modelID: String?, tag: String) -> String {
        (modelID ?? "").lowercased() + "\u{0}" + tag.lowercased()
    }

    /// The public zero-data-retention list, cached for the hour. A FAILURE IS
    /// NOT CACHED: one blip must not hide the badge for the rest of the
    /// process, which is the difference between "no badge" and "we didn't ask".
    static func zeroDataRetentionOffers(
        baseURL: URL,
        apiKey: String,
        authHeaderName: String? = nil,
        session: URLSession = .shared
    ) async -> Set<String> {
        if let cached = await ZeroDataRetentionList.shared.cached() { return cached }
        let url = baseURL.appendingPathComponent("endpoints").appendingPathComponent("zdr")
        switch await EndpointModelCatalog.fetchList(
            ZeroDataRetentionResponse.self, from: url, apiKey: apiKey,
            authHeaderName: authHeaderName, session: session
        ) {
        case .failure:
            return []
        case .success(let decoded):
            let keys = Set(decoded.data.compactMap { record -> String? in
                guard let tag = record.tag?.nilIfBlank else { return nil }
                return zdrKey(modelID: record.model_id, tag: tag)
            })
            await ZeroDataRetentionList.shared.store(keys)
            return keys
        }
    }

    static func resetZeroDataRetentionCache() async {
        await ZeroDataRetentionList.shared.reset()
    }
}

/// `GET /models/{author}/{slug}/endpoints` — `{ data: { endpoints: [...] } }`.
extension OpenRouterAdapter {
    struct OffersResponse: Decodable {
        let data: Body
        struct Body: Decodable { let endpoints: [Endpoint] }

        struct Endpoint: Decodable {
            let model_id: String?
            let provider_name: String?
            let tag: String?
            let quantization: String?
            let context_length: Int?
            let max_completion_tokens: Int?
            let pricing: ModelsResponse.Model.Pricing?
            /// Percent over the last day. The 5m and 30m windows are null on
            /// the public list, so this is the one teemoon reads.
            let uptime_last_1d: Double?
            /// Milliseconds, and null without a key (verified live 2026-09-15).
            let latency_last_30m: Percentiles?
            /// Tokens per second, same condition.
            let throughput_last_30m: Percentiles?
            let supports_implicit_caching: Bool?
        }

        struct Percentiles: Decodable { var p50: Double? = nil }
    }

    /// `GET /endpoints/zdr` — the same endpoint rows, for every model.
    struct ZeroDataRetentionResponse: Decodable {
        let data: [OffersResponse.Endpoint]
    }
}

/// Session cache for the zero-data-retention list: one fetch an hour, and
/// nothing remembered about a failure.
private actor ZeroDataRetentionList {
    static let shared = ZeroDataRetentionList()
    private var keys: Set<String>?
    private var storedAt: Date?
    private let ttl: TimeInterval = 3600

    func cached() -> Set<String>? {
        guard let keys, let storedAt, Date().timeIntervalSince(storedAt) < ttl else { return nil }
        return keys
    }

    func store(_ keys: Set<String>) {
        self.keys = keys
        storedAt = Date()
    }

    func reset() {
        keys = nil
        storedAt = nil
    }
}
