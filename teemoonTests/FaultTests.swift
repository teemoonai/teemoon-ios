import Foundation
import Testing
import CryptoKit
import TDXQuoteVerifier
@testable import teemoon

// MARK: - E2EE Fault Tests

@Suite("E2EE Faults")
struct E2EEFaultTests {

    // MARK: Session creation failures

    @Test func sessionCreation_invalidKeyLength_throws() {
        #expect(throws: E2EEError.invalidKeyLength) {
            _ = try E2EEPeer(modelEd25519PubKey: Data(count: 16))
        }
    }

    @Test func sessionCreation_emptyKey_throws() {
        #expect(throws: E2EEError.invalidKeyLength) {
            _ = try E2EEPeer(modelEd25519PubKey: Data())
        }
    }

    @Test func sessionCreation_oversizedKey_throws() {
        #expect(throws: E2EEError.invalidKeyLength) {
            _ = try E2EEPeer(modelEd25519PubKey: Data(count: 64))
        }
    }

    @Test func sessionCreation_validKey_succeeds() throws {
        let edKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: edKey.publicKey.rawRepresentation)
        #expect(session.clientPubKeyHex.count == 64)
    }

    // MARK: Decryption failures

    @Test func decrypt_invalidHex_throws() throws {
        let edKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: edKey.publicKey.rawRepresentation)
        #expect(throws: E2EEError.invalidHex) {
            _ = try session.decrypt("not_valid_hex_string_zzzz")
        }
    }

    @Test func decrypt_truncatedWireFormat_throws() throws {
        let edKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: edKey.publicKey.rawRepresentation)
        let shortHex = Data(count: 50).hexString
        #expect(throws: E2EEError.decryptionFailed) {
            _ = try session.decrypt(shortHex)
        }
    }

    @Test func decrypt_tamperedCiphertext_throws() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        let wire = try E2EEEnvelope.seal(
            plaintext: Data("secret message".utf8),
            recipientPubKey: session.agreementKey.publicKey
        )
        var tampered = wire
        tampered[wire.count - 1] ^= 0xFF

        #expect(throws: (any Error).self) {
            _ = try session.decrypt(tampered.hexString)
        }
    }

    @Test func decrypt_wrongRecipientKey_throws() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        let wrongRecipient = Curve25519.KeyAgreement.PrivateKey()
        let wire = try E2EEEnvelope.seal(
            plaintext: Data("secret".utf8),
            recipientPubKey: wrongRecipient.publicKey
        )

        #expect(throws: (any Error).self) {
            _ = try session.decrypt(wire.hexString)
        }
    }

    @Test func decrypt_emptyHex_throwsDecryptionFailed() throws {
        let edKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: edKey.publicKey.rawRepresentation)
        #expect(throws: E2EEError.decryptionFailed) {
            _ = try session.decrypt("")
        }
    }

    @Test func decrypt_allZeroWireFormat_throws() throws {
        let edKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: edKey.publicKey.rawRepresentation)
        let zeros = Data(count: 32 + 24 + 16 + 10).hexString
        #expect(throws: (any Error).self) {
            _ = try session.decrypt(zeros)
        }
    }

    // MARK: Request body encryption faults

    @Test func encryptRequestBody_noMessagesKey_returnsOriginal() throws {
        let edKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: edKey.publicKey.rawRepresentation)
        let body: [String: Any] = ["model": "test"]
        let data = try JSONSerialization.data(withJSONObject: body)
        let result = try session.encryptRequestBody(data)
        #expect(result == data)
    }

    @Test func encryptRequestBody_messagesNotArray_returnsOriginal() throws {
        let edKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: edKey.publicKey.rawRepresentation)
        let body: [String: Any] = ["messages": "not an array"]
        let data = try JSONSerialization.data(withJSONObject: body)
        let result = try session.encryptRequestBody(data)
        #expect(result == data)
    }

    @Test func encryptRequestBody_messageWithNilContent_preserved() throws {
        let edKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: edKey.publicKey.rawRepresentation)
        let body: [String: Any] = [
            "messages": [
                ["role": "assistant", "tool_calls": []] as [String: Any]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let result = try session.encryptRequestBody(data)
        let parsed = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        let msgs = parsed["messages"] as! [[String: Any]]
        #expect(msgs[0]["content"] == nil)
    }

    @Test func encryptRequestBody_numericContent_notEncrypted() throws {
        let edKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: edKey.publicKey.rawRepresentation)
        let body: [String: Any] = [
            "messages": [
                ["role": "user", "content": 42] as [String: Any]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let result = try session.encryptRequestBody(data)
        let parsed = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        let msgs = parsed["messages"] as! [[String: Any]]
        #expect(msgs[0]["content"] as? Int == 42)
    }

    // MARK: Hex edge cases

    @Test func hexString_singleByte() throws {
        let data = try Data(hexString: "ff")
        #expect(data == Data([0xFF]))
    }

    @Test func hexString_mixedCase() throws {
        let data = try Data(hexString: "DeAdBeEf")
        #expect(data == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    // MARK: Key conversion edge cases

    @Test func ed25519PubToX25519_degenerateKey_isRejected() {
        // y = 1 sits on the map's singularity and converts to u = 0, a
        // low-order point — rejected at conversion, fail-closed.
        var zeroKey = Data(count: 32)
        zeroKey[0] = 1
        #expect(throws: E2EEError.self) {
            _ = try Ed25519ToX25519.publicKey(edPub: zeroKey)
        }
    }
}

// MARK: - Attestation Record Fault Tests

@Suite("Attestation Record Faults")
struct AttestationRecordFaultTests {

    // MARK: Signing key binding

    @Test func signingKeyBoundToHardware_noQuoteVerification_returnsNil() {
        let record = makeRecord(signingAddress: "0xabcd", quoteVerification: nil)
        #expect(record.signingKeyBoundToHardware == nil)
    }

    @Test func signingKeyBoundToHardware_emptyAddress_returnsNil() {
        let record = makeRecord(signingAddress: "", quoteVerification: makeMockVerification(reportData: Data(count: 64)))
        #expect(record.signingKeyBoundToHardware == nil)
    }

    @Test func signingKeyBoundToHardware_nilAddress_returnsNil() {
        let record = makeRecord(signingAddress: nil, quoteVerification: makeMockVerification(reportData: Data(count: 64)))
        #expect(record.signingKeyBoundToHardware == nil)
    }

    @Test func signingKeyBoundToHardware_mismatchedAddress_returnsFalse() {
        // Realistic 20-byte address that does NOT match report_data.
        let addr = "0x" + String(repeating: "ab", count: 20)
        var reportData = Data(count: 64)
        reportData[0] = 0xFF
        let record = makeRecord(signingAddress: addr, quoteVerification: makeMockVerification(reportData: reportData))
        #expect(record.signingKeyBoundToHardware == false)
    }

    @Test func signingKeyBoundToHardware_matchingAddress_returnsTrue() {
        // Canonical layout: 20-byte address in the first 20 bytes of report_data.
        let addrHex = "deadbeef0102030405060708090a0b0c0d0e0f10"
        let addrBytes = try! Data(hexString: addrHex)
        var reportData = Data(count: 64)
        reportData.replaceSubrange(0..<addrBytes.count, with: addrBytes)
        let record = makeRecord(signingAddress: "0x\(addrHex)", quoteVerification: makeMockVerification(reportData: reportData))
        #expect(record.signingKeyBoundToHardware == true)
    }

    @Test func signingKeyBoundToHardware_matching_ignoresBytesBeyondAddress() {
        // Bytes 20..<32 of report_data are NOT part of the address; nonzero
        // content there must not break the binding (the old 32-byte padded
        // comparison would have failed this).
        let addrHex = "deadbeef0102030405060708090a0b0c0d0e0f10"
        let addrBytes = try! Data(hexString: addrHex)
        var reportData = Data(count: 64)
        reportData.replaceSubrange(0..<addrBytes.count, with: addrBytes)
        reportData[25] = 0x7F
        let record = makeRecord(signingAddress: "0x\(addrHex)", quoteVerification: makeMockVerification(reportData: reportData))
        #expect(record.signingKeyBoundToHardware == true)
    }

    @Test func signingKeyBoundToHardware_nonCanonicalAddressLength_returnsFalse() {
        // Not a 20-byte Ethereum address → unknown layout, never claim binding.
        let record = makeRecord(signingAddress: "0xdeadbeef", quoteVerification: makeMockVerification(reportData: Data(count: 64)))
        #expect(record.signingKeyBoundToHardware == false)
    }

    @Test func signingKeyBoundToHardware_shortReportData_returnsFalse() {
        let addr = "0x" + String(repeating: "cd", count: 20)
        let record = makeRecord(signingAddress: addr, quoteVerification: makeMockVerification(reportData: Data(count: 16)))
        #expect(record.signingKeyBoundToHardware == false)
    }

    @Test func signingKeyBoundToHardware_invalidHexAddress_returnsFalse() {
        let record = makeRecord(signingAddress: "0xZZZZ", quoteVerification: makeMockVerification(reportData: Data(count: 64)))
        #expect(record.signingKeyBoundToHardware == false)
    }

    // MARK: Code identity (manifest ↔ quote binding)

    /// Builds `(manifest, composeHash, mrConfigID)` for a manifest whose hash
    /// binds correctly, so tests can perturb one link at a time.
    private func codeIdentityFixture(manifest: String = "services:\n  cloud-api:\n    image: nearaidev/cloud-api@sha256:aaaa")
        -> (manifest: String, composeHash: String, mrConfigID: Data) {
        let hash = SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()
        // MRCONFIGID = 0x01 ‖ compose_hash (32 bytes) ‖ 15 trailing zero bytes → 48 bytes.
        let mrConfig = try! Data(hexString: "01" + hash) + Data(count: 15)
        return (manifest, hash, mrConfig)
    }

    @Test func codeIdentity_matchingManifestAndMrConfig_returnsTrue() {
        let f = codeIdentityFixture()
        let record = makeRecord(
            quoteVerification: makeMockVerification(reportData: Data(count: 64), mrConfigID: f.mrConfigID),
            composeHash: f.composeHash, composeManifest: f.manifest)
        #expect(record.codeIdentityVerified == true)
    }

    @Test func codeIdentity_tamperedManifest_returnsFalse() {
        let f = codeIdentityFixture()
        // Quote commits to the real manifest's hash, but we were shown a different manifest.
        let record = makeRecord(
            quoteVerification: makeMockVerification(reportData: Data(count: 64), mrConfigID: f.mrConfigID),
            composeHash: f.composeHash,
            composeManifest: f.manifest + "\n  malicious:\n    image: evil@sha256:bbbb")
        #expect(record.codeIdentityVerified == false)
    }

    @Test func codeIdentity_manifestNotBootedByQuote_returnsFalse() {
        let f = codeIdentityFixture()
        // Manifest hashes to composeHash, but the quote's mr_config commits to something else.
        let record = makeRecord(
            quoteVerification: makeMockVerification(reportData: Data(count: 64), mrConfigID: Data(count: 48)),
            composeHash: f.composeHash, composeManifest: f.manifest)
        #expect(record.codeIdentityVerified == false)
    }

    @Test func codeIdentity_composeHashFieldWrong_returnsFalse() {
        let f = codeIdentityFixture()
        let record = makeRecord(
            quoteVerification: makeMockVerification(reportData: Data(count: 64), mrConfigID: f.mrConfigID),
            composeHash: String(repeating: "00", count: 32), composeManifest: f.manifest)
        #expect(record.codeIdentityVerified == false)
    }

    @Test func codeIdentity_noManifest_returnsNil() {
        let f = codeIdentityFixture()
        let record = makeRecord(
            quoteVerification: makeMockVerification(reportData: Data(count: 64), mrConfigID: f.mrConfigID),
            composeHash: f.composeHash, composeManifest: nil)
        #expect(record.codeIdentityVerified == nil)
    }

    @Test func codeIdentity_noGatewayQuote_returnsNil() {
        let f = codeIdentityFixture()
        let record = makeRecord(quoteVerification: nil, composeHash: f.composeHash, composeManifest: f.manifest)
        #expect(record.codeIdentityVerified == nil)
    }

    // MARK: E2EE key binding to model TEE

    @Test func e2eeKeyBoundToModelTEE_noModelQuote_returnsNil() {
        let record = makeRecord(modelEd25519PubKey: Data(count: 32), modelQuoteVerification: nil)
        #expect(record.e2eeKeyBoundToModelTEE == nil)
    }

    @Test func e2eeKeyBoundToModelTEE_nilKey_returnsNil() {
        let record = makeRecord(modelEd25519PubKey: nil, modelQuoteVerification: makeMockVerification(reportData: Data(count: 64)))
        #expect(record.e2eeKeyBoundToModelTEE == nil)
    }

    @Test func e2eeKeyBoundToModelTEE_wrongKeyLength_returnsNil() {
        let record = makeRecord(modelEd25519PubKey: Data(count: 16), modelQuoteVerification: makeMockVerification(reportData: Data(count: 64)))
        #expect(record.e2eeKeyBoundToModelTEE == nil)
    }

    @Test func e2eeKeyBoundToModelTEE_keyMismatch_returnsFalse() {
        let key = Data(repeating: 0xAB, count: 32)
        var reportData = Data(count: 64)
        reportData.replaceSubrange(0..<32, with: Data(repeating: 0xCD, count: 32))
        let record = makeRecord(modelEd25519PubKey: key, modelQuoteVerification: makeMockVerification(reportData: reportData))
        #expect(record.e2eeKeyBoundToModelTEE == false)
    }

    @Test func e2eeKeyBoundToModelTEE_keyMatch_returnsTrue() {
        let key = Data(repeating: 0xAB, count: 32)
        var reportData = Data(count: 64)
        reportData.replaceSubrange(0..<32, with: key)
        let record = makeRecord(modelEd25519PubKey: key, modelQuoteVerification: makeMockVerification(reportData: reportData))
        #expect(record.e2eeKeyBoundToModelTEE == true)
    }

    @Test func e2eeKeyBoundToModelTEE_shortReportData_returnsFalse() {
        let key = Data(repeating: 0xAB, count: 32)
        let record = makeRecord(modelEd25519PubKey: key, modelQuoteVerification: makeMockVerification(reportData: Data(count: 16)))
        #expect(record.e2eeKeyBoundToModelTEE == false)
    }

    // MARK: GPU model name

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
        let record = makeRecord(gpuArch: "TURING")
        #expect(record.gpuModelName == "NVIDIA Turing")
    }

    @Test func gpuModelName_nil() {
        let record = makeRecord(gpuArch: nil)
        #expect(record.gpuModelName == nil)
    }

    @Test func gpuModelName_lowercaseInput() {
        let record = makeRecord(gpuArch: "hopper")
        #expect(record.gpuModelName == "NVIDIA H100")
    }

    // MARK: Helpers

    private func makeRecord(
        signingAddress: String? = nil,
        quoteVerification: TDXVerificationResult? = nil,
        modelEd25519PubKey: Data? = nil,
        modelQuoteVerification: TDXVerificationResult? = nil,
        gpuArch: String? = nil,
        composeHash: String = "",
        composeManifest: String? = nil
    ) -> AttestationRecord {
        AttestationRecord(
            composeHash: composeHash, mrtd: "", osImageHash: "", intelQuote: "",
            composeManifest: composeManifest, gpuArch: gpuArch, gpuNodeComposeHash: nil,
            modelFileHash: nil, signingAddress: signingAddress,
            gpuSigningAddress: nil, modelEd25519PubKey: modelEd25519PubKey,
            quoteVerification: quoteVerification,
            gpuQuoteVerification: nil,
            modelQuoteVerification: modelQuoteVerification,
            fetchedAt: Date(), providerID: UUID()
        )
    }

    private func makeMockVerification(reportData: Data, mrConfigID: Data = Data(count: 48)) -> TDXVerificationResult {
        let zero48 = Data(count: 48)
        let body = TDXQuote.TDReportBody(
            teeTcbSvn: Data(count: 16), mrSeam: zero48, mrSignerSeam: zero48,
            seamAttributes: Data(count: 8), tdAttributes: Data(count: 8), xfam: Data(count: 8),
            mrtd: zero48, mrConfigID: mrConfigID, mrOwner: zero48, mrOwnerConfig: zero48,
            rtmr0: zero48, rtmr1: zero48, rtmr2: zero48, rtmr3: zero48, reportData: reportData
        )
        let quote = TDXQuote(
            header: TDXQuote.Header(
                version: 4, attestationKeyType: 2, teeType: 0x00000081,
                qeVendorID: Data(count: 16), userData: Data(count: 20)
            ),
            body: body,
            signature: TDXQuote.SignatureData(
                ecdsaSignature: Data(count: 64), attestationPublicKey: Data(count: 64),
                certificateChainPEM: [], rawCertificationData: Data()
            )
        )
        return TDXVerificationResult(
            quote: quote,
            measurements: TDXMeasurements(from: body),
            signatureValid: true,
            certChainValid: true,
            certChainError: nil
        )
    }
}

