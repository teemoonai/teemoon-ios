import Foundation
import Testing
import CryptoKit
@testable import teemoon

// MARK: - Hex Encoding/Decoding

@Suite("Hex helpers")
struct HexTests {

    @Test func roundTrip() throws {
        let original = Data([0xde, 0xad, 0xbe, 0xef, 0x00, 0xff])
        let hex = original.hexString
        #expect(hex == "deadbeef00ff")
        let decoded = try Data(hexString: hex)
        #expect(decoded == original)
    }

    @Test func emptyData() throws {
        #expect(Data().hexString == "")
        let decoded = try Data(hexString: "")
        #expect(decoded.isEmpty)
    }

    @Test func oddLengthHex_parsesTrailingSingleChar() throws {
        // "abc" is 3 chars: parses "ab" (0xab), then "c" alone → UInt8("c", radix:16) = 12.
        let data = try Data(hexString: "abc")
        #expect(data == Data([0xab, 0x0c]))
    }

    @Test func invalidCharacters_throws() {
        #expect(throws: E2EEError.invalidHex) {
            _ = try Data(hexString: "zzzz")
        }
    }
}

// MARK: - XChaChaPoly known-answer tests (draft-irtf-cfrg-xchacha-03)

@Suite("XChaChaPoly known answers")
struct XChaChaPolyKnownAnswerTests {

    /// §2.2.1 "Test Vector for the HChaCha20 Block Function".
    @Test func hchacha20_draftVector() {
        let key = Array(0x00...0x1f) as [UInt8]  // 000102...1f
        let input: [UInt8] = [
            0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x4a,
            0x00, 0x00, 0x00, 0x00, 0x31, 0x41, 0x59, 0x27,
        ]
        let expected: [UInt8] = [
            0x82, 0x41, 0x3b, 0x42, 0x27, 0xb2, 0x7b, 0xfe,
            0xd3, 0x0e, 0x42, 0x50, 0x8a, 0x87, 0x7d, 0x73,
            0xa0, 0xf9, 0xe4, 0xd5, 0x8a, 0x74, 0xa8, 0x53,
            0xc1, 0x2e, 0xc4, 0x13, 0x26, 0xd3, 0xec, 0xdc,
        ]
        #expect(XChaChaPoly.hchacha20(key: key, input: input) == expected)
    }

    /// §A.3.1 AEAD_XChaCha20_Poly1305 test vector (with AAD).
    @Test func aead_draftVector() throws {
        let plaintext = try Data(hexString:
            "4c616469657320616e642047656e746c656d656e206f662074686520636c6173" +
            "73206f66202739393a204966204920636f756c64206f6666657220796f75206f" +
            "6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73" +
            "637265656e20776f756c642062652069742e")
        let aad = try Data(hexString: "50515253c0c1c2c3c4c5c6c7")
        let key = SymmetricKey(data: try Data(hexString:
            "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"))
        let nonce = try XChaChaPoly.Nonce(data: try Data(hexString:
            "404142434445464748494a4b4c4d4e4f5051525354555657"))
        let expectedCiphertext = try Data(hexString:
            "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb" +
            "731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b452" +
            "2f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff9" +
            "21f9664c97637da9768812f615c68b13b52e")
        let expectedTag = try Data(hexString: "c0875924c1c7987947deafd8780acf49")

        let box = try XChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        #expect(box.ciphertext == expectedCiphertext)
        #expect(box.tag == expectedTag)

        let opened = try XChaChaPoly.open(box, using: key, authenticating: aad)
        #expect(opened == plaintext)
    }
}

// MARK: - XChaChaPoly seal/open

@Suite("XChaChaPoly")
struct XChaChaPolyTests {

