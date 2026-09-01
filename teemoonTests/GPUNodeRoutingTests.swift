//
//  GPUNodeRoutingTests.swift
//  teemoonTests
//
//  Regression tests for the misrouted-node defense: near.ai's load balancer
//  behind a direct completions host occasionally hands out a node serving a
//  DIFFERENT model (observed live 2026-07-19: glm-5-1.completions.near.ai
//  answering with GLM-5.2's compose stack). Trusting that report stamps the
//  wrong model's compose path/artifact into a record that passes the session
//  read gate (it's stamped with the *requested* model), so the attestation
//  sheet brands the wrong model — the "switched to 5.1 but sheet says 5.2"
//  bug. `gpuReportServesExpectedModel` is the acceptance rule.
//
//  2026-07-20: the rule now anchors on the EXPECTED model's host, not the host
//  we happened to query. The earlier version compared the served host to the
//  queried host, which was a hole: when host resolution falls back to a
//  DIFFERENT model's host (model absent from the /endpoints directory), a node
//  honestly serving that host's own model authenticates itself (served host ==
//  queried host) and its stack is branded as the selected model. See
//  `rejectsFallbackHostOwnModel`.
//

import Foundation
import Testing
@testable import teemoon

@Suite("GPUNodeRouting")
struct GPUNodeRoutingTests {

    // The live failure: asked glm-5-1 for GLM-5.1, got a node serving 5.2.
    @Test func rejectsMisroutedNode() {
        #expect(!AttestationService.gpuReportServesExpectedModel(
            served: "z-ai/glm-5.2",
            expected: "zai-org/GLM-5.1-FP8",
            expectedModelHost: "glm-5-1.completions.near.ai",
            servedModelHost: "glm-5-2.completions.near.ai"))
    }

    @Test func acceptsExactMatch() {
        #expect(AttestationService.gpuReportServesExpectedModel(
            served: "zai-org/GLM-5.1-FP8",
            expected: "zai-org/GLM-5.1-FP8",
            expectedModelHost: "glm-5-1.completions.near.ai",
            servedModelHost: "glm-5-1.completions.near.ai"))
    }

    @Test func acceptsCaseInsensitiveMatch() {
        #expect(AttestationService.gpuReportServesExpectedModel(
            served: "ZAI-ORG/glm-5.1-fp8",
            expected: "zai-org/GLM-5.1-FP8",
            expectedModelHost: "glm-5-1.completions.near.ai",
            servedModelHost: nil))
    }

    // glm-5-2 serves both "z-ai/glm-5.2" and "zai-org/GLM-5.2-FP8"; asking
    // for one alias and hearing the other from the SAME host is legitimate.
    @Test func acceptsDirectoryAliasOnSameHost() {
        #expect(AttestationService.gpuReportServesExpectedModel(
            served: "z-ai/glm-5.2",
            expected: "zai-org/GLM-5.2-FP8",
            expectedModelHost: "glm-5-2.completions.near.ai",
            servedModelHost: "glm-5-2.completions.near.ai"))
    }

    // An alias claim whose directory host differs from the EXPECTED model's
    // host is a misroute, not an alias.
    @Test func rejectsAliasClaimFromDifferentHost() {
        #expect(!AttestationService.gpuReportServesExpectedModel(
            served: "z-ai/glm-5.2",
            expected: "zai-org/GLM-5.1-FP8",
            expectedModelHost: "glm-5-1.completions.near.ai",
            servedModelHost: "glm-5-2.completions.near.ai"))
    }

    // THE hole this fix closes: host resolution for the requested model fell
    // back to a DIFFERENT model's host, and the node there honestly serves that
    // host's own model. The old rule (served host == queried host) accepted it;
    // anchored on the expected model's host, it's a mismatch → reject. Without
    // this the sheet brands an unrelated model — one not even in the user's
    // saved list — as the selected one.
    @Test func rejectsFallbackHostOwnModel() {
        #expect(!AttestationService.gpuReportServesExpectedModel(
            served: "zai-org/GLM-5.1-FP8",          // the fallback host's real model
            expected: "zai-org/GLM-5.2-FP8",        // what the user actually selected
            expectedModelHost: "glm-5-2.completions.near.ai",
            servedModelHost: "glm-5-1.completions.near.ai"))  // == the host we fell back to
    }

    // A served id the directory can't resolve gives no same-host evidence —
    // fail closed on the mismatch.
    @Test func rejectsUnresolvableServedModelOnMismatch() {
        #expect(!AttestationService.gpuReportServesExpectedModel(
            served: "someone/other-model",
            expected: "zai-org/GLM-5.1-FP8",
            expectedModelHost: "glm-5-1.completions.near.ai",
            servedModelHost: nil))
    }

    // Older nodes that don't report model_name keep working (no false
    // rejection when there is nothing to verify).
    @Test func acceptsWhenNodeOmitsModelName() {
        #expect(AttestationService.gpuReportServesExpectedModel(
            served: nil,
            expected: "zai-org/GLM-5.1-FP8",
            expectedModelHost: "glm-5-1.completions.near.ai",
            servedModelHost: nil))
    }

    // Callers with no model expectation (legacy paths) never reject.
    @Test func acceptsWhenNoExpectation() {
        #expect(AttestationService.gpuReportServesExpectedModel(
            served: "z-ai/glm-5.2",
            expected: "",
            expectedModelHost: "glm-5-2.completions.near.ai",
            servedModelHost: "glm-5-2.completions.near.ai"))
    }
}
