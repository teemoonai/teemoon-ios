//
//  AuditIndexTests.swift
//  teemoonTests
//
//  The teemoonai/audits path spec is a permanence contract: shipped builds
//  construct URLs from attested fields, so the normalization rules here must
//  match the repo README exactly and never change. These tests pin them.
//

import Foundation
import Testing
@testable import teemoon

@Suite("AuditIndex")
@MainActor
struct AuditIndexTests {

    // MARK: the frozen normalization rules

    @Test func bareOfficialImageGainsLibrary() {
        #expect(AuditIndex.normalizedRef("nginx") == "docker.io/library/nginx")
    }

    @Test func bareNamespacedImageGainsDockerIO() {
        #expect(AuditIndex.normalizedRef("nearaidev/vllm-proxy-rs") == "docker.io/nearaidev/vllm-proxy-rs")
    }

    @Test func tagIsStripped() {
        #expect(AuditIndex.normalizedRef("lmsysorg/sglang:dev-cu12") == "docker.io/lmsysorg/sglang")
    }

    @Test func explicitRegistryKept() {
        #expect(AuditIndex.normalizedRef("ghcr.io/astral-sh/uv:python3.11-bookworm-slim")
                == "ghcr.io/astral-sh/uv")
    }

    @Test func registryPortIsNotATag() {
        #expect(AuditIndex.normalizedRef("registry.example:5000/team/img")
                == "registry.example:5000/team/img")
    }

    @Test func digestPrefixStripped() {
        #expect(AuditIndex.bareDigest("sha256:abc123") == "abc123")
        #expect(AuditIndex.bareDigest("abc123") == "abc123")
    }

    @Test func yamlExtensionStripped() {
        #expect(AuditIndex.stripYAMLExtension("nearai/cvm-compose-files/prod/X.yaml")
                == "nearai/cvm-compose-files/prod/X")
    }

    // MARK: gating — no index entry, no link (never overclaim)

    private static let digest = "b183677a5d32267539b9b21ec45327a4f3be0a013afeb608c68c4d76e9472e36"
    private static let fileSHA = "eb00b404e3218e2e8c8ab8da5845af10ce79929fd232fe8ac3d2f688582817be"

    private static let osHash = "da9a3d5cc196a1a76d953fb27069be428ddf60a1ce10b0534c3cf968d3053fde"

    private func seeded() -> AuditIndex {
        AuditIndex(fixedIndex: .init(
            schema: 1,
            images: ["docker.io/nearaidev/vllm-proxy-rs": [Self.digest]],
            sources: ["docker.io/lmsysorg/sglang":
                [Self.sglangDigest: .init(repo: "sgl-project/sglang", commit: "8805f4cf166649d0ab7cd728df514ed476690115")]],
            projects: [
                "docker.io/otel/opentelemetry-collector-contrib":
                    .init(name: "OpenTelemetry Collector Contrib",
                          repo: "open-telemetry/opentelemetry-collector-contrib",
                          status: "open source · shipped build not source-audited"),
                "nvcr.io/nvidia/k8s/dcgm-exporter":
                    .init(name: "NVIDIA DCGM Exporter",
                          repo: "NVIDIA/dcgm-exporter",
                          status: "pinned by tag · can drift · not source-audited")],
            tagAudits: ["nvcr.io/nvidia/k8s/dcgm-exporter": ["4.5.2-4.8.1-distroless"]],
            manifests: ["nearai/cvm-compose-files/prod/GLM-5.1-SGL-AWQ-TP4.yaml": [Self.fileSHA]],
            measured: ["2c650eae81601afade86d1aa5ad898473b992081998026bb42ee1524ce99ee38"],
            os: [Self.osHash], verdicts: nil))
    }

    private static let sglangDigest = "aac6b242680daeb74d2ab1d85f70575357552d7d165d2e5d30eb362797db54a1"

    @Test func imageSourceLink_pinsRunningVersion() {
        let s = seeded().imageSourceLink(image: "lmsysorg/sglang", digest: "sha256:\(Self.sglangDigest)")
        #expect(s?.title == "sgl-project/sglang @ 8805f4c")
        #expect(s?.url.absoluteString == "https://github.com/sgl-project/sglang/tree/8805f4cf166649d0ab7cd728df514ed476690115")
        // Unrecorded digest → no pin (never a guess).
        #expect(seeded().imageSourceLink(image: "lmsysorg/sglang", digest: String(repeating: "0", count: 64)) == nil)
    }

    // MARK: caveated project pointer (ref-keyed; works digest OR tag pinned)

    @Test func projectPointer_resolvesForThirdPartyDigestImage() {
        let p = seeded().projectPointer(image: "otel/opentelemetry-collector-contrib")
        #expect(p?.name == "OpenTelemetry Collector Contrib")
        #expect(p?.repo == "open-telemetry/opentelemetry-collector-contrib")
        #expect(p?.status == "open source · shipped build not source-audited")
        // Links to the project root — NOT a tree/<commit> verified-source URL.
        #expect(p?.url.absoluteString == "https://github.com/open-telemetry/opentelemetry-collector-contrib")
    }

    @Test func projectPointer_resolvesForTagPinnedImageDespiteTagOnRef() {
        // dcgm is pinned by tag; the pointer is ref-keyed, so it resolves even
        // though there is no digest anywhere for this image.
        let p = seeded().projectPointer(image: "nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-distroless")
        #expect(p?.repo == "NVIDIA/dcgm-exporter")
        #expect(p?.status == "pinned by tag · can drift · not source-audited")
    }

    @Test func projectPointer_unrecordedImageGivesNothing() {
        #expect(seeded().projectPointer(image: "lmsysorg/sglang") == nil)
        #expect(AuditIndex(fixedIndex: nil).projectPointer(image: "otel/opentelemetry-collector-contrib") == nil)
    }

    // MARK: tag-addressed audit page (additive sibling to the digest path spec)

    @Test func tagAuditURL_resolvesForAssessedTag() {
        let url = seeded().tagAuditURL(image: "nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-distroless",
                                       tag: "4.5.2-4.8.1-distroless")
        #expect(url?.absoluteString ==
            "https://github.com/teemoonai/audits/blob/main/images/nvcr.io/nvidia/k8s/dcgm-exporter/tag-4.5.2-4.8.1-distroless.md")
    }

    @Test func tagAuditURL_unassessedTagGivesNoLink() {
        // A tag the audit hasn't reviewed → no link (never overclaim a drifted tag).
        #expect(seeded().tagAuditURL(image: "nvcr.io/nvidia/k8s/dcgm-exporter", tag: "9.9.9") == nil)
        #expect(seeded().tagAuditURL(image: "docker.io/library/nginx", tag: "latest") == nil)
    }

    @Test func missingProjectAndTagFieldsDecodeToNoLink() throws {
        // An index.json predating these fields must still decode (→ nil) and
        // yield no links, never a decode failure.
        let json = #"{ "schema": 1, "images": {}, "manifests": {}, "measured": [] }"#
        let idx = try JSONDecoder().decode(AuditIndex.Index.self, from: Data(json.utf8))
        #expect(idx.projects == nil)
        #expect(idx.tagAudits == nil)
        let index = AuditIndex(fixedIndex: idx)
        #expect(index.projectPointer(image: "otel/opentelemetry-collector-contrib") == nil)
        #expect(index.tagAuditURL(image: "nvcr.io/nvidia/k8s/dcgm-exporter", tag: "4.5.2-4.8.1-distroless") == nil)
    }

    @Test func assessedImageLinks() {
        let url = seeded().imageAuditURL(image: "nearaidev/vllm-proxy-rs", digest: "sha256:\(Self.digest)")
        #expect(url?.absoluteString ==
            "https://github.com/teemoonai/audits/blob/main/images/docker.io/nearaidev/vllm-proxy-rs/sha256-\(Self.digest).md")
    }

    @Test func unassessedDigestGivesNoLink() {
        #expect(seeded().imageAuditURL(image: "nearaidev/vllm-proxy-rs",
                                       digest: String(repeating: "0", count: 64)) == nil)
    }

    @Test func unknownImageGivesNoLink() {
        #expect(seeded().imageAuditURL(image: "evil/injected", digest: Self.digest) == nil)
    }

    @Test func noIndexGivesNoLink() {
        let empty = AuditIndex(fixedIndex: nil)
        #expect(empty.imageAuditURL(image: "nearaidev/vllm-proxy-rs", digest: Self.digest) == nil)
    }

    @Test func assessedManifestLinks() {
        let url = seeded().manifestAuditURL(path: "prod/GLM-5.1-SGL-AWQ-TP4.yaml", fileSHA256: Self.fileSHA)
        #expect(url?.absoluteString ==
            "https://github.com/teemoonai/audits/blob/main/manifests/nearai/cvm-compose-files/prod/GLM-5.1-SGL-AWQ-TP4/sha256-\(Self.fileSHA).md")
    }

    @Test func measuredHashLinks() {
        let hash = "2c650eae81601afade86d1aa5ad898473b992081998026bb42ee1524ce99ee38"
        let url = seeded().measuredAuditURL(composeHash: hash)
        #expect(url?.absoluteString ==
            "https://github.com/teemoonai/audits/blob/main/manifests/measured/sha256-\(hash).md")
    }

    @Test func assessedOSImageLinks() {
        let url = seeded().osAuditURL(osImageHash: Self.osHash)
        #expect(url?.absoluteString ==
            "https://github.com/teemoonai/audits/blob/main/os/sha256-\(Self.osHash).md")
    }

    @Test func unassessedOSGivesNoLink() {
        #expect(seeded().osAuditURL(osImageHash: String(repeating: "0", count: 64)) == nil)
    }

    @Test func missingOSFieldDecodesToNoLink() throws {
        // An index.json WITHOUT the "os" key must still decode (os → nil) and
        // yield no OS link, never a decode failure.
        let json = #"{ "schema": 1, "images": {}, "manifests": {}, "measured": [] }"#
        let idx = try JSONDecoder().decode(AuditIndex.Index.self, from: Data(json.utf8))
        #expect(idx.os == nil)
        #expect(AuditIndex(fixedIndex: idx).osAuditURL(osImageHash: Self.osHash) == nil)
    }

    // MARK: index decoding matches the published schema

    @Test func decodesPublishedSchema() throws {
        let json = """
        { "schema": 1, "updated": "2026-07-19",
          "images": { "docker.io/library/nginx": ["\(Self.digest)"] },
          "manifests": { "nearai/cvm-compose-files/prod/X.yaml": ["\(Self.fileSHA)"] },
          "measured": ["\(Self.fileSHA)"] }
        """
        let idx = try JSONDecoder().decode(AuditIndex.Index.self, from: Data(json.utf8))
        #expect(idx.schema == 1)
        #expect(idx.images["docker.io/library/nginx"] == [Self.digest])
    }

    /// REGRESSION: the ladder rendered one fixed, reassuring subtitle for every
    /// audit link — "source reviewed for plaintext egress · this exact build" —
    /// whether the page behind it concluded "PRIVATE at deployed flags" or
    /// "COMPROMISABLE by credentialed operator" or "one unauthenticated runtime
    /// logging switch remains live". The existence of a review read as an
    /// all-clear. The verdict now travels with the link, in the reviewer's own
    /// words, and an unrecorded verdict must fail closed rather than inherit
    /// the reassuring copy.
    @Test func verdictTravelsWithTheAuditLinkAndFailsClosed() {
        let dig = String(repeating: "a", count: 64)
        let path = "images/docker.io/lmsysorg/sglang/sha256-\(dig).md"
        let idx = AuditIndex(fixedIndex: AuditIndex.Index(
            schema: 1,
            images: ["docker.io/lmsysorg/sglang": [dig]],
            sources: nil, projects: nil, tagAudits: nil,
            manifests: [:], measured: [], os: nil,
            verdicts: [path: "private at deployed flags — one unauthenticated runtime switch remains live"]))

        let url = idx.imageAuditURL(image: "lmsysorg/sglang", digest: dig)
        #expect(url != nil)
        #expect(idx.verdict(for: url!)?.contains("unauthenticated runtime switch") == true)

        // A URL the index has no verdict for → nil, so the caller shows neutral
        // copy instead of implying the review came back clean.
        let other = URL(string: "\(AuditIndex.webBase)/images/docker.io/x/y/sha256-\(String(repeating: "b", count: 64)).md")!
        #expect(idx.verdict(for: other) == nil)
        // A URL outside the audits repo is never matched.
        #expect(idx.verdict(for: URL(string: "https://example.com/whatever.md")!) == nil)
    }

    // MARK: the machine-readable layer (verdictClass + findings + updated)

    private static let leakDigest = String(repeating: "c", count: 64)
    private static var leakPath: String {
        "images/docker.io/lmsysorg/sglang/sha256-\(leakDigest).md"
    }
    private static var machineLayerJSON: String {
        """
        { "schema": 1, "updated": "2026-08-04",
          "images": { "docker.io/lmsysorg/sglang": ["\(leakDigest)"] },
          "manifests": {}, "measured": [],
          "verdicts": { "\(leakPath)": "LEAKS — prompts logged at INFO" },
          "verdictClass": { "\(leakPath)": "leaks" },
          "findings": { "\(leakPath)": [
            { "severity": "high", "deployed": "on",
              "qualifier": "deployed: ON, unconditional",
              "title": "the full user prompt is logged at INFO on every generation",
              "anchor": "high-deployed-on-unconditional--the-full-user-prompt" },
            { "severity": "medium", "deployed": null, "qualifier": "mechanism",
              "title": "structural finding with no deployed state",
              "anchor": "medium-mechanism--structural" } ] } }
        """
    }

    @Test func decodesMachineReadableLayerAndResolvesAccessors() throws {
        let parsed = try #require(AuditIndex.decodeIndex(Data(Self.machineLayerJSON.utf8)))
        #expect(parsed.updated == "2026-08-04")
        let index = AuditIndex(fixedIndex: parsed)
        let url = try #require(index.imageAuditURL(image: "lmsysorg/sglang", digest: Self.leakDigest))
        #expect(index.verdictClass(for: url) == .leaks)
        let findings = index.findings(for: url)
        #expect(findings.count == 2)
        #expect(findings[0].severity == "high")
        #expect(findings[0].deployed == "on")
        #expect(findings[0].anchor.hasPrefix("high-deployed-on"))
        // JSON null deployed (mechanism finding) → nil, not a decode failure.
        #expect(findings[1].deployed == nil)
        // A foreign URL never matches either map.
        let foreign = URL(string: "https://example.com/whatever.md")!
        #expect(index.verdictClass(for: foreign) == nil)
        #expect(index.findings(for: foreign).isEmpty)
    }

    @Test func unknownFutureVerdictClassFailsToNeutral() throws {
        // The repo may add a class this build predates. The badge must fail to
        // nil (neutral) — never a guessed class, never a decode failure.
        let json = Self.machineLayerJSON.replacingOccurrences(of: "\"leaks\"", with: "\"on-fire\"")
        let parsed = try #require(AuditIndex.decodeIndex(Data(json.utf8)))
        let index = AuditIndex(fixedIndex: parsed)
        let url = try #require(index.imageAuditURL(image: "lmsysorg/sglang", digest: Self.leakDigest))
        #expect(index.verdictClass(for: url) == nil)
        // The verbatim verdict still travels — only the badge is withheld.
        #expect(index.verdict(for: url)?.hasPrefix("LEAKS") == true)
    }

    @Test func schemaMismatchFailsClosedToNoIndex() {
        // schema is a compatibility promise: a different NUMBER means a layout
        // this reader predates. Fail closed to "no index" (no links at all)
        // rather than construct links from a layout we can't read.
        let v2 = #"{ "schema": 2, "images": {}, "manifests": {}, "measured": [] }"#
        #expect(AuditIndex.decodeIndex(Data(v2.utf8)) == nil)
        let v1 = #"{ "schema": 1, "images": {}, "manifests": {}, "measured": [] }"#
        #expect(AuditIndex.decodeIndex(Data(v1.utf8)) != nil)
    }

    @Test func indexWithoutMachineLayerStaysNeutral() throws {
        // A published index predating verdictClass/findings must decode and
        // leave both accessors neutral — additive keys, no cliff.
        let json = #"{ "schema": 1, "images": {}, "manifests": {}, "measured": [] }"#
        let parsed = try #require(AuditIndex.decodeIndex(Data(json.utf8)))
        #expect(parsed.verdictClass == nil)
        #expect(parsed.findings == nil)
        #expect(parsed.updated == nil)
        let index = AuditIndex(fixedIndex: parsed)
        let url = URL(string: "\(AuditIndex.webBase)/os/sha256-\(String(repeating: "d", count: 64)).md")!
        #expect(index.verdictClass(for: url) == nil)
        #expect(index.findings(for: url).isEmpty)
    }

}

