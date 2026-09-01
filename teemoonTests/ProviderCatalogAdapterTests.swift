//
//  ProviderCatalogAdapterTests.swift
//  teemoonTests
//
//  The cloud model pickers other than near.ai. Before the adapters, xAI and
//  Fireworks went through the generic `GET {base}/models` probe, which keeps
//  ids and throws everything else away. That produced four user-visible bugs,
//  each pinned by a test here:
//
//   1. xAI's `grok-imagine-*` image/video models were offered as CHAT models.
//   2. Every row rendered with no price and no context window.
//   3. Rows were titled by raw id ("grok-4.20-0309-non-reasoning", "kimi-k2p6").
//   4. Vendor sections came from the id's namespace, so Grok models each got
//      their OWN section ("Grok-4.3") and every Fireworks model landed under
//      one "Accounts" heading (their ids are `accounts/fireworks/models/…`).
//
//  Plus one data bug only the control plane exposes: Fireworks'
//  `/inference/v1/models` under-reports — it listed 6 models while 11 serverless
//  models were callable (deepseek-v4-flash, kimi-k2p7-code, minimax-m3 … all
//  answered /chat/completions but were missing from the picker).
//
//  Fixtures are REAL captured responses (2026-07-25):
//    Fixtures/xai_language_models.json        GET https://api.x.ai/v1/language-models
//    Fixtures/xai_models.json                 GET https://api.x.ai/v1/models
//    Fixtures/fireworks_serverless_models.json
//        GET https://api.fireworks.ai/v1/accounts/fireworks/models
//            ?pageSize=200&filter=supports_serverless=true
//        (only `baseModelDetails.huggingfaceFiles` stripped, for size)
//

import Foundation
import Testing
@testable import teemoon

// MARK: - Fixture loading

private func fixture(_ name: String, file: String = #filePath) throws -> Data {
    return try TestFixture.data(name, file: file)
}

/// Serves a canned body per request PATH, so an adapter that fans out over two
/// endpoints is exercised exactly as it runs in the app (URL construction, auth
/// header, decode, mapping). Any unmapped path answers 404.
///
/// Its state is static (URLProtocol is instantiated by URLSession), so each
/// suite gets its OWN subclass — sharing one would make the suites collide when
/// the test runner runs them in parallel.
private final class RouteBox {
    /// path suffix → (status, body)
    var routes: [String: (status: Int, body: Data)] = [:]
    var requestedURLs: [URL] = []
    var authHeaders: [String] = []
}

private class StubCatalogAPI: URLProtocol {
    /// Each subclass supplies its own box, so two suites never share routes.
    class var box: RouteBox { fatalError("use a subclass") }

    static func reset() { box.routes = [:]; box.requestedURLs = []; box.authHeaders = [] }
    static var routes: [String: (status: Int, body: Data)] {
        get { box.routes } set { box.routes = newValue }
    }
    static var requestedURLs: [URL] { box.requestedURLs }
    static var authHeaders: [String] { box.authHeaders }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let box = Self.box
        box.requestedURLs.append(url)
        if let auth = request.value(forHTTPHeaderField: "Authorization") { box.authHeaders.append(auth) }
        let match = box.routes.first { url.path.hasSuffix($0.key) }
        let status = match?.value.status ?? 404
        let body = match?.value.body ?? Data("{}".utf8)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class StubXAIAPI: StubCatalogAPI {
    nonisolated(unsafe) static let sharedBox = RouteBox()
    override class var box: RouteBox { sharedBox }
}

private final class StubFireworksAPI: StubCatalogAPI {
    nonisolated(unsafe) static let sharedBox = RouteBox()
    override class var box: RouteBox { sharedBox }
}

private func stubSession(_ stub: URLProtocol.Type) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [stub]
    return URLSession(configuration: config)
}

// MARK: - Catalog-generic helpers

@Suite("ModelCatalog — vendor, slug, formatting")
struct ModelCatalogTests {

    /// Bug 4, half one: a namespace-less id used to become its OWN vendor
    /// ("Grok-4.3"), so every Grok model got a section to itself.
    @Test func vendorComesFromTheFamilyWhenThereIsNoNamespace() {
        #expect(ModelCatalog.vendorLabel(forID: "grok-4.3") == "xAI")
        #expect(ModelCatalog.vendorLabel(forID: "grok-4.20-0309-reasoning") == "xAI")
        #expect(ModelCatalog.vendorLabel(forID: "qwen3.5:4b") == "Qwen")       // ollama-style tag
        #expect(ModelCatalog.vendorLabel(forID: "gemma-3-4b-it") == "Google")  // llama.cpp-style
        #expect(ModelCatalog.vendorLabel(forID: "totally-unknown-model") == "Other")
    }

    /// Bug 4, half two: Fireworks ids are `accounts/{account}/models/{slug}`, so
    /// the namespace is a hosting account. Only a catalogue that KNOWS that opts
    /// into the family lookup — the generic label keeps namespace authority.
    @Test func familyLookupIsOptInForContainerNamespaces() {
        #expect(ModelCatalog.vendorLabel(forID: "accounts/fireworks/models/kimi-k2p6") == "Accounts")
        #expect(ModelCatalog.familyVendor(forID: "kimi-k2p6") == "Moonshot")
        #expect(ModelCatalog.familyVendor(forID: "gpt-oss-120b") == "OpenAI")
        #expect(ModelCatalog.familyVendor(forID: "nemotron-3-ultra") == "NVIDIA")
        #expect(ModelCatalog.familyVendor(forID: "glm-5p2") == "Z.ai")
        #expect(ModelCatalog.familyVendor(forID: "totally-unknown-model") == nil)
    }

