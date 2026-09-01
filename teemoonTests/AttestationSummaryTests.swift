import Foundation
import Testing
import TDXQuoteVerifier
@testable import teemoon

@Suite("AttestationSummary")
struct AttestationSummaryTests {

    // MARK: - Helpers

    /// Clones a record with selected overrides. `fetchedAt` defaults to now so
    /// `timestampText` deterministically hits the "just now" branch.
    /// Pass `.some(nil)` for `modelQuoteVerification` to clear it.
    private func clone(
        _ base: AttestationRecord,
        modelQuoteVerification: TDXVerificationResult?? = nil,
        fetchedAt: Date = Date()
    ) -> AttestationRecord {
        AttestationRecord(
            composeHash: base.composeHash,
            mrtd: base.mrtd,
            osImageHash: base.osImageHash,
            intelQuote: base.intelQuote,
            composeManifest: base.composeManifest,
            gpuArch: base.gpuArch,
            gpuNodeComposeHash: base.gpuNodeComposeHash,
            modelFileHash: base.modelFileHash,
            signingAddress: base.signingAddress,
            gpuSigningAddress: base.gpuSigningAddress,
            modelEd25519PubKey: base.modelEd25519PubKey,
            quoteVerification: base.quoteVerification,
            gpuQuoteVerification: base.gpuQuoteVerification,
            modelQuoteVerification: modelQuoteVerification ?? base.modelQuoteVerification,
            fetchedAt: fetchedAt,
            providerID: base.providerID
        )
    }

    /// Builds a summary with sensible defaults for the healthy live case.
    private func makeSummary(
        attestation: AttestationRecord?,
        state: AttestationState = .ok,
        timedOut: Bool = false,
        provider: Provider? = .nearAI,
        lastRequestUsedE2EE: Bool? = nil,
        lastE2EEFailReason: String? = nil,
        verifiedResponseCount: Int = 0,
        mismatchedResponseCount: Int = 0,
        attestationFetchFailed: Bool = false,
        imageProvenance: ProvenanceService.ManifestProvenance? = nil
    ) -> AttestationSummary {
        AttestationSummary(
            attestation: attestation,
            state: state,
            timedOut: timedOut,
            provider: provider,
            lastRequestUsedE2EE: lastRequestUsedE2EE,
            lastE2EEFailReason: lastE2EEFailReason,
            verifiedResponseCount: verifiedResponseCount,
            mismatchedResponseCount: mismatchedResponseCount,
            attestationFetchFailed: attestationFetchFailed,
            imageProvenance: imageProvenance
        )
    }

    // MARK: - All checks pass

    @Test func allChecksPass_previewRecord() {
        let summary = makeSummary(attestation: clone(.preview))

        #expect(summary.e2eePassed == true)
        #expect(summary.gwTdxSignatureValid == true)
        #expect(summary.gwCertChainValid == true)
        #expect(summary.keyBoundToHardware == true)
        #expect(summary.modelTdxValid == true)
        #expect(summary.e2eeKeyBound == true)
        // No responses yet — response-signature check hidden.
        #expect(summary.responseSigValid == nil)
        #expect(summary.codeIdentityValid == true)
        #expect(summary.checksTotal == 7)
        #expect(summary.checksPassed == 7)
        #expect(summary.allChecksPassed)
        #expect(summary.headerTitle == "end-to-end encrypted")
        #expect(summary.timestampText == "verified just now")
    }

    @Test func allChecksPass_includesResponseSignaturesOnceSeen() {
        let summary = makeSummary(attestation: clone(.preview), verifiedResponseCount: 7)

        #expect(summary.responseSigValid == true)
        #expect(summary.checksTotal == 8)
        #expect(summary.checksPassed == 8)
        #expect(summary.allChecksPassed)
    }

    @Test func signatureMismatch_failsResponseCheck() {
        let summary = makeSummary(
            attestation: clone(.preview),
            verifiedResponseCount: 2,
            mismatchedResponseCount: 1
        )

        #expect(summary.responseSigValid == false)
        #expect(summary.checksTotal == 8)
        #expect(summary.checksPassed == 7)
        #expect(!summary.allChecksPassed)
    }

    // MARK: - E2EE failed on last request

    @Test func e2eeFailed_lastRequestPlaintext_withReason() {
        let summary = makeSummary(
            attestation: clone(.preview),
            state: .degraded,
            lastRequestUsedE2EE: false,
            lastE2EEFailReason: "Server rejected key (HTTP 421)"
        )

        #expect(summary.e2eePassed == false)
        #expect(summary.e2eeFailDetail == "Server rejected key (HTTP 421)")
        // Hardware + code-identity checks still pass; only the E2EE check fails.
        #expect(summary.checksTotal == 7)
        #expect(summary.checksPassed == 6)
        #expect(!summary.allChecksPassed)
        #expect(summary.headerTitle == "verified hardware")
    }

