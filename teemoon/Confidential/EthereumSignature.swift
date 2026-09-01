//
//  EthereumSignature.swift
//  teemoon
//
//  EIP-191 `personal_sign` recovery (ecrecover) for near.ai per-response
//  signatures: recover the secp256k1 public key from the 65-byte r‖s‖v
//  signature over keccak256("\x19Ethereum Signed Message:\n" + len + text),
//  and derive the Ethereum address (keccak256(pubkey)[12...]).
//
//  Uses the libsecp256k1 C API directly (the recovery module) rather than
//  the P256K Swift wrapper: the wrapper fatalErrors when
//  secp256k1_ecdsa_recover fails, and recovery failure is a normal outcome
//  for attacker-supplied signatures (~half of random r values have no curve
//  point), which must be an error, not a crash.
//

import Foundation
import libsecp256k1

enum EthereumSignature {

    /// Recovers the Ethereum address that produced `signatureHex` over `text`
    /// via EIP-191 personal_sign. Returns a lowercase 0x-address, or nil for
    /// any malformed or unrecoverable signature (never crashes on bad input).
    static func recoverAddress(text: String, signatureHex: String) -> String? {
        let hex = signatureHex.hasPrefix("0x") ? String(signatureHex.dropFirst(2)) : signatureHex
        guard let sig = try? Data(hexString: hex), sig.count == 65 else { return nil }
        let bytes = [UInt8](sig)

        // v is 27/28 (Ethereum) or already 0..3.
        var recid = Int32(bytes[64])
        if recid >= 27 { recid -= 27 }
        guard (0...3).contains(recid) else { return nil }

        let digest = [UInt8](personalSignDigest(text: text))

        guard let context = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else { return nil }
        defer { secp256k1_context_destroy(context) }

        var recoverable = secp256k1_ecdsa_recoverable_signature()
        guard secp256k1_ecdsa_recoverable_signature_parse_compact(
            context, &recoverable, Array(bytes[0..<64]), recid) == 1 else { return nil }

        var pubkey = secp256k1_pubkey()
        guard secp256k1_ecdsa_recover(context, &pubkey, &recoverable, digest) == 1 else { return nil }

        var serialized = [UInt8](repeating: 0, count: 65)
        var length = serialized.count
        guard secp256k1_ec_pubkey_serialize(
            context, &serialized, &length, &pubkey, UInt32(SECP256K1_EC_UNCOMPRESSED)) == 1,
            length == 65 else { return nil }

        // Address = last 20 bytes of keccak256(uncompressed pubkey minus 0x04 prefix).
        let hash = Keccak256.hash(Data(serialized[1..<65]))
        return "0x" + hash.suffix(20).hexString
    }

    /// keccak256("\x19Ethereum Signed Message:\n" + byte-length + text).
    static func personalSignDigest(text: String) -> Data {
        let body = Data(text.utf8)
        var message = Data("\u{19}Ethereum Signed Message:\n\(body.count)".utf8)
        message.append(body)
        return Keccak256.hash(message)
    }
}
