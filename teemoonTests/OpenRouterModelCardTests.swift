//
//  OpenRouterModelCardTests.swift
//  teemoonTests
//
//  OpenRouter publishes more about a model than a picker row shows: what it
//  charges besides the two text rates, what it can be asked to do, and who it
//  can route the model to. These pin the parts that are easy to get wrong —
//  units, and matching one provider's offer to the right model.
//
//  Payloads are real captures (Fixtures/openrouter_model_endpoints.json,
//  openrouter_zdr.json, 2026-09-15).
//

import Foundation
import Testing
@testable import teemoon

@Suite("OpenRouter model card")
struct OpenRouterModelCardTests {

    private func model(_ json: String) throws -> OpenRouterAdapter.ModelsResponse.Model {
        try JSONDecoder().decode(OpenRouterAdapter.ModelsResponse.Model.self, from: Data(json.utf8))
    }

    // MARK: what it costs

    /// The card's cost lines: everything priced that the row's "$in/$out"
    /// leaves out. A rate of zero is not a line — OpenRouter writes "0" for
    /// what it does not charge.
    @Test func extraCostsReadEveryPricedDimension() throws {
        let record = try model("""
        {"id":"openai/gpt-5.4","pricing":{"prompt":"0.0000025","completion":"0.000015",
         "web_search":"0.01","input_cache_read":"0.00000025","input_cache_write":"0",
         "internal_reasoning":"0","image":"0.000002","request":"0"}}
        """)
        let costs = OpenRouterAdapter.extraCosts(record.pricing)
        #expect(costs.map(\.label) == ["cache read", "image input", "web search"])
        #expect(costs.first?.amount == "$0.25 / 1M tokens")
        #expect(costs.last?.amount == "$0.01")
    }

    /// A sub-cent fee keeps the digits that make it different from nothing:
    /// rounding $0.0014 to "$0.00" says the search is free.
    @Test func subCentFeesKeepTheirPrecision() throws {
        let record = try model("""
        {"id":"x/y","pricing":{"prompt":"0","completion":"0","web_search":"0.0014"}}
        """)
        #expect(OpenRouterAdapter.extraCosts(record.pricing).first?.amount == "$0.0014")
    }

    /// A long-context tier always applies past its length, so it is shown. A
    /// time window needs a clock to be true, so it is not.
    @Test func onlyAlwaysOnOverridesAreShown() throws {
        let record = try model("""
        {"id":"x/y","pricing":{"prompt":"0.0000025","completion":"0.000015","overrides":[
          {"min_prompt_tokens":272000,"prompt":"0.000005","completion":"0.0000225"},
          {"utc_start":0,"utc_end":28800,"prompt":"0.000001","completion":"0.000002"}]}}
        """)
        let costs = OpenRouterAdapter.extraCosts(record.pricing)
        #expect(costs.map(\.label) == ["past 272k"])
        // Two rates, like the headline — never the two summed into one number.
        #expect(costs.first?.amount == "$5.00/$22.50 / 1M tokens")
    }

    // MARK: what it can do

    /// Chips come from the payload and nowhere else. `is_moderated: false` is
    /// silence, not an "unmoderated" badge.
    @Test func featuresAreOnlyWhatTheCatalogueClaims() throws {
        let reasoning = try model("""
        {"id":"x/y","supported_parameters":["tools","reasoning","structured_outputs"],
         "reasoning":{"mandatory":true,"supported_efforts":["high","low"]},
         "top_provider":{"is_moderated":true}}
        """)
        #expect(OpenRouterAdapter.features(from: reasoning)
                == ["tools", "reasoning (required)", "structured outputs", "moderated"])