    @Test func roundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("Hello, TEE world!".utf8)
        let box = try XChaChaPoly.seal(plaintext, using: key)
        let reconstructed = try XChaChaPoly.SealedBox(combined: box.combined)
        let recovered = try XChaChaPoly.open(reconstructed, using: key)
        #expect(recovered == plaintext)
    }

    @Test func wrongKey_fails() throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let box = try XChaChaPoly.seal(Data("secret".utf8), using: key1)
        #expect(throws: (any Error).self) {
            _ = try XChaChaPoly.open(box, using: key2)
        }
    }

    /// A 32-BYTE plaintext, not "x". The one-byte version failed about once in
    /// 256 runs and looked like a nonce-reuse alarm: two different keystreams
    /// produce two different single bytes with probability 255/256, so the
    /// ciphertext comparison collided by chance. The NONCE assertion — the
    /// actual invariant — passed every time, including on the run that failed.
    ///
    /// Widening the plaintext takes the collision probability to 2^-256 and
    /// keeps the intent. Deleting the ciphertext check would also have removed
    /// the flake, but it is worth keeping: a stream cipher reusing a nonce shows
    /// up here as identical ciphertext even if the nonce field looks fresh.
    ///
    /// A security test that cries wolf 0.4% of the time is worse than no test —
    /// it teaches the reader to re-run rather than investigate.
    @Test func freshNonceEverySeal() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data(repeating: 0xA5, count: 32)
        let box1 = try XChaChaPoly.seal(plaintext, using: key)
        let box2 = try XChaChaPoly.seal(plaintext, using: key)
        #expect(box1.nonce.bytes != box2.nonce.bytes)
        #expect(box1.ciphertext != box2.ciphertext)
    }

    @Test func combinedTooShort_throws() {
        #expect(throws: XChaChaPoly.Error.incorrectCombinedSize) {
            _ = try XChaChaPoly.SealedBox(combined: Data(count: 24 + 15))
        }
    }

    @Test func nonceWrongLength_throws() {
        #expect(throws: XChaChaPoly.Error.incorrectNonceSize) {
            _ = try XChaChaPoly.Nonce(data: Data(count: 12))
        }
    }
}

// MARK: - Ed25519 → X25519 Key Conversion

@Suite("Ed25519 to X25519 conversion")
struct KeyConversionTests {

    @Test func seedConversion_producesValidKey() throws {
        let edKey = Curve25519.Signing.PrivateKey()
        let xKey = try Ed25519ToX25519.privateKey(seed: edKey.rawRepresentation)
        // Should produce a valid 32-byte X25519 key that can do ECDH.
        let peer = Curve25519.KeyAgreement.PrivateKey()
        let shared = try xKey.sharedSecretFromKeyAgreement(with: peer.publicKey)
        // Shared secret should be non-empty.
        let desc = shared.description
        #expect(!desc.isEmpty)
    }

    @Test func pubKeyConversion_matchesCryptoKit() throws {
        // CryptoKit's Curve25519.Signing and KeyAgreement share the same underlying
        // curve, but use different raw representations. Our conversion must produce
        // a public key that agrees with the private key's X25519 form.
        let edPrivate = Curve25519.Signing.PrivateKey()
        let xPrivate = try Ed25519ToX25519.privateKey(seed: edPrivate.rawRepresentation)
        let xPubFromConversion = try Ed25519ToX25519.publicKey(edPub: edPrivate.publicKey.rawRepresentation)

        // Both should yield the same X25519 public key.
        #expect(xPrivate.publicKey.rawRepresentation == xPubFromConversion.rawRepresentation)
    }

    @Test func invalidLength_throws() {
        #expect(throws: E2EEError.invalidKeyLength) {
            _ = try Ed25519ToX25519.publicKey(edPub: Data(count: 16))
        }
    }
}

// MARK: - E2EE Wire Format

@Suite("E2EE wire format")
struct WireFormatTests {

    @Test func encrypt_producesCorrectLayout() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let plaintext = Data("test message".utf8)
        let wire = try E2EEEnvelope.seal(plaintext: plaintext, recipientPubKey: recipient.publicKey)

        // Wire = ephemeral_pub (32) + nonce (24) + ciphertext + tag (16)
        #expect(wire.count == 32 + 24 + plaintext.count + 16)
    }

    @Test func encrypt_decrypt_roundTrip() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let plaintext = Data("The quick brown fox jumps over the lazy dog".utf8)
        let wire = try E2EEEnvelope.seal(plaintext: plaintext, recipientPubKey: recipient.publicKey)
        let recovered = try E2EEEnvelope.open(wireFormat: wire, privateKey: recipient)
        #expect(recovered == plaintext)
    }

    @Test func decrypt_shortData_fails() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        #expect(throws: E2EEError.decryptionFailed) {
            _ = try E2EEEnvelope.open(wireFormat: Data(count: 50), privateKey: key)
        }
    }
}

