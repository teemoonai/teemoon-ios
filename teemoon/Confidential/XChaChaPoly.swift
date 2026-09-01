//
//  XChaChaPoly.swift
//  teemoon
//
//  XChaCha20-Poly1305 AEAD in the shape of CryptoKit's ChaChaPoly.
//  XChaCha20 = HChaCha20 subkey derivation (pure Swift, below) + CryptoKit's
//  ChaChaPoly for the actual AEAD, so all secret-dependent cipher work stays
//  in CryptoKit.
//
//  Spec: draft-irtf-cfrg-xchacha-03.
//    - HChaCha20 follows §2.2; reference implementation is libsodium's
//      crypto_core_hchacha20.
//    - Subkey/subnonce construction follows §2.3.
//  The §2.2.1 HChaCha20 vector and the §A.3.1 AEAD vector are pinned in
//  XChaChaPolyTests as known-answer tests.
//

import CryptoKit
import Foundation

enum XChaChaPoly {

    enum Error: Swift.Error, Equatable {
        /// The system CSPRNG failed. Sealing MUST fail rather than fall back
        /// to a predictable nonce.
        case randomGeneratorFailure(OSStatus)
        case incorrectNonceSize
        case incorrectCombinedSize
    }

    /// A 192-bit nonce for XChaCha20-Poly1305.
    ///
    /// `init()` draws from the system CSPRNG and throws on failure — an
    /// all-zero "fallback" nonce is unrepresentable by construction.
    struct Nonce: ContiguousBytes, Sendable {
        let bytes: [UInt8]  // exactly 24

        init() throws {
            var b = [UInt8](repeating: 0, count: 24)
            let status = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
            guard status == errSecSuccess else {
                throw Error.randomGeneratorFailure(status)
            }
            self.bytes = b
        }

        init(data: some DataProtocol) throws {
            guard data.count == 24 else { throw Error.incorrectNonceSize }
            self.bytes = Array(data)
        }

        func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
            try bytes.withUnsafeBytes(body)
        }
    }

    /// Nonce, ciphertext, and authentication tag — mirrors ChaChaPoly.SealedBox.
    struct SealedBox: Sendable {
        let nonce: Nonce
        let ciphertext: Data
        let tag: Data

        /// `nonce || ciphertext || tag`, matching ChaChaPoly.SealedBox.combined.
        var combined: Data { Data(nonce.bytes) + ciphertext + tag }

        init(nonce: Nonce, ciphertext: Data, tag: Data) {
            self.nonce = nonce
            self.ciphertext = ciphertext
            self.tag = tag
        }

        init(combined: some DataProtocol) throws {
            guard combined.count >= 24 + 16 else { throw Error.incorrectCombinedSize }
            let data = Data(combined)
            self.nonce = try Nonce(data: data.prefix(24))
            self.ciphertext = Data(data.dropFirst(24).dropLast(16))
            self.tag = Data(data.suffix(16))
        }
    }

    // MARK: Seal / open

    static func seal(
        _ message: some DataProtocol, using key: SymmetricKey, nonce: Nonce? = nil
    ) throws -> SealedBox {
        try seal(message, using: key, nonce: nonce, authenticating: Data())
    }

    static func seal(
        _ message: some DataProtocol, using key: SymmetricKey, nonce: Nonce? = nil,
        authenticating authenticatedData: some DataProtocol
    ) throws -> SealedBox {
        let nonce = try nonce ?? Nonce()
        let (subkey, subnonce) = deriveSubkeyAndNonce(key: key, nonce: nonce)
        let box = try ChaChaPoly.seal(
            message,
            using: subkey,
            nonce: ChaChaPoly.Nonce(data: subnonce),
            authenticating: authenticatedData
        )
        return SealedBox(nonce: nonce, ciphertext: box.ciphertext, tag: box.tag)
    }

    static func open(_ sealedBox: SealedBox, using key: SymmetricKey) throws -> Data {
        try open(sealedBox, using: key, authenticating: Data())
    }

    static func open(
        _ sealedBox: SealedBox, using key: SymmetricKey,
        authenticating authenticatedData: some DataProtocol
    ) throws -> Data {
        let (subkey, subnonce) = deriveSubkeyAndNonce(key: key, nonce: sealedBox.nonce)
        let box = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: subnonce),
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        return try ChaChaPoly.open(box, using: subkey, authenticating: authenticatedData)
    }

    /// §2.3: subkey = HChaCha20(key, nonce[0..16]); ChaCha20 nonce = 4 zero
    /// bytes || nonce[16..24].
    private static func deriveSubkeyAndNonce(key: SymmetricKey, nonce: Nonce) -> (SymmetricKey, [UInt8]) {
        let keyBytes = key.withUnsafeBytes { Array($0) }
        let subkeyBytes = hchacha20(key: keyBytes, input: Array(nonce.bytes[0..<16]))
        let subnonce = [UInt8](repeating: 0, count: 4) + Array(nonce.bytes[16..<24])
        return (SymmetricKey(data: subkeyBytes), subnonce)
    }

    // MARK: HChaCha20 (§2.2)

    /// Derives a 256-bit subkey from a 256-bit key and 128-bit input.
    /// This is the "X" in XChaCha20 — extends ChaCha20's 96-bit nonce to 192 bits.
    /// Internal (not private) so the §2.2.1 known-answer test can pin it directly.
    static func hchacha20(key: [UInt8], input: [UInt8]) -> [UInt8] {
        var s: [UInt32] = [
            0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
            le32(key, 0),   le32(key, 4),   le32(key, 8),   le32(key, 12),
            le32(key, 16),  le32(key, 20),  le32(key, 24),  le32(key, 28),
            le32(input, 0), le32(input, 4), le32(input, 8), le32(input, 12),
        ]
        for _ in 0..<10 {
            qr(&s, 0, 4, 8, 12);  qr(&s, 1, 5, 9, 13)
            qr(&s, 2, 6, 10, 14); qr(&s, 3, 7, 11, 15)
            qr(&s, 0, 5, 10, 15); qr(&s, 1, 6, 11, 12)
            qr(&s, 2, 7, 8, 13);  qr(&s, 3, 4, 9, 14)
        }
        var out = [UInt8](repeating: 0, count: 32)
        put32(&out, 0, s[0]);   put32(&out, 4, s[1])
        put32(&out, 8, s[2]);   put32(&out, 12, s[3])
        put32(&out, 16, s[12]); put32(&out, 20, s[13])
        put32(&out, 24, s[14]); put32(&out, 28, s[15])
        return out
    }

    private static func qr(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] &+= s[b]; s[d] ^= s[a]; s[d] = (s[d] << 16) | (s[d] >> 16)
        s[c] &+= s[d]; s[b] ^= s[c]; s[b] = (s[b] << 12) | (s[b] >> 20)
        s[a] &+= s[b]; s[d] ^= s[a]; s[d] = (s[d] <<  8) | (s[d] >> 24)
        s[c] &+= s[d]; s[b] ^= s[c]; s[b] = (s[b] <<  7) | (s[b] >> 25)
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24
    }

    private static func put32(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
        b[i] = UInt8(v & 0xff); b[i+1] = UInt8(v >> 8 & 0xff)
        b[i+2] = UInt8(v >> 16 & 0xff); b[i+3] = UInt8(v >> 24 & 0xff)
    }
}