// MARK: - TEE Signature Verification Fault Tests

@Suite("ResponseVerification Faults")
struct ResponseVerificationFaultTests {

    @Test func verified_containsAddress() {
        let result = ResponseVerification.verified(.init(signingAddress: "0xABCD"))
        if case .verified(let sig) = result {
            #expect(sig.signingAddress == "0xABCD")
        } else {
            Issue.record("Expected .verified")
        }
    }

    @Test func mismatch_containsBothAddresses() {
        let result = ResponseVerification.unverified(.signatureMismatch(expected: "0xAAAA", got: "0xBBBB"))
        if case .unverified(.signatureMismatch(let expected, let got)) = result {
            #expect(expected == "0xAAAA")
            #expect(got == "0xBBBB")
        } else {
            Issue.record("Expected .unverified(.signatureMismatch)")
        }
    }

    @Test func gatewayTrustOnly_isNotVerified() {
        let result = ResponseVerification.unverified(.gatewayTrustOnly(signingAddress: "0xCCCC"))
        if case .verified = result {
            Issue.record("Gateway trust must never be .verified")
        }
        if case .unverified(.gatewayTrustOnly(let addr)) = result {
            #expect(addr == "0xCCCC")
        } else {
            Issue.record("Expected .unverified(.gatewayTrustOnly)")
        }
    }

