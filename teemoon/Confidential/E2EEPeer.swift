//
//  E2EEPeer.swift
//  teemoon
//
//  Implements the near.ai E2EE v2 protocol on top of XChaChaPoly.
//
//  Protocol: https://docs.near.ai/cloud/guides/e2ee-chat-completions/
//
//  Encryption (E2EEEnvelope):
//    1. Ephemeral X25519 ECDH → shared secret
//    2. HKDF-SHA256(shared, info: "ed25519_encryption") → 32-byte key
//    3. XChaCha20-Poly1305 (see XChaChaPoly.swift)
//    4. Wire format: ephemeral_pub (32) || nonce (24) || ciphertext+tag
//
//  Ed25519→X25519 conversion (Ed25519ToX25519 + Fe) uses GF(2^255-19)
//  arithmetic ported from TweetNaCl (public domain, tweetnacl.cr.yp.to);
//  `pubKeyConversion_matchesCryptoKit` cross-checks it against CryptoKit.
//

import CryptoKit
import Foundation

// MARK: - E2EE peer

/// The client's key material paired with one model's public identity —
/// everything needed to encrypt requests to, and decrypt responses from,
/// a specific attested model.
final class E2EEPeer: @unchecked Sendable {
    /// Client Ed25519 signing key (public key goes in X-Client-Pub-Key header).
    let signingKey: Curve25519.Signing.PrivateKey
    /// Client X25519 key derived from the Ed25519 seed (used to decrypt responses).
    let agreementKey: Curve25519.KeyAgreement.PrivateKey
    /// Model's X25519 public key (converted from Ed25519).
    let modelX25519PubKey: Curve25519.KeyAgreement.PublicKey

    /// Ed25519 public key hex for the X-Client-Pub-Key header.
    var clientPubKeyHex: String {
        signingKey.publicKey.rawRepresentation.hexString
    }

    /// Model's Ed25519 public key hex for the X-Model-Pub-Key header.
    let modelPubKeyHex: String

    init(modelEd25519PubKey: Data) throws {
        self.signingKey = Curve25519.Signing.PrivateKey()
        self.agreementKey = try Ed25519ToX25519.privateKey(
            seed: signingKey.rawRepresentation
        )
        self.modelX25519PubKey = try Ed25519ToX25519.publicKey(edPub: modelEd25519PubKey)
        self.modelPubKeyHex = modelEd25519PubKey.hexString
    }

    /// TEST SEAM (internal): a peer around a raw X25519 model key, BYPASSING
    /// the conversion guard above. Exists so the exploit suite can pin the
    /// layer below the guard — ECDH against a low-order key must throw
    /// mid-seal with nothing touching the wire — even though `publicKey(edPub:)`
    /// now refuses to build such a peer at all.
    init(bypassingConversionWith modelKey: Curve25519.KeyAgreement.PublicKey,
         modelPubKeyHex: String) throws {
        self.signingKey = Curve25519.Signing.PrivateKey()
        self.agreementKey = try Ed25519ToX25519.privateKey(
            seed: signingKey.rawRepresentation
        )
        self.modelX25519PubKey = modelKey
        self.modelPubKeyHex = modelPubKeyHex
    }

    /// HTTP headers for E2EE requests.
    var headers: [String: String] {
        [
            "X-Signing-Algo": "ed25519",
            "X-Client-Pub-Key": clientPubKeyHex,
            "X-Model-Pub-Key": modelPubKeyHex,
            "X-Encryption-Version": "2",
            "X-Encrypt-All-Fields": "true",
        ]
    }

    /// Encrypts plaintext for the model. Returns hex-encoded wire format.
    func encrypt(_ plaintext: String) throws -> String {
        try E2EEEnvelope.seal(
            plaintext: Data(plaintext.utf8),
            recipientPubKey: modelX25519PubKey
        ).hexString
    }

    /// Decrypts hex-encoded wire format from the model.
    func decrypt(_ hex: String) throws -> String {
        let data = try Data(hexString: hex)
        let decrypted = try E2EEEnvelope.open(wireFormat: data, privateKey: agreementKey)
        guard let text = String(data: decrypted, encoding: .utf8) else {
            throw E2EEError.invalidUTF8
        }
        return text
    }