// MARK: - E2EEPeer

@Suite("E2EEPeer")
struct E2EEPeerTests {

    /// Simulates a model keypair and verifies full session encrypt/decrypt.
    @Test func sessionEncryptDecrypt_roundTrip() throws {
        // Simulate model: generate Ed25519 key, expose public key.
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let modelEdPubData = modelEdKey.publicKey.rawRepresentation

        // Derive model's X25519 private key (the "model side" for decryption).
        let modelXPrivate = try Ed25519ToX25519.privateKey(seed: modelEdKey.rawRepresentation)

        // Client creates session with model's Ed25519 public key.
        let session = try E2EEPeer(modelEd25519PubKey: modelEdPubData)

        // Client encrypts a message.
        let original = "Hello from the client!"
        let encryptedHex = try session.encrypt(original)

        // Model decrypts using its X25519 private key.
        let wireData = try Data(hexString: encryptedHex)
        let decrypted = try E2EEEnvelope.open(wireFormat: wireData, privateKey: modelXPrivate)
        #expect(String(data: decrypted, encoding: .utf8) == original)
    }

    /// Simulates model encrypting a response, client session decrypts.
    @Test func sessionDecrypt_modelResponse() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        // Model encrypts a response to the client's X25519 public key.
        let responseText = "Here is the model's response."
        let wire = try E2EEEnvelope.seal(
            plaintext: Data(responseText.utf8),
            recipientPubKey: session.agreementKey.publicKey
        )
        let wireHex = wire.hexString

        // Client session decrypts.
        let recovered = try session.decrypt(wireHex)
        #expect(recovered == responseText)
    }

    @Test func headers_containRequiredFields() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)
        let h = session.headers

        #expect(h["X-Signing-Algo"] == "ed25519")
        #expect(h["X-Encryption-Version"] == "2")
        #expect(h["X-Client-Pub-Key"]?.count == 64) // 32 bytes hex
        #expect(h["X-Model-Pub-Key"]?.count == 64)
    }
}

// MARK: - Request Body Encryption

@Suite("Request body encryption")
struct RequestBodyEncryptionTests {

    @Test func encryptRequestBody_replacesContent() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let modelXPrivate = try Ed25519ToX25519.privateKey(seed: modelEdKey.rawRepresentation)
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        let body: [String: Any] = [
            "model": "test-model",
            "messages": [
                ["role": "system", "content": "You are helpful."],
                ["role": "user", "content": "What is 2+2?"],
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let encrypted = try session.encryptRequestBody(bodyData)

        // Parse result and verify structure preserved.
        let result = try JSONSerialization.jsonObject(with: encrypted) as! [String: Any]
        #expect(result["model"] as? String == "test-model")

        let msgs = result["messages"] as! [[String: Any]]
        #expect(msgs.count == 2)
        #expect(msgs[0]["role"] as? String == "system")
        #expect(msgs[1]["role"] as? String == "user")

        // Content should be hex-encoded ciphertext, not plaintext.
        let encSystem = msgs[0]["content"] as! String
        let encUser = msgs[1]["content"] as! String
        #expect(encSystem != "You are helpful.")
        #expect(encUser != "What is 2+2?")

        // Decrypt and verify.
        let sysWire = try Data(hexString: encSystem)
        let sysPlain = try E2EEEnvelope.open(wireFormat: sysWire, privateKey: modelXPrivate)
        #expect(String(data: sysPlain, encoding: .utf8) == "You are helpful.")

        let userWire = try Data(hexString: encUser)
        let userPlain = try E2EEEnvelope.open(wireFormat: userWire, privateKey: modelXPrivate)
        #expect(String(data: userPlain, encoding: .utf8) == "What is 2+2?")
    }

    @Test func encryptRequestBody_emptyContent_unchanged() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        let body: [String: Any] = [
            "messages": [
                ["role": "user", "content": ""],
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let encrypted = try session.encryptRequestBody(bodyData)
        let result = try JSONSerialization.jsonObject(with: encrypted) as! [String: Any]
        let msgs = result["messages"] as! [[String: Any]]
        // Empty content should remain empty (not encrypted).
        #expect(msgs[0]["content"] as? String == "")
    }

    @Test func encryptRequestBody_invalidJSON_returnsOriginal() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)
        let garbage = Data("not json".utf8)
        let result = try session.encryptRequestBody(garbage)
        #expect(result == garbage)
    }