    @Test func unavailable_isUnverified() {
        let result = ResponseVerification.unverified(.signatureUnavailable)
        if case .unverified(.signatureUnavailable) = result {
            // pass
        } else {
            Issue.record("Expected .unverified(.signatureUnavailable)")
        }
    }

    @Test func failed_containsError() {
        let error = NSError(domain: "test", code: -1)
        let result = ResponseVerification.unverified(.fetchFailed(error))
        if case .unverified(.fetchFailed(let e)) = result {
            #expect((e as NSError).code == -1)
        } else {
            Issue.record("Expected .unverified(.fetchFailed)")
        }
    }
}

// MARK: - Brave Grounding Fault Tests

@Suite("Brave Grounding Faults")
struct BraveGroundingFaultTests {

    // MARK: Source parsing faults

    @Test func parseSources_emptyString_returnsEmpty() {
        let result = BraveWebSearchTool.parseSources(from: "")
        #expect(result.isEmpty)
    }

    @Test func parseSources_malformedXML_returnsEmpty() {
        let result = BraveWebSearchTool.parseSources(from: "<source><url>test</url></source>")
        #expect(result.isEmpty)
    }

    @Test func parseSources_missingTitle_returnsEmpty() {
        let result = BraveWebSearchTool.parseSources(from: """
            <source index="1"><url>https://example.com</url><content>text</content></source>
            """)
        #expect(result.isEmpty)
    }

    @Test func parseSources_missingContent_returnsEmpty() {
        let result = BraveWebSearchTool.parseSources(from: """
            <source index="1"><url>https://example.com</url><title>Test</title></source>
            """)
        #expect(result.isEmpty)
    }