    /// Encrypts every field near.ai's E2EE spec puts behind
    /// `X-Encrypt-All-Fields: true`, which this client always sends.
    ///
    /// Per docs.near.ai/cloud/guides/e2ee-chat-completions, the flag covers, on
    /// the request side: `tools[].function.{name, description, parameters}`,
    /// `tool_choice.function.name`, message `name` and `refusal`, and
    /// `tool_calls[].function.{name, arguments}`.
    ///
    /// This used to seal only `tools[].function.name`, which bought nothing:
    /// `description` went out in the clear reading "Search the web for current,
    /// real-time information…", so the gateway could identify the tool exactly
    /// despite the encrypted name. Asserting the header while leaving the
    /// fields it names in plaintext is the worst of both — it claims a property
    /// it does not have.
    ///
    /// `parameters` is a JSON schema, not a string: the spec says to serialize
    /// it and encrypt it whole, so that is what happens here.
    func encryptRequestBody(_ body: Data) throws -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]]
        else { return body }

        let encrypted: [[String: Any]] = try messages.map { msg in
            var m = msg
            if let content = msg["content"] as? String, !content.isEmpty {
                m["content"] = try encrypt(content)
            }
            // `name` identifies the speaker and `refusal` is model-authored
            // prose; the spec lists both.
            if let name = msg["name"] as? String, !name.isEmpty {
                m["name"] = try encrypt(name)
            }
            if let refusal = msg["refusal"] as? String, !refusal.isEmpty {
                m["refusal"] = try encrypt(refusal)
            }
            // Encrypt tool_calls[].function.name and .arguments.
            if let toolCalls = msg["tool_calls"] as? [[String: Any]] {
                m["tool_calls"] = try toolCalls.map { tc in
                    var t = tc
                    if var fn = tc["function"] as? [String: Any] {
                        if let name = fn["name"] as? String, !name.isEmpty {
                            fn["name"] = try encrypt(name)
                        }
                        if let args = fn["arguments"] as? String, !args.isEmpty {
                            fn["arguments"] = try encrypt(args)
                        }
                        t["function"] = fn
                    }
                    return t
                }
            }
            return m
        }
        json["messages"] = encrypted

        // Tool definitions: name, description, and the parameters schema.
        if let tools = json["tools"] as? [[String: Any]] {
            json["tools"] = try tools.map { tool in
                var t = tool
                if var fn = tool["function"] as? [String: Any] {
                    if let name = fn["name"] as? String, !name.isEmpty {
                        fn["name"] = try encrypt(name)
                    }
                    if let description = fn["description"] as? String, !description.isEmpty {
                        fn["description"] = try encrypt(description)
                    }
                    // Serialized whole, then encrypted as one string — the
                    // schema is an object, and encrypting it key-by-key would
                    // leave its shape (property names, required list) readable,
                    // which is most of what it discloses.
                    //
                    // `.sortedKeys` so the ciphertext is not gratuitously
                    // different per request for an identical schema.
                    if let parameters = fn["parameters"] as? [String: Any], !parameters.isEmpty,
                       let data = try? JSONSerialization.data(withJSONObject: parameters,
                                                             options: [.sortedKeys]),
                       let text = String(data: data, encoding: .utf8) {
                        fn["parameters"] = try encrypt(text)
                    }
                    t["function"] = fn
                }
                return t
            }
        }

        // tool_choice, when the caller pinned a specific function.
        if var choice = json["tool_choice"] as? [String: Any],
           var fn = choice["function"] as? [String: Any],
           let name = fn["name"] as? String, !name.isEmpty {
            fn["name"] = try encrypt(name)
            choice["function"] = fn
            json["tool_choice"] = choice
        }

        return try JSONSerialization.data(withJSONObject: json)
    }
}

enum E2EEError: Error, LocalizedError {
    case invalidHex
    case invalidUTF8
    case invalidKeyLength
    case decryptionFailed
    /// An Ed25519→X25519 conversion produced a small-order/degenerate point.
    /// Fail-closed at construction: no peer exists, so no send is possible
    /// under the E2EE promise.
    case lowOrderPublicKey
    /// A request that promised sealing could not be encrypted. Fail-closed:
    /// the transport throws this BEFORE anything touches the wire — plaintext
    /// is never sent as a fallback under an E2EE promise.
    case encryptionFailed

    var errorDescription: String? {
        switch self {
        case .invalidHex: "Invalid hex string"
        case .lowOrderPublicKey: "Model public key converts to a low-order point"
        case .invalidUTF8: "Decrypted data is not valid UTF-8"
        case .invalidKeyLength: "Invalid key length (expected 32 bytes)"
        case .decryptionFailed: "Decryption failed"
        case .encryptionFailed: "Encryption failed — the request was not sent"
        }
    }
}

// MARK: - E2EE envelope (wire format)

/// The near.ai v2 wire envelope: ephemeral-key hybrid encryption around
/// XChaChaPoly. `ephemeral_pub (32) || nonce (24) || ciphertext+tag`.
enum E2EEEnvelope {

    static func seal(plaintext: Data, recipientPubKey: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPubKey)
        let key = deriveKey(from: shared)

        // XChaChaPoly.seal draws its nonce from the system CSPRNG and throws
        // on RNG failure — a predictable nonce is unrepresentable.
        let box = try XChaChaPoly.seal(plaintext, using: key)

        return ephemeral.publicKey.rawRepresentation + box.combined
    }

    static func open(wireFormat data: Data, privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard data.count >= 32 + 24 + 16 else { throw E2EEError.decryptionFailed }
        let ephPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data.prefix(32))
        let box = try XChaChaPoly.SealedBox(combined: data.dropFirst(32))

        let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephPub)
        let key = deriveKey(from: shared)
        do {
            return try XChaChaPoly.open(box, using: key)
        } catch {
            throw E2EEError.decryptionFailed
        }
    }

    private static func deriveKey(from shared: SharedSecret) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("ed25519_encryption".utf8),
            outputByteCount: 32
        )
    }
}