        let plain = try model("""
        {"id":"x/y","supported_parameters":["temperature","seed"],
         "top_provider":{"is_moderated":false}}
        """)
        #expect(OpenRouterAdapter.features(from: plain).isEmpty,
                "sampling knobs are not features, and false is not a badge")
    }

    @Test func aRowCarriesTheCardsFacts() throws {
        let record = try model("""
        {"id":"openai/gpt-5.4","name":"OpenAI: GPT-5.4","created":1788000000,
         "context_length":1050000,"knowledge_cutoff":"2025-09-30",
         "supported_parameters":["tools","reasoning"],
         "reasoning":{"supported_efforts":["high","low"]},
         "top_provider":{"max_completion_tokens":128000},
         "pricing":{"prompt":"0.0000025","completion":"0.000015"}}
        """)
        let row = OpenRouterAdapter.row(record, now: Date(timeIntervalSince1970: 1788100000))
        #expect(row.knowledgeCutoff == "2025-09-30")
        #expect(row.reasoningEfforts == ["high", "low"])
        #expect(row.maxOutputTokens == 128000)
        #expect(row.price == "$2.50/$15.00")
        #expect(row.features.contains("tools"))
    }

    /// OpenRouter lists alias rows ("~openai/gpt-sol-latest"), and has no
    /// endpoints for them — a question about how one is served belongs to the
    /// model it redirects to.
    @Test func anAliasRowNamesTheModelThatAnswers() throws {
        let record = try model("""
        {"id":"~openai/gpt-sol-latest","name":"OpenAI: GPT Sol (latest)",
         "alias_target":{"name":"OpenAI: GPT-5.6 Sol","slug":"openai/gpt-5.6-sol"}}
        """)
        #expect(OpenRouterAdapter.row(record, now: Date()).aliasOf == "openai/gpt-5.6-sol")

        let plain = try model(#"{"id":"openai/gpt-5.4"}"#)
        #expect(OpenRouterAdapter.row(plain, now: Date()).aliasOf == nil)

        // The "~" is OpenRouter's marker for an alias, not part of the vendor's
        // name: without this the browser grew a second "~openai" section.
        #expect(ModelCatalog.vendorLabel(forID: "~openai/gpt-sol-latest") == "OpenAI")
        #expect(ModelCatalog.vendorLabel(forID: "~deepseek/deepseek-pro-latest") == "DeepSeek")
    }

    // MARK: who can serve it

    private func offers(file: String = #filePath) throws -> [OpenRouterAdapter.OffersResponse.Endpoint] {
        let data = try TestFixture.data("openrouter_model_endpoints.json", file: file)
        return try JSONDecoder().decode(OpenRouterAdapter.OffersResponse.self, from: data).data.endpoints
    }

    private func zdrKeys(file: String = #filePath) throws -> Set<String> {
        let data = try TestFixture.data("openrouter_zdr.json", file: file)
        let rows = try JSONDecoder().decode(OpenRouterAdapter.ZeroDataRetentionResponse.self, from: data).data
        return Set(rows.compactMap { row in
            row.tag?.nilIfBlank.map { OpenRouterAdapter.zdrKey(modelID: row.model_id, tag: $0) }
        })
    }

    /// One provider can serve the same model twice under different tags, so the
    /// variant is part of the name and part of the identity.
    @Test func offersNameTheirVariant() throws {
        let built = OpenRouterAdapter.buildOffers(from: try offers())
        #expect(built.map(\.title) == ["OpenAI · flex", "Azure", "OpenAI"])
        #expect(Set(built.map(\.id)).count == built.count)
    }

    /// Latency is milliseconds and throughput is tokens per second — checked
    /// against a live keyed response, not guessed from the magnitude.
    @Test func speedIsReadInTheUnitsOpenRouterSends() throws {
        let built = OpenRouterAdapter.buildOffers(from: try offers())
        let flex = try #require(built.first)
        #expect(flex.latencyMilliseconds == 2085.5)
        #expect(flex.latencyLabel == "2.1 s")
        #expect(flex.throughputLabel == "37 tok/s")
        #expect(flex.uptimeLabel == "91.6%")
        // The public list answers null for both, and a blank row says nothing.
        #expect(built.last?.latencyLabel == nil)
        #expect(built.last?.throughputLabel == nil)
    }

    /// "unknown" is how OpenRouter spells "no answer"; a row saying
    /// "quantization: unknown" is worse than no row.
    @Test func anUnknownQuantizationIsNotARow() throws {
        let built = OpenRouterAdapter.buildOffers(from: try offers())
        #expect(built.allSatisfy { $0.quantization == nil })
    }

    /// The badge follows the (model, tag) pair. Azure serves both models in the
    /// fixture, and only one of those offers is on the list.
    @Test func zeroDataRetentionMatchesTheModelAndTheTag() throws {
        let keys = try zdrKeys()
        let built = OpenRouterAdapter.buildOffers(from: try offers(), zeroDataRetention: keys)
        let azure = try #require(built.first { $0.providerName == "Azure" })
        #expect(azure.tag == "azure")
        #expect(!azure.isZeroDataRetention,
                "gpt-5.4 is listed under azure/us and azure/eu, not under azure")

        var elsewhere = try offers()[1]
        #expect(elsewhere.provider_name == "Azure")
        let relabelled = OpenRouterAdapter.zdrKey(modelID: "openai/gpt-5.4", tag: "azure/us")
        #expect(keys.contains(relabelled))
        _ = elsewhere
    }

    /// A failed fetch must not be remembered: one blip would hide every badge
    /// for the rest of the process, which reads as "no provider retains
    /// nothing" rather than "we could not ask".
    @Test func aFailedZeroDataRetentionFetchIsNotCached() async throws {
        await OpenRouterAdapter.resetZeroDataRetentionCache()
        let base = try #require(URL(string: "https://openrouter.ai/api/v1"))
        let session = StubZDRAPI.session()
        StubZDRAPI.reset()
        StubZDRAPI.routes = ["/api/v1/endpoints/zdr": (500, Data("{}".utf8))]
        let failed = await OpenRouterAdapter.zeroDataRetentionOffers(
            baseURL: base, apiKey: "", session: session)
        #expect(failed.isEmpty)

        StubZDRAPI.routes = ["/api/v1/endpoints/zdr": (200, Data("""
        {"data":[{"model_id":"openai/gpt-5.4","tag":"azure/us","provider_name":"Azure"}]}
        """.utf8))]
        let second = await OpenRouterAdapter.zeroDataRetentionOffers(
            baseURL: base, apiKey: "", session: session)
        #expect(second.contains(OpenRouterAdapter.zdrKey(modelID: "openai/gpt-5.4", tag: "azure/us")))
        #expect(StubZDRAPI.requestCount == 2, "the failure was re-asked, the success was not")

        _ = await OpenRouterAdapter.zeroDataRetentionOffers(baseURL: base, apiKey: "", session: session)
        #expect(StubZDRAPI.requestCount == 2)
        await OpenRouterAdapter.resetZeroDataRetentionCache()
    }
}

/// Serves the zdr list from a script.
private final class StubZDRAPI: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Int, Data)] = [:]
    nonisolated(unsafe) static var requestCount = 0

    static func reset() { requestCount = 0 }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubZDRAPI.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requestCount += 1
        let path = request.url?.path ?? ""
        let (status, body) = Self.routes[path] ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