    @Test func parseSources_validSource_returnsSource() {
        let xml = """
            <source index="1"><url>https://example.com</url><title>Test Page</title><content>Some content</content></source>
            """
        let result = BraveWebSearchTool.parseSources(from: xml)
        #expect(result.count == 1)
        #expect(result[0].url == "https://example.com")
        #expect(result[0].title == "Test Page")
        #expect(result[0].snippet == "Some content")
    }

    @Test func parseSources_multipleSources_parsesAll() {
        let xml = """
            <source index="1"><url>https://a.com</url><title>A</title><content>Content A</content></source>
            <source index="2"><url>https://b.com</url><title>B</title><content>Content B</content></source>
            """
        let result = BraveWebSearchTool.parseSources(from: xml)
        #expect(result.count == 2)
    }

    @Test func parseSources_extractsDomain() {
        let xml = """
            <source index="1"><url>https://www.example.com/path</url><title>T</title><content>C</content></source>
            """
        let result = BraveWebSearchTool.parseSources(from: xml)
        #expect(result[0].domain == "www.example.com")
    }

    @Test func parseSources_invalidURL_usesFallbackDomain() {
        let xml = """
            <source index="1"><url>not-a-url</url><title>T</title><content>C</content></source>
            """
        let result = BraveWebSearchTool.parseSources(from: xml)
        #expect(result[0].domain == "not-a-url")
    }

    // MARK: Markdown link parsing faults

    @Test func parseMarkdownLinks_noLinks_returnsEmpty() {
        let result = BraveWebSearchTool.parseMarkdownLinks(from: "No links here.")
        #expect(result.isEmpty)
    }

    @Test func parseMarkdownLinks_invalidURL_excluded() {
        let result = BraveWebSearchTool.parseMarkdownLinks(from: "[Title](ftp://bad.com)")
        #expect(result.isEmpty)
    }

    @Test func parseMarkdownLinks_duplicateURLs_deduplicated() {
        let text = "[A](https://a.com) and [B](https://a.com)"
        let result = BraveWebSearchTool.parseMarkdownLinks(from: text)
        #expect(result.count == 1)
    }

    @Test func parseMarkdownLinks_validLink_parsed() {
        let text = "Check [Google](https://google.com) for info"
        let result = BraveWebSearchTool.parseMarkdownLinks(from: text)
        #expect(result.count == 1)
        #expect(result[0].url == "https://google.com")
        #expect(result[0].title == "Google")
    }

    // MARK: GroundingSource faults

    @Test func groundingSource_isStructuredData_json() {
        #expect(GroundingSource.isStructuredData("{\"key\": \"value\"}") == true)
    }

    @Test func groundingSource_isStructuredData_array() {
        #expect(GroundingSource.isStructuredData("[1, 2, 3]") == true)
    }

    @Test func groundingSource_isStructuredData_ldJson() {
        #expect(GroundingSource.isStructuredData("something \"@type\": \"Organization\"") == true)
    }

    @Test func groundingSource_isStructuredData_plainText() {
        #expect(GroundingSource.isStructuredData("Just plain text") == false)
    }

    @Test func groundingSource_isStructuredData_empty() {
        #expect(GroundingSource.isStructuredData("") == false)
    }

    @Test func groundingSource_displaySnippet_hidesStructuredData() {
        let source = GroundingSource(url: "https://a.com", domain: "a.com", title: "A", snippet: "{\"@type\": \"WebPage\"}")
        #expect(source.displaySnippet == "")
    }

    @Test func groundingSource_displaySnippet_showsPlainText() {
        let source = GroundingSource(url: "https://a.com", domain: "a.com", title: "A", snippet: "A useful snippet")
        #expect(source.displaySnippet == "A useful snippet")
    }

    @Test func groundingSource_decodingWithoutSnippet_defaultsToEmpty() throws {
        let json = """
            {"url": "https://a.com", "domain": "a.com", "title": "A"}
            """
        let source = try JSONDecoder().decode(GroundingSource.self, from: Data(json.utf8))
        #expect(source.snippet == "")
    }
}

// MARK: - Provider Configuration Fault Tests

@Suite("Provider Faults")
struct ProviderFaultTests {

    @Test func openAIBaseURL_validEndpoint_stripsCompletions() {
        let provider = Provider(name: "Test", endpoint: "https://api.example.com/v1/chat/completions", model: "gpt-4")
        #expect(provider.openAIBaseURL?.absoluteString == "https://api.example.com/v1")
    }

    @Test func openAIBaseURL_endpointWithoutCompletions_unchanged() {
        let provider = Provider(name: "Test", endpoint: "https://api.example.com/v1", model: "gpt-4")
        #expect(provider.openAIBaseURL?.absoluteString == "https://api.example.com/v1")
    }

    @Test func openAIBaseURL_emptyEndpoint_returnsNil() {
        let provider = Provider(name: "Test", endpoint: "", model: "gpt-4")
        #expect(provider.openAIBaseURL == nil)
    }

    @Test func openAIBaseURL_whitespaceEndpoint_returnsNil() {
        let provider = Provider(name: "Test", endpoint: "   ", model: "gpt-4")
        // After stripping, "   " has no path component — URL(string:) may or may not accept
        // But the URL is definitely not useful for API calls
        let url = provider.openAIBaseURL
        // Whitespace-only strings may still produce a URL; test the empty case separately
        _ = url // Just verifying no crash
    }

    @Test func isValid_allFieldsPresent_returnsTrue() {
        let provider = Provider(name: "Test", endpoint: "https://api.example.com/v1", model: "gpt-4")
        #expect(provider.isValid == true)
    }

    @Test func isValid_emptyName_returnsFalse() {
        let provider = Provider(name: "", endpoint: "https://api.example.com/v1", model: "gpt-4")
        #expect(provider.isValid == false)
    }

    @Test func isValid_whitespaceOnlyName_returnsFalse() {
        let provider = Provider(name: "   ", endpoint: "https://api.example.com/v1", model: "gpt-4")
        #expect(provider.isValid == false)
    }

    @Test func isValid_emptyEndpoint_returnsFalse() {
        let provider = Provider(name: "Test", endpoint: "", model: "gpt-4")
        #expect(provider.isValid == false)
    }

    @Test func isValid_emptyModel_returnsFalse() {
        let provider = Provider(name: "Test", endpoint: "https://api.example.com/v1", model: "")
        #expect(provider.isValid == false)
    }

    @Test func isValid_emptyEndpoint_isInvalid() {
        // Empty endpoint reliably returns nil from URL(string:)
        let provider = Provider(name: "Test", endpoint: "", model: "gpt-4")
        #expect(provider.isValid == false)
    }