// MARK: - Ed25519 → X25519 key conversion

enum Ed25519ToX25519 {

    /// Converts an Ed25519 seed to an X25519 private key via SHA-512 + clamping
    /// (RFC 8032 §5.1.5 scalar derivation).
    static func privateKey(seed: Data) throws -> Curve25519.KeyAgreement.PrivateKey {
        let hash = SHA512.hash(data: seed)
        var h = Array(hash.prefix(32))
        h[0] &= 248
        h[31] &= 127
        h[31] |= 64
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(h))
    }

    /// Converts an Ed25519 public key to X25519 via the birational map
    /// u = (1+y)/(1-y) mod p (RFC 7748 §4.1).
    static func publicKey(edPub: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        guard edPub.count == 32 else { throw E2EEError.invalidKeyLength }
        var bytes = Array(edPub)
        bytes[31] &= 0x7f  // clear sign bit → y coordinate

        let y = Fe.unpack(bytes)
        let num = Fe.add(Fe.one, y)
        let den = Fe.sub(Fe.one, y)
        let u = Data(Fe.pack(Fe.mul(num, Fe.invert(den))))

        // Small-order / degenerate results are REJECTED here, explicitly.
        // ECDH against any of these yields an all-zero or attacker-fixed
        // shared secret; CryptoKit would throw later at key agreement, but a
        // peer must fail to EXIST rather than fail to seal. `pack()` reduces
        // mod p, so only the canonical encodings below can ever appear.
        guard !Self.lowOrderUHex.contains(u.hexString.lowercased()) else {
            throw E2EEError.lowOrderPublicKey
        }
        return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: u)
    }

    /// Canonical low-order X25519 u-coordinates (libsodium's blocklist,
    /// canonical-encoding subset): u = 0, u = 1, the two order-8 points,
    /// and p − 1 (order 2).
    private static let lowOrderUHex: Set<String> = [
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0100000000000000000000000000000000000000000000000000000000000000",
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
        "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    ]
}

// MARK: - GF(2^255-19) Field Arithmetic

/// Minimal field arithmetic for Ed25519→X25519 public key conversion.
/// Ported from TweetNaCl's 16×Int64-limb representation (public domain,
/// tweetnacl.cr.yp.to): unpack25519/pack25519/A/Z/M/inv25519/car25519.
private enum Fe {
    typealias Element = [Int64]

    static let zero: Element = .init(repeating: 0, count: 16)
    static let one: Element = {
        var a = zero; a[0] = 1; return a
    }()

    static func unpack(_ n: [UInt8]) -> Element {
        var o = zero
        for i in 0..<16 { o[i] = Int64(n[2*i]) | (Int64(n[2*i+1]) << 8) }
        o[15] &= 0x7fff
        return o
    }

    static func pack(_ n: Element) -> [UInt8] {
        var t = n
        carry(&t); carry(&t); carry(&t)
        for _ in 0..<2 {
            var m = zero
            m[0] = t[0] - 0xffed
            for i in 1..<15 {
                m[i] = t[i] - 0xffff - ((m[i-1] >> 16) & 1)
                m[i-1] &= 0xffff
            }
            m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
            let b = (m[15] >> 16) & 1
            m[14] &= 0xffff
            for i in 0..<16 { t[i] = t[i] &* b &+ m[i] &* (1 &- b) }
        }
        var o = [UInt8](repeating: 0, count: 32)
        for i in 0..<16 {
            o[2*i]   = UInt8(truncatingIfNeeded: t[i])
            o[2*i+1] = UInt8(truncatingIfNeeded: t[i] >> 8)
        }
        return o
    }

    static func add(_ a: Element, _ b: Element) -> Element {
        (0..<16).map { a[$0] + b[$0] }
    }

    static func sub(_ a: Element, _ b: Element) -> Element {
        (0..<16).map { a[$0] - b[$0] }
    }

    static func mul(_ a: Element, _ b: Element) -> Element {
        var t = [Int64](repeating: 0, count: 31)
        for i in 0..<16 { for j in 0..<16 { t[i+j] &+= a[i] &* b[j] } }
        for i in stride(from: 30, through: 16, by: -1) { t[i-16] &+= 38 &* t[i] }
        var o = Array(t[0..<16])
        carry(&o); carry(&o)
        return o
    }

    /// a^(p-2) mod p via square-and-multiply. p-2 = 2^255-21, bits 2 and 4 are zero.
    static func invert(_ a: Element) -> Element {
        var c = a
        for i in stride(from: 253, through: 0, by: -1) {
            c = mul(c, c)
            if i != 2 && i != 4 { c = mul(c, a) }
        }
        return c
    }

    private static func carry(_ o: inout Element) {
        for i in 0..<16 {
            o[i] += (1 << 16)
            let c = o[i] >> 16
            o[i] -= c << 16
            if i < 15 { o[i+1] += c - 1 } else { o[0] += 38 * (c - 1) }
        }
    }
}
