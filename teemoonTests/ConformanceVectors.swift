//
//  ConformanceVectors.swift
//  teemoonTests
//
//  Phase 0 of the Android port: the conformance kit.
//  Golden vectors are generated HERE, in Swift, from the production code paths,
//  and vendored by teemoon-android. Acceptance for every ported module is its
//  fixture suite green on the JVM — "correct" is bytes, not prose.
//
//  Two rules this file exists to enforce, both learned the hard way:
//
//  1. GENERATION MUST BE DETERMINISTIC. §13.2 makes CI run the generator and
//     `git diff --exit-code conformance/` as a freshness gate. A generator that
//     draws from the CSPRNG produces a diff on every run, and the gate becomes
//     noise everyone learns to ignore. So every input here is a frozen
//     constant and every output is recomputed from it.
//
//     This bites immediately: `E2EEEnvelope.seal` draws BOTH a random ephemeral
//     key and a random nonce (deliberately — see its comment: "a predictable
//     nonce is unrepresentable"). So the envelope vector is assembled from the
//     documented wire layout with fixed keys and a fixed nonce, and then PROVED
//     by handing it to the production `E2EEEnvelope.open`. If the assembly and
//     production ever disagree, `envelopeOpensUnderProduction` fails here — the
//     vector cannot silently encode a fiction.
//
//  2. THE VECTORS ARE ROUND-TRIPPED, NOT JUST WRITTEN. Every vector is asserted
//     against the production API in `ConformanceRoundTripTests`, which runs on
//     every CI pass whether or not anyone regenerates. This is the Phase 0 gate
//     ("vectors round-trip against the existing Swift suite"), and it is what
//     stops the kit from rotting into a record of what the app used to do.
//
//  Emission is `.enabled(if:)` on both an env var and source-tree availability:
//  it writes into the repo, so it is a local `make conformance` step, never
//  something a CI or on-device run does. See TestFixture.sourceTreeAvailable.
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

// MARK: - Vector model

/// One fixture class of the kit. `version` is the stamp teemoon-android pins
/// (§13.6: kit stamp, ports-map baseline and followed tag fold into one ref).
struct ConformanceDocument<Body: Encodable>: Encodable {
    let kitVersion: String
    let fixtureClass: String
    let sourceOfTruth: String
    let vectors: Body
}

/// §7 item 1 — crypto known-answer tests.
struct CryptoVectors: Encodable {

    struct HChaCha20Vector: Encodable {
        let note: String
        let key: String
        let input: String
        let output: String
    }

    struct AEADVector: Encodable {
        let note: String
        let key: String
        let nonce: String
        let aad: String
        let plaintext: String
        let ciphertext: String
        let tag: String
    }

    struct Ed25519ToX25519Vector: Encodable {
        let ed25519Seed: String
        let ed25519PublicKey: String
        let x25519PrivateKey: String
        let x25519PublicKeyFromPrivate: String
        let x25519PublicKeyFromEdPublic: String
    }

    struct KeccakVector: Encodable {
        let note: String
        let messageUTF8: String?
        let messageHex: String?
        let digest: String
    }

    struct EcrecoverVector: Encodable {
        let note: String
        let text: String
        let signature: String
        let expectedAddress: String?
        let personalSignDigest: String?
    }

    struct EnvelopeVector: Encodable {
        let note: String
        let recipientX25519PrivateKey: String
        let recipientX25519PublicKey: String
        let ephemeralX25519PrivateKey: String
        let ephemeralX25519PublicKey: String
        let hkdfSalt: String
        let hkdfInfoUTF8: String
        let derivedKey: String
        let nonce: String
        let plaintextUTF8: String
        let wireFormat: String
    }

    let hchacha20: [HChaCha20Vector]
    let xchachaAEAD: [AEADVector]
    let ed25519ToX25519: [Ed25519ToX25519Vector]
    let keccak256: [KeccakVector]
    let ecrecover: [EcrecoverVector]
    let e2eeEnvelope: [EnvelopeVector]
}

// MARK: - Frozen inputs

/// Every input the generator consumes. Nothing here may ever be regenerated
/// randomly; changing a value here is a deliberate, reviewable act.
enum ConformanceInputs {

    /// draft-irtf-cfrg-xchacha-03 §2.2.1.
    static let hchachaKey: [UInt8] = Array(0x00...0x1f)
    static let hchachaInput: [UInt8] = [
        0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x4a,
        0x00, 0x00, 0x00, 0x00, 0x31, 0x41, 0x59, 0x27,
    ]

    /// draft-irtf-cfrg-xchacha-03 §A.3.1.
    static let aeadKeyHex =
        "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"
    static let aeadNonceHex = "404142434445464748494a4b4c4d4e4f5051525354555657"
    static let aeadAADHex = "50515253c0c1c2c3c4c5c6c7"
    static let aeadPlaintextHex =
        "4c616469657320616e642047656e746c656d656e206f662074686520636c6173" +
        "73206f66202739393a204966204920636f756c64206f6666657220796f75206f" +
        "6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73" +
        "637265656e20776f756c642062652069742e"

