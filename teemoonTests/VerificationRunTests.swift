//
//  VerificationRunTests.swift
//  teemoonTests
//
//  The verification-run structure the redesigned sheet renders: sections in
//  near.ai's documented order, results rolled up from real inputs, and TLS /
//  gateway sections appearing only when applicable.
//

import Foundation
import TDXQuoteVerifier
import Testing
@testable import teemoon

@Suite("VerificationRun")
struct VerificationRunTests {

    private func summary(
        attestation: AttestationRecord? = .preview,
        state: AttestationState = .ok,
        verifiedResponseCount: Int = 0,
        imageProvenance: ProvenanceService.ManifestProvenance? = nil,
        dcap: RecordDCAPVerification? = nil,
        nras: NRASVerification? = nil,
        tls: TLSAttestation? = nil,
        modelLayerVerification: ModelLayerVerification? = nil,
        degradeIsHardFailure: Bool = false
    ) -> AttestationSummary {
        AttestationSummary(
            attestation: attestation, state: state, timedOut: false, provider: .nearAI,
            lastRequestUsedE2EE: nil, lastE2EEFailReason: nil,
            verifiedResponseCount: verifiedResponseCount, mismatchedResponseCount: 0,
            attestationFetchFailed: false, imageProvenance: imageProvenance,
            dcapVerification: dcap, nrasVerification: nras, tlsAttestation: tls,
            modelLayerVerification: modelLayerVerification,
            degradeIsHardFailure: degradeIsHardFailure)
    }

    /// Image steps carry a "/" in their label; the engine step does not.
    private func imageSteps(_ s: AttestationSummary) -> [RunStep] {
        section(s, "provenance")?.steps.filter { $0.url != nil && $0.label.contains("/") } ?? []
    }

    private func section(_ s: AttestationSummary, _ id: String) -> VerificationSection? {
        s.verificationRun.first { $0.id == id }
    }