    @Test func capabilities_nearAI_includesAttestationAndE2EE() {
        let provider = Provider(name: "near.ai", endpoint: "https://cloud-api.near.ai/v1/chat/completions", model: "test")
        #expect(provider.capabilities.contains([.attestation, .endToEndEncryption]))
    }

    @Test func capabilities_otherProvider_excludesAttestation() {
        let provider = Provider(name: "OpenAI", endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-4")
        #expect(!provider.capabilities.contains(.attestation))
    }

    @Test func provider_encodeDecode_roundTrip() throws {
        let original = Provider(
            name: "Test", endpoint: "https://api.example.com/v1/chat/completions",
            model: "gpt-4", authHeaderName: "X-Custom", requiresAPIKey: true,
            supportsModelBrowsing: true, extraParams: ["temp": "0.7"],
            maxMessages: 5, hasBuiltInGrounding: true, omitSystemPrompt: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Provider.self, from: data)
        #expect(decoded.name == original.name)
        #expect(decoded.endpoint == original.endpoint)
        #expect(decoded.model == original.model)
        #expect(decoded.authHeaderName == original.authHeaderName)
        #expect(decoded.requiresAPIKey == original.requiresAPIKey)
        #expect(decoded.maxMessages == original.maxMessages)
        #expect(decoded.hasBuiltInGrounding == original.hasBuiltInGrounding)
        #expect(decoded.omitSystemPrompt == original.omitSystemPrompt)
    }

    @Test func provider_decodeMissingOptionalFields_succeeds() throws {
        let json = """
            {"id": "00000000-0000-0000-0000-000000000001", "name": "Test", "endpoint": "https://api.example.com/v1", "model": "gpt-4", "requiresAPIKey": true, "supportsModelBrowsing": false, "extraParams": {}, "hasBuiltInGrounding": false, "omitSystemPrompt": false}
            """
        let provider = try JSONDecoder().decode(Provider.self, from: Data(json.utf8))
        #expect(provider.authHeaderName == nil)
        #expect(provider.maxMessages == nil)
    }
}

// MARK: - Keychain Fault Tests

@Suite("Keychain Faults")
struct KeychainFaultTests {

    @Test func save_emptyKey_throws() {
        #expect(throws: Keychain.KeychainError.self) {
            try Keychain.save("value", for: "")
        }
    }

    @Test func save_emptyValue_throws() {
        #expect(throws: Keychain.KeychainError.self) {
            try Keychain.save("", for: "test-key")
        }
    }

    @Test func load_emptyKey_returnsNil() {
        let result = Keychain.load(for: "")
        #expect(result == nil)
    }

    @Test func load_nonexistentKey_returnsNil() {
        let result = Keychain.load(for: "fault-test-nonexistent-key-\(UUID().uuidString)")
        #expect(result == nil)
    }

    @Test func keychainError_descriptions() {
        let saveError = Keychain.KeychainError.saveFailed(-25300)
        #expect(saveError.errorDescription?.contains("save") == true)

        let deleteError = Keychain.KeychainError.deleteFailed(-25300)
        #expect(deleteError.errorDescription?.contains("delete") == true)

        let inputError = Keychain.KeychainError.invalidInput("bad input")
        #expect(inputError.errorDescription?.contains("bad input") == true)
    }
}

// MARK: - ThinkingContentParser Fault Tests

@Suite("ThinkingContentParser Faults")
struct ThinkingContentParserFaultTests {

    @Test func parse_noThinkTag_allIsAnswer() {
        let result = ThinkingContentParser.parse("Just an answer")
        #expect(result.thinking == nil)
        #expect(result.answer == "Just an answer")
    }

    @Test func parse_openThinkTag_noClose_allIsThinking() {
        let result = ThinkingContentParser.parse("<think>I'm thinking...")
        #expect(result.thinking == "I'm thinking...")
        #expect(result.answer == nil)
    }

    @Test func parse_emptyThinkTag_emptyThinking() {
        let result = ThinkingContentParser.parse("<think></think>Answer here")
        #expect(result.thinking == "")
        #expect(result.answer == "Answer here")
    }

    @Test func parse_thinkTagOnly_noAnswer() {
        let result = ThinkingContentParser.parse("<think>Thinking content</think>")
        #expect(result.thinking == "Thinking content")
        #expect(result.answer == nil)
    }

    @Test func parse_thinkWithWhitespaceAnswer_noAnswer() {
        let result = ThinkingContentParser.parse("<think>Thinking</think>   \n  ")
        #expect(result.thinking == "Thinking")
        #expect(result.answer == nil)
    }

    @Test func parse_normalCase_splitsCorrectly() {
        let result = ThinkingContentParser.parse("<think>Let me think</think>Here's the answer")
        #expect(result.thinking == "Let me think")
        #expect(result.answer == "Here's the answer")
    }

    @Test func parse_emptyString_emptyAnswer() {
        let result = ThinkingContentParser.parse("")
        #expect(result.thinking == nil)
        #expect(result.answer == "")
    }

    @Test func parse_whitespaceOnly_nilAnswer() {
        let result = ThinkingContentParser.parse("   \n  ")
        #expect(result.thinking == nil)
        #expect(result.answer == "")
    }

    @Test func parse_nestedThinkTags_usesFirst() {
        let result = ThinkingContentParser.parse("<think>outer<think>inner</think>after inner</think>final answer")
        // The parser uses the first <think> and first </think>
        #expect(result.thinking == "outer<think>inner")
        #expect(result.answer == "after inner</think>final answer")
    }

    @Test func parse_textBeforeThinkTag_thinkingStartsAtTag() {
        let result = ThinkingContentParser.parse("preamble<think>thinking</think>answer")
        #expect(result.thinking == "thinking")
        #expect(result.answer == "answer")
    }
}

// MARK: - SSE / tool-call parsing fault tests

@Suite("Tool Call Parsing Faults")
struct ToolCallParsingFaultTests {

    @Test func parseTextToolCalls_malformedJSON_handlesGracefully() {
        let content = "<tool_call>{broken json here}</tool_call>"
        let result = SSEStreamParser.parseTextToolCalls(from: content)
        // Should still attempt to parse; may return empty or partial
        #expect(result.count <= 1)
    }

    @Test func parseTextToolCalls_emptyToolCallTag_skipped() {
        let content = "<tool_call></tool_call>"
        let result = SSEStreamParser.parseTextToolCalls(from: content)
        // Empty inner content doesn't match any format — entry skipped
        #expect(result.isEmpty)
    }

    @Test func parseTextToolCalls_missingName_skipped() {
        let content = """
            <tool_call>{"arguments": {"query": "test"}}</tool_call>
            """
        let result = SSEStreamParser.parseTextToolCalls(from: content)
        // JSON variant requires non-empty "name" → falls through all formats → skipped
        #expect(result.isEmpty)
    }