    /// Simulates follow-up request body (tool results) being encrypted.
    @Test func encryptRequestBody_toolResultsFollowUp() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let modelXPrivate = try Ed25519ToX25519.privateKey(seed: modelEdKey.rawRepresentation)
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        // Simulates the follow-up body built by handleToolCallsAndContinue.
        let body: [String: Any] = [
            "model": "test-model",
            "stream": true,
            "messages": [
                ["role": "system", "content": "You are helpful."],
                ["role": "user", "content": "What's the weather?"],
                ["role": "assistant", "content": "", "tool_calls": [
                    ["id": "call_1", "type": "function",
                     "function": ["name": "brave_search", "arguments": "{\"query\":\"weather today\"}"]]
                ]],
                ["role": "tool", "tool_call_id": "call_1",
                 "content": "SOURCE weather.com | https://weather.com\nSunny, 72F"],
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let encrypted = try session.encryptRequestBody(bodyData)

        let result = try JSONSerialization.jsonObject(with: encrypted) as! [String: Any]
        let msgs = result["messages"] as! [[String: Any]]
        #expect(msgs.count == 4)

        // System, user, and tool content should be encrypted (non-empty content replaced).
        let systemEnc = msgs[0]["content"] as! String
        let userEnc = msgs[1]["content"] as! String
        let toolEnc = msgs[3]["content"] as! String
        #expect(systemEnc != "You are helpful.")
        #expect(userEnc != "What's the weather?")
        #expect(toolEnc != "SOURCE weather.com | https://weather.com\nSunny, 72F")

        // Assistant empty content should remain empty.
        #expect(msgs[2]["content"] as? String == "")

        // All encrypted fields should be decryptable.
        let toolWire = try Data(hexString: toolEnc)
        let toolPlain = try E2EEEnvelope.open(wireFormat: toolWire, privateKey: modelXPrivate)
        #expect(String(data: toolPlain, encoding: .utf8) == "SOURCE weather.com | https://weather.com\nSunny, 72F")
    }
}

// MARK: - reasoning_content Decryption

@Suite("reasoning_content decryption")
struct ReasoningContentTests {

    /// Verifies that reasoning_content can be encrypted and decrypted using the same
    /// E2EEPeer path as regular content.
    @Test func reasoningContent_encryptDecrypt_roundTrip() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        // Simulate model encrypting reasoning_content for the client.
        let reasoning = "Let me think about this step by step..."
        let wire = try E2EEEnvelope.seal(
            plaintext: Data(reasoning.utf8),
            recipientPubKey: session.agreementKey.publicKey
        )
        let wireHex = wire.hexString

        // Client decrypts — same path as content decryption.
        let recovered = try session.decrypt(wireHex)
        #expect(recovered == reasoning)
    }

    /// Verifies that both content and reasoning_content from the same chunk
    /// can be decrypted independently by the same session.
    @Test func bothFields_decryptIndependently() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        let reasoning = "The user is asking about X..."
        let content = "Here is my answer."

        // Each field is independently encrypted with a fresh ephemeral key.
        let reasoningWire = try E2EEEnvelope.seal(
            plaintext: Data(reasoning.utf8),
            recipientPubKey: session.agreementKey.publicKey
        )
        let contentWire = try E2EEEnvelope.seal(
            plaintext: Data(content.utf8),
            recipientPubKey: session.agreementKey.publicKey
        )

        // Ciphertexts should differ (different ephemeral keys + nonces).
        #expect(reasoningWire != contentWire)

