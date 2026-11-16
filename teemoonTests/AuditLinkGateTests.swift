//
//  AuditLinkGateTests.swift
//  teemoonTests
//
//  trust-audit-links-gated (the maintainer 2026-11-06): an audit link only over what verified; findings read whatever
//  their case; no reassuring subtitle without a verdict. trust-audit-tag-pages: only digest-pinned audits count.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Audit links are gated on what was checked")
@MainActor
struct AuditLinkGateTests {
    static let fileSHA = String(repeating: "f", count: 64)
    static let path = "prod/GLM.yaml"

    private func audit(measured: [String] = [], manifests: [String: [String]] = [:],
                       tagAudits: [String: [String]]? = nil) -> AuditIndex {
        AuditIndex(fixedIndex: .init(schema: 1, images: [:], sources: nil, projects: nil, tagAudits: tagAudits,
                                     manifests: manifests, measured: measured, os: [], verdicts: nil))
    }

    private func record() -> AttestationRecord {
        var rec = AttestationRecord(
            composeHash: "gateway-hash", mrtd: "mrtd", osImageHash: "gateway-os", intelQuote: "",
            composeManifest: nil, gpuArch: nil, gpuNodeComposeHash: "gpu-hash", modelFileHash: Self.fileSHA,
            signingAddress: nil, gpuSigningAddress: nil, modelEd25519PubKey: nil, quoteVerification: nil,
            gpuQuoteVerification: nil, modelQuoteVerification: nil, fetchedAt: Date(), providerID: UUID())
        rec.modelComposePath = Self.path
        return rec
    }

    @Test func aRecipeWhoseHashDidntVerifyCarriesNoAuditLink() throws {
        let index = audit(manifests: ["\(ProvenanceService.modelComposeRepo)/\(Self.path)": [Self.fileSHA]])
        for layer in [ModelLayerVerification.hashMismatch, .fetchFailed, nil] {
            let g = EnclaveGrouping(attestation: record(), imageProvenance: nil, modelLayerManifest: nil,
                                    modelLayerVerification: layer, audit: index)
            let recipe = try #require(g.groups().first { $0.primary }?.recipe, "precondition: a recipe card")
            #expect(recipe.auditURL == nil, "\(String(describing: layer)): an unverified recipe is linked and counted")
        }
    }

    @Test func aVerifiedRecipeKeepsItsAuditLink() throws {
        let index = audit(manifests: ["\(ProvenanceService.modelComposeRepo)/\(Self.path)": [Self.fileSHA]])
        let g = EnclaveGrouping(attestation: record(), imageProvenance: nil, modelLayerManifest: nil,
                                modelLayerVerification: .verified, audit: index)
        #expect(try #require(g.groups().first { $0.primary }?.recipe).auditURL != nil)
    }

    /// trust-audit-tag-pages: a tag names a build but pins no bytes, so a page keyed on it covers nothing here.
    @Test func aTagPinnedImageWearsNoAuditEvenWhenTheIndexListsItsTag() throws {
        let ref = "nvcr.io/nvidia/k8s/dcgm-exporter"
        let inner = """
        services:
          dcgm-exporter:
            image: \(ref):4.5.2-4.8.1-distroless
        """
        let g = EnclaveGrouping(attestation: record(), imageProvenance: nil, modelLayerManifest: inner,
                                modelLayerVerification: .verified,
                                audit: audit(tagAudits: [AuditIndex.normalizedRef(ref): ["4.5.2-4.8.1-distroless"]]))
        let tagged = try #require(g.groups().first { $0.primary }?.images.filter { $0.kind == .tagPinned })
        #expect(!tagged.isEmpty, "precondition: the tag-pinned row exists")
        #expect(tagged.allSatisfy { $0.auditURL == nil && !$0.links.contains { $0.title.hasPrefix("audit") } })
    }

    @Test func aMeasuredConfigOverAnUnverifiedQuoteCarriesNoAuditLink() throws {
        let g = EnclaveGrouping(attestation: record(), imageProvenance: nil, modelLayerManifest: nil,
                                modelLayerVerification: nil, audit: audit(measured: ["gpu-hash"]))
        let group = try #require(g.groups().first { $0.primary })
        #expect(record().modelQuoteVerification == nil, "precondition: the quote isn't verified")
        #expect(group.configAuditURL == nil)
    }

    @Test func deployedAndSeverityAreReadWhateverTheirCase() {
        func finding(_ severity: String, _ deployed: String) -> NodeFinding {
            NodeFinding(id: "f", severity: severity, deployed: deployed, qualifier: nil, title: "t", source: "s",
                        url: URL(string: "https://example.com/p.md#a")!)
        }
        let split = splitNodeFindings([finding("HIGH", "ON"), finding("INFO", "off")])
        #expect(split.live.count == 1, "a live finding written ON reads as latent")
        #expect(split.info.count == 1, "an INFO finding reads as latent")
        #expect(severityRank("HIGH") == severityRank("high"))
    }

    @Test func noVerdictMeansNoReassuringSubtitle() {
        #expect(FableAuditCopy.unrecordedLine(verdict: nil) == "verdict not recorded — open the review")
        #expect(FableAuditCopy.unrecordedLine(verdict: "PRIVATE at deployed flags") == nil)
    }
}
