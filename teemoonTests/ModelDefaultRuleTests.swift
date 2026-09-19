//
//  ModelDefaultRuleTests.swift
//  teemoonTests
//
//  The per-provider default-model rule resolved against a live catalogue. These
//  lock in the behaviour that caused today's bugs — especially the GLM 5.2-vs-5.1
//  tie-break that made the picked default flicker.
//

import Foundation
import Testing
@testable import teemoon

@Suite("ModelDefaultRule")
struct ModelDefaultRuleTests {

    // A small near.ai-shaped catalogue. Prices are "input/output"; the two GLMs share
    // a price so the tie-break must decide between them.
    private func km(_ id: String, _ price: String, _ ctx: String) -> KnownModel {
        KnownModel(id: id, displayName: id, vendor: "v", price: price, contextWindow: ctx)
    }
    private var catalogue: [KnownModel] {
        [
            km("z-ai/glm-5.2", "$1.40/$4.40", "1M"),      // e2ee, 5.80, 1M
            km("zai-org/GLM-5.1-FP8", "$1.40/$4.40", "203K"), // e2ee, 5.80, 203K
            km("Qwen/Qwen3.6-27B-FP8", "$0.33/$3.25", "262K"),// e2ee, 3.58
            km("anthropic/claude-opus-4-7", "$5.00/$25.00", "1M"), // proxied, 30.0
            km("openai/gpt-5.5", "$5.00/$30.00", "1.1M"),  // proxied, 35.0
        ]
    }

    // MARK: priceScore / contextValue

    @Test func priceScoreSumsInputAndOutput() {
        #expect(abs(ModelDefaultRule.priceScore(km("x", "$1.40/$4.40", "")) - 5.80) < 0.0001)
        #expect(ModelDefaultRule.priceScore(km("x", "$5.00/$25.00", "")) == 30.0)
        #expect(ModelDefaultRule.priceScore(km("x", "", "")) == 0)
    }

    @Test func contextValueParsesUnits() {
        #expect(ModelDefaultRule.contextValue("1M") == 1_000_000)
        #expect(ModelDefaultRule.contextValue("1.1M") == 1_100_000)
        #expect(ModelDefaultRule.contextValue("203k") == 203_000)
        #expect(ModelDefaultRule.contextValue("128000") == 128_000)
        #expect(ModelDefaultRule.contextValue("") == 0)
        // A local row spells the quantisation after the size. The "m" in
        // "q4_k_m" is not a unit; reading it as one made 128k look like 128M
        // and a laptop model win every largest-context comparison.
        #expect(ModelDefaultRule.contextValue("128k · Q4_K_M") == 128_000)
        #expect(ModelDefaultRule.contextValue("32768 · Q8_0") == 32_768)
    }