    @Test func sectionsFollowNearAIDocOrder() {
        var dcap = RecordDCAPVerification()
        dcap.gateway = .verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
        let s = summary(verifiedResponseCount: 2,
                        imageProvenance: .allVerified(verified: [], thirdParty: []), dcap: dcap,
                        nras: .verified, tls: .verified)
        // model → gateway → tls → chat → provenance
        #expect(s.verificationRun.map(\.id) == ["model", "gateway", "tls", "chat", "provenance"])
        for sec in s.verificationRun { #expect(!sec.steps.isEmpty) }
    }

    @Test func eachSectionLinksItsDoc() {
        let s = summary(tls: .verified)
        #expect(section(s, "model")?.docURL.hasSuffix("/model") == true)
        #expect(section(s, "tls")?.docURL.hasSuffix("/tls") == true)
    }

    @Test func tlsNotPerformed_dropsTheSection() {
        let s = summary(tls: .notPerformed)
        #expect(section(s, "tls") == nil)
    }

    @Test func tlsFailure_showsFailedSectionAndFailsRun() {
        let s = summary(tls: .failed("live TLS certificate does not match the attested fingerprint"))
        let tls = section(s, "tls")
        #expect(tls?.result == .failed)
        #expect(tls?.steps.first?.detail.contains("does not match") == true)
        #expect(s.runResult == .failed)
    }

    @Test func provenanceIsMarkedTeemoonExtra() {
        let s = summary(imageProvenance: .allVerified(verified: [], thirdParty: []))
        #expect(section(s, "provenance")?.isExtra == true)
        #expect(section(s, "model")?.isExtra == false)
    }

    @Test func provenancePerImageStep_linksSourceReleaseAndSigstore() {
        let repo = "https://github.com/nearai/private-ml-sdk"
        let commit = "84367f0253fa94aa6816d64210e5812215ee2622"
        let digest = String(repeating: "a", count: 64)
        let verified = [ProvenanceService.ImageRef(
            image: "nearaidev/cloud-api", digest: digest, sourceRepo: repo,
            sourceRef: "refs/tags/v0.5.1", sourceCommit: commit)]
        let s = summary(imageProvenance: .allVerified(verified: verified, thirdParty: []))
        // evidence names the actual repo, not just the org
        #expect(s.provenanceEvidence?.contains("nearai/private-ml-sdk") == true)

        let step = section(s, "provenance")?.steps.first { $0.label == "nearaidev/cloud-api" }
        // detail carries the running digest and attested version
        #expect(step?.detail.contains("sha256:aaaaaaaaaaaa") == true)
        #expect(step?.detail.contains("v0.5.1") == true)
        // tapping the step navigates directly to the code that's running
        #expect(step?.url == "\(repo)/tree/\(commit)")
        // secondary links: release tag and public sigstore log
        let urls = step?.links.map(\.url) ?? []
        #expect(urls.contains("\(repo)/releases/tag/v0.5.1"))
        #expect(urls.contains("https://search.sigstore.dev/?hash=\(digest)"))
    }

    @Test func provenanceBranchBuild_hasNoReleaseLink() {
        let verified = [ProvenanceService.ImageRef(
            image: "nearaidev/cloud-api", digest: String(repeating: "a", count: 64),
            sourceRepo: "https://github.com/nearai/cloud-api",
            sourceRef: "refs/heads/main", sourceCommit: "84367f02")]
        let s = summary(imageProvenance: .allVerified(verified: verified, thirdParty: []))
        let step = section(s, "provenance")?.steps.first { $0.label == "nearaidev/cloud-api" }
        #expect(step?.detail.contains("main") == true)
        #expect(step?.url == "https://github.com/nearai/cloud-api/tree/84367f02")
        #expect(step?.links.contains { $0.url.contains("/releases/tag/") } == false)
    }

    @Test func provenanceStepsIdentifyTheirMachine() {
        let verified = [
            ProvenanceService.ImageRef(
                image: "nearaidev/compose-manager", digest: String(repeating: "e", count: 64),
                sourceRepo: "https://github.com/nearai/compose-manager", hosts: ["model"]),
            ProvenanceService.ImageRef(
                image: "nearaidev/cloud-api", digest: String(repeating: "a", count: 64),
                sourceRepo: "https://github.com/nearai/cloud-api", hosts: ["gateway"]),
            ProvenanceService.ImageRef(
                image: "nearaidev/dstack-vpc", digest: String(repeating: "c", count: 64),
                sourceRepo: "https://github.com/nearai/dstack-vpc", hosts: ["gateway", "model"]),
        ]
        let s = summary(imageProvenance: .allVerified(verified: verified, thirdParty: []))
        let steps = imageSteps(s)
        // each detail names its machine, grouped gateway → shared → model
        #expect(steps.map(\.label) == ["nearaidev/cloud-api", "nearaidev/dstack-vpc", "nearaidev/compose-manager"])
        #expect(steps[0].detail.hasPrefix("runs on gateway ·"))
        #expect(steps[1].detail.hasPrefix("runs on gateway + model ·"))
        #expect(steps[2].detail.hasPrefix("runs on model ·"))
    }

    @Test func provenanceTagWithoutCommit_navigatesToTagTree() {
        let verified = [ProvenanceService.ImageRef(
            image: "nearaidev/cloud-api", digest: String(repeating: "a", count: 64),
            sourceRepo: "https://github.com/nearai/cloud-api",
            sourceRef: "refs/tags/v0.5.1", sourceCommit: nil)]
        let s = summary(imageProvenance: .allVerified(verified: verified, thirdParty: []))
        let step = section(s, "provenance")?.steps.first { $0.label == "nearaidev/cloud-api" }
        #expect(step?.url == "https://github.com/nearai/cloud-api/tree/v0.5.1")
    }

    @Test func provenanceWithoutRepoFallsBackToOrg() {
        let s = summary(imageProvenance: .allVerified(
            verified: [ProvenanceService.ImageRef(image: "nearaidev/cloud-api", digest: String(repeating: "a", count: 64))],
            thirdParty: []))
        #expect(s.provenanceEvidence?.contains("github.com/nearai") == true)
        #expect(imageSteps(s).isEmpty)
    }

    @Test func engineStepPinsAttestedSource() {
        let s = summary(imageProvenance: .allVerified(verified: [], thirdParty: []),
                        modelLayerVerification: .verified)
        let engine = section(s, "provenance")?.steps.first { $0.label.contains("inference engine") }
        #expect(engine?.status == .pass)
        #expect(engine?.detail.contains("prod/GLM-5.1-SGL-AWQ-TP4.yaml") == true)
        #expect(engine?.detail.contains("v0.0.296") == true)
        #expect(engine?.url == "https://github.com/nearai/cvm-compose-files/blob/c545c95545dba47d8bea293aaae317089ea52f4d/prod/GLM-5.1-SGL-AWQ-TP4.yaml")
    }

    @Test func engineStep_fetchFailedFlags_hashMismatchFails_absentFieldsDropStep() {
        // Transient fetch failure → advisory (orange), never a tamper accusation.
        let flagged = summary(imageProvenance: .allVerified(verified: [], thirdParty: []),
                              modelLayerVerification: .fetchFailed)
        #expect(section(flagged, "provenance")?.steps.first { $0.label.contains("inference engine") }?.status == .flag)
        // Hash mismatch → HARD fail (red): the recipe does not match the action
        // log's pin. Must NOT collapse to the same advisory as a fetch failure.
        let mismatch = summary(imageProvenance: .allVerified(verified: [], thirdParty: []),
                               modelLayerVerification: .hashMismatch)
        #expect(section(mismatch, "provenance")?.steps.first { $0.label.contains("inference engine") }?.status == .fail)
        // record without compose-manager action fields → no engine step
        // (section may be absent entirely, hence != true)
        let none = summary(attestation: .previewDegraded,
                           imageProvenance: .allVerified(verified: [], thirdParty: []))
        #expect(section(none, "provenance")?.steps.contains { $0.label.contains("inference engine") } != true)
    }

    @Test func degrade_hardFailureRendersRed_softStaysOrange() {
        // HARD adversarial break (tamper/replay/MITM) → red "verification failed".
        let hard = summary(state: .degraded, degradeIsHardFailure: true)
        #expect(hard.headerSeverity == .failed)
        #expect(hard.headerTitle == "verification failed")
        #expect(hard.headerIcon == "xmark.shield.fill")
        #expect(hard.headerSubtitle.contains("treat this chat as unverified"))
        // SOFT/operational degrade (E2EE simply unavailable) → orange advisory,
        // NOT the same red as a security break.
        let soft = summary(state: .degraded, degradeIsHardFailure: false)
        #expect(soft.headerSeverity == .advisory)
        #expect(soft.headerTitle == "verified hardware")
        #expect(soft.headerIcon == "lock.trianglebadge.exclamationmark.fill")
    }

    @Test func outOfDateTcb_passesNotFlags() {
        var dcap = RecordDCAPVerification()
        dcap.gateway = .verified(tcbStatus: .outOfDate, mrConfigIdHex: "01", reportDataHex: "")
        // TLS + provenance resolved so no pending section keeps the run "running".
        let s = summary(imageProvenance: .allVerified(verified: [], thirdParty: []),
                        dcap: dcap, tls: .notPerformed)
        // Genuine hardware behind on Intel platform updates is a note, not a
        // warning — the quote still proves real sealed silicon and the E2EE
        // binding holds. Matches the green expert "genuine hardware" row; only
        // `revoked` breaks (separate hard-failure path via hasHardFailure).
        #expect(section(s, "gateway")?.result == .passed)
        #expect(s.runResult == .passed)
    }

    @Test func pendingTLS_keepsRunRunning() {
        var dcap = RecordDCAPVerification()
        dcap.gateway = .verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
        let s = summary(dcap: dcap, tls: nil)   // TLS still in flight
        #expect(section(s, "tls")?.result == .running)
        #expect(s.runResult == .running)
    }

    @Test func directOnlyPath_hasNoGatewaySection() {
        // A record with no gateway signing address (direct model only).
        var record = AttestationRecord.preview
        record = AttestationRecord(
            composeHash: record.composeHash, mrtd: "", osImageHash: "", intelQuote: "",
            modelIntelQuote: "aa", modelNonce: nil,
            composeManifest: nil, gpuArch: nil, gpuNodeComposeHash: nil, modelFileHash: nil,
            signingAddress: nil, gpuSigningAddress: nil, modelEd25519PubKey: record.modelEd25519PubKey,
            quoteVerification: nil, gpuQuoteVerification: nil,
            modelQuoteVerification: record.modelQuoteVerification,
            fetchedAt: Date(), providerID: record.providerID)
        let s = summary(attestation: record, tls: .verified)
        #expect(section(s, "gateway") == nil)
    }

    // MARK: - Design-review imports (July 2026)

    /// The hero verdict is never greener than its worst check — a FAILED check
    /// demotes the green hero to failed, with an honest subtitle. Genuine
    /// hardware behind on Intel platform updates (outOfDate TCB) is a note, not
    /// a warning, so the verdict stays green (see `outOfDateTcb_passesNotFlags`).
    @Test func heroVerdictTracksWorstCheck() {
        var dcap = RecordDCAPVerification()
        dcap.model = .verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
        dcap.gateway = .verified(tcbStatus: .outOfDate, mrConfigIdHex: "01", reportDataHex: "")
        // outOfDate TCB no longer demotes the hero: genuine hardware, E2EE holds.
        let outOfDate = summary(verifiedResponseCount: 2,
                              imageProvenance: .allVerified(verified: [], thirdParty: []),
                              dcap: dcap, nras: .verified, tls: .verified,
                              modelLayerVerification: .verified)
        #expect(outOfDate.runResult == .passed)
        #expect(outOfDate.headerSeverity == .ok)
        #expect(outOfDate.headerTitle == "end-to-end encrypted")
        #expect(outOfDate.headerIcon == "checkmark.shield.fill")

        let failed = summary(dcap: dcap,
                             tls: .failed("live TLS certificate does not match the attested fingerprint"))
        #expect(failed.headerSeverity == .failed)
        #expect(failed.headerTitle == "verification failed")
        #expect(failed.headerIcon == "xmark.shield.fill")
        #expect(failed.headerSubtitle.contains("treat it as unencrypted"))

        // and all-green stays green
        var ok = dcap
        ok.gateway = .verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
        let verified = summary(verifiedResponseCount: 2,
                               imageProvenance: .allVerified(verified: [], thirdParty: []),
                               dcap: ok, nras: .verified, tls: .verified,
                               modelLayerVerification: .verified)
        #expect(verified.headerTitle == "end-to-end encrypted")
        #expect(verified.headerSeverity == .ok)
        #expect(verified.headerIcon == "checkmark.shield.fill")
    }

    /// Chip taxonomy: one register (passed/advisory/failed/checking/pending)
    /// and a glyph on every state — verdicts never ride on color alone.
    @Test func chipTaxonomyOneRegisterWithGlyphs() {
        #expect(SectionResult.flagged.chipLabel == "advisory")
        #expect(SectionResult.running.chipLabel == "checking")
        #expect(SectionResult.notRun.chipLabel == "pending")
        #expect(SectionResult.passed.chipIcon == "checkmark.circle.fill")
        #expect(SectionResult.flagged.chipIcon == "exclamationmark.triangle.fill")
        #expect(SectionResult.failed.chipIcon == "xmark.octagon.fill")
    }

    /// Proof rows mark literal attested tokens with backticks (rendered as
    /// mono chips inside plain wrapping sentences), and the inline ✓ that
    /// competed with the step icons is gone.
    @Test func proofDetailsMarkLiteralTokens() {
        var dcap = RecordDCAPVerification()
        dcap.model = .verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
        let s = summary(dcap: dcap)
        let details = section(s, "model")!.steps.map(\.detail)
        #expect(details.contains { $0.contains("`UpToDate`") })
        #expect(details.contains { $0.contains("`mr_config`") || $0.contains("`report_data`") })
        #expect(!details.contains { $0.contains("\u{2713}") })
    }
}

#if os(iOS)
/// The recipe-vs-measured classification that drives the recipe-card split in
/// `EnclaveGroupView`: the in-enclave engine is always recipe, the guest OS
/// never is, and everything else is recipe exactly when its image name appears
/// in the hash-verified inner compose YAML.
@Suite("RecipeClassification")
struct RecipeClassificationTests {
    /// A production-shaped inner compose: the OHTTP proxy (declared by DIGEST) +
    /// the :local sglang engine, PLUS the pervasive telemetry LABELS near.ai
    /// attaches to the model/proxy services. The harness sidecars (datadog, otel)
    /// live in the OUTER measured compose and are ABSENT here — but their NAMES
    /// substring-appear in those labels, which is exactly the trap the digest
    /// check must ignore.
    static let proxyDigest = "aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff00112233"
    private var inner: String {
        """
        services:
          proxy:
            image: nearaidev/vllm-proxy-rs@sha256:\(Self.proxyDigest)
            labels:
              nearai.otel.scrape: "true"
              com.datadoghq.ad.logs: '[{"source":"vllm-proxy"}]'
          model-sg:
            image: glm51-sgl-awq-tp4-patched:local
            command: sglang serve --model-path QuantTrio/GLM-5.1-AWQ
        networks:
          default:
        """
    }

