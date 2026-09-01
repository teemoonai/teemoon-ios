//
//  FireworksAdapter.swift
//  teemoon
//
//  Fireworks AI model catalogue, contained in one file.
//  Inference is OpenAI-compat at `https://api.fireworks.ai/inference/v1/*`, but
//  the model list teemoon needs lives on the CONTROL PLANE at
//  `https://api.fireworks.ai/v1/accounts/fireworks/models`.
//
//  Why the control plane, not `/inference/v1/models`:
//   • **Completeness.** `/inference/v1/models` under-reports: it returned 6
//     models while 11 serverless models were callable — `deepseek-v4-flash`,
//     `kimi-k2p7-code`, `minimax-m3`, `nemotron-3-ultra-nvfp4` and others were
//     missing from the picker yet answered `/chat/completions` fine.
//   • **Metadata.** The control plane carries `displayName`, `contextLength`,
//     `supportsTools`, `supportsImageInput`, `state` and `deprecationDate`; the
//     inference list carries ids (+ a couple of flags) and nothing to render.
//   • Every id is `accounts/fireworks/models/<slug>`, whose "namespace" is the
//     meaningless "accounts" — vendor comes from the slug's family
//     (`ModelCatalog.vendorLabel`), else the whole catalogue sat under one
//     "accounts" section.
//
//  Fireworks publishes no price in either API, so the per-1M rates come from the
//  curated `KnownModel.fireworksModels` snapshot (kept honest by
//  the catalog generator), matched by slug.
//
//  Wire contract — https://docs.fireworks.ai/api-reference/list-models
//   GET /v1/accounts/{account}/models?pageSize&pageToken&filter
//   filter is CEL over the snake_case field names: `supports_serverless=true`.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "fireworks-adapter")

enum FireworksAdapter {

    /// Hosts this adapter serves.
    static func handles(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "fireworks.ai" || host.hasSuffix(".fireworks.ai")
    }

    /// The account whose public catalogue holds the first-party serverless
    /// models. A user's own fine-tunes live under their account id and are not
    /// listed here (they aren't serverless).
    static let catalogAccount = "fireworks"

    /// Control-plane base derived from the inference base URL: the same host,
    /// with `/inference` dropped — `…/inference/v1` → `…/v1`.
    static func controlPlaneBase(from inferenceBase: URL) -> URL? {
        guard var comps = URLComponents(url: inferenceBase, resolvingAgainstBaseURL: false) else {
            return nil
        }
        comps.path = "/v1/accounts/\(catalogAccount)/models"
        comps.query = nil
        comps.fragment = nil
        return comps.url
    }

    // MARK: - List models

    /// Lists the serverless chat models, doubling as the connection test. Falls
    /// back to the generic `/models` probe when the control plane refuses (an
    /// account-scoped key, or an API change) so the user still gets a list.
    static func listModels(
        baseURL: URL,
        apiKey: String,
        session: URLSession = .shared
    ) async -> EndpointModelCatalog.ProbeResult {
        guard let base = controlPlaneBase(from: baseURL) else {
            return await EndpointModelCatalog.probe(baseURL: baseURL, apiKey: apiKey, session: session)
        }
        var records: [ModelsResponse.Model] = []
        var pageToken: String? = nil
        var pagesFetched = 0
        repeat {
            switch await fetchPage(base: base, pageToken: pageToken, apiKey: apiKey, session: session) {
            case .failure(let kind):
                logger.warning("[list] control plane failed (\(String(describing: kind))) — using the generic /models probe")
                return await EndpointModelCatalog.probe(baseURL: baseURL, apiKey: apiKey, session: session)
            case .success(let page):
                records.append(contentsOf: page.models)
                pageToken = page.nextPageToken?.isEmpty == false ? page.nextPageToken : nil
                pagesFetched += 1
            }
            // The serverless set is small (one page today); the cap only stops a
            // malformed nextPageToken from looping.
        } while pageToken != nil && pagesFetched < 5

        let models = buildModels(from: records)
        guard !models.isEmpty else { return .failed(.badResponse) }
        logger.info("[list] \(models.count) fireworks serverless chat model(s) from \(records.count) record(s)")
        return .connected(models)
    }