    /// `attested 3p` (Chutes) hardware is attestable but has NO confidential
    /// endpoint via near.ai, so an e2ee-only rule must never name one — however
    /// dear it is. Live on 2026-09-14 that was kimi-k3 at $19.80.
    @Test func e2eeOnlyExcludesAttestedThirdParty() {
        let models = [
            km("moonshotai/kimi-k3", "$3.30/$16.50", "1M"),      // attested 3p, 19.80
            km("z-ai/glm-5.3-flash", "$0.15/$0.50", "1M"),       // own fleet, 0.65
        ]
        #expect(ModelDefaultRule.mostExpensive(e2eeOnly: true).resolve(from: models)
                == "z-ai/glm-5.3-flash")
        #expect(NearAIModelCatalog.confidentiality(forID: "moonshotai/kimi-k3") == .teeThirdParty)
        // Without the filter the dearest model still wins.
        #expect(ModelDefaultRule.mostExpensive(e2eeOnly: false).resolve(from: models)
                == "moonshotai/kimi-k3")
    }

    // MARK: mostExpensive (near.ai's rule)

    @Test func mostExpensiveE2EEPicksFlagshipNotProxied() {
        NearAIModelCatalog.resetTierCache()  // exercise the id heuristic, not stale live tiers
        // Claude/GPT are pricier but proxied — must be excluded; GLM 5.2 is the top e2ee.
        let picked = ModelDefaultRule.mostExpensive(e2eeOnly: true).resolve(from: catalogue)
        #expect(picked == "z-ai/glm-5.2")
    }

    @Test func mostExpensiveTieBreaksByContextIndependentOfOrder() {
        NearAIModelCatalog.resetTierCache()
        // GLM 5.1 first in the list, same price as 5.2 — the larger-context tie-break
        // must still choose 5.2 (this is the flicker bug).
        let reordered = [
            km("zai-org/GLM-5.1-FP8", "$1.40/$4.40", "203K"),
            km("z-ai/glm-5.2", "$1.40/$4.40", "1M"),
        ]
        #expect(ModelDefaultRule.mostExpensive(e2eeOnly: true).resolve(from: reordered) == "z-ai/glm-5.2")
    }

    @Test func mostExpensiveWithoutE2EEFilterAllowsProxied() {
        NearAIModelCatalog.resetTierCache()
        // No tier filter → the single most expensive overall wins (gpt-5.5, 35.0).
        #expect(ModelDefaultRule.mostExpensive(e2eeOnly: false).resolve(from: catalogue) == "openai/gpt-5.5")
    }

    // MARK: other rules

    // MARK: strongestOpenWeight

    private func open(_ id: String, _ price: String, isNew: Bool = false) -> KnownModel {
        var m = km(id, price, ""); m.openWeights = true; m.isNew = isNew; return m
    }
    private func closed(_ id: String, _ price: String) -> KnownModel {
        var m = km(id, price, ""); m.openWeights = false; return m
    }

    @Test func parameterCountReadsTotalsFromIds() {
        #expect(ModelDefaultRule.parameterCount("qwen/qwen3.8-27b") == 27)
        #expect(ModelDefaultRule.parameterCount("nvidia/nemotron-3-super-120b-a12b") == 120)
        #expect(ModelDefaultRule.parameterCount("nvidia/nemotron-3-ultra-550b-a55b") == 550)
        #expect(ModelDefaultRule.parameterCount("qwen/qwen3.8-2.4t-a95b") == 2400)
        #expect(ModelDefaultRule.parameterCount("z-ai/glm-5.3-flash") == nil)
        #expect(ModelDefaultRule.parameterCount("x-ai/grok-4.6") == nil)
        #expect(ModelDefaultRule.parameterCount("zai-org/GLM-5.1-FP8") == nil)
    }

    @Test func strongestOpenWeightIgnoresClosedModelsHoweverExpensive() {
        let picked = ModelDefaultRule.strongestOpenWeight.resolve(from: [
            closed("anthropic/claude-opus-5", "$5.00/$25.00"),
            open("deepseek/deepseek-v4-pro", "$1.60/$3.20"),
            open("moonshotai/kimi-k3", "$2.65/$13.28"),
            km("qwen/qwen3.8-max", "$2.00/$6.00", ""),        // unknown, not open
        ])
        #expect(picked == "moonshotai/kimi-k3")
    }

    @Test func strongestOpenWeightOnAFreeHostFallsToParameterCount() {
        let picked = ModelDefaultRule.strongestOpenWeight.resolve(from: [
            open("nvidia/nemotron-3-super-120b-a12b", ""),
            open("moonshotai/kimi-k3", ""),
            open("nvidia/nemotron-3-ultra-550b-a55b", ""),
        ])
        #expect(picked == "nvidia/nemotron-3-ultra-550b-a55b")
    }

    @Test func strongestOpenWeightBreaksAFullTieByRecency() {
        let picked = ModelDefaultRule.strongestOpenWeight.resolve(from: [
            open("qwen/qwen3.6-27b", "$0.30/$2.00"),
            open("qwen/qwen3.7-27b", "$0.30/$2.00", isNew: true),
        ])
        #expect(picked == "qwen/qwen3.7-27b")
    }

    @Test func strongestOpenWeightWithNothingOpenTakesTheFirstModel() {
        #expect(ModelDefaultRule.strongestOpenWeight.resolve(from: [closed("a", "$1/$1"), closed("b", "$9/$9")]) == "a")
        #expect(ModelDefaultRule.strongestOpenWeight.resolve(from: []) == nil)
    }

    @Test func fixedReturnsItsIdRegardlessOfCatalogue() {
        #expect(ModelDefaultRule.fixed("brave").resolve(from: []) == "brave")
        #expect(ModelDefaultRule.fixed("brave").resolve(from: catalogue) == "brave")
        #expect(ModelDefaultRule.fixed("brave").needsCatalogue == false)
    }

    @Test func firstReturnsTheFirstModel() {
        #expect(ModelDefaultRule.first.resolve(from: catalogue) == "z-ai/glm-5.2")
        #expect(ModelDefaultRule.first.resolve(from: []) == nil)
    }

    @Test func curatedTakesFirstAvailableElseFallsBack() {
        // First curated id present → it wins.
        #expect(ModelDefaultRule.curated(["missing", "Qwen/Qwen3.6-27B-FP8"]).resolve(from: catalogue)
                == "Qwen/Qwen3.6-27B-FP8")
        // None present → fall back to the first catalogue entry.
        #expect(ModelDefaultRule.curated(["nope"]).resolve(from: catalogue) == "z-ai/glm-5.2")
    }

    @Test func newestE2EEPicksFirstAttestableInList() {
        NearAIModelCatalog.resetTierCache()
        // The catalogue is recency-sorted, so "newest" = first in the e2ee pool.
        #expect(ModelDefaultRule.newest(e2eeOnly: true).resolve(from: catalogue) == "z-ai/glm-5.2")
    }
}