    @Test func localEngineIsAlwaysRecipe() {
        // The :local build has no registry digest, yet it IS the recipe —
        // true regardless of the YAML.
        #expect(isRecipeImage(digestFull: nil, isLocalEngine: true,
                              isGuestOS: false, innerComposeYAML: inner))
        #expect(isRecipeImage(digestFull: "sha256:whatever", isLocalEngine: true,
                              isGuestOS: false, innerComposeYAML: nil))
    }

    @Test func guestOSIsNeverRecipe() {
        // Even if its digest somehow appeared in the compose, the guest OS is the
        // measured substrate, not part of the launched recipe.
        #expect(!isRecipeImage(digestFull: "sha256:\(Self.proxyDigest)", isLocalEngine: false,
                               isGuestOS: true, innerComposeYAML: inner))
    }

    @Test func imageDeclaredByDigestInInnerComposeIsRecipe() {
        #expect(isRecipeImage(digestFull: "sha256:\(Self.proxyDigest)", isLocalEngine: false,
                              isGuestOS: false, innerComposeYAML: inner))
    }

    /// THE L1 regression (observed live on Qwen-3.6): a harness sidecar whose
    /// NAME substring-appears in the compose's telemetry labels (`nearai.otel.*`,
    /// `com.datadoghq.*`) but whose DIGEST is NOT declared must classify as
    /// measured, not recipe. The old `yaml.contains(name)` check failed this —
    /// pulling the otel collector into the recipe card while datadog stayed out.
    @Test func labelSubstringDoesNotPullSidecarIntoRecipe() {
        let otelDigest = "ffeeddccbbaa998877665544332211000011223344556677889900aabbccddee"
        #expect(!isRecipeImage(digestFull: "sha256:\(otelDigest)", isLocalEngine: false,
                               isGuestOS: false, innerComposeYAML: inner),
                "otel's digest is not declared in the inner compose — a telemetry LABEL substring must not make it recipe")
    }

    @Test func noInnerComposeMeansNotRecipe() {
        // Fail-safe: without the hash-verified document to establish membership,
        // an ordinary image is NOT claimed as recipe (only the local engine is).
        #expect(!isRecipeImage(digestFull: "sha256:\(Self.proxyDigest)", isLocalEngine: false,
                               isGuestOS: false, innerComposeYAML: nil))
    }

    @Test func emptyDigestIsNotRecipe() {
        #expect(!isRecipeImage(digestFull: nil, isLocalEngine: false,
                               isGuestOS: false, innerComposeYAML: inner))
        #expect(!isRecipeImage(digestFull: "", isLocalEngine: false,
                               isGuestOS: false, innerComposeYAML: inner))
    }

    /// The tag-membership rule: a DIGESTLESS entry is recipe iff its full tag
    /// ref is declared as a service `image:` in the inner compose. Without it
    /// the tag-pinned dcgm row would strand ABOVE the seam with the
    /// hardware-measured harness — worse than invisible.
    @Test func tagRefDeclaredInInnerComposeIsRecipe() {
        let yaml = """
        services:
          dcgm:
            image: nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-distroless
            labels:
              com.datadoghq.ad.logs: '[{"source":"dcgm"}]'
        """
        #expect(isRecipeImage(digestFull: nil,
                              tagRef: "nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-distroless",
                              isLocalEngine: false, isGuestOS: false, innerComposeYAML: yaml))
        // A ref NOT declared there stays out — even if a label VALUE mentions it.
        #expect(!isRecipeImage(digestFull: nil,
                               tagRef: "datadog/agent:7.55.0",
                               isLocalEngine: false, isGuestOS: false, innerComposeYAML: yaml))
    }
}

