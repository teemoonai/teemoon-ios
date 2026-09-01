import Foundation
import Testing
import TDXQuoteVerifier
@testable import teemoon

@Suite("AttestationRecord")
struct AttestationRecordTests {

    // MARK: - Helpers

    private func makeRecord(
        signingAddress: String? = nil,
        gpuSigningAddress: String? = nil,
        modelEd25519PubKey: Data? = nil,
        quoteVerification: TDXVerificationResult? = nil,
        modelQuoteVerification: TDXVerificationResult? = nil,
        gpuArch: String? = nil,
        gatewayNonce: String? = nil,
        modelNonce: String? = nil
    ) -> AttestationRecord {
        AttestationRecord(
            composeHash: "abc",
            mrtd: "def",
            osImageHash: "ghi",
            intelQuote: "",
            gatewayNonce: gatewayNonce,
            modelNonce: modelNonce,
            composeManifest: nil,
            gpuArch: gpuArch,
            gpuNodeComposeHash: nil,
            modelFileHash: nil,
            signingAddress: signingAddress,
            gpuSigningAddress: gpuSigningAddress,
            modelEd25519PubKey: modelEd25519PubKey,
            quoteVerification: quoteVerification,
            gpuQuoteVerification: nil,
            modelQuoteVerification: modelQuoteVerification,
            fetchedAt: Date(),
            providerID: UUID()
        )
    }

    /// TDXVerificationResult with a chosen report_data (all else zeroed).
    private func verification(reportData: Data) -> TDXVerificationResult {
        let zero48 = Data(count: 48)
        let body = TDXQuote.TDReportBody(
            teeTcbSvn: Data(count: 16), mrSeam: zero48, mrSignerSeam: zero48,
            seamAttributes: Data(count: 8), tdAttributes: Data(count: 8), xfam: Data(count: 8),
            mrtd: zero48, mrConfigID: zero48, mrOwner: zero48, mrOwnerConfig: zero48,
            rtmr0: zero48, rtmr1: zero48, rtmr2: zero48, rtmr3: zero48, reportData: reportData
        )
        let quote = TDXQuote(
            header: TDXQuote.Header(version: 4, attestationKeyType: 2, teeType: 0x81,
                                    qeVendorID: Data(count: 16), userData: Data(count: 20)),
            body: body,
            signature: TDXQuote.SignatureData(
                ecdsaSignature: Data(count: 64), attestationPublicKey: Data(count: 64),
                certificateChainPEM: [], rawCertificationData: Data())
        )
        return TDXVerificationResult(quote: quote, measurements: TDXMeasurements(from: body),
                                     signatureValid: true, certChainValid: true, certChainError: nil)
    }

    /// 64-byte report_data with `nonceHex` in bytes [32..64].
    private func reportData(echoing nonceHex: String) -> Data {
        var data = Data(count: 64)
        if let nonce = try? Data(hexString: nonceHex) {
            data.replaceSubrange(32..<64, with: nonce.prefix(32))
        }
        return data
    }

    // MARK: - nonceEchoed

    @Test func nonceEchoed_trueWhenAllPairsMatch() {
        let nonce = String(repeating: "ab", count: 32)
        let record = makeRecord(
            quoteVerification: verification(reportData: reportData(echoing: nonce)),
            modelQuoteVerification: verification(reportData: reportData(echoing: nonce)),
            gatewayNonce: nonce, modelNonce: nonce)
        #expect(record.nonceEchoed == true)
    }

    @Test func nonceEchoed_falseWhenAnyPairMismatches() {
        let nonce = String(repeating: "ab", count: 32)
        let record = makeRecord(
            quoteVerification: verification(reportData: reportData(echoing: nonce)),
            modelQuoteVerification: verification(reportData: reportData(echoing: String(repeating: "cd", count: 32))),
            gatewayNonce: nonce, modelNonce: nonce)
        #expect(record.nonceEchoed == false)
    }

    @Test func nonceEchoed_nilWhenNothingCheckable() {
        // No nonces recorded at all.
        #expect(makeRecord(quoteVerification: verification(reportData: Data(count: 64))).nonceEchoed == nil)
        // Nonce recorded but no parsed quote.
        #expect(makeRecord(gatewayNonce: "aa").nonceEchoed == nil)
    }