    /// Pure (no network) so it is unit-testable against a captured payload.
    ///
    /// Everything here is live except the price: existence, name, context,
    /// tools/vision, and recency all come from the control plane, so the shipped
    /// table is a price list and nothing more (Fireworks serves no price field —
    /// see the header). Rows run newest-first within a vendor, by `createTime`.
    static func buildModels(from records: [ModelsResponse.Model], now: Date = Date()) -> [KnownModel] {
        var seen = Set<String>()
        let models: [KnownModel] = records.compactMap { r in
            guard r.isSelectableChatModel, seen.insert(r.name.lowercased()).inserted else { return nil }
            var caps: ModelCapabilities = []
            if r.supportsTools == true { caps.insert(.tools) }
            if r.supportsImageInput == true { caps.insert(.vision) }
            // Every id is `accounts/{account}/models/{slug}` — the namespace
            // names the hosting account, never the model's vendor, so the
            // section comes from the slug's family.
            let vendor = ModelCatalog.familyVendor(forID: ModelCatalog.slug(r.name)) ?? "Fireworks"
            return KnownModel(
                id: r.name,
                // `productName`, not the raw field. Fireworks writes these by hand
                // and they are the one set of rows in the browser that didn't read
                // like the rest — see that function for the three styles it fixes.
                displayName: (r.displayName?.nilIfBlank).map { ModelCatalog.productName($0, vendor: vendor) }
                    ?? ModelCatalog.displayName(forID: r.name),
                vendor: vendor,
                price: price(forID: r.name),
                contextWindow: ModelCatalog.contextLabel(r.contextLength),
                isNew: ModelCatalog.isNew(created: ModelCatalog.parseISO8601(r.createTime), now: now),
                capabilities: caps,
                summary: r.description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                huggingFaceURL: r.huggingFaceUrl?.nilIfBlank,
                githubURL: r.githubUrl?.nilIfBlank,
                // Predictable per-model page, verified live against
                // deepseek-v4-flash-0731. The slug is the id's last component.
                modelPageURL: "https://app.fireworks.ai/models/fireworks/"
                    + ModelCatalog.displayName(forID: r.name),
                // Parsed HERE, at the wire, not re-parsed by every reader of the
                // model. Fireworks is the only provider that publishes this.
                deprecationDate: KnownModel.deprecationDate(fromProvider: r.deprecationDate))
        }
        return sortByVendorThenRecency(models, records: records)
    }

    /// The shipped rate for an id, matched exactly and then by slug so a
    /// namespace or quant-suffix change upstream doesn't silently blank it.
    /// Empty when the model isn't in the table — a row with no price, never a
    /// wrong one.
    static func price(forID id: String) -> String {
        if let exact = KnownModel.fireworksPrices[id] { return exact }
        let key = ModelCatalog.slug(id)
        if let bySlug = KnownModel.fireworksPrices.first(
            where: { ModelCatalog.slug($0.key) == key })?.value { return bySlug }
        // A DATED SNAPSHOT is the same model at the same tier.
        //
        // Fireworks republishes a family under a release date —
        // `deepseek-v4-flash-0731` — and that id matches neither the table's key
        // nor its slug, because `ModelCatalog.slug` peels precision and quant
        // markers and nothing else. The row then quoted no price at all, which
        // is what surfaced in the Where chip.
        //
        // Verified rather than assumed before generalising: Fireworks lists
        // deepseek-v4-flash-0731 at $0.14/$0.28, the same as the undated entry
        // already in the table.
        //
        // Exact match is tried FIRST, above, so if a future snapshot is ever
        // priced differently, adding its full id to the table overrides this.
        let undated = droppingDateSuffix(key)
        guard undated != key else { return "" }
        return KnownModel.fireworksPrices.first {
            ModelCatalog.slug($0.key) == undated
        }?.value ?? ""
    }

    /// Drops a trailing release-date suffix — `-0731`, `-202607`, `-20260731`.
    ///
    /// Deliberately narrow: the tail must be ALL DIGITS and of a date-ish
    /// length. Fireworks slugs spell their sizes and variants with letters
    /// (`gpt-oss-120b`, `kimi-k2p6`, `minimax-m2p7`), so nothing in the shipped
    /// table can lose a meaningful segment to this.
    private static func droppingDateSuffix(_ slug: String) -> String {
        guard let dash = slug.lastIndex(of: "-") else { return slug }
        let tail = slug[slug.index(after: dash)...]
        guard [4, 6, 8].contains(tail.count), tail.allSatisfy(\.isNumber) else { return slug }
        return String(slug[..<dash])
    }

    /// Vendors in first-appearance order, newest model first inside each — the
    /// ordering the curated block used to encode by hand, now read from
    /// `createTime` so a new release lands in the right place on its own.
    private static func sortByVendorThenRecency(
        _ models: [KnownModel], records: [ModelsResponse.Model]
    ) -> [KnownModel] {
        let createdByID = Dictionary(
            records.map { ($0.name.lowercased(), ModelCatalog.parseISO8601($0.createTime) ?? .distantPast) },
            uniquingKeysWith: { first, _ in first })
        func created(_ m: KnownModel) -> Date { createdByID[m.id.lowercased()] ?? .distantPast }
        // A vendor ranks by its newest model, so the freshest family leads.
        var newestByVendor: [String: Date] = [:]
        for m in models {
            newestByVendor[m.vendor] = max(newestByVendor[m.vendor] ?? .distantPast, created(m))
        }
        return models.sorted { a, b in
            let (va, vb) = (newestByVendor[a.vendor] ?? .distantPast, newestByVendor[b.vendor] ?? .distantPast)
            if va != vb { return va > vb }
            if a.vendor != b.vendor { return a.vendor < b.vendor }   // stable for equal dates
            if created(a) != created(b) { return created(a) > created(b) }
            return a.id < b.id
        }
    }