/// Tag-pinned (digestless) image extraction from the verified inner compose —
/// the piece that makes dcgm-exporter a row at all. Parsed per-service via the
/// anchor-aware block parser (never a doc-wide regex), with the flood guards.
@Suite("TagPinnedExtraction")
struct TagPinnedExtractionTests {

    /// The REAL production dcgm shape: tag-pinned, no @sha256 — extracted with
    /// registry host, path, and tag intact.
    @Test func realDcgmShapeIsExtracted() {
        let yaml = """
        services:
          dcgm-exporter:
            image: nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-distroless
            cap_add:
              - SYS_ADMIN
            runtime: nvidia
        """
        #expect(ProvenanceService.tagPinnedImageRefs(inManifest: yaml)
                == ["nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-distroless"])
    }

    /// Flood guards: digest-pinned refs belong to `imageRefs`, `:local` builds
    /// to the local-engine row — neither may emit a tag-pinned ref.
    @Test func digestPinnedAndLocalBuildsAreExcluded() {
        let yaml = """
        services:
          proxy:
            image: nearaidev/vllm-proxy-rs@sha256:\(String(repeating: "a", count: 64))
          engine:
            image: glm51-sgl-awq-tp4-patched:local
          nginx:
            image: nginx:1.25
        """
        #expect(ProvenanceService.tagPinnedImageRefs(inManifest: yaml) == ["nginx:1.25"])
    }

    /// Replicas of the same tag-pinned image collapse to ONE ref (one dcgm
    /// row, not one per model service).
    @Test func replicasDedupeByFullRef() {
        let yaml = """
        services:
          dcgm-r1:
            image: nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2
          dcgm-r2:
            image: nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2
        """
        #expect(ProvenanceService.tagPinnedImageRefs(inManifest: yaml)
                == ["nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2"])
    }

    /// `${VAR:-default}` unwraps to the default, like `shortImageName`.
    @Test func shellDefaultSyntaxUnwraps() {
        let yaml = """
        services:
          dcgm:
            image: ${DCGM_IMAGE:-nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2}
        """
        #expect(ProvenanceService.tagPinnedImageRefs(inManifest: yaml)
                == ["nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2"])
    }

    /// Parsed per-service, never a doc-wide regex: image-shaped strings inside
    /// label VALUES and comments must not become refs.
    @Test func labelValuesAndCommentsDoNotEmitRefs() {
        let yaml = """
        services:
          proxy:
            image: nearaidev/vllm-proxy-rs@sha256:\(String(repeating: "b", count: 64))
            # the old deploy used datadog/agent:7.55.0 here
            labels:
              com.datadoghq.ad.logs: '[{"source":"otel/opentelemetry-collector-contrib:0.98.0"}]'
        """
        #expect(ProvenanceService.tagPinnedImageRefs(inManifest: yaml).isEmpty)
    }
}