    /// Ed25519 seeds. Arbitrary but FIXED — 32 bytes each, counting patterns so
    /// a reader can see at a glance that they are test material, not a leak.
    static let edSeeds: [String] = [
        String(repeating: "00", count: 32),
        String(repeating: "01", count: 32),
        (0..<32).map { String(format: "%02x", $0) }.joined(),
        (0..<32).map { String(format: "%02x", 255 - $0) }.joined(),
    ]

    /// The envelope vector's two keys and its nonce, all fixed.
    static let recipientSeed = String(repeating: "a1", count: 32)
    static let ephemeralSeed = String(repeating: "b2", count: 32)
    static let envelopeNonceHex = "000102030405060708090a0b0c0d0e0f1011121314151617"
    static let envelopePlaintext = "the quick brown fox jumps over the lazy dog"

    /// The envelope's KDF parameters, as `E2EEEnvelope.deriveKey` uses them.
    /// Duplicated here because that method is private; the duplication is what
    /// `envelopeOpensUnderProduction` proves faithful.
    static let hkdfInfo = "ed25519_encryption"
}

// MARK: - Builders

enum ConformanceVectors {

    static let kitVersion = "0.5.0"

    static func crypto(file: String = #filePath) throws -> CryptoVectors {
        CryptoVectors(
            hchacha20: [hchachaVector()],
            xchachaAEAD: [try aeadVector()],
            ed25519ToX25519: try ConformanceInputs.edSeeds.map(edConversionVector),
            keccak256: keccakVectors(),
            ecrecover: try ecrecoverVectors(file: file),
            e2eeEnvelope: [try envelopeVector()]
        )
    }

    // MARK: KATs from the draft

    private static func hchachaVector() -> CryptoVectors.HChaCha20Vector {
        let out = XChaChaPoly.hchacha20(
            key: ConformanceInputs.hchachaKey, input: ConformanceInputs.hchachaInput)
        return .init(
            note: "draft-irtf-cfrg-xchacha-03 §2.2.1 HChaCha20 block function",
            key: Data(ConformanceInputs.hchachaKey).hexString,
            input: Data(ConformanceInputs.hchachaInput).hexString,
            output: Data(out).hexString)
    }

    private static func aeadVector() throws -> CryptoVectors.AEADVector {
        let key = SymmetricKey(data: try Data(hexString: ConformanceInputs.aeadKeyHex))
        let nonce = try XChaChaPoly.Nonce(data: try Data(hexString: ConformanceInputs.aeadNonceHex))
        let aad = try Data(hexString: ConformanceInputs.aeadAADHex)
        let plaintext = try Data(hexString: ConformanceInputs.aeadPlaintextHex)
        let box = try XChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return .init(
            note: "draft-irtf-cfrg-xchacha-03 §A.3.1 AEAD_XChaCha20_Poly1305",
            key: ConformanceInputs.aeadKeyHex,
            nonce: ConformanceInputs.aeadNonceHex,
            aad: ConformanceInputs.aeadAADHex,
            plaintext: ConformanceInputs.aeadPlaintextHex,
            ciphertext: box.ciphertext.hexString,
            tag: box.tag.hexString)
    }

    // MARK: Key conversion

    /// Both directions for the same seed. The two public keys MUST match: one
    /// comes from RFC 8032 §5.1.5 scalar derivation, the other from the RFC 7748
    /// §4.1 birational map, and a port that gets either wrong produces a peer
    /// that silently cannot decrypt.
    private static func edConversionVector(seedHex: String) throws -> CryptoVectors.Ed25519ToX25519Vector {
        let seed = try Data(hexString: seedHex)
        let edPub = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            .publicKey.rawRepresentation
        let xPriv = try Ed25519ToX25519.privateKey(seed: seed)
        let xPubFromEd = try Ed25519ToX25519.publicKey(edPub: edPub)
        return .init(
            ed25519Seed: seedHex,
            ed25519PublicKey: edPub.hexString,
            x25519PrivateKey: xPriv.rawRepresentation.hexString,
            x25519PublicKeyFromPrivate: xPriv.publicKey.rawRepresentation.hexString,
            x25519PublicKeyFromEdPublic: xPubFromEd.rawRepresentation.hexString)
    }

    // MARK: Keccak

    private static func keccakVectors() -> [CryptoVectors.KeccakVector] {
        func utf8(_ s: String, _ note: String) -> CryptoVectors.KeccakVector {
            .init(note: note, messageUTF8: s, messageHex: Data(s.utf8).hexString,
                  digest: Keccak256.hash(Data(s.utf8)).hexString)
        }
        return [
            .init(note: "empty input — Ethereum's empty account code hash",
                  messageUTF8: "", messageHex: "", digest: Keccak256.hash(Data()).hexString),
            utf8("abc", "short input, single absorb block"),
            utf8("The quick brown fox jumps over the lazy dog", "single block"),
            utf8(String(repeating: "a", count: 300),
                 "300 bytes — forces multiple absorb blocks past the 136-byte rate"),
        ]
    }