        // Both should decrypt correctly.
        #expect(try session.decrypt(reasoningWire.hexString) == reasoning)
        #expect(try session.decrypt(contentWire.hexString) == content)
    }
}

// MARK: - Non-streaming E2EE (stream forced to false)

@Suite("E2EE request body encryption preserves stream flag")
struct E2EEStreamingTests {

    @Test func encryptRequestBody_preservesStreamTrue() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        let body: [String: Any] = [
            "model": "test-model",
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": [["role": "user", "content": "Hello"]]
        ]
        let encrypted = try session.encryptRequestBody(
            JSONSerialization.data(withJSONObject: body)
        )
        let result = try JSONSerialization.jsonObject(with: encrypted) as! [String: Any]
        // stream and stream_options must be preserved — the gateway supports streaming E2EE.
        #expect(result["stream"] as? Bool == true)
        #expect(result["stream_options"] != nil)
    }

    @Test func encryptRequestBody_preservesAllFields() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        let body: [String: Any] = [
            "model": "zai-org/GLM-5-FP8",
            "stream": true,
            "temperature": 0.7,
            "max_tokens": 1024,
            "messages": [["role": "user", "content": "Test"]]
        ]
        let encrypted = try session.encryptRequestBody(
            JSONSerialization.data(withJSONObject: body)
        )
        let result = try JSONSerialization.jsonObject(with: encrypted) as! [String: Any]
        #expect(result["model"] as? String == "zai-org/GLM-5-FP8")
        #expect(result["temperature"] as? Double == 0.7)
        #expect(result["max_tokens"] as? Int == 1024)
        #expect(result["stream"] as? Bool == true)
    }

    /// Simulates per-chunk streaming decryption: each SSE chunk's content
    /// is independently encrypted and can be decrypted by the same session.
    @Test func streamingChunks_decryptIndependently() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        let chunks = ["Hello", ", ", "world", "!"]
        for chunk in chunks {
            // Each SSE chunk's content is independently encrypted by the TEE.
            let wire = try E2EEEnvelope.seal(
                plaintext: Data(chunk.utf8),
                recipientPubKey: session.agreementKey.publicKey
            )
            let decrypted = try session.decrypt(wire.hexString)
            #expect(decrypted == chunk)
        }
    }

    /// Full roundtrip: encrypt request → model decrypts → model encrypts
    /// streaming chunks → client decrypts each chunk.
    @Test func fullE2EERoundtrip_streaming() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let modelXPrivate = try Ed25519ToX25519.privateKey(seed: modelEdKey.rawRepresentation)
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        // 1. Client encrypts request.
        let requestBody: [String: Any] = [
            "model": "test-model", "stream": true,
            "messages": [
                ["role": "system", "content": "You are helpful."],
                ["role": "user", "content": "What is 2+2?"],
            ]
        ]
        let encrypted = try session.encryptRequestBody(
            JSONSerialization.data(withJSONObject: requestBody)
        )
        let encJSON = try JSONSerialization.jsonObject(with: encrypted) as! [String: Any]
        #expect(encJSON["stream"] as? Bool == true)

        // 2. TEE decrypts request messages.
        let encMsgs = encJSON["messages"] as! [[String: Any]]
        for msg in encMsgs {
            let encContent = msg["content"] as! String
            let wire = try Data(hexString: encContent)
            let plain = try E2EEEnvelope.open(wireFormat: wire, privateKey: modelXPrivate)
            #expect(!String(data: plain, encoding: .utf8)!.isEmpty)
        }

        // 3. Model streams response, TEE encrypts each chunk for the client.
        let responseChunks = ["2+2", " equals", " 4."]
        var accumulated = ""
        for chunk in responseChunks {
            let wire = try E2EEEnvelope.seal(
                plaintext: Data(chunk.utf8),
                recipientPubKey: session.agreementKey.publicKey
            )
            let decrypted = try session.decrypt(wire.hexString)
            accumulated += decrypted
        }
        #expect(accumulated == "2+2 equals 4.")
    }

    /// Non-streaming fallback: when the server returns JSON instead of SSE,
    /// the client can still decrypt the complete response.
    @Test func nonStreamingFallback_decryptsBothFields() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        let content = "The answer is 42."
        let reasoning = "I need to think about this carefully..."

        let contentWire = try E2EEEnvelope.seal(
            plaintext: Data(content.utf8),
            recipientPubKey: session.agreementKey.publicKey
        )
        let reasoningWire = try E2EEEnvelope.seal(
            plaintext: Data(reasoning.utf8),
            recipientPubKey: session.agreementKey.publicKey
        )

        // Simulate non-streaming JSON response (fallback path).
        let responseJSON: [String: Any] = [
            "id": "chatcmpl-test123",
            "choices": [[
                "message": [
                    "content": contentWire.hexString,
                    "reasoning_content": reasoningWire.hexString,
                ],
                "finish_reason": "stop",
            ] as [String: Any]],
            "usage": ["completion_tokens": 10, "prompt_tokens": 5, "total_tokens": 15],
        ]

        let choices = responseJSON["choices"] as! [[String: Any]]
        let message = choices[0]["message"] as! [String: Any]
        #expect(try session.decrypt(message["content"] as! String) == content)
        #expect(try session.decrypt(message["reasoning_content"] as! String) == reasoning)
    }
}

