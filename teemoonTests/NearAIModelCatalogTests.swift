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

    @Test func curatedMetadataIsPreserved() {
        let rows = NearAIModelCatalog.merge(liveIDs: ["zai-org/GLM-5.1-FP8"], directHosts: [:])
        let glm = try? #require(rows.first { $0.id == "zai-org/GLM-5.1-FP8" })
        #expect(glm?.displayName == "GLM 5.1")
        #expect(glm?.price == "$1.40/$4.40")   // 2026-07-18 catalog snapshot
        #expect(glm?.directBaseURL == "https://glm-5-1.completions.near.ai/v1")
    }

    @Test func uncuratedModelIsSynthesizedWithDirectHost() {
        // An id NOT in the curated snapshot (glm-5.2-long exists only in
        // /endpoints, not /v1/models) must be synthesized from the live data.
        let rows = NearAIModelCatalog.merge(
            liveIDs: ["z-ai/glm-5.2-long"],
            directHosts: ["z-ai/glm-5.2-long": "https://glm-5-2-long.completions.near.ai/v1"])
        let glm = try? #require(rows.first { $0.id == "z-ai/glm-5.2-long" })
        #expect(glm?.vendor == "Z.ai")
        #expect(glm?.displayName == "glm-5.2-long")
        #expect(glm?.price == "")  // unknown price → blank in the row
        #expect(glm?.directBaseURL == "https://glm-5-2-long.completions.near.ai/v1")
    }

    @Test func nonChatModelsAreFiltered() {
        let ids = ["Qwen/Qwen3-Embedding-0.6B", "Qwen/Qwen3-Reranker-0.6B",
                   "openai/whisper-large-v3", "openai/privacy-filter",
                   "black-forest-labs/FLUX.2-klein-4B", "zai-org/GLM-5.1-FP8"]
        let rows = NearAIModelCatalog.merge(liveIDs: ids, directHosts: [:])
        #expect(rows.map(\.id) == ["zai-org/GLM-5.1-FP8"])
    }

    @Test func duplicatesCollapse() {
        let rows = NearAIModelCatalog.merge(
            liveIDs: ["openai/gpt-oss-120b", "openai/gpt-oss-120b"], directHosts: [:])
        #expect(rows.filter { $0.id == "openai/gpt-oss-120b" }.count == 1)
    }

    @Test func vendorLabelsMapNamespaces() {
        #expect(NearAIModelCatalog.vendorLabel(forID: "zai-org/GLM-5.1-FP8") == "Z.ai")
        #expect(NearAIModelCatalog.vendorLabel(forID: "deepseek-ai/DeepSeek-V4-Flash") == "DeepSeek")
        #expect(NearAIModelCatalog.vendorLabel(forID: "moonshotai/kimi-k2.6") == "Moonshot")
        #expect(NearAIModelCatalog.vendorLabel(forID: "mystery/model") == "Mystery")
    }

    @Test func curatedListHasNoRetiredModels() {
        // Regression for the prune: the retired ids must be gone.
        let ids = Set(KnownModel.nearAIModels.map(\.id))
        for retired in ["deepseek-ai/DeepSeek-V3.1", "google/gemini-3-pro",
                        "Qwen/Qwen3-30B-A3B-Instruct-2507", "zai-org/GLM-5-FP8"] {
            #expect(!ids.contains(retired), "\(retired) is retired and must not be curated")
        }
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

// appended by the recency-ordering fix — kept outside the main suite body
// so the file's existing structure is untouched.
@Suite("NearAIModelCatalog.merge — ordering")
struct NearAIModelCatalogOrderingTests {

    /// The live merge must preserve the curated ordering (families by newest,
    /// recency within family), not re-sort alphabetically — and uncurated live
    /// ids join at the HEAD of their family (they're the newest releases).
    @Test func mergePreservesCuratedRecencyOrder() {
        let rows = NearAIModelCatalog.merge(
            liveIDs: ["openai/gpt-oss-120b", "z-ai/glm-5.3-preview", "zai-org/GLM-5.1-FP8", "z-ai/glm-5.2"],
            directHosts: [:])
        let ids = rows.map(\.id)
        // Z.ai family leads (its newest curated model tops the curated list),
        // with the uncurated glm-5.3-preview at the family head.
        #expect(ids == ["z-ai/glm-5.3-preview", "z-ai/glm-5.2", "zai-org/GLM-5.1-FP8", "openai/gpt-oss-120b"])
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

    /// And the snapshot can no longer carry one at all: the curated rows are the
    /// OFFLINE fallback, where teemoon has no date to judge by, so a badge there
    /// would be a claim it cannot support.
    @Test func theCuratedSnapshotNoLongerBadgesAnything() {
        #expect(KnownModel.nearAIModels.allSatisfy { !$0.isNew })
    }
}
