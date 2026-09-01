//
//  NearAICatalogParseTests.swift
//  teemoonTests
//
//  The #19 refactor: near.ai's /v1/models is decoded as a full typed struct and its
//  metadata (price, context, capabilities, tier) built straight into KnownModels.
//  These pin the wire contract and the parse helpers.
//

import Foundation
import Testing
@testable import teemoon

@Suite("NearAI /v1/models parse")
struct NearAICatalogParseTests {

    /// A trimmed but real-shaped /v1/models body: one proxied (Anthropic) model with
    /// image input + tools, one near.ai-fleet GLM with reasoning.
    private let sampleJSON = """
    {"object":"list","data":[
      {"id":"anthropic/claude-haiku-4-5","owned_by":"anthropic","name":"Claude Haiku 4.5",
       "pricing":{"input":1.0,"output":5.0,"prompt":"0.000001","completion":"0.000005"},
       "context_length":200000,"max_output_length":8192,
       "input_modalities":["text","image"],"output_modalities":["text"],
       "supported_features":["tools","structured_outputs"],"is_ready":false,
       "description":"Fastest Anthropic model.","top_provider":{"context_length":200000}},
      {"id":"z-ai/glm-5.2","owned_by":"nearai","name":"GLM 5.2",
       "pricing":{"input":1.4,"output":4.4},"context_length":1000000,
       "input_modalities":["text"],"supported_features":["tools","reasoning"]}
    ]}
    """

    private func decoded() throws -> NearAIModelCatalog.ModelsResponse {
        try JSONDecoder().decode(NearAIModelCatalog.ModelsResponse.self,
                                 from: Data(sampleJSON.utf8))
    }

    // MARK: full typed decode (the strong-typing rule)

    @Test func decodesTheFullShape() throws {
        let r = try decoded()
        #expect(r.data.count == 2)
        let haiku = r.data[0]
        #expect(haiku.id == "anthropic/claude-haiku-4-5")
        #expect(haiku.owned_by == "anthropic")
        #expect(haiku.name == "Claude Haiku 4.5")
        #expect(haiku.pricing?.input == 1.0)
        #expect(haiku.pricing?.output == 5.0)
        #expect(haiku.context_length == 200000)
        #expect(haiku.input_modalities == ["text", "image"])
        #expect(haiku.supported_features == ["tools", "structured_outputs"])
        #expect(haiku.is_ready == false)
        #expect(haiku.description == "Fastest Anthropic model.")
        #expect(haiku.top_provider?.context_length == 200000)
    }

    // MARK: parse helpers

    @Test func priceAndContextLabels() throws {
        let r = try decoded()
        #expect(NearAIModelCatalog.priceLabel(r.data[0].pricing) == "$1/$5")
        #expect(NearAIModelCatalog.priceLabel(r.data[1].pricing) == "$1.40/$4.40")
        #expect(NearAIModelCatalog.priceLabel(nil) == "")
        #expect(NearAIModelCatalog.contextLabel(200000) == "200k")
        #expect(NearAIModelCatalog.contextLabel(1_000_000) == "1M")
        #expect(NearAIModelCatalog.contextLabel(nil) == "")
    }

    @Test func capabilitiesFromFeaturesAndModalities() throws {
        let r = try decoded()
        // Anthropic entry: tools + image input → .tools and .vision.
        let caps = NearAIModelCatalog.capabilities(from: r.data[0])
        #expect(caps.contains(.tools))
        #expect(caps.contains(.vision))
        // GLM: tools, text-only → .tools, no .vision.
        let glmCaps = NearAIModelCatalog.capabilities(from: r.data[1])
        #expect(glmCaps.contains(.tools))
        #expect(!glmCaps.contains(.vision))
    }

    // MARK: slug (drift matching)

    @Test func slugStripsQuantSuffixSoCuratedMatchesLive() {
        // The drift that caused the flicker: curated "…GLM-5.1-FP8" must slug-match a
        // live "glm-5.1".
        #expect(NearAIModelCatalog.slug("zai-org/GLM-5.1-FP8") == "glm-5.1")
        #expect(NearAIModelCatalog.slug("z-ai/glm-5.1") == "glm-5.1")
        #expect(NearAIModelCatalog.slug("z-ai/glm-5.2") == "glm-5.2")
        #expect(NearAIModelCatalog.slug("Qwen/Qwen3.6-27B-FP8") == "qwen3.6-27b")
    }

    // MARK: buildModels (live metadata → KnownModels)

    @Test func buildsKnownModelsFromLiveMetadata() async throws {
        NearAIModelCatalog.resetTierCache()
        let models = await NearAIModelCatalog.buildModels(from: try decoded().data)
        // GLM 5.2 (e2ee, Z.ai) sorts before the proxied Anthropic model.
        let glm = try #require(models.first { $0.id == "z-ai/glm-5.2" })
        #expect(glm.displayName == "GLM 5.2")
        #expect(glm.price == "$1.40/$4.40")
        #expect(glm.contextWindow == "1M")
        #expect(glm.capabilities?.contains(.tools) == true)
        #expect(glm.vendor == "Z.ai")

        let haiku = try #require(models.first { $0.id == "anthropic/claude-haiku-4-5" })
        #expect(haiku.displayName == "Claude Haiku 4.5")
        #expect(haiku.price == "$1/$5")
        #expect(haiku.contextWindow == "200k")
        #expect(haiku.capabilities?.contains(.vision) == true)
    }
}
