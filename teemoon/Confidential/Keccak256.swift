//
//  Keccak256.swift
//  teemoon
//
//  Keccak-256 (the pre-NIST original with 0x01 domain padding, as used by
//  Ethereum — NOT SHA3-256, whose padding byte is 0x06 and which CryptoKit
//  provides). Needed for EIP-191 message hashing and Ethereum address
//  derivation in response-signature verification.
//
//  Straightforward Keccak-f[1600] sponge, rate 1088 bits (136 bytes).
//  Validated against the standard vectors in Keccak256Tests.
//

import Foundation

enum Keccak256 {

    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]

    /// Rotation offsets, indexed [x + 5y].
    private static let rho: [UInt64] = [
        0, 1, 62, 28, 27,
        36, 44, 6, 55, 20,
        3, 10, 43, 25, 39,
        41, 45, 15, 21, 8,
        18, 2, 61, 56, 14,
    ]

    static func hash(_ message: Data) -> Data {
        let rate = 136  // 1088-bit rate for 256-bit output
        var state = [UInt64](repeating: 0, count: 25)

        // Pad: message ‖ 0x01 ‖ 0…0 ‖ 0x80 (last byte OR'd).
        var padded = [UInt8](message)
        padded.append(0x01)
        while padded.count % rate != 0 { padded.append(0x00) }
        padded[padded.count - 1] |= 0x80

        // Absorb.
        for blockStart in stride(from: 0, to: padded.count, by: rate) {
            for lane in 0..<(rate / 8) {
                var word: UInt64 = 0
                for byte in 0..<8 {
                    word |= UInt64(padded[blockStart + lane * 8 + byte]) << (8 * UInt64(byte))
                }
                state[lane] ^= word
            }
            keccakF(&state)
        }

        // Squeeze 32 bytes.
        var out = Data(capacity: 32)
        for lane in 0..<4 {
            var word = state[lane]
            for _ in 0..<8 {
                out.append(UInt8(truncatingIfNeeded: word))
                word >>= 8
            }
        }
        return out
    }

    private static func keccakF(_ a: inout [UInt64]) {
        for round in 0..<24 {
            // θ
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 { c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20] }
            for x in 0..<5 {
                let d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1)
                for y in 0..<5 { a[x + 5 * y] ^= d }
            }
            // ρ and π
            var b = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 {
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(a[x + 5 * y], rho[x + 5 * y])
                }
            }
            // χ
            for x in 0..<5 {
                for y in 0..<5 {
                    a[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y])
                }
            }
            // ι
            a[0] ^= roundConstants[round]
        }
    }

    private static func rotl(_ value: UInt64, _ by: UInt64) -> UInt64 {
        by == 0 ? value : (value << by) | (value >> (64 - by))
    }
}