    /// A real namespace still wins — near.ai ids must label exactly as before.
    /// Load-bearing: `differentVendor` compares these labels to catch a node
    /// serving a different model than the one requested, so a shared family
    /// keyword must NOT collapse `QuantTrio/GLM-5.1-AWQ` into `zai-org/…`.
    @Test func namespaceStillWinsForNearAIStyleIDs() {
        #expect(ModelCatalog.vendorLabel(forID: "zai-org/GLM-5.1-FP8") == "Z.ai")
        #expect(ModelCatalog.vendorLabel(forID: "deepseek-ai/DeepSeek-V4-Flash") == "DeepSeek")
        #expect(ModelCatalog.vendorLabel(forID: "moonshotai/kimi-k2.6") == "Moonshot")
        #expect(ModelCatalog.vendorLabel(forID: "openai/gpt-oss-120b") == "OpenAI")
        #expect(ModelCatalog.vendorLabel(forID: "mystery/model") == "Mystery")
        #expect(ModelCatalog.vendorLabel(forID: "") == "Other")
        #expect(NearAIModelCatalog.differentVendor("QuantTrio/GLM-5.1-AWQ", "zai-org/GLM-5.1-FP8"))
    }

    @Test func slugDropsQuantSuffixesIncludingNVFP4() {
        #expect(ModelCatalog.slug("accounts/fireworks/models/nemotron-3-ultra-nvfp4") == "nemotron-3-ultra")
        #expect(ModelCatalog.slug("zai-org/GLM-5.1-FP8") == "glm-5.1")
    }