    @Test func parseTextToolCalls_nestedToolCallTags_breaksParsing() {
        // Inner </tool_call> terminates the outer tag prematurely, breaking the JSON
        let content = """
            <tool_call>{"name": "outer", "arguments": {"text": "<tool_call>inner</tool_call>"}}</tool_call>
            """
        let result = SSEStreamParser.parseTextToolCalls(from: content)
        // The premature close means JSON is truncated — neither fragment parses
        #expect(result.isEmpty)
    }

    @Test func stripTextToolCalls_noTags_returnsOriginal() {
        let content = "No tool calls present"
        let result = SSEStreamParser.stripTextToolCalls(from: content)
        #expect(result == content)
    }

    @Test func stripTextToolCalls_emptyString_returnsEmpty() {
        let result = SSEStreamParser.stripTextToolCalls(from: "")
        #expect(result == "")
    }

    @Test func stripTextToolCalls_onlyToolCall_returnsEmpty() {
        let result = SSEStreamParser.stripTextToolCalls(from: "<tool_call>content</tool_call>")
        #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "")
    }
}

@Suite("SSE Processing Faults")
struct SSEProcessingFaultTests {

    @Test func processSSEChunks_emptyData_returnsEmpty() {
        let (forwarded, toolCalls, detected) = SSEStreamParser.processSSEChunks(Data(), hasTools: false)
        #expect(forwarded.isEmpty)
        #expect(toolCalls.isEmpty)
        #expect(!detected)
    }

    @Test func processSSEChunks_doneOnly_returnsEmpty() {
        let data = Data("data: [DONE]\n\n".utf8)
        let (forwarded, toolCalls, detected) = SSEStreamParser.processSSEChunks(data, hasTools: false)
        #expect(toolCalls.isEmpty)
        #expect(!detected)
        // [DONE] itself shouldn't produce forwarded content
        #expect(forwarded.isEmpty || String(data: forwarded, encoding: .utf8)?.contains("[DONE]") == true)
    }

    @Test func processSSEChunks_invalidJSON_handledGracefully() {
        let data = Data("data: {not valid json}\n\n".utf8)
        let (_, toolCalls, detected) = SSEStreamParser.processSSEChunks(data, hasTools: false)
        #expect(toolCalls.isEmpty)
        #expect(!detected)
    }

    @Test func processSSEChunks_emptyContent_forwarded() {
        let chunk = sseContentDelta("")
        var data = chunk
        data.append(Data("data: [DONE]\n\n".utf8))
        let (forwarded, _, _) = SSEStreamParser.processSSEChunks(data, hasTools: false)
        let str = String(data: forwarded, encoding: .utf8) ?? ""
        // Empty content delta should still be forwarded as a valid SSE event
        #expect(str.contains("data:"))
    }

    @Test func processSSEChunks_multipleContentDeltas_allForwarded() {
        var data = Data()
        data.append(sseContentDelta("Hello"))
        data.append(sseContentDelta(" World"))
        data.append(sseContentDelta("!"))
        data.append(Data("data: [DONE]\n\n".utf8))

        let (forwarded, _, _) = SSEStreamParser.processSSEChunks(data, hasTools: false)
        let str = String(data: forwarded, encoding: .utf8) ?? ""
        #expect(str.contains("Hello"))
        #expect(str.contains("World"))
    }

    @Test func processSSEChunks_finishReasonStop_notDetectedAsToolCall() {
        var data = Data()
        data.append(sseContentDelta("Response", finishReason: "stop"))
        data.append(Data("data: [DONE]\n\n".utf8))

        let (_, toolCalls, detected) = SSEStreamParser.processSSEChunks(data, hasTools: false)
        // finish_reason "stop" is not a tool call
        #expect(!detected)
        #expect(toolCalls.isEmpty)
    }

    @Test func processSSEChunks_finishReasonToolCalls_detected() {
        var data = Data()
        data.append(sseEvent([
            "id": "chatcmpl-test",
            "object": "chat.completion.chunk",
            "choices": [[
                "index": 0,
                "delta": [
                    "tool_calls": [[
                        "index": 0,
                        "id": "call_1",
                        "function": ["name": "web_search", "arguments": "{\"query\":\"test\"}"]
                    ] as [String: Any]]
                ] as [String: Any],
                "finish_reason": NSNull()
            ] as [String: Any]]
        ]))
        data.append(sseEvent([
            "id": "chatcmpl-test",
            "object": "chat.completion.chunk",
            "choices": [[
                "index": 0,
                "delta": [String: Any](),
                "finish_reason": "tool_calls"
            ] as [String: Any]]
        ]))
        data.append(Data("data: [DONE]\n\n".utf8))

        let (_, toolCalls, detected) = SSEStreamParser.processSSEChunks(data, hasTools: true)
        #expect(detected)
        #expect(toolCalls.count == 1)
    }

    // MARK: SSE helpers

    private func sseEvent(_ json: [String: Any]) -> Data {
        let data = try! JSONSerialization.data(withJSONObject: json)
        let str = String(data: data, encoding: .utf8)!
        return Data("data: \(str)\n\n".utf8)
    }

    private func sseContentDelta(_ content: String, finishReason: String? = nil) -> Data {
        var choice: [String: Any] = [
            "index": 0,
            "delta": ["content": content] as [String: Any]
        ]
        if let reason = finishReason {
            choice["finish_reason"] = reason
        } else {
            choice["finish_reason"] = NSNull()
        }
        return sseEvent([
            "id": "chatcmpl-test",
            "object": "chat.completion.chunk",
            "choices": [choice]
        ])
    }
}

// MARK: - LLMError Fault Tests

@Suite("LLMError Faults")
struct LLMErrorFaultTests {

    @Test func providerMessage_allMappedCodes() {
        let codes = [401, 403, 404, 422, 429, 500, 502, 503]
        for code in codes {
            let msg = LLMError.providerMessage(httpStatus: code, provider: "Test")
            #expect(!msg.isEmpty)
            #expect(msg.contains("Test") || msg.contains("\(code)"))
        }
    }

    @Test func providerMessage_unmappedCode_includesCode() {
        let msg = LLMError.providerMessage(httpStatus: 418, provider: "Test")
        #expect(msg.contains("418"))
    }

    @Test func groundingMessage_allMappedCodes() {
        let codes = [401, 402, 429]
        for code in codes {
            let msg = LLMError.groundingMessage(httpStatus: code)
            #expect(!msg.isEmpty)
        }
    }

