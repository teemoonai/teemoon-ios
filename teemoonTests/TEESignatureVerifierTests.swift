import Foundation
import Testing
@testable import teemoon

// MARK: - TEEMessageSignature Decoding

@Suite("TEEMessageSignature decoding")
struct TEEMessageSignatureTests {

    @Test func decodesValidJSON() throws {
        let json = """
        {
            "text": "abc123:def456",
            "signature": "0xdeadbeef",
            "signing_address": "0x4a8b3f2e9d1c7a5e2b0f8d3c6e1a4b7f2e9d1c7a",
            "signing_algo": "ecdsa"
        }
        """.data(using: .utf8)!

        let sig = try JSONDecoder().decode(TEEMessageSignature.self, from: json)
        #expect(sig.text == "abc123:def456")
        #expect(sig.signature == "0xdeadbeef")
        #expect(sig.signingAddress == "0x4a8b3f2e9d1c7a5e2b0f8d3c6e1a4b7f2e9d1c7a")
        #expect(sig.signingAlgo == "ecdsa")
    }

    @Test func missingFieldThrows() {
        let json = """
        {
            "text": "abc:def",
            "signature": "0xdeadbeef"
        }
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TEEMessageSignature.self, from: json)
        }
    }
}

// MARK: - ResponseVerification

@Suite("ResponseVerification")
struct ResponseVerificationTests {

    @Test func verifiedCarriesAddress() {
        let result = ResponseVerification.verified(.init(signingAddress: "0xABC"))
        if case .verified(let sig) = result {
            #expect(sig.signingAddress == "0xABC")
        } else {
            Issue.record("Expected .verified")
        }
    }

    @Test func mismatchCarriesBothAddresses() {
        let result = ResponseVerification.unverified(.signatureMismatch(expected: "0xAAA", got: "0xBBB"))
        if case .unverified(.signatureMismatch(let expected, let got)) = result {
            #expect(expected == "0xAAA")
            #expect(got == "0xBBB")
        } else {
            Issue.record("Expected .unverified(.signatureMismatch)")
        }
    }

    @Test func unavailable() {
        let result = ResponseVerification.unverified(.signatureUnavailable)
        if case .unverified(.signatureUnavailable) = result {
            // pass
        } else {
            Issue.record("Expected .unverified(.signatureUnavailable)")
        }
    }

    @Test func failedCarriesError() {
        struct FakeError: Error {}
        let result = ResponseVerification.unverified(.fetchFailed(FakeError()))
        if case .unverified(.fetchFailed(let err)) = result {
            #expect(err is FakeError)
        } else {
            Issue.record("Expected .unverified(.fetchFailed)")
        }
    }
}

// MARK: - Verifier integration (live endpoint)

@Suite("TEESignatureVerifier.verify")
struct TEESignatureVerifierIntegrationTests {

    private func makeAttestation(
        signingAddress: String? = nil,
        gpuSigningAddress: String? = nil
    ) -> AttestationRecord {
        AttestationRecord(
            composeHash: "test",
            mrtd: "test",
            osImageHash: "test",
            intelQuote: "",
            composeManifest: nil,
            gpuArch: nil,
            gpuNodeComposeHash: nil,
            modelFileHash: nil,
            signingAddress: signingAddress,
            gpuSigningAddress: gpuSigningAddress,
            modelEd25519PubKey: nil,
            quoteVerification: nil,
            gpuQuoteVerification: nil,
            modelQuoteVerification: nil,
            fetchedAt: Date(),
            providerID: UUID()
        )
    }

    @Test func returnsUnavailableWhenNoTrustedAddresses() async {
        let att = makeAttestation()
        let provider = Provider(name: "Test", endpoint: "https://example.com/v1", model: "test-model", requiresAPIKey: false)
        let ctx = TEEContext(provider: provider, apiKey: "", attestation: att)!
        let result = await TEESignatureVerifier.verify(chatID: "test-123", ctx: ctx)
        if case .unverified(.signatureUnavailable) = result {
            // pass — no trusted addresses means immediate .unverified(.signatureUnavailable)
        } else {
            Issue.record("Expected .unverified(.signatureUnavailable) when no signing addresses, got \(result)")
        }
    }

    @Test func returnsUnavailableWhenEmptyAddresses() async {
        let att = makeAttestation(signingAddress: "", gpuSigningAddress: "")
        let provider = Provider(name: "Test", endpoint: "https://example.com/v1", model: "test-model", requiresAPIKey: false)
        let ctx = TEEContext(provider: provider, apiKey: "", attestation: att)!
        let result = await TEESignatureVerifier.verify(chatID: "test-123", ctx: ctx)
        if case .unverified(.signatureUnavailable) = result {
            // pass
        } else {
            Issue.record("Expected .unverified(.signatureUnavailable) for empty addresses, got \(result)")
        }
    }
}