    /// A hand-written catalogue name, made to read like the rows around it.
    ///
    /// Fireworks' `displayName` field is the only one written per model, and its
    /// three styles were visible as three kinds of row in one list. The near.ai
    /// column is the reference in each case.
    @Test func productNameReadsLikeTheRestOfTheCatalogue() {
        // The vendor the section header already prints, dropped — what's left
        // still names the family, so nothing is lost.
        #expect(ModelCatalog.productName("OpenAI gpt-oss-20b", vendor: "OpenAI") == "gpt oss 20b")
        // And a precision suffix with it: this row rendered "nvidia nemotron 3
        // ultra n…", truncating the model out of its own name.
        #expect(ModelCatalog.productName("NVIDIA Nemotron 3 Ultra NVFP4", vendor: "NVIDIA")
                == "Nemotron 3 Ultra")
        // NOT dropped when the vendor word is also the family word — "V4 Flash"
        // names nothing, and near.ai renders this exact model "deepseek v4 flash".
        #expect(ModelCatalog.productName("DeepSeek-V4-Flash", vendor: "DeepSeek") == "DeepSeek V4 Flash")
        #expect(ModelCatalog.productName("Minimax M3", vendor: "MiniMax") == "Minimax M3")
        // A name that was already in the house style is left exactly alone.
        #expect(ModelCatalog.productName("Kimi K2.7 Code", vendor: "Moonshot") == "Kimi K2.7 Code")
        #expect(ModelCatalog.productName("GLM 5.2", vendor: "Z.ai") == "GLM 5.2")
        // Case is the ROW's business (`.textCase(.lowercase)`), so it survives here.
        #expect(ModelCatalog.productName("Qwen3p7 Plus", vendor: "Qwen") == "Qwen3p7 Plus")
        // Never peels to nothing, however build-word-ish the name is.
        #expect(ModelCatalog.productName("instruct", vendor: "Other") == "instruct")
    }

    /// Every Fireworks model teemoon knows about has a price — and this test cannot
    /// prove that for the ones it doesn't.
    ///
    /// Worth being precise, because the obvious question is why a fixture-based suite missed a
    /// priceless row. `inkling` came back from the LIVE control plane on device
    /// (2026-07-30) and rendered with a context window and no rate.
    /// `fireworksRowsGainTheContextTheSnapshotNeverHad` asserts every row has a
    /// price and passed anyway — it runs against a capture from 2026-07-25, and a
    /// frozen capture cannot contain a model added upstream afterwards. No unit test
    /// can: the only thing that sees new models is the catalog generator's
    /// read-only verifier, which reports live serverless models missing from this
    /// table and needs `FIREWORKS_API_KEY`, so it runs by hand rather than in CI.
    ///
    /// What IS testable is the table itself, which is why this pins the id that was
    /// missing — and the shape of the fix, since inkling's rate is published only on
    /// its model page, not in the pricing table a refresh reads.
    @Test func everyKnownFireworksModelHasAPrice() {
        for id in KnownModel.fireworksPrices.keys {
            #expect(!FireworksAdapter.price(forID: id).isEmpty)
        }
        // The row from the device report.
        #expect(FireworksAdapter.price(forID: "accounts/fireworks/models/inkling")
                == "$1.00/$4.05")
        // Slug matching still carries a namespace or quant change over.
        #expect(FireworksAdapter.price(forID: "accounts/fireworks/models/inkling-fp8")
                == "$1.00/$4.05")
        // A model nobody has priced yet is EMPTY, never a wrong number borrowed
        // from a neighbour — the invariant that makes a blank row the honest state.
        #expect(FireworksAdapter.price(forID: "accounts/fireworks/models/not-a-model").isEmpty)
    }

    /// A DATED SNAPSHOT keeps its family's price.
    ///
    /// Reported from the device: the Where chip showed no price at all for
    /// `deepseek-v4-flash-0731`. Fireworks republishes a family under a release
    /// date, and that id matches neither the table's key nor its slug —
    /// `ModelCatalog.slug` peels precision and quant markers and nothing else.
    ///
    /// The rate is not inferred: Fireworks lists the dated form at the same
    /// rate as the undated entry. (The incident family, deepseek-v4-flash, has
    /// since been retired from the price map — the mechanism is pinned against
    /// a family that still ships.)
    @Test func aDatedSnapshotInheritsItsFamilysPrice() {
        #expect(FireworksAdapter.price(forID: "accounts/fireworks/models/glm-5p2-0731")
                == "$1.40/$4.40")
        // Longer date forms too — Fireworks has used both.
        #expect(FireworksAdapter.price(forID: "accounts/fireworks/models/glm-5p2-20260731")
                == "$1.40/$4.40")
        // A dated snapshot of something NOT in the table stays blank. The
        // stripping must not become a way to borrow a neighbour's number.
        #expect(FireworksAdapter.price(forID: "accounts/fireworks/models/mystery-model-0731").isEmpty)
        // And a numeric-looking segment that ISN'T a date suffix must survive:
        // this would otherwise become "gpt-oss" and match nothing, blanking a
        // row that works today.
        #expect(FireworksAdapter.price(forID: "accounts/fireworks/models/gpt-oss-120b")
                == "$0.15/$0.60")
    }

    @Test func priceAndContextFormatting() {
        #expect(ModelCatalog.priceLabel(inputPerMillion: 1.25, outputPerMillion: 2.5) == "$1.25/$2.50")
        #expect(ModelCatalog.priceLabel(inputPerMillion: 2, outputPerMillion: 6) == "$2/$6")
        #expect(ModelCatalog.priceLabel(inputPerMillion: nil, outputPerMillion: 6) == "")
        #expect(ModelCatalog.contextLabel(1_048_576) == "1M")     // not "1.0M"
        #expect(ModelCatalog.contextLabel(1_100_000) == "1.1M")
        #expect(ModelCatalog.contextLabel(202_752) == "202k")
        #expect(ModelCatalog.contextLabel(0) == "")
        #expect(ModelCatalog.contextLabel(nil) == "")
    }

    /// Not every provider uses 401 for a bad key: xAI answers HTTP 400 with
    /// "Incorrect API key provided" (verified live 2026-07-26), which on status
    /// alone reads as `.offline` — "couldn't reach that endpoint" — and sends
    /// the user to check their network instead of their key.
    @Test func badKeyIsRecognizedFromTheBodyWhenTheStatusLies() {
        let xai = Data(#"{"code":"invalid-argument","error":"Incorrect API key provided. You can obtain an API key from https://console.x.ai."}"#.utf8)
        #expect(EndpointModelCatalog.failureKind(forStatus: 400, body: xai) == .unauthorized)
        #expect(EndpointModelCatalog.failureKind(forStatus: 400, body: nil) == .offline)

        // A 400 about something OTHER than credentials must stay generic — a
        // body-sniffing rule that over-fires would send users to re-enter a key
        // that was never the problem.
        let shapeError = Data(#"{"error":{"detail":"messages: List should have at most 1 item"}}"#.utf8)
        #expect(EndpointModelCatalog.failureKind(forStatus: 400, body: shapeError) == .offline)

        // Statuses that are already unambiguous keep their meaning.
        #expect(EndpointModelCatalog.failureKind(forStatus: 401, body: nil) == .unauthorized)
        #expect(EndpointModelCatalog.failureKind(forStatus: 402, body: xai) == .paymentRequired)
        #expect(EndpointModelCatalog.failureKind(forStatus: 200, body: nil) == nil)
    }

    /// Routing is by host, and only the hosts we have a richer catalogue for.
    @Test func sourceResolvesByHost() {
        #expect(EndpointModelCatalog.Source.resolve(host: "cloud-api.near.ai") == .nearAI)
        #expect(EndpointModelCatalog.Source.resolve(host: "api.x.ai") == .xAI)
        #expect(EndpointModelCatalog.Source.resolve(host: "api.fireworks.ai") == .fireworks)
        #expect(EndpointModelCatalog.Source.resolve(host: "ringzero.tailnet-name.ts.net") == .generic)
        #expect(EndpointModelCatalog.Source.resolve(host: nil) == .generic)
        // Not a suffix match on a lookalike domain.
        #expect(EndpointModelCatalog.Source.resolve(host: "api.x.ai.evil.com") == .generic)
    }
}

// MARK: - xAI

@Suite("XAIAdapter", .serialized)
struct XAIAdapterTests {

    private func stubXAI() throws {
        StubXAIAPI.reset()
        StubXAIAPI.routes = [
            "/language-models": (200, try fixture("xai_language_models.json")),
            "/models": (200, try fixture("xai_models.json")),
        ]
    }

    @Test func priceUnitIsHundredthsOfACentPer100MTokens() {
        // 12500 → $1.25 / 1M (the unit the catalog generator documents).
        #expect(XAIAdapter.perMillion(12500) == 1.25)
        #expect(XAIAdapter.perMillion(60000) == 6.0)
        #expect(XAIAdapter.perMillion(nil) == nil)
    }

    /// Bug 1: the media family carries no text-token price and must never reach
    /// the chat picker. The real /v1/models fixture has 10 entries, 6 of them text.
    @Test func mediaModelsAreNotChatModels() throws {
        let list = try JSONDecoder().decode(XAIAdapter.ModelsResponse.self, from: fixture("xai_models.json"))
        #expect(list.data.count == 10)
        let text = list.data.filter(\.isTextModel).map(\.id)
        #expect(text.count == 6)
        #expect(!text.contains { $0.hasPrefix("grok-imagine") })
    }

    @Test func languageModelsFixtureDecodesModalitiesAndAliases() throws {
        let list = try JSONDecoder().decode(XAIAdapter.LanguageModelsResponse.self,
                                            from: fixture("xai_language_models.json"))
        #expect(list.models.count == 6)
        let flagship = try #require(list.models.first { $0.id == "grok-4.5" })
        #expect(flagship.input_modalities == ["text", "image"])
        #expect(flagship.prompt_text_token_price == 20000)
        #expect(flagship.completion_text_token_price == 60000)
        // The retired ids xAI silently redirects live here, not as models.
        let g420 = try #require(list.models.first { $0.id == "grok-4.20-0309-reasoning" })
        #expect(g420.aliases?.contains("grok-4.20") == true)
    }

    /// The whole picker row, end-to-end through URLSession: chat models only,
    /// named, priced, sized, with a vendor and capabilities. (Bugs 1–4.)
    @Test func listModelsBuildsCompletePickerRows() async throws {
        try stubXAI()
        let result = await XAIAdapter.listModels(
            baseURL: URL(string: "https://api.x.ai/v1")!, apiKey: "test-key", session: stubSession(StubXAIAPI.self))
        guard case .connected(let models) = result else {
            Issue.record("expected .connected, got \(result)"); return
        }
        #expect(models.count == 6)
        #expect(!models.contains { $0.id.hasPrefix("grok-imagine") })
        #expect(models.allSatisfy { $0.vendor == "xAI" })
        #expect(models.allSatisfy { !$0.price.isEmpty })
        #expect(models.allSatisfy { !$0.contextWindow.isEmpty })
        #expect(models.allSatisfy { $0.capabilities?.contains(.tools) == true })
        #expect(models.allSatisfy { $0.capabilities?.contains(.vision) == true })   // Grok is multimodal

        // Newest first — the flagship leads, not whatever xAI happened to list first.
        #expect(models.first?.id == "grok-4.5")
        let flagship = try #require(models.first)
        #expect(flagship.displayName == "Grok 4.5")     // curated name, not the raw id
        #expect(flagship.price == "$2/$6")
        #expect(flagship.contextWindow == "500k")       // joined from /v1/models

        // Both endpoints were called, both authenticated.
        #expect(StubXAIAPI.requestedURLs.contains { $0.path == "/v1/language-models" })
        #expect(StubXAIAPI.requestedURLs.contains { $0.path == "/v1/models" })
        #expect(StubXAIAPI.authHeaders.allSatisfy { $0 == "Bearer test-key" })
    }

    /// An id the curated block hasn't caught up with still reads as a product.
    @Test func uncuratedIDsGetASynthesizedName() {
        #expect(XAIAdapter.displayName(forID: "grok-5") == "Grok 5")
        #expect(XAIAdapter.displayName(forID: "grok-4.20-0309-non-reasoning")
                == "Grok 4.20 0309 Non Reasoning")
    }

    /// A rejected key must classify as unauthorized (the add-provider screen
    /// turns that into "key rejected"), not as a silent empty list.
    @Test func rejectedKeyClassifiesAsUnauthorized() async {
        StubXAIAPI.reset()
        StubXAIAPI.routes = [
            "/language-models": (401, Data("{\"error\":\"bad key\"}".utf8)),
            "/models": (401, Data("{\"error\":\"bad key\"}".utf8)),
        ]
        let result = await XAIAdapter.listModels(
            baseURL: URL(string: "https://api.x.ai/v1")!, apiKey: "nope", session: stubSession(StubXAIAPI.self))
        #expect(result == .failed(.unauthorized))
    }

    /// If only `/v1/language-models` breaks, `/v1/models` still yields a list —
    /// filtered to text models, just without context windows.
    @Test func fallsBackToModelsWhenLanguageModelsIsUnavailable() async throws {
        StubXAIAPI.reset()
        StubXAIAPI.routes = [
            "/language-models": (404, Data("{}".utf8)),
            "/models": (200, try fixture("xai_models.json")),
        ]
        let result = await XAIAdapter.listModels(
            baseURL: URL(string: "https://api.x.ai/v1")!, apiKey: "k", session: stubSession(StubXAIAPI.self))
        guard case .connected(let models) = result else {
            Issue.record("expected .connected, got \(result)"); return
        }
        #expect(models.count == 6)
        #expect(!models.contains { $0.id.hasPrefix("grok-imagine") })
    }
}

