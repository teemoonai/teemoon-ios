import Foundation
import Testing
@testable import teemoon

@Suite("EnclaveGrouping")
@MainActor
struct EnclaveGroupingTests {

    private static let digest = String(repeating: "ab", count: 32)
    private static let datadogDigest = "5556fb80b952832719a76b016f905616c76ee0989a239c4680c6220148e865d6"

    private func emptyAudit() -> AuditIndex {
        AuditIndex(fixedIndex: .init(
            schema: 1,
            images: [:],
            sources: nil,
            projects: nil,
            tagAudits: nil,
            manifests: [:],
            measured: [],
            os: [],
            verdicts: nil))
    }

    private func datadogAudit() -> AuditIndex {
        AuditIndex(fixedIndex: .init(
            schema: 1,
            images: ["docker.io/datadog/agent": [Self.datadogDigest]],
            sources: nil,
            projects: nil,
            tagAudits: nil,
            manifests: [:],
            measured: [],
            os: [],
            verdicts: nil))
    }

    private func record(
        gpuHash: String? = "gpu-hash",
        osHash: String? = nil
    ) -> AttestationRecord {
        var rec = AttestationRecord(
            composeHash: "gateway-hash",
            mrtd: "mrtd",
            osImageHash: "gateway-os",
            intelQuote: "",
            composeManifest: nil,
            gpuArch: nil,
            gpuNodeComposeHash: gpuHash,
            modelFileHash: nil,
            signingAddress: nil,
            gpuSigningAddress: nil,
            modelEd25519PubKey: nil,
            quoteVerification: nil,
            gpuQuoteVerification: nil,
            modelQuoteVerification: nil,
            fetchedAt: Date(),
            providerID: UUID()
        )
        rec.modelOSImageHash = osHash
        return rec
    }

    private func ref(
        _ image: String,
        digest: String = Self.digest,
        hosts: [String]
    ) -> ProvenanceService.ImageRef {
        .init(image: image, digest: digest, hosts: hosts)
    }

    private func grouping(
        attestation: AttestationRecord? = nil,
        provenance: ProvenanceService.ManifestProvenance? = nil,
        inner: String? = nil,
        audit: AuditIndex? = nil
    ) -> EnclaveGrouping {
        EnclaveGrouping(
            attestation: attestation ?? record(),
            imageProvenance: provenance,
            modelLayerManifest: inner,
            modelLayerVerification: nil,
            audit: audit ?? emptyAudit()
        )
    }

    @Test func noProvenanceAndNoMrConfigIsEmpty() {
        #expect(grouping(attestation: record(gpuHash: nil), provenance: nil).groups().isEmpty)
    }

    @Test func emptyHostFallsToTheModelGroupOnce() {
        let image = ref("nearaidev/engine", hosts: [])
        let groups = grouping(
            provenance: .allVerified(verified: [image], thirdParty: [])
        ).groups()
        let model = groups.first { $0.primary }
        let gateway = groups.first { !$0.primary }
        #expect(model?.images.contains { $0.name == "nearaidev/engine" } == true)
        #expect(gateway?.images.contains { $0.name == "nearaidev/engine" } != true)
    }

    @Test func gatewayHostDoesNotAppearOnTheModel() {
        let image = ref("nearaidev/gateway-api", hosts: ["gateway"])
        let groups = grouping(
            provenance: .allVerified(verified: [image], thirdParty: [])
        ).groups()
        #expect(groups.first { $0.primary }?.images.contains { $0.name == "nearaidev/gateway-api" } != true)
        #expect(groups.first { !$0.primary }?.images.contains { $0.name == "nearaidev/gateway-api" } == true)
    }

    @Test func guestOSIsModelOnlyAndFirst() {
        let image = ref("nearaidev/engine", hosts: ["model"])
        let groups = grouping(
            attestation: record(osHash: "oshashoshashoshashoshashoshashoshashoshashoshashoshashoshash12"),
            provenance: .allVerified(verified: [image], thirdParty: [])
        ).groups()
        let modelImages = groups.first { $0.primary }?.images ?? []
        #expect(modelImages.first?.kind == .guestOS)
        #expect(groups.first { !$0.primary }?.images.contains { $0.kind == .guestOS } != true)
    }

    @Test func unverifiedOutranksVerifiedInTheModelGroup() {
        let digest = Self.digest
        let bad = ProvenanceService.Failure(
            ref: ref("nearaidev/broken", digest: digest, hosts: ["model"]),
            reason: .unverified(.fetchFailed("404")))
        let good = ref("nearaidev/engine", digest: String(repeating: "cd", count: 32), hosts: ["model"])
        let groups = grouping(
            provenance: .incomplete(verified: [good], failures: [bad], thirdParty: [])
        ).groups()
        let names = groups.first { $0.primary }?.images.map(\.kind) ?? []
        #expect(names.first == .unverified)
        #expect(names.contains(.registry))
    }

    @Test func gatewaySameDigestDoesNotCarryTheModelAudit() {
        let image = ProvenanceService.ImageRef(
            image: "datadog/agent",
            digest: Self.datadogDigest,
            hosts: ["gateway", "model"])
        let groups = grouping(
            provenance: .allVerified(verified: [], thirdParty: [image]),
            audit: datadogAudit()
        ).groups()
        let modelRow = groups.first { $0.primary }?.images.first { $0.name == "datadog/agent" }
        let gatewayRow = groups.first { !$0.primary }?.images.first { $0.name == "datadog/agent" }
        #expect(modelRow?.auditURL != nil)
        #expect(gatewayRow?.auditURL == nil)
    }

    @Test func belongsEmptyHostIsPrimaryOnly() {
        let empty = ref("x", hosts: [])
        #expect(EnclaveGrouping.belongs(empty, host: "model", primary: true))
        #expect(!EnclaveGrouping.belongs(empty, host: "gateway", primary: false))
        let both = ref("x", hosts: ["model", "gateway"])
        #expect(EnclaveGrouping.belongs(both, host: "model", primary: true))
        #expect(EnclaveGrouping.belongs(both, host: "gateway", primary: false))
    }
}
