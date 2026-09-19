//
//  NearAIModelCatalogTests.swift
//  teemoonTests
//
//  The pure merge that turns a live /v1/models id list into browser rows:
//  curated metadata preserved, non-chat models filtered, uncurated ids
//  synthesized with resolved direct hosts.
//

import Foundation
import Testing
@testable import teemoon

@Suite("NearAIModelCatalog")
struct NearAIModelCatalogTests {

    /// A CLOSED-WEIGHT MODEL CAN NEVER BE PROMOTED TO near.ai's OWN ENCLAVE,
    /// whatever the catalogue says about it.
    ///
    /// Observed live 2026-08-02: near.ai returned `owned_by: "nearai"` for
    /// `anthropic/claude-sonnet-5`, while `claude-sonnet-4-5` and `-4-6` came
    /// back `"anthropic"`. The authoritative cache is consulted before the id
    /// heuristic, so that single field made teemoon tell the user
    /// "end-to-end encrypted" about a passthrough to Anthropic's API.
    ///
    /// Anthropic does not release these weights. No third party is running them
    /// in its own TEE, and a wrong e2ee claim is the worst thing this app can
    /// say — so the id vetoes the upgrade.
    @Test func ownedByCannotPromoteAClosedWeightModelToTheOwnFleet() {
        NearAIModelCatalog.resetTierCache()
        defer { NearAIModelCatalog.resetTierCache() }

        // Exactly what the live catalogue served.
        NearAIModelCatalog.recordTiers(["anthropic/claude-sonnet-5": .teeOwn])
        #expect(NearAIModelCatalog.confidentiality(forID: "anthropic/claude-sonnet-5") == .proxied)
        #expect(!NearAIModelCatalog.isAttestable("anthropic/claude-sonnet-5"))

        // The same refusal for the other closed frontier vendors.
        NearAIModelCatalog.recordTiers([
            "openai/gpt-5.2": .teeOwn,
            "google/gemini-3-pro": .teeOwn,
        ])
        #expect(NearAIModelCatalog.confidentiality(forID: "openai/gpt-5.2") == .proxied)
        #expect(NearAIModelCatalog.confidentiality(forID: "google/gemini-3-pro") == .proxied)
    }

    /// DOWNGRADES MUST STILL WORK. The veto is one-way — the catalogue remains
    /// authoritative for moving an open-weight model teemoon guessed was
    /// own-fleet down to third-party or proxied.
    @Test func theCatalogueCanStillDowngradeAnOpenWeightModel() {
        NearAIModelCatalog.resetTierCache()
        defer { NearAIModelCatalog.resetTierCache() }

        let id = "zai-org/GLM-5.1-FP8"
        #expect(NearAIModelCatalog.classify(id) == .teeOwn)
        NearAIModelCatalog.recordTiers([id: .teeThirdParty])
        #expect(NearAIModelCatalog.confidentiality(forID: id) == .teeThirdParty)
    }

    /// near.ai proxies whole vendor namespaces it does not host: the ids
    /// that arrived 2026-09-12 fell through every rule to "own fleet", and
    /// the catalog tool refused to write a list the app would mislabel.
    @Test func proxiedVendorNamespacesAreNotOwnFleet() {
        #expect(NearAIModelCatalog.classify("x-ai/grok-4.6") == .proxied)
        #expect(NearAIModelCatalog.classify("deepseek/deepseek-v4.1-flash") == .proxied)
        // The own-fleet DeepSeek node keeps its namespace.
        #expect(NearAIModelCatalog.classify("deepseek-ai/DeepSeek-V4-Flash") == .teeOwn)
        #expect(NearAIModelCatalog.classify("z-ai/glm-5.3-flash") == .teeOwn)
    }


    // MARK: reused-node vendor mismatch (DeepSeek-host-shows-Qwen bug)