// MARK: - Fireworks

@Suite("FireworksAdapter", .serialized)
struct FireworksAdapterTests {

    private func records() throws -> [FireworksAdapter.ModelsResponse.Model] {
        try JSONDecoder().decode(FireworksAdapter.ModelsResponse.self,
                                 from: fixture("fireworks_serverless_models.json")).models
    }

    /// The list endpoint lives on the control plane, NOT under /inference.
    @Test func controlPlaneBaseDropsTheInferencePrefix() throws {
        let base = try #require(FireworksAdapter.controlPlaneBase(
            from: URL(string: "https://api.fireworks.ai/inference/v1")!))
        #expect(base.absoluteString == "https://api.fireworks.ai/v1/accounts/fireworks/models")
    }

    @Test func fixtureDecodesTheFieldsAPickerRowNeeds() throws {
        let all = try records()
        #expect(all.count == 14)
        let kimi = try #require(all.first { $0.name == "accounts/fireworks/models/kimi-k2p6" })
        #expect(kimi.contextLength == 262_144)
        #expect(kimi.supportsTools == true)
        #expect(kimi.supportsImageInput == true)
        #expect(kimi.state == "READY")
        #expect(kimi.deprecationDate == nil)
        #expect(kimi.baseModelDetails?.parameterCount == "1028542417904")
    }

    /// Embeddings/rerankers ship in the same serverless list and must not be
    /// offered as chat models; a CUSTOM_MODEL (qwen3.7 plus) must NOT be dropped.
    @Test func nonChatKindsAreExcludedAndCustomModelsKept() throws {
        let models = FireworksAdapter.buildModels(from: try records())
        let ids = models.map(\.id)
        #expect(!ids.contains { $0.contains("embedding") || $0.contains("reranker") })
        #expect(ids.contains("accounts/fireworks/models/qwen3p7-plus"))
        #expect(models.count == 12)
    }

    /// Bug 3 + 4 + the under-reporting bug, in one assertion set: every model
    /// the control plane says is callable is listed, titled, and filed under a
    /// real vendor — including the five `/inference/v1/models` never returned.
    @Test func rowsAreCompleteNamedAndVendored() throws {
        let models = FireworksAdapter.buildModels(from: try records())
        for missingFromInferenceList in [
            "accounts/fireworks/models/deepseek-v4-flash",
            "accounts/fireworks/models/gpt-oss-20b",
            "accounts/fireworks/models/kimi-k2p7-code",
            "accounts/fireworks/models/minimax-m2p7",
            "accounts/fireworks/models/minimax-m3",
            "accounts/fireworks/models/nemotron-3-ultra-nvfp4",
        ] {
            #expect(models.contains { $0.id == missingFromInferenceList },
                    "\(missingFromInferenceList) is serverless-callable but missing from the picker")
        }
        #expect(!models.contains { $0.vendor == "Accounts" })
        #expect(models.allSatisfy { !$0.displayName.contains("accounts/") })
        let kimi = try #require(models.first { $0.id == "accounts/fireworks/models/kimi-k2p6" })
        #expect(kimi.displayName == "Kimi K2.6")
        #expect(kimi.vendor == "Moonshot")
        #expect(kimi.contextWindow == "262k")
        #expect(kimi.price == "$0.95/$4.00")     // the one shipped field: no pricing API
    }

    /// Capabilities are MODELED, not guessed: gpt-oss-20b reports no tool
    /// support, so teemoon must withhold the web-search tool from it instead of
    /// discovering the 400 in the chat hot path.
    @Test func toolAndVisionCapabilitiesComeFromTheAPI() throws {
        let models = FireworksAdapter.buildModels(from: try records())
        let noTools = try #require(models.first { $0.id == "accounts/fireworks/models/gpt-oss-20b" })
        #expect(noTools.capabilities == [])
        #expect(Provider(name: "fw", endpoint: "https://api.fireworks.ai/inference/v1",
                         model: noTools.id, modelCapabilities: noTools.capabilities)
                .modelSupportsTools == false)

        let vision = try #require(models.first { $0.id == "accounts/fireworks/models/kimi-k2p7-code" })
        #expect(vision.capabilities == [.tools, .vision])
    }

    /// The request the adapter actually issues: control-plane path, serverless
    /// filter in CEL snake_case (camelCase is rejected with 400), bearer key.
    @Test func listModelsQueriesTheControlPlaneWithTheServerlessFilter() async throws {
        StubFireworksAPI.reset()
        StubFireworksAPI.routes = [
            "/v1/accounts/fireworks/models": (200, try fixture("fireworks_serverless_models.json")),
        ]
        let result = await FireworksAdapter.listModels(
            baseURL: URL(string: "https://api.fireworks.ai/inference/v1")!,
            apiKey: "fw-key", session: stubSession(StubFireworksAPI.self))
        guard case .connected(let models) = result else {
            Issue.record("expected .connected, got \(result)"); return
        }
        #expect(models.count == 12)
        let url = try #require(StubFireworksAPI.requestedURLs.first)
        #expect(url.path == "/v1/accounts/fireworks/models")
        let query = try #require(url.query)
        #expect(query.contains("supports_serverless%3Dtrue") || query.contains("supports_serverless=true"))
        #expect(query.contains("pageSize=200"))
        #expect(StubFireworksAPI.authHeaders == ["Bearer fw-key"])
    }

    /// A key that can't read the control plane still gets a usable picker: the
    /// adapter falls back to the OpenAI-compat list rather than failing shut.
    @Test func fallsBackToTheGenericProbeWhenTheControlPlaneRefuses() async {
        StubFireworksAPI.reset()
        StubFireworksAPI.routes = [
            "/v1/accounts/fireworks/models": (403, Data("{}".utf8)),
            "/inference/v1/models": (200, Data("""
            {"data":[{"id":"accounts/fireworks/models/kimi-k2p6","object":"model"}]}
            """.utf8)),
        ]
        let result = await FireworksAdapter.listModels(
            baseURL: URL(string: "https://api.fireworks.ai/inference/v1")!,
            apiKey: "fw-key", session: stubSession(StubFireworksAPI.self))
        guard case .connected(let models) = result else {
            Issue.record("expected .connected, got \(result)"); return
        }
        #expect(models.map(\.id) == ["accounts/fireworks/models/kimi-k2p6"])
    }
}

