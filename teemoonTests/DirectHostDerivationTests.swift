//
//  DirectHostDerivationTests.swift
//  teemoonTests
//
//  Best-effort direct-completions-host slug derivation from a model id. The
//  candidates only need to CONTAIN the correct near.ai slug — the runtime
//  model_name check discards wrong guesses — so these assert the known slugs
//  are among the generated candidates.
//

import Foundation
import Testing
@testable import teemoon

@Suite("DirectHostDerivation")
struct DirectHostDerivationTests {

    @Test func derivesKnownNearAISlugs() {
        // Each pair: model id → the real near.ai direct-host slug (from
        // KnownModel.directBaseURL) that must appear among the candidates.
        let cases: [(model: String, slug: String)] = [
            ("zai-org/GLM-5.1-FP8", "glm-5-1"),      // '.'→'-', drop -FP8
            ("zai-org/GLM-5-FP8", "glm-5"),          // drop -FP8
            ("Qwen/Qwen3.5-122B-A10B", "qwen35-122b"), // '.'→'', drop -A10B
            ("deepseek-ai/DeepSeek-V3.1", "deepseek-v31"), // '.'→''
            ("openai/gpt-oss-120b", "gpt-oss-120b"), // identity
        ]
        for c in cases {
            let slugs = AttestationService.derivedDirectHostSlugs(forModel: c.model)
            #expect(slugs.contains(c.slug), "\(c.model) → \(slugs) should contain \(c.slug)")
        }
    }

    @Test func candidatesAreBoundedAndClean() {
        let slugs = AttestationService.derivedDirectHostSlugs(forModel: "zai-org/GLM-5.1-FP8")
        #expect(slugs.count <= 3)
        // Valid DNS label characters only.
        for slug in slugs {
            #expect(slug.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
            #expect(!slug.isEmpty)
        }
    }

    @Test func handlesBareModelIdWithoutVendor() {
        let slugs = AttestationService.derivedDirectHostSlugs(forModel: "gpt-oss-120b")
        #expect(slugs.contains("gpt-oss-120b"))
    }
}