    @Test func differentVendorFlagsCrossVendorComposeMismatch() {
        // The live bug: DeepSeek V4 Flash's node's latest compose_up is a Qwen
        // YAML, so the parsed artifact is Qwen while the requested model is
        // DeepSeek — must be flagged as a mismatch and dropped.
        #expect(NearAIModelCatalog.differentVendor(
            "Qwen/Qwen3.5-122B", "deepseek-ai/DeepSeek-V4-Flash"))
        #expect(NearAIModelCatalog.differentVendor(
            "deepseek-ai/DeepSeek-V4-Flash", "Qwen/Qwen3.6-27B-FP8"))
    }

    @Test func differentVendorAcceptsNamespaceAliases() {
        // z-ai / zai-org are the same vendor (Z.ai) — NOT a mismatch.
        #expect(!NearAIModelCatalog.differentVendor("z-ai/glm-5.2", "zai-org/GLM-5.2-FP8"))
        // deepseek / deepseek-ai both map to DeepSeek.
        #expect(!NearAIModelCatalog.differentVendor("deepseek/deepseek-v3.2", "deepseek-ai/DeepSeek-V4-Flash"))
    }

    @Test func differentVendorIsFalseWhenUnknown() {
        #expect(!NearAIModelCatalog.differentVendor(nil, "deepseek-ai/DeepSeek-V4-Flash"))
        #expect(!NearAIModelCatalog.differentVendor("Qwen/Qwen3.6-27B-FP8", nil))
    }

    @Test func requantizedWeightsMustCompareServedNameNotModelPath() {
        // GLM-5.1 runs `QuantTrio/GLM-5.1-AWQ` weights but declares
        // `--served-model-name zai-org/GLM-5.1-FP8`. The reused-node guard must
        // compare the SERVED name (matches the requested id) — NOT the weights
        // repo, whose vendor differs by design. Comparing the served name is a
        // match (kept):
        #expect(!NearAIModelCatalog.differentVendor("zai-org/GLM-5.1-FP8", "zai-org/GLM-5.1-FP8"))
        // …while comparing the model-path would have FALSELY flagged it (the
        // regression that dropped GLM-5.1's whole model layer):
        #expect(NearAIModelCatalog.differentVendor("QuantTrio/GLM-5.1-AWQ", "zai-org/GLM-5.1-FP8"))
    }

    /// The live row is the whole row: teemoon keeps no metadata of its own to
    /// merge in, so what near.ai says is what shows.
    @Test func liveMetadataIsTheRow() async {
        let json = """
        {"data":[{"id":"z-ai/glm-5.3-flash","owned_by":"nearai","name":"GLM 5.3 Flash",
                  "created":1788000000,"pricing":{"input":0.15,"output":0.5},
                  "context_length":1000000,"supported_features":["tools"]}]}
        """
        let list = try! JSONDecoder().decode(NearAIModelCatalog.ModelsResponse.self, from: Data(json.utf8))
        let rows = await NearAIModelCatalog.buildModels(from: list.data)
        let glm = rows.first { $0.id == "z-ai/glm-5.3-flash" }
        #expect(glm?.displayName == "GLM 5.3 Flash")
        #expect(glm?.price == "$0.15/$0.50")
        #expect(glm?.contextWindow == "1M")
        #expect(glm?.created != nil)
    }

    /// A row near.ai names only by id still reads as a product.
    @Test func anUnnamedModelIsStillReadable() async {
        let json = """
        {"data":[{"id":"z-ai/glm-5.2-long","owned_by":"nearai","created":1788000000}]}
        """
        let list = try! JSONDecoder().decode(NearAIModelCatalog.ModelsResponse.self, from: Data(json.utf8))
        let rows = await NearAIModelCatalog.buildModels(from: list.data)
        let glm = rows.first { $0.id == "z-ai/glm-5.2-long" }
        #expect(glm?.vendor == "Z.ai")
        #expect(glm?.displayName == "glm-5.2-long")
        #expect(glm?.price == "")
    }

    @Test func nonChatModelsAreFiltered() async {
        let ids = ["Qwen/Qwen3-Embedding-0.6B", "Qwen/Qwen3-Reranker-0.6B",
                   "openai/whisper-large-v3", "openai/privacy-filter",
                   "black-forest-labs/FLUX.2-klein-4B", "zai-org/GLM-5.1-FP8"]
        let json = "{\"data\":[" + ids.map { "{\"id\":\"\($0)\",\"owned_by\":\"nearai\"}" }
            .joined(separator: ",") + "]}"
        let list = try! JSONDecoder().decode(NearAIModelCatalog.ModelsResponse.self, from: Data(json.utf8))
        let rows = await NearAIModelCatalog.buildModels(from: list.data)
        #expect(rows.map(\.id) == ["zai-org/GLM-5.1-FP8"])
    }

    @Test func duplicatesCollapse() async {
        let json = """
        {"data":[{"id":"openai/gpt-oss-120b","owned_by":"nearai"},
                 {"id":"openai/gpt-oss-120b","owned_by":"nearai"}]}
        """
        let list = try! JSONDecoder().decode(NearAIModelCatalog.ModelsResponse.self, from: Data(json.utf8))
        let rows = await NearAIModelCatalog.buildModels(from: list.data)
        #expect(rows.filter { $0.id == "openai/gpt-oss-120b" }.count == 1)
    }

    @Test func vendorLabelsMapNamespaces() {
        #expect(NearAIModelCatalog.vendorLabel(forID: "zai-org/GLM-5.1-FP8") == "Z.ai")
        #expect(NearAIModelCatalog.vendorLabel(forID: "deepseek-ai/DeepSeek-V4-Flash") == "DeepSeek")
        #expect(NearAIModelCatalog.vendorLabel(forID: "moonshotai/kimi-k2.6") == "Moonshot")
        #expect(NearAIModelCatalog.vendorLabel(forID: "mystery/model") == "Mystery")
    }

    /// teemoon ships no near.ai model list at all: a retired model can only
    /// reach a screen by being in what near.ai served.
    @Test func noModelListShips() {
        #expect(KnownModel.braveAnswersModel.id == Provider.braveAnswers.model)
    }

    // MARK: - Confidentiality tier / attestation gate

    @Test func classify_openWeightModelsAreAttestable() {
        NearAIModelCatalog.resetTierCache()
        #expect(NearAIModelCatalog.isAttestable("zai-org/GLM-5.1-FP8"))
        #expect(NearAIModelCatalog.isAttestable("openai/gpt-oss-120b"))   // open-weight, not proxied
        #expect(NearAIModelCatalog.isAttestable("google/gemma-4-31b-it")) // gemma ≠ gemini
        #expect(NearAIModelCatalog.isAttestable("Qwen/Qwen3.5-122B-A10B"))
        #expect(NearAIModelCatalog.isAttestable("deepseek-ai/DeepSeek-V4-Flash"))
    }

    @Test func classify_proxiedClosedModelsAreNotAttestable() {
        NearAIModelCatalog.resetTierCache()
        #expect(!NearAIModelCatalog.isAttestable("anthropic/claude-opus-4-6"))
        #expect(!NearAIModelCatalog.isAttestable("openai/gpt-5.2"))
        #expect(!NearAIModelCatalog.isAttestable("openai/o3"))
        #expect(!NearAIModelCatalog.isAttestable("google/gemini-2.5-pro"))
        #expect(!NearAIModelCatalog.isAttestable("qwen/qwen3.7-max"))
    }

    @Test func tierFromOwnedBy_mapsCatalogValues() {
        #expect(NearAIModelCatalog.tierFromOwnedBy("nearai") == .teeOwn)
        #expect(NearAIModelCatalog.tierFromOwnedBy("attested 3p") == .teeThirdParty)
        #expect(NearAIModelCatalog.tierFromOwnedBy("chutes") == .teeThirdParty)
        #expect(NearAIModelCatalog.tierFromOwnedBy("anthropic") == .proxied)
        #expect(NearAIModelCatalog.tierFromOwnedBy("") == nil)
        #expect(NearAIModelCatalog.tierFromOwnedBy(nil) == nil)
    }

    @Test func ownedBy_cacheIsAuthoritativeAndCaseInsensitive() {
        NearAIModelCatalog.resetTierCache()
        // The live catalog's owned_by overrides the id heuristic: a vendor-owned
        // id the heuristic would treat as open-weight is marked proxied, and a
        // Chutes-attested model resolves to the third-party tier.
        NearAIModelCatalog.recordTiers([
            "vendor/some-open-model": .proxied,
            "moonshotai/kimi-k2.5": .teeThirdParty,
        ])
        #expect(!NearAIModelCatalog.isAttestable("vendor/some-open-model"))
        #expect(NearAIModelCatalog.confidentiality(forID: "MoonshotAI/Kimi-K2.5") == .teeThirdParty)
        NearAIModelCatalog.resetTierCache()
        // Once cleared, the offline heuristic governs again — and it too knows
        // kimi is attested-3p (the exact-id set beside the catalog snapshot),
        // so an offline launch can't misfile a Chutes model as E2EE-capable.
        #expect(NearAIModelCatalog.confidentiality(forID: "moonshotai/kimi-k2.5") == .teeThirdParty)
    }
}