// MARK: - One catalogue per endpoint, whichever door you came through

/// Bug 2 again — "every row rendered with no price and no context window" — from
/// the other direction, three months later and in the OTHER browser.
///
/// The adapters fixed what Settings' add/edit screen renders. The Where sheet's
/// `browse <provider>` row is a second door onto the same catalogue, and it kept
/// its own routing table: near.ai fetched live there (fixed 2026-07-29) and grok
/// and fireworks did not, so they fell back to `WhereProviderPresentation
/// .browseModels`, whose Grok rows come from a NAME table (`price: ""`, no
/// context) and whose Fireworks rows come from a PRICE table (no context, no
/// recency). Same key, same models, three different-looking lists.
///
/// `ModelCatalog.liveCatalog` is the one table now. These tests pin the routing
/// decision and the row shape it produces, because the decision is what was
/// wrong: the fetching code was right and simply never called.
@Suite("Cloud browse routing", .serialized)
struct CloudBrowseRoutingTests {

    private func machine() -> Provider {
        Provider(name: "second mac", endpoint: "http://100.100.0.12:11434/v1",
                 model: "qwen3:14b", requiresAPIKey: false)
    }

    /// The regression that matters: this returned `.nearAI` or nil, and nil is
    /// what made a Grok row a name and a vendor.
    @Test func everyCloudProviderResolvesToItsOwnCatalogue() {
        #expect(WhereProviderPresentation.liveCatalogSource(for: .nearAI) == .nearAI)
        #expect(WhereProviderPresentation.liveCatalogSource(for: .grok) == .xAI)
        #expect(WhereProviderPresentation.liveCatalogSource(for: .fireworks) == .fireworks)

        // A BYOK endpoint the presets don't cover has no curated snapshot at all,
        // so routing it to the generic probe is the difference between live bare
        // ids and an empty browse sheet.
        let custom = Provider(name: "my proxy", endpoint: "https://llm.example.com/v1/chat/completions",
                              model: "some-model", requiresAPIKey: true)
        #expect(WhereProviderPresentation.liveCatalogSource(for: custom) == .generic)
    }