    @Test func e2eeFailed_lastRequestPlaintext_withoutReason() {
        let summary = makeSummary(
            attestation: clone(.preview),
            state: .degraded,
            lastRequestUsedE2EE: false
        )

        #expect(summary.e2eePassed == false)
        #expect(summary.e2eeFailDetail == "Encryption failed on last request")
    }

    @Test func e2eeUnavailable_noEd25519Key() {
        let summary = makeSummary(attestation: clone(.previewDegraded), state: .degraded)

        #expect(summary.e2eePassed == false)
        #expect(summary.e2eeFailDetail == "Ed25519 encryption key unavailable")
        // No model attestation on the degraded record → model checks hidden.
        #expect(summary.modelTdxValid == nil)
        #expect(summary.e2eeKeyBound == nil)
        #expect(summary.checksTotal == 4)
        #expect(summary.checksPassed == 3)
    }

    // MARK: - Attestation fetch failed

    @Test func attestationFetchFailed_appendsStaleNote() {
        let summary = makeSummary(attestation: clone(.preview), attestationFetchFailed: true)

        #expect(summary.timestampText == "verified just now (refresh failed)")
        // Fetch failure alone doesn't flip the checks — they reflect the last record.
        #expect(summary.allChecksPassed)
    }

    @Test func attestationFetchFailed_noRecordAtAll() {
        let summary = makeSummary(
            attestation: nil,
            state: .degraded,
            attestationFetchFailed: true
        )

        #expect(summary.timestampText == "No attestation data")
        #expect(summary.e2eePassed == false)
        #expect(summary.e2eeFailDetail == "Ed25519 encryption key unavailable")
        // Only the E2EE row is derivable without a record.
        #expect(summary.checksTotal == 1)
        #expect(summary.checksPassed == 0)
    }

    // MARK: - Missing model attestation

    @Test func missingModelAttestation_e2eeKeyUnverified() {
        let record = clone(.preview, modelQuoteVerification: .some(nil))
        let summary = makeSummary(attestation: record)

        #expect(summary.e2eePassed == false)
        #expect(summary.e2eeFailDetail == "Model TEE attestation unavailable")
        #expect(summary.modelTdxValid == nil)
        #expect(summary.e2eeKeyBound == nil)
        // Gateway checks unaffected.
        #expect(summary.gwTdxSignatureValid == true)
        // Code identity still binds via the gateway quote.
        #expect(summary.codeIdentityValid == true)
        #expect(summary.checksTotal == 5)
        #expect(summary.checksPassed == 4)
        #expect(!summary.allChecksPassed)
    }

    // MARK: - Share report

    @Test func shareText_verifiedRecord_formatsReport() {
        let record = clone(.preview)
        let summary = makeSummary(attestation: record)
        let text = summary.shareText(
            e2eeMessageCount: 14,
            verifiedResponseCount: 7,
            mismatchedResponseCount: 0
        )
        let lines = text.components(separatedBy: "\n")

        #expect(lines[0] == "near.ai TEE Attestation (VERIFIED)")
        #expect(lines[1] == "Fetched: \(record.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
        #expect(lines[2] == "")
        #expect(lines[3] == "E2EE messages this session: 14")
        #expect(lines[4] == "Signed responses this session: 7")
        // No mismatches — the mismatch line is omitted entirely.
        #expect(!text.contains("Signature mismatches this session"))
        #expect(lines[5] == "")
        #expect(lines[6] == "Gateway TDX Signature: Valid")
        #expect(lines[7] == "Gateway Cert Chain: Valid")
        // Preview record has no GPU quote → GPU node lines omitted.
        #expect(!text.contains("GPU Node TDX Signature"))
        // Hex-formatted measurement lines with aligned padding.
        #expect(lines.contains("MRTD (Intel TDX):         \(record.mrtd)"))
        #expect(lines.contains("Compose hash (mr_config): \(record.composeHash)"))
        #expect(lines.contains("GPU TEE compose hash:     \(record.gpuNodeComposeHash!)"))
        #expect(lines.contains("Model YAML SHA256:        \(record.modelFileHash!)"))
        // 32 bytes of 0xAB → 64 lowercase hex chars.
        #expect(lines.contains("Model Ed25519 pubkey:     \(String(repeating: "ab", count: 32))"))
        #expect(lines.contains("Gateway signing address:  \(record.signingAddress!)"))
        #expect(lines.contains("GPU signing address:      \(record.gpuSigningAddress!)"))
        #expect(lines.last == "Verify: https://cloud-api.near.ai/v1/attestation/report?nonce=manual&signing_algo=ecdsa")
    }