    // MARK: - Fetch

    private static func fetchPage(
        base: URL, pageToken: String?, apiKey: String, session: URLSession
    ) async -> Result<ModelsResponse, EndpointModelCatalog.FailureKind> {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return .failure(.badResponse)
        }
        comps.queryItems = [
            URLQueryItem(name: "pageSize", value: "200"),
            // CEL filter over snake_case fields — camelCase is rejected with 400.
            URLQueryItem(name: "filter", value: "supports_serverless=true"),
        ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
        guard let url = comps.url else { return .failure(.badResponse) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .failure(EndpointModelCatalog.failureKind(forTransport: error))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let kind = EndpointModelCatalog.failureKind(forStatus: status, body: data) { return .failure(kind) }
        guard let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            return .failure(.badResponse)
        }
        return .success(decoded)
    }
}

private extension String {
    // Moved to Provider.swift so every adapter can use it — it was
    // fileprivate here and the near.ai catalogue needed the same rule.
    var unusedNilIfBlank: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}

// MARK: - Wire contract — https://docs.fireworks.ai/api-reference/list-models

extension FireworksAdapter {

    /// `GET /v1/accounts/{account}/models` — the control-plane catalogue.
    /// `totalSize` counts matches for the filter, `nextPageToken` is empty on the
    /// last page. (`baseModelDetails` carries a further ~10 training-oriented
    /// fields — checkpoint format, HF file list, world size — modeled here only
    /// down to what a picker row can use.)
    struct ModelsResponse: Decodable {
        let models: [Model]
        let nextPageToken: String?
        let totalSize: Int?

        struct Model: Decodable {
            /// Full resource id — `accounts/fireworks/models/kimi-k2p6`. This is
            /// exactly what `/chat/completions` expects as `model`.
            let name: String
            let displayName: String?
            let description: String?
            let createTime: String?
            let updateTime: String?
            /// HF_BASE_MODEL · CUSTOM_MODEL · EMBEDDING_MODEL · FLUMINA_BASE_MODEL
            /// (image) · *_ADDON (LoRA/draft adapters, not directly callable).
            let kind: String?
            /// READY when it can serve; anything else is not selectable.
            let state: String?
            let status: Status?
            /// Set once retirement is announced — such a model must not be offered.
            let deprecationDate: String?
            let contextLength: Int?
            let trainingContextLength: Int?
            let supportsServerless: Bool?
            let supportsTools: Bool?
            let supportsImageInput: Bool?
            let supportsLora: Bool?
            let tunable: Bool?
            let `public`: Bool?
            let huggingFaceUrl: String?
            let githubUrl: String?
            let serverlessModes: [String]?
            let deployedModelRefs: [DeployedModelRef]?
            let baseModelDetails: BaseModelDetails?

            struct Status: Decodable {
                let code: String?
                let message: String?
            }
            struct DeployedModelRef: Decodable {
                let name: String?
                let deployment: String?
                let state: String?
                let `default`: Bool?
            }
            struct BaseModelDetails: Decodable {
                let modelType: String?          // "llama", "deepseek_v4", …
                let parameterCount: String?     // decimal string, e.g. "284000000000"
                let moe: Bool?
                let checkpointFormat: String?
                let defaultPrecision: String?
                let worldSize: Int?
            }

            /// Kinds that are not a chat model you can select: embeddings /
            /// rerankers, Flumina (image), and adapters that only load on top of
            /// a base model.
            private static let nonChatKinds: Set<String> = [
                "EMBEDDING_MODEL", "FLUMINA_BASE_MODEL", "FLUMINA_ADDON",
                "DRAFT_ADDON", "HF_PEFT_ADDON", "HF_TEFT_ADDON",
            ]

            /// Serverless, ready, not deprecated, and actually a chat model.
            var isSelectableChatModel: Bool {
                guard supportsServerless == true else { return false }
                guard deprecationDate == nil else { return false }
                if let state, state != "READY" { return false }
                if let kind, Self.nonChatKinds.contains(kind) || kind.hasSuffix("_ADDON") { return false }
                return !ModelCatalog.isNonChat(name)
            }
        }
    }
}