// MARK: - E2EE follow-up (tool call continuation) roundtrip

@Suite("E2EE follow-up request encryption")
struct E2EEFollowUpTests {

    /// Simulates the full tool-call flow: initial request → tool_calls response →
    /// follow-up request with tool results → final encrypted response.
    /// Verifies that the follow-up request body is properly encrypted (stream:false)
    /// and the final response can be decrypted by the same session.
    @Test func followUp_encryptsAndDecryptsRoundtrip() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let modelXPrivate = try Ed25519ToX25519.privateKey(seed: modelEdKey.rawRepresentation)
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        // 1. Build a follow-up request body (tool results appended to history).
        let followUpBody: [String: Any] = [
            "model": "zai-org/GLM-5-FP8",
            "stream": true,
            "messages": [
                ["role": "system", "content": "You are helpful."],
                ["role": "user", "content": "What's the weather in Tokyo?"],
                ["role": "assistant", "content": "", "tool_calls": [
                    ["id": "call_1", "type": "function",
                     "function": ["name": "brave_search", "arguments": "{\"query\":\"weather Tokyo\"}"]]
                ]],
                ["role": "tool", "tool_call_id": "call_1",
                 "content": "Tokyo: Sunny, 25°C, humidity 40%"],
            ]
        ]
        let followUpData = try JSONSerialization.data(withJSONObject: followUpBody)

        // 2. Encrypt the follow-up body (same as the generation engine does).
        let encrypted = try session.encryptRequestBody(followUpData)
        let encJSON = try JSONSerialization.jsonObject(with: encrypted) as! [String: Any]

        // stream is preserved (streaming E2EE supported).
        #expect(encJSON["stream"] as? Bool == true)

        // 3. Model side: verify all message contents are decryptable.
        let msgs = encJSON["messages"] as! [[String: Any]]
        let systemPlain = try E2EEEnvelope.open(
            wireFormat: Data(hexString: msgs[0]["content"] as! String),
            privateKey: modelXPrivate
        )
        #expect(String(data: systemPlain, encoding: .utf8) == "You are helpful.")

        let toolResultPlain = try E2EEEnvelope.open(
            wireFormat: Data(hexString: msgs[3]["content"] as! String),
            privateKey: modelXPrivate
        )
        #expect(String(data: toolResultPlain, encoding: .utf8) == "Tokyo: Sunny, 25°C, humidity 40%")

        // 4. Model generates a response, TEE encrypts for the client.
        let responseText = "It's sunny and 25°C in Tokyo with 40% humidity."
        let responseWire = try E2EEEnvelope.seal(
            plaintext: Data(responseText.utf8),
            recipientPubKey: session.agreementKey.publicKey
        )