// MARK: - the per-node egress rollup + everyday audit rollup (pure helpers)

@Suite("EgressRollup")
struct EgressRollupTests {

    private func finding(_ severity: String, deployed: String?, _ n: Int) -> NodeFinding {
        NodeFinding(id: "f\(n)", severity: severity, deployed: deployed,
                    qualifier: nil, title: "t\(n)", source: "s",
                    url: URL(string: "https://example.com/p.md#a\(n)")!)
    }

    @Test func liveSplitsFromLatentAndSortsBySeverity() {
        let split = splitNodeFindings([
            finding("medium", deployed: "on", 1),
            finding("high", deployed: "off", 2),
            finding("high", deployed: "on", 3),
            finding("info", deployed: nil, 4),
            finding("medium", deployed: "armed", 5),
        ])
        // live = deployed ON only, severity order; armed/off/nil are latent.
        #expect(split.live.map(\.id) == ["f3", "f1"])
        #expect(split.latent.map(\.id) == ["f2", "f5"])
        #expect(split.info.map(\.id) == ["f4"])
    }

    @Test func unknownSeveritySinksToTheBottomButSurvives() {
        // A severity this build doesn't know must stay visible (never dropped
        // — suppression reads as safe), ranked after everything known.
        let split = splitNodeFindings([
            finding("catastrophic", deployed: "off", 1),
            finding("low", deployed: "off", 2),
        ])
        #expect(split.latent.map(\.id) == ["f2", "f1"])
    }

    @Test func everydayRollupWorstClassWins() {
        // Any leaks → alert, regardless of coverage.
        #expect(everydayAuditState(classes: [.privateReview, .leaks],
                                   allTouchersCovered: true) == .leaks)
        #expect(everydayAuditState(classes: [.leaks],
                                   allTouchersCovered: false) == .leaks)
        // Full coverage, no leaks/inconclusive → reviewed. compromisable
        // control-plane pages don't demote it (their verdicts state no
        // data-plane reach); qualified-pass doesn't either.
        #expect(everydayAuditState(classes: [.privateReview, .qualifiedPass, .compromisable],
                                   allTouchersCovered: true) == .reviewed)
        // A coverage gap can never read as an all-clear…
        #expect(everydayAuditState(classes: [.privateReview],
                                   allTouchersCovered: false) == .incomplete)
        // …nor can an empty class set (offline, no index)…
        #expect(everydayAuditState(classes: [], allTouchersCovered: true) == .incomplete)
        // …nor a review that made no claim.
        #expect(everydayAuditState(classes: [.privateReview, .inconclusive],
                                   allTouchersCovered: true) == .incomplete)
    }

}