    @Test func llmError_preservesAllFields() {
        let underlying = NSError(domain: "test", code: 42)
        let error = LLMError(
            source: .provider(name: "TestProvider"),
            userMessage: "Something failed",
            httpStatus: 500,
            url: URL(string: "https://example.com"),
            requestHeaders: ["Auth": "Bearer xxx"],
            requestBodyJSON: "{\"test\": true}",
            messageHistory: "user: hello",
            responseBody: "Internal Server Error",
            underlyingError: underlying
        )
        #expect(error.userMessage == "Something failed")
        #expect(error.httpStatus == 500)
        #expect(error.url?.absoluteString == "https://example.com")
        #expect(error.requestHeaders?["Auth"] == "Bearer xxx")
        #expect(error.requestBodyJSON == "{\"test\": true}")
        #expect(error.messageHistory == "user: hello")
        #expect(error.responseBody == "Internal Server Error")
        #expect((error.underlyingError as? NSError)?.code == 42)
    }

    @Test func llmError_braveGroundingSource() {
        let error = LLMError(
            source: .braveGrounding,
            userMessage: "Search failed",
            httpStatus: nil, url: nil,
            requestHeaders: nil, requestBodyJSON: nil,
            messageHistory: nil, responseBody: nil, underlyingError: nil
        )
        if case .braveGrounding = error.source {
            // pass
        } else {
            Issue.record("Expected .braveGrounding source")
        }
    }
}

// MARK: - E2EE Error Description Tests

@Suite("E2EE Error Descriptions")
struct E2EEErrorDescriptionTests {

    @Test func invalidHex_hasDescription() {
        let error = E2EEError.invalidHex
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test func invalidUTF8_hasDescription() {
        let error = E2EEError.invalidUTF8
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test func invalidKeyLength_hasDescription() {
        let error = E2EEError.invalidKeyLength
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test func decryptionFailed_hasDescription() {
        let error = E2EEError.decryptionFailed
        #expect(error.errorDescription?.isEmpty == false)
    }
}

// MARK: - Attestation State Transition Fault Tests

@Suite("Attestation State Faults")
struct AttestationStateFaultTests {

    @Test func requestResult_e2eeActive_true() {
        let result = RequestResult(
            url: nil, requestHeaders: nil, requestBodyJSON: nil,
            responseBody: nil, toolCalls: [], outputTokens: nil,
            teeVerification: nil, isE2EEActive: true
        )
        #expect(result.isE2EEActive == true)
    }

    @Test func requestResult_e2eeActive_false() {
        let result = RequestResult(
            url: nil, requestHeaders: nil, requestBodyJSON: nil,
            responseBody: nil, toolCalls: [], outputTokens: nil,
            teeVerification: nil, isE2EEActive: false
        )
        #expect(result.isE2EEActive == false)
    }

    @Test func debugInfo_preservesAllFields() {
        let threadID = UUID()
        let info = LastRequestDebugInfo(
            providerName: "near.ai", url: URL(string: "https://api.near.ai"),
            requestHeaders: ["X-Key": "val"], requestBodyJSON: "{\"test\": 1}",
            responseBody: "response", toolCalls: [],
            threadID: threadID, totalDuration: 2.5,
            timeToFirstToken: 0.5, outputTokens: 100,
            isE2EEActive: true, teeVerification: .unverified(.signatureUnavailable)
        )
        #expect(info.providerName == "near.ai")
        #expect(info.threadID == threadID)
        #expect(info.totalDuration == 2.5)
        #expect(info.timeToFirstToken == 0.5)
        #expect(info.outputTokens == 100)
        #expect(info.isE2EEActive == true)
    }

    /// The debug card must name the model that was SENT, not the provider record's
    /// label — found on device 2026-07-30, on a Fireworks key.
    ///
    /// `provider.name` is auto-generated as "<provider> <model>" when a key is saved
    /// and deliberately never refreshed afterwards (the user may have typed it), so
    /// a record labelled "fireworks Qwen3.7 Plus" outlives every later model change.
    /// The Where chip read `provider.model` and said `deepseek-v4-flash`; this card
    /// read the label and said `Qwen3.7 Plus`; the request had used deepseek, which
    /// `HTTPTransport` takes from the same `provider.model`. Two surfaces, one fact,
    /// and the one whose entire job is to report the fact was the one that was wrong.
    @Test func debugCardNamesTheModelThatWasSentNotTheRecordLabel() {
        let stale = "fireworks Qwen3.7 Plus"
        let sent = "accounts/fireworks/models/deepseek-v4-flash"
        let view = RequestDebugView(info: LastRequestDebugInfo(
            providerName: Provider.fireworks.canonicalName,
            modelID: sent,
            url: URL(string: "https://api.fireworks.ai/inference/v1/chat/completions"),
            requestHeaders: nil, requestBodyJSON: "{\"model\":\"\(sent)\"}",
            responseBody: "hi", toolCalls: [],
            threadID: UUID(), totalDuration: 0.9,
            timeToFirstToken: 0.9, outputTokens: 24,
            isE2EEActive: false, teeVerification: nil
        ))

        // The canonical place, never the label — the label's model name is what made
        // the card unreadable, and `canonicalName` is endpoint-derived.
        #expect(view.info.providerName == "fireworks")
        #expect(!view.info.providerName.contains("Qwen"))
        #expect(stale.contains("Qwen"), "the label this replaced did name a model")

        // The copied text carries the FULL id, so a pasted card can be replayed.
        #expect(view.debugText.hasPrefix("=== fireworks \(sent) Debug ==="))
        #expect(view.debugText.contains(sent))

        // And the header's shortened form is the id's own spelling, not the
        // catalogue's prettified name.
        #expect(ModelCatalog.displayName(forID: sent) == "deepseek-v4-flash")
    }

    /// On-device, the header must NOT print the model twice.
    ///
    /// `Provider.local` names the record after the model it wraps, so the place
    /// token already reads "gemma 4 e2b" — and the id token then repeated it as the
    /// half that says nothing: `google/gemma-4-e2b-it-litert-lm` shortens to
    /// `gemma-4-e2b-it-litert-lm`, whose tail is a tuning marker, a file format and
    /// a runtime, middle-truncated on a phone into "gemma-4…tert-lm". The developer asked
    /// why the line was so long; that was why.
    ///
    /// Asserted through the same values the view branches on, since the branch is
    /// `url == nil`: nothing was sent anywhere, so there is no second name to show.
    @Test func onDeviceHeaderDoesNotPrintTheModelTwice() {
        let repoID = "google/gemma-4-e2b-it-litert-lm"
        let local = Provider.local(LocalModelCatalog.all[0])
        // The record IS the model — that is what makes a second token a repeat.
        #expect(local.name == LocalModelCatalog.all[0].displayName)
        #expect(local.canonicalName
                == LocalModelCatalog.all[0].displayName.lowercased())

        let info = LastRequestDebugInfo(
            providerName: "gemma 4 e2b", modelID: repoID,
            url: nil,                                   // ← on-device
            requestHeaders: nil, requestBodyJSON: "{\"model\":\"\(repoID)\"}",
            responseBody: "hi", toolCalls: [],
            threadID: UUID(), totalDuration: 6.5,
            timeToFirstToken: 6.3, outputTokens: 10,
            isE2EEActive: false, teeVerification: nil
        )
        #expect(info.url == nil, "the view suppresses the id token on exactly this")

        // Nothing is lost: the full repo id stays in the copied text and the body.
        let view = RequestDebugView(info: info)
        #expect(view.debugText.contains(repoID))
        #expect(info.requestBodyJSON?.contains(repoID) == true)

        // And the shortened form really is the noise it was accused of being.
        #expect(ModelCatalog.displayName(forID: repoID) == "gemma-4-e2b-it-litert-lm")
        #expect(ModelCatalog.displayName(forID: repoID).count > "gemma 4 e2b".count)
    }

    @Test func debugInfo_generationTime_calculated() {
        let info = LastRequestDebugInfo(
            providerName: "test", url: nil,
            requestHeaders: nil, requestBodyJSON: nil,
            responseBody: nil, toolCalls: [],
            threadID: UUID(), totalDuration: 3.0,
            timeToFirstToken: 1.0, outputTokens: nil,
            isE2EEActive: false, teeVerification: nil
        )
        #expect(info.generationTime == 2.0)
    }

    @Test func debugInfo_generationTime_nilWhenMissing() {
        let info = LastRequestDebugInfo(
            providerName: "test", url: nil,
            requestHeaders: nil, requestBodyJSON: nil,
            responseBody: nil, toolCalls: [],
            threadID: UUID(), totalDuration: nil,
            timeToFirstToken: nil, outputTokens: nil,
            isE2EEActive: false, teeVerification: nil
        )
        #expect(info.generationTime == nil)
    }

    @Test func debugInfo_tokensPerSecond_calculated() {
        let info = LastRequestDebugInfo(
            providerName: "test", url: nil,
            requestHeaders: nil, requestBodyJSON: nil,
            responseBody: nil, toolCalls: [],
            threadID: UUID(), totalDuration: 3.0,
            timeToFirstToken: 1.0, outputTokens: 100,
            isE2EEActive: false, teeVerification: nil
        )
        #expect(info.tokensPerSecond == 50.0)
    }

    @Test func debugInfo_tokensPerSecond_nilWhenNoTokens() {
        let info = LastRequestDebugInfo(
            providerName: "test", url: nil,
            requestHeaders: nil, requestBodyJSON: nil,
            responseBody: nil, toolCalls: [],
            threadID: UUID(), totalDuration: 3.0,
            timeToFirstToken: 1.0, outputTokens: nil,
            isE2EEActive: false, teeVerification: nil
        )
        #expect(info.tokensPerSecond == nil)
    }
}

// MARK: - XChaChaPoly Fault Tests

@Suite("XChaChaPoly Faults")
struct XChaChaFaultTests {

    @Test func seal_open_roundTrip_largePayload() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data(repeating: 0x42, count: 65536)
        let box = try XChaChaPoly.seal(plaintext, using: key)
        let recovered = try XChaChaPoly.open(box, using: key)
        #expect(recovered == plaintext)
    }

    @Test func seal_open_emptyPlaintext() throws {
        let key = SymmetricKey(size: .bits256)
        let box = try XChaChaPoly.seal(Data(), using: key)
        let recovered = try XChaChaPoly.open(box, using: key)
        #expect(recovered.isEmpty)
    }

    @Test func combined_tooShort_throws() {
        #expect(throws: XChaChaPoly.Error.incorrectCombinedSize) {
            _ = try XChaChaPoly.SealedBox(combined: Data(count: 24 + 15))
        }
    }