        // 5. Client decrypts the follow-up response (same session, same keys).
        let decrypted = try session.decrypt(responseWire.hexString)
        #expect(decrypted == responseText)
    }

    /// Verifies that follow-up responses with both content and reasoning_content
    /// can be decrypted by the same session that encrypted the request.
    @Test func followUp_decryptsBothResponseFields() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        let content = "Based on search results, Tokyo is sunny today."
        let reasoning = "The search returned weather data for Tokyo..."

        let contentWire = try E2EEEnvelope.seal(
            plaintext: Data(content.utf8),
            recipientPubKey: session.agreementKey.publicKey
        )
        let reasoningWire = try E2EEEnvelope.seal(
            plaintext: Data(reasoning.utf8),
            recipientPubKey: session.agreementKey.publicKey
        )

        // Simulate the non-streaming JSON response from a follow-up.
        let responseJSON: [String: Any] = [
            "id": "chatcmpl-followup",
            "choices": [[
                "message": [
                    "content": contentWire.hexString,
                    "reasoning_content": reasoningWire.hexString,
                ],
                "finish_reason": "stop",
            ] as [String: Any]],
            "usage": ["completion_tokens": 20, "prompt_tokens": 50, "total_tokens": 70],
        ]

        // Client-side decryption (mirrors handleE2EENonStreamingResponse).
        let choices = responseJSON["choices"] as! [[String: Any]]
        let message = choices[0]["message"] as! [String: Any]

        #expect(try session.decrypt(message["content"] as! String) == content)
        #expect(try session.decrypt(message["reasoning_content"] as! String) == reasoning)
    }

    /// Multiple sequential follow-ups (chained tool calls) all use the same
    /// E2EE session, so all responses should be decryptable.
    @Test func chainedFollowUps_sameSessionDecryptsAll() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        let responses = [
            "First search found 3 results.",
            "Second search refined the answer.",
            "Here is the final answer based on all searches.",
        ]

        for (i, text) in responses.enumerated() {
            let wire = try E2EEEnvelope.seal(
                plaintext: Data(text.utf8),
                recipientPubKey: session.agreementKey.publicKey
            )
            let decrypted = try session.decrypt(wire.hexString)
            #expect(decrypted == text, "Failed to decrypt response \(i)")
        }
    }
}

// MARK: - Tool Call Encryption (X-Encrypt-All-Fields)

@Suite("Tool call encryption")
struct ToolCallEncryptionTests {

    // MARK: Request-side: encrypt tool_calls in messages

    @Test func encryptRequestBody_encryptsToolCallArgsAndNames() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let modelXPrivate = try Ed25519ToX25519.privateKey(seed: modelEdKey.rawRepresentation)
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        let body: [String: Any] = [
            "model": "test-model",
            "messages": [
                ["role": "user", "content": "What's the weather?"],
                ["role": "assistant", "content": "", "tool_calls": [
                    ["id": "call_1", "type": "function",
                     "function": ["name": "brave_search", "arguments": "{\"query\":\"weather today\"}"]]
                ]],
                ["role": "tool", "tool_call_id": "call_1",
                 "content": "Sunny, 72F"],
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let encrypted = try session.encryptRequestBody(bodyData)

        let result = try JSONSerialization.jsonObject(with: encrypted) as! [String: Any]
        let msgs = result["messages"] as! [[String: Any]]

        // The assistant message's tool_calls should have encrypted name and arguments.
        let assistantMsg = msgs[1]
        let toolCalls = assistantMsg["tool_calls"] as! [[String: Any]]
        let fn = toolCalls[0]["function"] as! [String: Any]
        let encName = fn["name"] as! String
        let encArgs = fn["arguments"] as! String

        // Name and arguments should NOT be plaintext.
        #expect(encName != "brave_search")
        #expect(encArgs != "{\"query\":\"weather today\"}")

        // They should be decryptable.
        let namePlain = try E2EEEnvelope.open(
            wireFormat: Data(hexString: encName), privateKey: modelXPrivate
        )
        #expect(String(data: namePlain, encoding: .utf8) == "brave_search")

        let argsPlain = try E2EEEnvelope.open(
            wireFormat: Data(hexString: encArgs), privateKey: modelXPrivate
        )
        #expect(String(data: argsPlain, encoding: .utf8) == "{\"query\":\"weather today\"}")
    }

    @Test func encryptRequestBody_encryptsToolDefinitions() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let modelXPrivate = try Ed25519ToX25519.privateKey(seed: modelEdKey.rawRepresentation)
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        let body: [String: Any] = [
            "model": "test-model",
            "messages": [["role": "user", "content": "Hello"]],
            "tools": [
                ["type": "function", "function": [
                    "name": "brave_search",
                    "description": "Search the web",
                    "parameters": ["type": "object", "properties": [
                        "query": ["type": "string"]
                    ]]
                ] as [String: Any]]
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let encrypted = try session.encryptRequestBody(bodyData)

        let result = try JSONSerialization.jsonObject(with: encrypted) as! [String: Any]
        let tools = result["tools"] as! [[String: Any]]
        let fn = tools[0]["function"] as! [String: Any]

        // Tool definition name should be encrypted.
        let encName = fn["name"] as! String
        #expect(encName != "brave_search")

        let namePlain = try E2EEEnvelope.open(
            wireFormat: Data(hexString: encName), privateKey: modelXPrivate
        )
        #expect(String(data: namePlain, encoding: .utf8) == "brave_search")
    }

    // MARK: Response-side: decrypt tool_calls in streaming SSE

    @Test func streamingToolCallDeltas_decryptArgsPerChunk() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        // Simulate model encrypting tool call argument fragments.
        let argFragments = ["{\"query\":", "\"weather ", "today\"}"]
        var decryptedArgs = ""

        for fragment in argFragments {
            let wire = try E2EEEnvelope.seal(
                plaintext: Data(fragment.utf8),
                recipientPubKey: session.agreementKey.publicKey
            )
            let hexEncrypted = wire.hexString

            // Client decrypts each fragment independently, then concatenates.
            let plainFragment = try session.decrypt(hexEncrypted)
            decryptedArgs += plainFragment
        }

        #expect(decryptedArgs == "{\"query\":\"weather today\"}")
    }

    @Test func streamingToolCallName_decrypted() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)

