//
//  XAIAdapter.swift
//  teemoon
//
//  xAI (Grok) model catalogue, contained in one file.
//  xAI speaks OpenAI-compat at `https://api.x.ai/v1/*`, but its `/v1/models` is
//  RICHER than the OpenAI list — per-token prices, context window, aliases — and
//  it is joined by a sibling `/v1/language-models` that carries modalities and,
//  crucially, lists ONLY the text models.
//
//  Why native, not the generic /v1/models probe:
//   • the generic probe keeps ids only, so every Grok row rendered with no price
//     and no context, titled by its raw id ("grok-4.20-0309-non-reasoning");
//   • `/v1/models` also lists the `grok-imagine-*` image/video family, which the
//     generic probe offered as chat models — picking one breaks the chat;
//   • `/v1/language-models` reports `input_modalities`, so vision is modeled
//     instead of guessed.
//
//  Wire contract — https://docs.x.ai/docs/api-reference
//   GET /v1/models           — every model (text + media), price + context_length
//   GET /v1/language-models  — text models only, + modalities (no context_length)
//  Both are authenticated with `Authorization: Bearer <key>`.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "xai-adapter")

enum XAIAdapter {

    /// Hosts this adapter serves. `api.x.ai` today; matched on suffix so a
    /// regional/proxy subdomain still resolves here.
    static func handles(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "x.ai" || host.hasSuffix(".x.ai")
    }

    // MARK: - List models

    /// Lists the chat models, doubling as the connection test — same
    /// `ProbeResult` as every other adapter. `/v1/language-models` defines the
    /// SET (text only); `/v1/models` supplies each one's context window. Both
    /// are fetched concurrently; if the models call fails the list still renders,
    /// just without context windows.
    static func listModels(
        baseURL: URL,
        apiKey: String,
        session: URLSession = .shared
    ) async -> EndpointModelCatalog.ProbeResult {
        async let languageTask = fetch(
            LanguageModelsResponse.self, from: baseURL.appendingPathComponent("language-models"),
            apiKey: apiKey, session: session)
        async let modelsTask = fetch(
            ModelsResponse.self, from: baseURL.appendingPathComponent("models"),
            apiKey: apiKey, session: session)

        let language = await languageTask
        let models = await modelsTask

        // The language-models call is the load-bearing one — its failure is the
        // connection failure. Fall back to /v1/models (filtered to text models)
        // if only that one answered, so an xAI API change can't blank the list.
        let contextByID: [String: Int] = Dictionary(
            (try? models.get())?.data.compactMap { m in
                m.context_length.map { (m.id.lowercased(), $0) }
            } ?? [],
            uniquingKeysWith: { first, _ in first })

        let entries: [Entry]
        switch language {
        case .success(let list):
            entries = list.models.filter(\.isTextModel).map(Entry.init(language:))
        case .failure(let kind):
            guard case .success(let fallback) = models else { return .failed(kind) }
            logger.warning("[list] /v1/language-models unavailable — falling back to /v1/models")
            entries = fallback.data.filter(\.isTextModel).map(Entry.init(model:))
        }
        let known = buildModels(from: entries, contexts: contextByID)
        guard !known.isEmpty else { return .failed(.badResponse) }
        logger.info("[list] \(known.count) xai chat model(s)")
        return .connected(known)
    }

    /// Picker rows from the normalized entries. Pure (no network) so the same
    /// path runs in tests and previews. `contexts` maps a lowercased id to its
    /// window (from `/v1/models`); missing simply renders no context.
    /// Ordered newest-first by xAI's `created`, which is how the curated block
    /// reads too — the flagship leads instead of whatever the API listed first.
    static func buildModels(
        from entries: [Entry], contexts: [String: Int], now: Date = Date()
    ) -> [KnownModel] {
        entries.sorted { $0.created > $1.created }.map { entry in
            KnownModel(
                id: entry.id,
                // The ONLY curated field: ids read like build artifacts
                // ("grok-4.20-0309-non-reasoning"), so a product name is worth
                // keeping by hand. Everything else is live.
                displayName: KnownModel.grokDisplayNames[entry.id] ?? displayName(forID: entry.id),
                vendor: ModelCatalog.vendorLabel(forID: entry.id),
                price: ModelCatalog.priceLabel(inputPerMillion: entry.inputPerMillion,
                                               outputPerMillion: entry.outputPerMillion),
                contextWindow: ModelCatalog.contextLabel(contexts[entry.id.lowercased()]),
                // xAI publishes NO description and no weights/source links in
                // the API — `/v1/language-models` is ids, prices, context and
                // aliases — so grok's detail page has no "about" section rather
                // than a borrowed or invented one.
                //
                // It DOES have a per-model doc page, and the slug is the api id
                // verbatim. Verified for every id in the curated table, and an
                // invented id 307s where a real one 200s.
                //
                // An earlier check said this could not be verified, because it
                // used `curl -L` — which followed the 307 to a 200 not-found
                // page and made every id look alive, bogus ones included.
                // Redirects are the difference between "this exists" and "this
                // resolves to something".
                // Badge from xAI's own `created`, so it expires on its own.
                isNew: ModelCatalog.isNew(created: entry.createdDate, now: now),
                capabilities: entry.capabilities,
                modelPageURL: "https://docs.x.ai/developers/models/" + entry.id)
        }
    }