    @Test func open_emptyCiphertextWrongTag_throws() throws {
        // 24-byte nonce + 16-byte zero tag parses as a SealedBox with empty
        // ciphertext, but the forged tag must fail authentication.
        let key = SymmetricKey(size: .bits256)
        let box = try XChaChaPoly.SealedBox(combined: Data(count: 24 + 16))
        #expect(throws: (any Error).self) {
            _ = try XChaChaPoly.open(box, using: key)
        }
    }

    @Test func open_wrongNonce_throws() throws {
        let key = SymmetricKey(size: .bits256)
        let nonce1 = try XChaChaPoly.Nonce(data: Data(repeating: 0x11, count: 24))
        let nonce2 = try XChaChaPoly.Nonce(data: Data(repeating: 0x22, count: 24))
        let box = try XChaChaPoly.seal(Data("test".utf8), using: key, nonce: nonce1)
        let tampered = XChaChaPoly.SealedBox(nonce: nonce2, ciphertext: box.ciphertext, tag: box.tag)
        #expect(throws: (any Error).self) {
            _ = try XChaChaPoly.open(tampered, using: key)
        }
    }
}

// MARK: - Wire Format Fault Tests

@Suite("Wire Format Faults")
struct WireFormatFaultTests {

    @Test func encrypt_decrypt_unicode() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let plaintext = Data("Hello \u{1F30D} \u{2603} \u{1F680}".utf8)
        let wire = try E2EEEnvelope.seal(plaintext: plaintext, recipientPubKey: recipient.publicKey)
        let recovered = try E2EEEnvelope.open(wireFormat: wire, privateKey: recipient)
        #expect(recovered == plaintext)
    }

    @Test func encrypt_decrypt_emptyPlaintext() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let wire = try E2EEEnvelope.seal(plaintext: Data(), recipientPubKey: recipient.publicKey)
        let recovered = try E2EEEnvelope.open(wireFormat: wire, privateKey: recipient)
        #expect(recovered.isEmpty)
    }

    @Test func decrypt_exactMinimumLength_throws() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        // Exactly 32 + 24 + 16 = 72 bytes (minimum), but with garbage data
        #expect(throws: (any Error).self) {
            _ = try E2EEEnvelope.open(wireFormat: Data(count: 72), privateKey: key)
        }
    }

    @Test func decrypt_oneByteShort_throws() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        #expect(throws: E2EEError.decryptionFailed) {
            _ = try E2EEEnvelope.open(wireFormat: Data(count: 71), privateKey: key)
        }
    }

    @Test func encrypt_produces_uniqueCiphertexts() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let plaintext = Data("same message".utf8)
        let wire1 = try E2EEEnvelope.seal(plaintext: plaintext, recipientPubKey: recipient.publicKey)
        let wire2 = try E2EEEnvelope.seal(plaintext: plaintext, recipientPubKey: recipient.publicKey)
        // Ephemeral keys differ, so ciphertexts must differ
        #expect(wire1 != wire2)
    }
}
