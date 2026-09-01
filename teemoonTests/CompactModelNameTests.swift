//
//  CompactModelNameTests.swift
//  teemoonTests
//
//  `ModelCatalog.compactName` is what the chat title bar shows, and the title
//  bar has no room to be wrong: it must drop how the model was *built* while
//  keeping which model it *is*.
//

import XCTest
@testable import teemoon

final class CompactModelNameTests: XCTestCase {

    func testDropsNamespaceAndPrecision() {
        XCTAssertEqual(ModelCatalog.compactName(forID: "zai-org/GLM-5.1-FP8"), "glm-5.1")
        XCTAssertEqual(ModelCatalog.compactName(forID: "Qwen/Qwen3.6-27B-FP8"), "qwen3.6-27b")
        XCTAssertEqual(ModelCatalog.compactName(forID: "z-ai/glm-5.2"), "glm-5.2")
    }

    func testDropsStackedBuildSuffixes() {
        // format + tuning + precision all at once, plus a quant tag
        XCTAssertEqual(
            ModelCatalog.compactName(forID: "unsloth/gemma-4-E4B-it-qat-GGUF:UD-Q4_K_XL"),
            "gemma-4-e4b")
    }

    /// Build words hide inside the `:tag` too — Ollama's `gemma4:e2b-it-qat`
    /// puts the size and the tuning markers in the same tag. Peel the tag by the
    /// same rule as the base, keeping only the part that says which model it is.
    func testPeelsBuildWordsOutOfTheTag() {
        XCTAssertEqual(ModelCatalog.compactName(forID: "gemma4:e2b-it-qat"), "gemma4:e2b")
        XCTAssertEqual(ModelCatalog.compactName(forID: "qwen3.5:4b-instruct-fp16"), "qwen3.5:4b")
        // …but a tag that is ONLY build words identifies nothing, so it all goes.
        XCTAssertEqual(ModelCatalog.compactName(forID: "mymodel:it-qat-gguf"), "mymodel")
    }

    /// A size tag identifies a different model; a quantisation tag does not.
    func testKeepsSizeTagDropsQuantTag() {
        XCTAssertEqual(ModelCatalog.compactName(forID: "gemma4:e2b"), "gemma4:e2b")
        XCTAssertEqual(ModelCatalog.compactName(forID: "qwen3.5:4b"), "qwen3.5:4b")
        XCTAssertEqual(ModelCatalog.compactName(forID: "llama4:latest"), "llama4:latest")
        XCTAssertEqual(ModelCatalog.compactName(forID: "mymodel:Q8_0"), "mymodel")
        XCTAssertEqual(ModelCatalog.compactName(forID: "mymodel:IQ3_M"), "mymodel")
    }

    /// llama.cpp pointed straight at a weights file: the "model id" is a
    /// filename, so it carries both an extension and an in-name quant code.
    func testStripsWeightsFilenameCruft() {
        XCTAssertEqual(ModelCatalog.compactName(forID: "ternary-bonsai-8b-q2_0.gguf"),
                       "ternary-bonsai-8b")
        XCTAssertEqual(ModelCatalog.compactName(forID: "/models/Meta-Llama-4-8B-Q4_K_M.gguf"),
                       "meta-llama-4-8b")
        XCTAssertEqual(ModelCatalog.compactName(forID: "mistral-7b-iq3_m.gguf"), "mistral-7b")
    }

    /// A size word must never be mistaken for packaging.
    func testKeepsSizeWords() {
        XCTAssertEqual(ModelCatalog.compactName(forID: "ternary-bonsai-8b"), "ternary-bonsai-8b")
        XCTAssertEqual(ModelCatalog.compactName(forID: "gemma-4-e4b-gguf"), "gemma-4-e4b")
    }

    /// Whatever we strip, we never hand the UI an empty string.
    func testNeverReturnsEmpty() {
        XCTAssertEqual(ModelCatalog.compactName(forID: "GGUF"), "gguf")
        XCTAssertEqual(ModelCatalog.compactName(forID: "vendor/-fp8"), "-fp8")
        XCTAssertFalse(ModelCatalog.compactName(forID: "org/model-it-qat-gguf").isEmpty)
    }

    // MARK: - titleLabel (what the chat title bar shows)

    /// Brave Answers has no /models endpoint and ships `model: "brave"` — a
    /// placeholder that says less than the provider's own name.
    func testPlaceholderModelFallsBackToProviderName() {
        XCTAssertEqual(ModelCatalog.titleLabel(model: "brave", providerName: "Brave Answers"),
                       "brave answers")
    }

    /// REGRESSION: the fallback first matched on `contains`, but a self-hosted
    /// provider's auto-label is "<host> <model>" — so it always contained the
    /// model, returned the whole long label, and the title bar dropped the
    /// segment entirely rather than overflow. Prefix, not containment.
    func testSelfHostedLabelDoesNotSwallowTheModel() {
        XCTAssertEqual(
            ModelCatalog.titleLabel(model: "ternary-bonsai-8b-q2_0.gguf",
                                    providerName: "ringzero ternary-bonsai-8b-q2_0.gguf"),
            "ternary-bonsai-8b")
        XCTAssertEqual(
            ModelCatalog.titleLabel(model: "gemma4:e2b", providerName: "ringzero gemma4:e2b"),
            "gemma4:e2b")
    }

    func testOrdinaryProviderKeepsTheModel() {
        XCTAssertEqual(ModelCatalog.titleLabel(model: "zai-org/GLM-5.1-FP8",
                                               providerName: "near.ai"), "glm-5.1")
        XCTAssertNil(ModelCatalog.titleLabel(model: "", providerName: "near.ai"))
    }

    func testLeavesOrdinaryNamesAlone() {
        XCTAssertEqual(ModelCatalog.compactName(forID: "gpt-5"), "gpt-5")
        XCTAssertEqual(ModelCatalog.compactName(forID: "claude-opus-5"), "claude-opus-5")
    }
}
