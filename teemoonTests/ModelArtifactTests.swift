//
//  ModelArtifactTests.swift
//  teemoonTests
//
//  Covers parsing the pinned model artifact out of the model-layer compose
//  YAML, and the FP8→AWQ quantization-drift detection that is the payoff.
//

import Testing
@testable import teemoon

struct ModelArtifactTests {

    /// The real near.ai shape: launch flags as a YAML list, served alias's
    /// quant tag contradicting the pinned path's.
    private let listFormYAML = """
    services:
      model-sg-glm51-awq-tp4-r1:
        image: glm51-sgl-awq-tp4-patched:local
        command:
          - python3
          - -m
          - sglang.launch_server
          - --model-path
          - QuantTrio/GLM-5.1-AWQ
          - --revision
          - 8f60817aa28023f2607850d1a1e51d21aa34817a
          - --served-model-name
          - zai-org/GLM-5.1-FP8
          - --tp
          - "4"
    """

    @Test func parsesListForm() {
        let a = ModelArtifact.parse(fromComposeYAML: listFormYAML)
        #expect(a?.modelPath == "QuantTrio/GLM-5.1-AWQ")
        #expect(a?.revision == "8f60817aa28023f2607850d1a1e51d21aa34817a")
        #expect(a?.servedName == "zai-org/GLM-5.1-FP8")
        #expect(a?.quant == "AWQ")
    }

    @Test func derivesCleanBaseName() {
        let a = ModelArtifact.parse(fromComposeYAML: listFormYAML)
        // vendor prefix and quant suffix stripped
        #expect(a?.baseModelName == "GLM-5.1")
    }

    @Test func detectsQuantDrift() {
        let a = ModelArtifact.parse(fromComposeYAML: listFormYAML)
        #expect(a?.servedQuant == "FP8")
        #expect(a?.quantDrift == true)
        #expect(a?.driftNote?.contains("QuantTrio/GLM-5.1-AWQ") == true)
    }

    @Test func inlineCommandForm() {
        let yaml = """
        services:
          model:
            command: python3 -m sglang.launch_server --model-path org/Model-AWQ --served-model-name org/Model-AWQ
        """
        let a = ModelArtifact.parse(fromComposeYAML: yaml)
        #expect(a?.modelPath == "org/Model-AWQ")
        #expect(a?.quant == "AWQ")
    }

    @Test func equalsFlagForm() {
        let yaml = "command: [--model-path=vendor/Foo-GPTQ, --served-model-name=vendor/Foo-GPTQ]"
        let a = ModelArtifact.parse(fromComposeYAML: yaml)
        #expect(a?.modelPath == "vendor/Foo-GPTQ")
        #expect(a?.quant == "GPTQ")
    }

    /// When the served alias matches the real quantization, there is no drift.
    @Test func noDriftWhenAligned() {
        let yaml = """
        command:
          - --model-path
          - vendor/Model-AWQ
          - --served-model-name
          - vendor/Model-AWQ
        """
        let a = ModelArtifact.parse(fromComposeYAML: yaml)
        #expect(a?.quantDrift == false)
        #expect(a?.driftNote == nil)
    }

    @Test func noModelPathReturnsNil() {
        #expect(ModelArtifact.parse(fromComposeYAML: "services:\n  x:\n    image: foo") == nil)
    }

    // A near.ai COMBINED node: one compose runs three models, each its own
    // vLLM server with its own --model-path/--served-model-name. `parse` alone
    // took the first (DeepSeek) and mis-branded Qwen/Gemma requests.
    private let combinedYAML = """
    services:
      dsv4:
        command:
          - --model-path
          - deepseek-ai/DeepSeek-V4-Flash
          - --served-model-name
          - deepseek-ai/DeepSeek-V4-Flash
      qwen36:
        command:
          - --model-path
          - Qwen/Qwen3.6-27B
          - --served-model-name
          - Qwen/Qwen3.6-27B-FP8
      gemma4:
        command: ["--model-path", "google/gemma-4-31B", "--served-model-name", "google/gemma-4-31B-it"]
    """