    // MARK: ecrecover

    /// Built from the REAL recorded near.ai exchange, not a synthetic signature:
    /// `Fixtures/nearai_signed_response.json` is a live streaming request with
    /// its production signature payload. The negatives are the cases
    /// `recoverAddress` must answer `nil` for rather than crash.
    private static func ecrecoverVectors(file: String) throws -> [CryptoVectors.EcrecoverVector] {
        let fixture = try EthereumSignatureTests.loadFixture(file: file)
        // `sig.text` is what the signature COVERS. The fixture also carries
        // `responseText` (the raw SSE lines joined) — that is the input to
        // content binding, a different check. Signing the wrong one of the two
        // recovers a valid-looking address that is not the signer, which is
        // exactly the failure this kit has to make impossible on the JVM.
        let text = fixture.sig.text
        let sig = fixture.sig.signature

        var vectors: [CryptoVectors.EcrecoverVector] = [
            .init(note: "production near.ai signature over the response text",
                  text: text, signature: sig,
                  expectedAddress: fixture.sig.signingAddress.lowercased(),
                  personalSignDigest: EthereumSignature.personalSignDigest(text: text).hexString),
            .init(note: "tampered text — recovers a DIFFERENT address, never the signer",
                  text: text + "x", signature: sig,
                  expectedAddress: EthereumSignature.recoverAddress(text: text + "x", signatureHex: sig),
                  personalSignDigest: EthereumSignature.personalSignDigest(text: text + "x").hexString),
        ]

        // Malformed inputs: every one of these must be nil, never a crash.
        let badRecid = String(repeating: "ab", count: 64) + "05"
        for (note, s) in [
            ("wrong length", "0xdead"),
            ("not hex", "zz"),
            ("recovery id out of range", badRecid),
        ] {
            vectors.append(.init(note: "malformed — \(note)", text: "x", signature: s,
                                 expectedAddress: nil, personalSignDigest: nil))
        }
        return vectors
    }

    // MARK: E2EE envelope

    /// The full near.ai v2 wire envelope under fixed keys and a fixed nonce:
    /// `ephemeral_pub (32) || nonce (24) || ciphertext || tag`.
    ///
    /// Assembled rather than sealed, because production seal is randomized by
    /// design. `ConformanceRoundTripTests.envelopeOpensUnderProduction` feeds
    /// this exact byte string to `E2EEEnvelope.open`, which is what makes the
    /// assembly trustworthy.
    private static func envelopeVector() throws -> CryptoVectors.EnvelopeVector {
        let recipientPriv = try Ed25519ToX25519.privateKey(
            seed: try Data(hexString: ConformanceInputs.recipientSeed))
        let ephemeralPriv = try Ed25519ToX25519.privateKey(
            seed: try Data(hexString: ConformanceInputs.ephemeralSeed))

        let shared = try ephemeralPriv.sharedSecretFromKeyAgreement(with: recipientPriv.publicKey)
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(ConformanceInputs.hkdfInfo.utf8),
            outputByteCount: 32)

        let nonce = try XChaChaPoly.Nonce(data: try Data(hexString: ConformanceInputs.envelopeNonceHex))
        let box = try XChaChaPoly.seal(
            Data(ConformanceInputs.envelopePlaintext.utf8), using: derived, nonce: nonce)
        let wire = ephemeralPriv.publicKey.rawRepresentation + box.combined

        return .init(
            note: "near.ai v2 envelope: ephemeral_pub(32) || nonce(24) || ciphertext || tag",
            recipientX25519PrivateKey: recipientPriv.rawRepresentation.hexString,
            recipientX25519PublicKey: recipientPriv.publicKey.rawRepresentation.hexString,
            ephemeralX25519PrivateKey: ephemeralPriv.rawRepresentation.hexString,
            ephemeralX25519PublicKey: ephemeralPriv.publicKey.rawRepresentation.hexString,
            hkdfSalt: "",
            hkdfInfoUTF8: ConformanceInputs.hkdfInfo,
            derivedKey: derived.withUnsafeBytes { Data($0).hexString },
            nonce: ConformanceInputs.envelopeNonceHex,
            plaintextUTF8: ConformanceInputs.envelopePlaintext,
            wireFormat: wire.hexString)
    }
}

// MARK: - Encoding

enum ConformanceEncoder {

    /// Stable bytes: sorted keys, pretty-printed, no escaped slashes, trailing
    /// newline. The freshness gate diffs this output — formatting drift would
    /// read as content drift.
    static func encode<T: Encodable>(_ document: ConformanceDocument<T>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(document) + Data("\n".utf8)
    }
}