    /// nil for the tiers that don't browse — a home server's models all arrive in
    /// `ready now` through the probe, and the phone has no browse row at all.
    @Test func theOtherTwoTiersHaveNothingLiveToBrowse() {
        #expect(WhereProviderPresentation.liveCatalogSource(for: machine()) == nil)
        #expect(WhereProviderPresentation.liveCatalogSource(
            for: .local(LocalModelCatalog.all[0])) == nil)
    }

    /// Grok rows through the router carry exactly what a near.ai row carries.
    /// Asserted against the curated snapshot in the same test, because that is the
    /// comparison the user was making on the device: the fallback's rows have an
    /// empty `metaLabel`, so the right-hand column of the list is simply blank.
    @Test func grokRowsGainThePriceAndContextTheSnapshotNeverHad() async throws {
        StubXAIAPI.reset()
        StubXAIAPI.routes = [
            "/language-models": (200, try fixture("xai_language_models.json")),
            "/models": (200, try fixture("xai_models.json")),
        ]
        let result = await ModelCatalog.liveCatalog(
            for: .xAI,
            baseURL: URL(string: "https://api.x.ai/v1")!,
            apiKey: "test-key",
            session: stubSession(StubXAIAPI.self))
        guard case .connected(let live) = result else {
            Issue.record("expected .connected, got \(result)"); return
        }
        #expect(live.allSatisfy { !$0.metaLabel.isEmpty })
        // `isNew` is a 45-day window on `created`. The newest id in
        // xai_language_models.json is 2026-06-29; as of 2026-08-15 that
        // window is closed, so this no longer asserts a badge. The
        // routing claim is the non-empty metaLabel against an empty snapshot.

        // What the sheet showed instead, and why it looked like another design.
        let curated = WhereProviderPresentation.browseModels(for: .grok)
        #expect(!curated.isEmpty, "the fallback still exists — it is offline cover")
        #expect(curated.allSatisfy { $0.metaLabel.isEmpty },
                "if the snapshot ever gains prices, this test is measuring the wrong thing")
    }

    /// Fireworks: the snapshot has prices but no context window, so its rows read
    /// as half a row next to near.ai's. Live fills both, and the vendor sections
    /// come from the model family rather than the "accounts/" namespace.
    @Test func fireworksRowsGainTheContextTheSnapshotNeverHad() async throws {
        StubFireworksAPI.reset()
        StubFireworksAPI.routes = [
            "/v1/accounts/fireworks/models": (200, try fixture("fireworks_serverless_models.json")),
        ]
        let result = await ModelCatalog.liveCatalog(
            for: .fireworks,
            baseURL: URL(string: "https://api.fireworks.ai/inference/v1")!,
            apiKey: "fw-key",
            session: stubSession(StubFireworksAPI.self))
        guard case .connected(let live) = result else {
            Issue.record("expected .connected, got \(result)"); return
        }
        // Every row the price map covers carries its rate. Rows the map no
        // longer covers (the fixture predates the fleet's deprecations) list
        // priceless BY DESIGN — "a model missing here still lists".
        let priced = live.filter { KnownModel.fireworksPrices[$0.id] != nil }
        #expect(!priced.isEmpty)
        #expect(priced.allSatisfy { !$0.price.isEmpty })
        #expect(!live.contains { $0.vendor == "Accounts" })
        // Every model the control plane reports a window for carries it. ONE in
        // the captured fixture reports `contextLength: 0` — qwen3p7-plus, a
        // CUSTOM_MODEL deployment — and that row is a price with no context
        // rather than a blank rail, which is what `metaLabel` joins for.
        let noContext = live.filter { $0.contextWindow.isEmpty }
        #expect(noContext.map(\.id) == ["accounts/fireworks/models/qwen3p7-plus"])
        #expect(noContext.allSatisfy { !$0.metaLabel.isEmpty })

        let curated = WhereProviderPresentation.browseModels(for: .fireworks)
        #expect(curated.allSatisfy { $0.contextWindow.isEmpty })
    }

    /// The other half of "look like near rows": what the row SAYS, not just what
    /// it carries. Fireworks' hand-written names arrive in three styles, and the
    /// browser groups by vendor — so "OpenAI gpt-oss-20b" printed the section
    /// header again inside the row, and "NVIDIA Nemotron 3 Ultra NVFP4" was long
    /// enough to truncate to "nvidia nemotron 3 ultra n…".
    @Test func fireworksRowsAreNamedInTheHouseStyle() async throws {
        StubFireworksAPI.reset()
        StubFireworksAPI.routes = [
            "/v1/accounts/fireworks/models": (200, try fixture("fireworks_serverless_models.json")),
        ]
        let result = await ModelCatalog.liveCatalog(
            for: .fireworks,
            baseURL: URL(string: "https://api.fireworks.ai/inference/v1")!,
            apiKey: "fw-key",
            session: stubSession(StubFireworksAPI.self))
        guard case .connected(let live) = result else {
            Issue.record("expected .connected, got \(result)"); return
        }
        func name(_ id: String) throws -> String {
            try #require(live.first { $0.id == "accounts/fireworks/models/\(id)" }).displayName
        }
        #expect(try name("gpt-oss-20b") == "gpt oss 20b")
        #expect(try name("nemotron-3-ultra-nvfp4") == "Nemotron 3 Ultra")
        // Kept whole: for these the first word is the family, not just the company.
        #expect(try name("deepseek-v4-flash") == "DeepSeek V4 Flash")
        #expect(try name("minimax-m3") == "Minimax M3")
        #expect(try name("kimi-k2p6") == "Kimi K2.6")

        // The invariant across the whole list, stated as the rule rather than as
        // "no row starts with its vendor" — which is FALSE on purpose: "deepseek
        // v4 flash" and "minimax m3" both do, because there the vendor word is
        // also the family word. What must never happen is a row keeping a
        // company-only prefix, i.e. one whose removal still leaves a family.
        for model in live {
            let words = model.displayName.split(separator: " ").map(String.init)
            guard words.count > 1,
                  words[0].compare(model.vendor, options: .caseInsensitive) == .orderedSame
            else { continue }
            let rest = words.dropFirst().joined(separator: "-")
            #expect(ModelCatalog.familyVendor(forID: rest) == nil,
                    "\(model.displayName) restates its own vendor section")
        }
    }

    /// A failure must stay a failure. The browse sheet renders the curated list
    /// while nothing live has arrived, so a router that turned 401 into
    /// `.connected([])` would replace a usable fallback with an empty list —
    /// the one outcome worse than the inconsistency this fixes.
    @Test func aRejectedKeyIsNotAnEmptyCatalogue() async {
        StubXAIAPI.reset()
        StubXAIAPI.routes = [
            "/language-models": (401, Data("{\"error\":\"bad key\"}".utf8)),
            "/models": (401, Data("{\"error\":\"bad key\"}".utf8)),
        ]
        let result = await ModelCatalog.liveCatalog(
            for: .xAI,
            baseURL: URL(string: "https://api.x.ai/v1")!,
            apiKey: "nope",
            session: stubSession(StubXAIAPI.self))
        #expect(result == .failed(.unauthorized))
    }
}

