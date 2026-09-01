//
//  AuditLinkScopingTests.swift
//  teemoonTests
//
//  Regression: image audit links are keyed only by (image ref, digest), so a
//  digest that runs in more than one enclave would surface the SAME review in
//  every one. But the teemoonai/audits reviews cover an image AS DEPLOYED in the
//  model compose (in scope for plaintext); the identical digest also runs
//  gateway-side over ciphertext, a deployment the review does not cover. The app
//  must therefore scope image audit links to the in-scope (model) enclave.
//
//  Live example this guards: datadog/agent + otel/opentelemetry-collector-contrib
//  run at the same digest in both the model and gateway composes.
//

import Foundation
import Testing
@testable import teemoon

@Suite("AuditLinkScoping")
@MainActor
struct AuditLinkScopingTests {

    // A digest that is assessed in the index AND runs in both enclaves.
    static let ref = "docker.io/datadog/agent"
    static let digest = "5556fb80b952832719a76b016f905616c76ee0989a239c4680c6220148e865d6"

    private func indexWithDatadog() -> AuditIndex {
        AuditIndex(fixedIndex: .init(
            schema: 1,
            images: [Self.ref: [Self.digest]],
            sources: nil,
            projects: nil,
            tagAudits: nil,
            manifests: [:],
            measured: [],
            os: [], verdicts: nil))
    }

    @Test func modelEnclaveImageSurfacesAuditLink() {
        let url = indexWithDatadog().scopedImageAuditURL(
            inScope: true,
            image: "datadog/agent", digestFull: "sha256:\(Self.digest)")
        #expect(url?.absoluteString ==
            "https://github.com/teemoonai/audits/blob/main/images/docker.io/datadog/agent/sha256-\(Self.digest).md")
    }

    @Test func gatewaySameDigestGetsNoAuditLink() {
        // THE regression: the model-node review must not leak onto the
        // out-of-scope gateway row running the identical digest.
        let url = indexWithDatadog().scopedImageAuditURL(
            inScope: false,
            image: "datadog/agent", digestFull: "sha256:\(Self.digest)")
        #expect(url == nil)
    }

    @Test func inScopeButUnassessedDigestGetsNoLink() {
        // Scope gate open, but this digest isn't in the index → still no link
        // (the existing digest gating still applies on top of the scope gate).
        let url = indexWithDatadog().scopedImageAuditURL(
            inScope: true,
            image: "datadog/agent", digestFull: "sha256:\(String(repeating: "0", count: 64))")
        #expect(url == nil)
    }

    @Test func missingDigestGetsNoLink() {
        #expect(indexWithDatadog().scopedImageAuditURL(
            inScope: true, image: "datadog/agent", digestFull: nil) == nil)
    }
}