/// The recipe card's in-card sub-grouping: rows partition by DATA PATH into
/// "handles your message" vs "telemetry sidecars", fail-soft to the flat list
/// when the toucher analysis yielded no handler, and NEVER suppress an
/// untagged telemetry row.
@Suite("RecipeRowPartition")
struct RecipeRowPartitionTests {
    /// A stand-in for the recipe card's rows: `handler` mirrors
    /// `plaintextRole != nil || kind == .local`; `tagged` mirrors whether a
    /// capability tag was detected.
    private struct Row: Equatable {
        let name: String
        let handler: Bool
        var tagged: Bool = true
    }

    @Test func partitionsByDataPath() {
        let rows = [Row(name: "proxy", handler: true),
                    Row(name: "engine", handler: true),
                    Row(name: "dcgm", handler: false),
                    Row(name: "otel", handler: false)]
        let split = partitionRecipeRows(rows, handlesMessage: \.handler)
        #expect(split?.handlers.map(\.name) == ["proxy", "engine"])
        #expect(split?.telemetry.map(\.name) == ["dcgm", "otel"])
    }

    /// FAIL-SOFT: no identified handler (toucher-analysis parse failure) →
    /// nil, so the view falls back to the flat list. The engine must never be
    /// dumped into "telemetry sidecars" by a parse failure.
    @Test func noHandlersMeansNoSplit() {
        let rows = [Row(name: "proxy", handler: false),
                    Row(name: "otel", handler: false)]
        #expect(partitionRecipeRows(rows, handlesMessage: \.handler) == nil)
    }

    /// INVARIANT: a telemetry row with NO capability tag is a signal-detection
    /// gap — it must still be in the partition's telemetry list, never
    /// suppressed (suppression would read as "safe to ignore").
    @Test func untaggedTelemetryRowStillRenders() {
        let rows = [Row(name: "engine", handler: true),
                    Row(name: "mystery-sidecar", handler: false, tagged: false)]
        let split = partitionRecipeRows(rows, handlesMessage: \.handler)
        #expect(split?.telemetry.map(\.name) == ["mystery-sidecar"])
    }

    /// No telemetry rows → an empty telemetry list (the view omits the
    /// sub-header; there is no empty section).
    @Test func allHandlersYieldsEmptyTelemetry() {
        let rows = [Row(name: "proxy", handler: true),
                    Row(name: "engine", handler: true)]
        let split = partitionRecipeRows(rows, handlesMessage: \.handler)
        #expect(split?.handlers.count == 2)
        #expect(split?.telemetry.isEmpty == true)
    }

    @Test func emptyInputHasNoSplit() {
        #expect(partitionRecipeRows([Row]())  { $0.handler } == nil)
    }
}
#endif