// MARK: - LM Studio

/// LM Studio's `/api/v0/models` is the richest catalogue any local server
/// exposes, and the generic `/v1/models` probe throws all of it away: it lists
/// the embedding model as selectable, names rows by raw id including the
/// "@quant" suffix, and leaves context, quantization, tools and vision blank.
///
/// Fixture is the real response from a live LM Studio 1234 (2026-07-25) whose
/// library was symlinked to the same GGUFs llama.cpp serves.
@Suite("LMStudioAdapter")
struct LMStudioAdapterTests {

    private func records() throws -> [LMStudioAdapter.ModelsResponse.Model] {
        try JSONDecoder().decode(LMStudioAdapter.ModelsResponse.self,
                                 from: fixture("lmstudio_api_v0_models.json")).data
    }

    @Test func fixtureDecodesTheNativeFields() throws {
        let all = try records()
        #expect(all.count == 4)
        let gemma = try #require(all.first { $0.id == "gemma-4-e4b-it-qat@q4_k_xl" })
        #expect(gemma.type == "vlm")
        #expect(gemma.publisher == "unsloth")
        #expect(gemma.arch == "gemma4")
        #expect(gemma.quantization == "Q4_K_XL")
        #expect(gemma.max_context_length == 131_072)
        #expect(gemma.capabilities == ["tool_use"])
        #expect(gemma.state == "not-loaded")
        #expect(gemma.isLoaded == false)
    }

    /// The embedding model ships in the same list; selecting it 400s on send.
    @Test func embeddingsAreExcludedAndChatModelsKept() throws {
        let models = LMStudioAdapter.buildModels(from: try records())
        #expect(models.count == 3)
        #expect(!models.contains { $0.id.contains("embedding") })
    }

    @Test func rowsCarryNameVendorContextAndQuant() throws {
        let models = LMStudioAdapter.buildModels(from: try records())
        let qwen = try #require(models.first { $0.id == "qwen2.5-7b-instruct" })
        #expect(qwen.displayName == "qwen2.5-7b-instruct")
        // "bartowski" is the GGUF uploader, not the vendor.
        #expect(qwen.vendor == "Qwen")
        #expect(qwen.contextWindow == "32k · Q4_K_M")
        #expect(qwen.price == "")                       // local inference is free

        let gemma = try #require(models.first { $0.id == "gemma-4-e4b-it-qat@q4_k_xl" })
        // The quant moves out of the name and next to the context window; the id
        // keeps its suffix because that is what /v1/chat/completions expects.
        #expect(gemma.displayName == "gemma-4-e4b-it-qat")
        #expect(gemma.id.hasSuffix("@q4_k_xl"))
        #expect(gemma.vendor == "Google")
        #expect(gemma.contextWindow == "128k · Q4_K_XL")   // 131072 is 128k, not 131k
    }

    /// Capabilities are MODELED here (LM Studio states them), so an empty set
    /// means "supports neither" — not "unknown".
    @Test func toolAndVisionCapabilitiesComeFromTheAPI() throws {
        let models = LMStudioAdapter.buildModels(from: try records())
        let gemma = try #require(models.first { $0.id == "gemma-4-e4b-it-qat@q4_k_xl" })
        #expect(gemma.capabilities == [.tools, .vision])   // type: vlm + tool_use
        let qwen = try #require(models.first { $0.id == "qwen2.5-7b-instruct" })
        #expect(qwen.capabilities == [.tools])             // type: llm + tool_use
    }