        // The tool call name comes in one chunk, encrypted.
        let name = "brave_search"
        let wire = try E2EEEnvelope.seal(
            plaintext: Data(name.utf8),
            recipientPubKey: session.agreementKey.publicKey
        )
        let decrypted = try session.decrypt(wire.hexString)
        #expect(decrypted == name)
    }

    // MARK: Header

    @Test func headers_includeEncryptAllFields() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)
        let h = session.headers
        #expect(h["X-Encrypt-All-Fields"] == "true")
    }
}

// MARK: - isE2EEActive flag

@Suite("isE2EEActive propagation")
struct E2EEActiveFlagTests {

    @Test func requestResult_flagReflectsSessionPresence() {
        let resultWithE2EE = RequestResult(
            url: nil, requestHeaders: nil, requestBodyJSON: nil,
            responseBody: nil, toolCalls: [], outputTokens: nil,
            teeVerification: nil, isE2EEActive: true
        )
        #expect(resultWithE2EE.isE2EEActive == true)

        let resultWithoutE2EE = RequestResult(
            url: nil, requestHeaders: nil, requestBodyJSON: nil,
            responseBody: nil, toolCalls: [], outputTokens: nil,
            teeVerification: nil, isE2EEActive: false
        )
        #expect(resultWithoutE2EE.isE2EEActive == false)
    }

    @Test func debugInfo_preservesE2EEFlag() {
        let info = LastRequestDebugInfo(
            providerName: "near.ai", url: nil,
            requestHeaders: nil, requestBodyJSON: nil,
            responseBody: nil, toolCalls: [],
            threadID: UUID(), totalDuration: nil,
            timeToFirstToken: nil, outputTokens: nil,
            isE2EEActive: true, teeVerification: nil
        )
        #expect(info.isE2EEActive == true)

        let infoOff = LastRequestDebugInfo(
            providerName: "OpenAI", url: nil,
            requestHeaders: nil, requestBodyJSON: nil,
            responseBody: nil, toolCalls: [],
            threadID: UUID(), totalDuration: nil,
            timeToFirstToken: nil, outputTokens: nil,
            isE2EEActive: false, teeVerification: nil
        )
        #expect(infoOff.isE2EEActive == false)
    }
}