    @Test func shareText_noCounts_omitsSessionBlock() {
        let summary = makeSummary(attestation: clone(.preview))
        let text = summary.shareText(
            e2eeMessageCount: 0,
            verifiedResponseCount: 0,
            mismatchedResponseCount: 0
        )
        let lines = text.components(separatedBy: "\n")

        #expect(!text.contains("this session"))
        // Session block omitted → gateway lines follow the header blank line directly.
        #expect(lines[3] == "Gateway TDX Signature: Valid")
    }

    @Test func shareText_noRecord_returnsPlaceholder() {
        let summary = makeSummary(attestation: nil, state: .degraded)
        let text = summary.shareText(
            e2eeMessageCount: 0,
            verifiedResponseCount: 0,
            mismatchedResponseCount: 0
        )
        #expect(text == "near.ai TEE Attestation\nNo data available.")
    }
}

@Suite("AttestationSummary — image provenance")
struct AttestationSummaryProvenanceTests {
    private func makeSummary(imageProvenance: ProvenanceService.ManifestProvenance?) -> AttestationSummary {
        AttestationSummary(
            attestation: .preview, state: .ok, timedOut: false, provider: .nearAI,
            lastRequestUsedE2EE: nil, lastE2EEFailReason: nil,
            verifiedResponseCount: 0, mismatchedResponseCount: 0,
            attestationFetchFailed: false, imageProvenance: imageProvenance
        )
    }
    private let ref = ProvenanceService.ImageRef(image: "nearaidev/cloud-api", digest: String(repeating: "a", count: 64))

    @Test func pending_showsLiveRow_notCounted() {
        let s = makeSummary(imageProvenance: nil)
        #expect(s.provenanceState == .live || s.provenanceState == .pending)
        // Pending provenance is not part of the pass/fail count.
        #expect(s.checksTotal == 7)   // preview's 7 (incl. code identity), provenance excluded
    }

    @Test func allVerified_addsGreenCheck() {
        let s = makeSummary(imageProvenance: .allVerified(verified: [ref], thirdParty: []))
        #expect(s.provenanceState == .done)
        #expect(s.checksTotal == 8)
        #expect(s.checksPassed == 8)
    }

    @Test func incomplete_addsFailingCheck() {
        let failure = ProvenanceService.Failure(ref: ref, reason: .unverified(.fetchFailed("HTTP 404")))
        let s = makeSummary(imageProvenance: .incomplete(verified: [], failures: [failure], thirdParty: []))
        #expect(s.provenanceState == .stuck)
        #expect(s.checksTotal == 8)
        #expect(s.checksPassed == 7)  // provenance fails
    }

    @Test func incompleteDetail_namesTheFailingImageAndReason() {
        let failing = ProvenanceService.Failure(ref: ref, reason: .unverified(.fetchFailed("HTTP 404")))
        let s = makeSummary(imageProvenance: .incomplete(
            verified: [ProvenanceService.ImageRef(image: "nearaidev/mesh", digest: String(repeating: "b", count: 64))],
            failures: [failing], thirdParty: []))
        // Names the specific image (last path component) and the plain reason,
        // not just a bare "1 of 2" count.
        #expect(s.provenanceDetail.contains("cloud-api"))
        #expect(s.provenanceDetail.contains("GitHub 404"))
        #expect(s.provenanceDetail.contains("1 of 2"))
    }

    @Test func namedFailures_boundsTheListAndCountsTheRest() {
        let failures = (0..<4).map { i in
            ProvenanceService.Failure(
                ref: ProvenanceService.ImageRef(image: "nearaidev/img\(i)", digest: String(repeating: "\(i)", count: 64)),
                reason: .unverified(.fetchFailed("HTTP 404")))
        }
        let text = AttestationSummary.namedFailures(failures)
        #expect(text.contains("img0"))
        #expect(text.contains("img1"))
        #expect(!text.contains("img2"))       // beyond the limit
        #expect(text.contains("+2 more"))
    }

    @Test func thirdPartySidecars_doNotFailProvenance_andAreDisclosed() {
        let sidecar = ProvenanceService.ImageRef(image: "datadog/agent", digest: String(repeating: "1", count: 64))
        let s = makeSummary(imageProvenance: .allVerified(verified: [ref], thirdParty: [sidecar]))
        #expect(s.provenanceState == .done)
        #expect(s.checksPassed == s.checksTotal)
        #expect(s.provenanceDetail.contains("third-party"))
    }
}