    /// Both local kinds report warm/cold, on different surfaces; the row shows it.
    @Test func loadedStateIsRead() throws {
        let all = try records()
        #expect(all.filter(\.isLoaded).isEmpty)            // fixture captured all cold
        let decoded = try JSONDecoder().decode(
            LMStudioAdapter.ModelsResponse.self,
            from: Data(#"{"data":[{"id":"m","state":"loaded","type":"llm"}]}"#.utf8))
        #expect(decoded.data.first?.isLoaded == true)
    }

    /// A future LM Studio `type` must not silently empty the picker.
    @Test func unknownTypesAreKeptAsChatModels() throws {
        let decoded = try JSONDecoder().decode(
            LMStudioAdapter.ModelsResponse.self,
            from: Data(#"{"data":[{"id":"some-new-thing","type":"omni"},{"id":"m2"}]}"#.utf8))
        #expect(LMStudioAdapter.buildModels(from: decoded.data).count == 2)
    }
}

// MARK: - Brave (no /models endpoint)

@Suite("Brave Answers provider")
struct BraveProviderTests {

    /// Brave has no model list, so the add-provider screen used to jump straight
    /// to "connected" without touching the network — a wrong key only surfaced
    /// when the first message failed. It now has an endpoint to verify against.
    @Test func braveIsTheOnlyPresetWithAKeyValidationEndpoint() {
        #expect(Provider.braveAnswers.keyValidationEndpoint == .braveSearch)
        for preset in Provider.presets where preset.id != Provider.braveAnswers.id {
            #expect(preset.keyValidationEndpoint == nil)
        }
    }

    /// A plan without the AI-answers option returns HTTP 400 with the reason in
    /// `error.detail` — it must reach the user verbatim, not as a bare "HTTP 400".
    @Test func planNotSubscribedErrorIsSurfacedVerbatim() {
        let body = """
        {"type":"ErrorResponse","error":{"id":"x","status":400,
         "detail":"The option is not subscribed in the plan.",
         "meta":{"component":"authentication"},"code":"OPTION_NOT_IN_PLAN"}}
        """
        let message = apiErrorMessage(from: body, httpStatus: 400, provider: "Brave Answers")
        #expect(message.contains("The option is not subscribed in the plan."))
    }

    /// Brave answers directly — it publishes no model list, so the add-provider
    /// screen must not offer one (`.fixed` rule ⇒ connection check, not picker).
    @Test func braveHasAFixedModelAndNoBrowsableCatalogue() {
        #expect(Provider.braveAnswers.defaultModelRule == .fixed("brave"))
        #expect(Provider.braveAnswers.supportsModelBrowsing == false)
        #expect(!Provider.braveAnswers.capabilities.contains(.modelBrowsing))
    }
}

// MARK: - Brave Answers wire format

/// Brave interleaves `<citation>{…}</citation>` and a trailing
/// `<usage>{…}</usage>` into the assistant's `content`, so teemoon rendered raw
/// JSON (and base64 favicon URLs) inside the prose. Fixture is the real
/// assembled content of a live streamed answer to "capital of france"
/// (2026-07-25, brave-pro, `enable_citations: true`).
@Suite("Brave Answers content format")
struct BraveAnswersFormatTests {

    private func liveAnswer(file: String = #filePath) throws -> String {
        return try TestFixture.string("brave_answers_content.txt", file: file)
    }

    @Test func realAnswerSplitsIntoProseAndSources() throws {
        let raw = try liveAnswer()
        #expect(raw.contains("<citation>"))     // fixture really is the raw form
        #expect(raw.contains("<usage>"))

        let (visible, sources) = BraveAnswersFormat.split(raw)
        #expect(!visible.contains("<citation>"))
        #expect(!visible.contains("<usage>"))
        #expect(!visible.contains("X-Request-Total-Cost"))
        #expect(!visible.contains("imgs.search.brave.com"))   // base64 favicon URLs
        #expect(visible.hasPrefix("**Paris** is the capital"))
        // The prose is a fraction of the payload — that is how much JSON was
        // being rendered into the message.
        #expect(visible.count < raw.count / 4)

        #expect(sources.count >= 5)
        #expect(sources.contains { $0.url == "https://en.wikipedia.org/wiki/Paris" })
        let wiki = try #require(sources.first { $0.url.contains("wikipedia") })
        #expect(wiki.domain == "en.wikipedia.org")
        #expect(!wiki.snippet.isEmpty)
        #expect(wiki.title.isEmpty)             // Brave sends none; the row shows the domain
        #expect(Set(sources.map(\.url)).count == sources.count)   // deduplicated
    }

    /// `split` runs on every streaming delta, so a block that hasn't closed yet
    /// must be withheld — otherwise the user watches `{"start_index": 58, "e`
    /// type across the screen before it vanishes.
    @Test func partialBlocksAreWithheldWhileStreaming() {
        #expect(BraveAnswersFormat.split("Paris is the capital.<cit").visible
                == "Paris is the capital.")
        #expect(BraveAnswersFormat.split("Paris is the capital.<").visible
                == "Paris is the capital.")
        #expect(BraveAnswersFormat.split(#"Paris.<citation>{"url": "https://ex"#).visible
                == "Paris.")
        #expect(BraveAnswersFormat.split("Paris.<usage>{\"X-Request").visible == "Paris.")
        // A "<" that can't begin a block is ordinary text and must survive.
        #expect(BraveAnswersFormat.split("2 < 3 is true").visible == "2 < 3 is true")
        #expect(BraveAnswersFormat.split("use <b>bold</b>").visible == "use <b>bold</b>")
    }

    @Test func textBetweenBlocksIsJoinedAndUsageIsNotASource() {
        let raw = #"One.<citation>{"url": "https://a.example/x", "snippet": "s"}</citation> Two."#
            + #"<usage>{"X-Request-Total-Cost": 0.05}</usage>"#
        let (visible, sources) = BraveAnswersFormat.split(raw)
        #expect(visible == "One. Two.")
        #expect(sources.map(\.url) == ["https://a.example/x"])
        #expect(sources.first?.domain == "a.example")
    }

    /// Every other provider streams plain content — the split must be a no-op
    /// for text with no blocks (it runs per delta on the shared path).
    @Test func plainAnswersPassThroughUnchanged() {
        let plain = "Here is a normal answer with a [link](https://example.com) and math: 2<3."
        let (visible, sources) = BraveAnswersFormat.split(plain)
        #expect(visible == plain)
        #expect(sources.isEmpty)
    }
}