@Suite("NearAIModelCatalog ordering")
struct NearAIModelCatalogOrderingTests {

    private func row(_ id: String, _ created: TimeInterval?) -> KnownModel {
        KnownModel(id: id, displayName: id, vendor: NearAIModelCatalog.vendorLabel(forID: id),
                   price: "", created: created.map { Date(timeIntervalSince1970: $0) })
    }

    /// What teemoon can seal comes first, then attested third-party hardware,
    /// then the plain proxies — newest first inside each tier. The tier order
    /// is the point: a cheap proxied model must not head a list titled by
    /// what near.ai runs itself.
    @Test func tiersLeadAndRecencyOrdersWithinThem() {
        let rows = NearAIModelCatalog.ordered([
            row("anthropic/claude-sonnet-5", 1_788_000_000),   // proxied, newest overall
            row("moonshotai/kimi-k3", 1_787_000_000),          // attested 3p
            row("z-ai/glm-5.3-flash", 1_780_000_000),          // own fleet, oldest
            row("Qwen/Qwen3.8-27B", 1_786_000_000),            // own fleet, newer
        ])
        #expect(rows.map(\.id) == ["Qwen/Qwen3.8-27B", "z-ai/glm-5.3-flash",
                                   "moonshotai/kimi-k3", "anthropic/claude-sonnet-5"])
    }

    /// A row near.ai gives no date keeps the server's own position rather than
    /// sorting to the top or the bottom by accident.
    @Test func undatedRowsKeepTheServersOrder() {
        let rows = NearAIModelCatalog.ordered([
            row("Qwen/QwenA", nil), row("Qwen/QwenB", nil), row("Qwen/QwenC", 1_780_000_000),
        ])
        #expect(rows.map(\.id) == ["Qwen/QwenC", "Qwen/QwenA", "Qwen/QwenB"])
    }
}