    @Test func parseAllFindsEveryServer() {
        let all = ModelArtifact.parseAll(fromComposeYAML: combinedYAML)
        #expect(all.count == 3)
        #expect(all.map { $0.servedName } == [
            "deepseek-ai/DeepSeek-V4-Flash", "Qwen/Qwen3.6-27B-FP8", "google/gemma-4-31B-it"])
    }

    @Test func selectsRequestedServerNotFirst() {
        // Qwen request must return the Qwen server, not the first (DeepSeek).
        let q = ModelArtifact.parse(fromComposeYAML: combinedYAML, servingModel: "Qwen/Qwen3.6-27B-FP8")
        #expect(q?.servedName == "Qwen/Qwen3.6-27B-FP8")
        #expect(q?.modelPath == "Qwen/Qwen3.6-27B")
        let g = ModelArtifact.parse(fromComposeYAML: combinedYAML, servingModel: "google/gemma-4-31B-it")
        #expect(g?.modelPath == "google/gemma-4-31B")
        let d = ModelArtifact.parse(fromComposeYAML: combinedYAML, servingModel: "deepseek-ai/DeepSeek-V4-Flash")
        #expect(d?.modelPath == "deepseek-ai/DeepSeek-V4-Flash")
    }

    @Test func selectionToleratesAliasByVendorAndFallsBack() {
        // Alias spelling still selects the right server (same vendor).
        let q = ModelArtifact.parse(fromComposeYAML: combinedYAML, servingModel: "qwen/qwen3.6-27b")
        #expect(q?.modelPath == "Qwen/Qwen3.6-27B")
        // A model not in the compose falls back to the first server (never worse
        // than the old parse — the reused-node guard drops it downstream).
        let none = ModelArtifact.parse(fromComposeYAML: combinedYAML, servingModel: "meta/llama-9")
        #expect(none?.modelPath == "deepseek-ai/DeepSeek-V4-Flash")
        // Single-model GLM-5.1: requantized path, served as the near.ai id.
        let glm = ModelArtifact.parse(
            fromComposeYAML: "command: [--model-path, QuantTrio/GLM-5.1-AWQ, --served-model-name, zai-org/GLM-5.1-FP8]",
            servingModel: "zai-org/GLM-5.1-FP8")
        #expect(glm?.servedName == "zai-org/GLM-5.1-FP8")
    }

    @Test func detectsPositionalVllmServeForm() {
        // Newer vLLM: `vllm serve <repo>` positional (gemma-4 uses this), no
        // --model-path. The block-scalar / multi-line shape from the real compose.
        let yaml = """
        command:
          - >
            exec vllm serve RedHatAI/gemma-4-31B-it-FP8-block
            --revision 9a9994e657
            --served-model-name google/gemma-4-31B-it
        """
        let g = ModelArtifact.parse(fromComposeYAML: yaml, servingModel: "google/gemma-4-31B-it")
        #expect(g?.modelPath == "RedHatAI/gemma-4-31B-it-FP8-block")
        #expect(g?.servedName == "google/gemma-4-31B-it")
        #expect(g?.revision == "9a9994e657")
    }

    @Test func combinedComposeMixingBothFormsFindsGemma() {
        // The live failure: DeepSeek/Qwen use --model-path, Gemma uses `vllm
        // serve` positional in the SAME combined compose. All must be found, and
        // a Gemma request must select Gemma (not fall back to the first).
        let combined = """
        services:
          ds:
            command: [--model-path, deepseek-ai/DeepSeek-V4-Flash, --served-model-name, deepseek-ai/DeepSeek-V4-Flash]
          gm:
            command:
              - >
                exec vllm serve google/gemma-4-31B
                --served-model-name google/gemma-4-31B-it
        """
        #expect(ModelArtifact.parseAll(fromComposeYAML: combined).count == 2)
        let g = ModelArtifact.parse(fromComposeYAML: combined, servingModel: "google/gemma-4-31B-it")
        #expect(g?.modelPath == "google/gemma-4-31B")
        #expect(g?.servedName == "google/gemma-4-31B-it")
    }

    /// Boundary matching: FP8 must not be found inside FP16, and the tag must
    /// sit on a non-alphanumeric boundary.
    @Test func quantTagBoundaries() {
        #expect(ModelArtifact.quantTag(in: "org/Model-FP16") == "FP16")
        #expect(ModelArtifact.quantTag(in: "org/Model-FP8") == "FP8")
        #expect(ModelArtifact.quantTag(in: "org/GLM-5.1-AWQ") == "AWQ")
        #expect(ModelArtifact.quantTag(in: "org/Model-W4A16") == "W4A16")
        #expect(ModelArtifact.quantTag(in: "org/PlainModel") == nil)
    }
}