    @Test func nonceEchoed_falseWhenReportDataTooShort() {
        let nonce = String(repeating: "ab", count: 32)
        let record = makeRecord(
            quoteVerification: verification(reportData: Data(count: 16)),
            gatewayNonce: nonce)
        #expect(record.nonceEchoed == false)
    }

    @Test func nonceEchoed_uncheckedQuoteDoesNotBlockOthers() {
        // Gateway pair matches; model quote exists but no nonce was recorded
        // for it (legacy fetch) — result stays true, not nil/false.
        let nonce = String(repeating: "ab", count: 32)
        let record = makeRecord(
            quoteVerification: verification(reportData: reportData(echoing: nonce)),
            modelQuoteVerification: verification(reportData: Data(count: 64)),
            gatewayNonce: nonce)
        #expect(record.nonceEchoed == true)
    }

    // MARK: - gpuModelName

    @Test func gpuModelName_hopper() {
        let record = makeRecord(gpuArch: "HOPPER")
        #expect(record.gpuModelName == "NVIDIA H100")
    }

    @Test func gpuModelName_ampere() {
        let record = makeRecord(gpuArch: "AMPERE")
        #expect(record.gpuModelName == "NVIDIA A100")
    }

    @Test func gpuModelName_ada() {
        let record = makeRecord(gpuArch: "ADA")
        #expect(record.gpuModelName == "NVIDIA L40S")
    }

    @Test func gpuModelName_blackwell() {
        let record = makeRecord(gpuArch: "BLACKWELL")
        #expect(record.gpuModelName == "NVIDIA B200")
    }

    @Test func gpuModelName_unknown() {
        let record = makeRecord(gpuArch: "VOLTA")
        #expect(record.gpuModelName == "NVIDIA Volta")
    }

    @Test func gpuModelName_nil() {
        let record = makeRecord(gpuArch: nil)
        #expect(record.gpuModelName == nil)
    }

    @Test func gpuModelName_caseInsensitive() {
        let record = makeRecord(gpuArch: "hopper")
        #expect(record.gpuModelName == "NVIDIA H100")
    }

    // MARK: - signingKeyBoundToHardware

    @Test func signingKeyBound_nilWhenNoQuoteVerification() {
        let record = makeRecord(signingAddress: "0xABC")
        #expect(record.signingKeyBoundToHardware == nil)
    }

    @Test func signingKeyBound_nilWhenNoSigningAddress() {
        let record = makeRecord()
        #expect(record.signingKeyBoundToHardware == nil)
    }

    @Test func signingKeyBound_nilWhenEmptySigningAddress() {
        let record = makeRecord(signingAddress: "")
        #expect(record.signingKeyBoundToHardware == nil)
    }

    // MARK: - e2eeKeyBoundToModelTEE

    @Test func e2eeKeyBound_nilWhenNoModelQuoteVerification() {
        let record = makeRecord(modelEd25519PubKey: Data(repeating: 0xAB, count: 32))
        #expect(record.e2eeKeyBoundToModelTEE == nil)
    }

    @Test func e2eeKeyBound_nilWhenNoKey() {
        let record = makeRecord()
        #expect(record.e2eeKeyBoundToModelTEE == nil)
    }

    @Test func e2eeKeyBound_nilWhenKeyWrongLength() {
        let record = makeRecord(modelEd25519PubKey: Data(repeating: 0xAB, count: 16))
        #expect(record.e2eeKeyBoundToModelTEE == nil)
    }

    // MARK: - Preview records

    @Test func previewRecord_isNotNil() {
        let record = AttestationRecord.preview
        #expect(!record.composeHash.isEmpty)
        #expect(!record.mrtd.isEmpty)
        #expect(record.modelEd25519PubKey != nil)
    }

    @Test func previewDegradedRecord_hasNoE2EEKey() {
        let record = AttestationRecord.previewDegraded
        #expect(record.modelEd25519PubKey == nil)
    }
}