// MARK: - The recency badge, from near.ai's own `created`

/// near.ai DOES date its models, and nothing was reading it.
///
/// `ModelsResponse.Model.created` was modelled and unused, so the two surfaces
/// that render the badge disagreed and both were wrong:
///
///   - settings → browse fed `fetchLive`'s rows, whose `isNew` was never set, so
///     NO near.ai model was ever badged — including six that qualified.
///   - Where → browse near.ai fed `KnownModel.nearAIModels`, the curated
///     snapshot, whose `isNew: true` was frozen at generation time. Measured
///     2026-07-29: two of its three badged models had been published 54 days
///     earlier, nine days past the 45-day window.
///
/// Fixture is a real captured `/v1/models` slice, and `now` is pinned, so this
/// asserts the RULE rather than drifting with the clock.
@Suite("NearAIModelCatalog — recency")
struct NearAIRecencyTests {

    private func liveModels() throws -> [NearAIModelCatalog.ModelsResponse.Model] {
        try JSONDecoder().decode(
            NearAIModelCatalog.ModelsResponse.self,
            from: TestFixture.data("nearai_models.json", file: #filePath)
        ).data
    }

    /// Every model in a real response carries a distinct, plausible timestamp —
    /// this is the premise the whole rule rests on, so it is asserted rather than
    /// assumed.
    @Test func everyLiveModelCarriesACreatedDate() throws {
        let models = try liveModels()
        #expect(!models.isEmpty)
        for m in models {
            #expect(m.createdDate != nil, "\(m.id) has no created date")
        }
        #expect(Set(models.map(\.created)).count > 1, "one bulk timestamp, not real dates")
    }

    /// glm-5.2 was published 2026-06-17. At 41 days it is inside the window; ten
    /// days later it is outside — and nothing has to be re-run for that to happen,
    /// which is the entire point.
    @Test func theBadgeExpiresOnItsOwn() throws {
        let glm = try #require(try liveModels().first { $0.id == "z-ai/glm-5.2" })
        let created = try #require(glm.createdDate)

        #expect(ModelCatalog.isNew(created: created,
                                   now: created.addingTimeInterval(41 * 86_400)))
        #expect(!ModelCatalog.isNew(created: created,
                                    now: created.addingTimeInterval(51 * 86_400)))
    }

    /// The two rows the snapshot was badging wrongly, at the date it was measured.
    ///
    /// The date is BUILT, not written as an epoch literal — the first version of
    /// this test hardcoded 1_784_073_600 for "2026-07-29", which is actually
    /// 2026-07-15, and the fourteen-day error made the assertion fail for a reason
    /// that had nothing to do with the code under test.
    @Test func staleSnapshotBadgesAreNowCorrectlyDenied() throws {
        let models = try liveModels()
        var when = DateComponents()
        when.year = 2026; when.month = 7; when.day = 29
        when.timeZone = TimeZone(identifier: "UTC")
        let measured = try #require(Calendar(identifier: .gregorian).date(from: when))

        for id in ["Qwen/Qwen3.6-27B-FP8", "deepseek-ai/DeepSeek-V4-Flash"] {
            let m = try #require(models.first { $0.id == id })
            let created = try #require(m.createdDate)
            // 2026-06-04, so 55 days — ten past the window it was still claiming.
            #expect(measured.timeIntervalSince(created) / 86_400 > 45)
            #expect(!ModelCatalog.isNew(created: created, now: measured),
                    "\(id) is 55 days old and must not be badged new")
        }
    }

    /// The rows carry near.ai's own `created`, so a saved list can re-age its
    /// badges instead of freezing them.
    @Test func rowsCarryTheirCreationDate() async {
        let json = """
        {"data":[{"id":"z-ai/glm-5.3-flash","owned_by":"nearai","created":1788000000}]}
        """
        let list = try! JSONDecoder().decode(NearAIModelCatalog.ModelsResponse.self, from: Data(json.utf8))
        let rows = await NearAIModelCatalog.buildModels(from: list.data)
        #expect(rows.first?.created == Date(timeIntervalSince1970: 1788000000))
    }
}