    /// One text model, normalized from whichever endpoint answered.
    struct Entry {
        let id: String
        let created: Int
        let inputPerMillion: Double?
        let outputPerMillion: Double?
        let capabilities: ModelCapabilities

        /// `created` is a unix timestamp; 0 means the endpoint didn't report one.
        var createdDate: Date? { created > 0 ? Date(timeIntervalSince1970: TimeInterval(created)) : nil }

        init(language m: LanguageModelsResponse.Model) {
            id = m.id
            created = m.created ?? 0
            inputPerMillion = XAIAdapter.perMillion(m.prompt_text_token_price)
            outputPerMillion = XAIAdapter.perMillion(m.completion_text_token_price)
            // Every Grok language model supports function calling (docs.x.ai →
            // "Function Calling"); vision follows the reported input modalities.
            var caps: ModelCapabilities = [.tools]
            if m.input_modalities?.contains("image") == true { caps.insert(.vision) }
            capabilities = caps
        }

        init(model m: ModelsResponse.Model) {
            id = m.id
            created = m.created ?? 0
            inputPerMillion = XAIAdapter.perMillion(m.prompt_text_token_price)
            outputPerMillion = XAIAdapter.perMillion(m.completion_text_token_price)
            // /v1/models reports no modalities — vision stays unclaimed here.
            capabilities = [.tools]
        }
    }

    /// xAI quotes prices in hundredths of a cent per 100M tokens: 12500 → $1.25
    /// per 1M. (Base tier; the >`long_context_threshold` tier is priced
    /// separately and is not what a picker row should quote.)
    static func perMillion(_ raw: Int?) -> Double? {
        guard let raw else { return nil }
        return Double(raw) / 10_000
    }

    /// "grok-4.20-0309-non-reasoning" → "Grok 4.20 0309 Non Reasoning" — used
    /// only for ids the curated block doesn't name yet, so a new Grok still
    /// reads as a product rather than a slug.
    static func displayName(forID id: String) -> String {
        id.split(separator: "-")
            .map { $0.lowercased() == "grok" ? "Grok" : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: - Fetch

    private static func fetch<T: Decodable>(
        _ type: T.Type, from url: URL, apiKey: String, session: URLSession
    ) async -> Result<T, EndpointModelCatalog.FailureKind> {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
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
        if let kind = EndpointModelCatalog.failureKind(forStatus: status, body: data) {
            logger.warning("[fetch] HTTP \(status) for \(url.absoluteString)")
            return .failure(kind)
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            return .failure(.badResponse)
        }
        return .success(decoded)
    }
}

// MARK: - Wire contract — https://docs.x.ai/docs/api-reference

extension XAIAdapter {

    /// `GET /v1/models` — every model xAI serves, text **and** media
    /// (`grok-imagine-*`). Prices are per-token integers (see `perMillion`);
    /// `aliases` are the retired/short ids that redirect to this canonical one.
    struct ModelsResponse: Decodable {
        let data: [Model]

        struct Model: Decodable {
            let id: String
            let object: String?
            let created: Int?
            let owned_by: String?
            let aliases: [String]?
            let context_length: Int?
            let prompt_text_token_price: Int?
            let cached_prompt_text_token_price: Int?
            let prompt_image_token_price: Int?
            let completion_text_token_price: Int?
            let prompt_text_token_price_long_context: Int?
            let cached_prompt_text_token_price_long_context: Int?
            let completion_text_token_price_long_context: Int?
            let long_context_threshold: Int?

            /// Chat models only. The `grok-imagine-*` image/video family carries
            /// no text-token pricing — the same test the catalog generator
            /// uses to keep them out of the curated block.
            var isTextModel: Bool {
                !id.lowercased().hasPrefix("grok-imagine")
                    && prompt_text_token_price != nil
                    && completion_text_token_price != nil
            }
        }
    }

    /// `GET /v1/language-models` — the text models only, with modalities and a
    /// serving `fingerprint`. Note the envelope key is `models`, not `data`, and
    /// that no `context_length` is reported here (join `/v1/models` for it).
    struct LanguageModelsResponse: Decodable {
        let models: [Model]

        struct Model: Decodable {
            let id: String
            let fingerprint: String?
            let created: Int?
            let object: String?
            let owned_by: String?
            let version: String?
            let input_modalities: [String]?      // ["text","image"]
            let output_modalities: [String]?
            let aliases: [String]?
            let prompt_text_token_price: Int?
            let cached_prompt_text_token_price: Int?
            let prompt_image_token_price: Int?
            let completion_text_token_price: Int?
            let search_price: Int?
            let prompt_text_token_price_long_context: Int?
            let cached_prompt_text_token_price_long_context: Int?
            let completion_text_token_price_long_context: Int?
            let long_context_threshold: Int?

            /// This endpoint is already text-only; the guard keeps a future
            /// media entry (or a priceless placeholder) out of the picker.
            var isTextModel: Bool { !id.lowercased().hasPrefix("grok-imagine") }
        }
    }
}
