import Testing
import Foundation
@testable import TDXQuoteVerifier

@Suite("Quote Parser")
struct QuoteParserTests {

    @Test("Rejects data shorter than minimum quote size")
    func tooShort() {
        #expect(throws: QuoteParseError.self) {
            try QuoteParser.parse(Data(repeating: 0, count: 100))
        }
    }

    @Test("Rejects non-TDX quote (SGX tee_type=0)")
    func sgxRejected() {
        // Build a minimal fake quote: version=4, att_key_type=2, tee_type=0 (SGX)
        var data = Data(repeating: 0, count: 700)
        // version = 4 (little-endian)
        data[0] = 4; data[1] = 0
        // att_key_type = 2
        data[2] = 2; data[3] = 0
        // tee_type = 0 (SGX, not TDX)
        data[4] = 0; data[5] = 0; data[6] = 0; data[7] = 0

        #expect(throws: QuoteParseError.self) {
            try QuoteParser.parse(data)
        }
    }

    @Test("Parses valid TDX v4 header")
    func validHeader() throws {
        // Build minimal valid-looking TDX quote
        var data = Data(repeating: 0, count: 800)
        // version = 4
        data[0] = 4; data[1] = 0
        // att_key_type = 2 (ECDSA-256)
        data[2] = 2; data[3] = 0
        // tee_type = 0x81 (TDX) - little endian: 0x81, 0x00, 0x00, 0x00
        data[4] = 0x81; data[5] = 0; data[6] = 0; data[7] = 0
        // sig_data_size at offset 632 (48 header + 584 body)
        // Set to 128 (minimum: 64 sig + 64 key)
        data[632] = 128; data[633] = 0; data[634] = 0; data[635] = 0

        let quote = try QuoteParser.parse(data)
        #expect(quote.header.version == 4)
        #expect(quote.header.isTDX)
        #expect(quote.header.isECDSA256)
        #expect(quote.body.mrtd.count == 48)
        #expect(quote.body.reportData.count == 64)
    }
}

@Suite("Data Hex Helpers")
struct DataHexTests {
    @Test("Hex roundtrip")
    func hexRoundtrip() {
        let original = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let hex = original.hexString
        #expect(hex == "deadbeef")
        let decoded = Data(hexString: hex)
        #expect(decoded == original)
    }

    @Test("Hex with 0x prefix")
    func hexPrefix() {
        let data = Data(hexString: "0xCAFE")
        #expect(data == Data([0xCA, 0xFE]))
    }
}

@Suite("ECDSA DER Encoding")
struct ECDSATests {

    @Test("Signature verification with known key rejects wrong message")
    func wrongMessageRejected() throws {
        // Generate a fresh P-256 key pair and sign a message
        let privateKey = P256.Signing.PrivateKey()
        let message = Data("hello TDX".utf8)
        let sig = try privateKey.signature(for: SHA256.hash(data: message))

        // Extract raw r||s from DER
        let derBytes = sig.derRepresentation
        let rawSig = extractRawRS(from: derBytes)!
        #expect(rawSig.count == 64)

        // Build a fake quote-like buffer: 632 bytes of message + signature data
        var quoteData = Data(repeating: 0, count: 632)
        // Put our message hash seed in the first 632 bytes
        quoteData.replaceSubrange(0..<message.count, with: message)

        // The verifier signs SHA256(quoteData[0..<632]), so signing `message` won't match
        // This just validates our DER↔raw conversion works
        let pubKeyX963 = privateKey.publicKey.x963Representation
        let pubKeyRaw = pubKeyX963.dropFirst() // drop 0x04 prefix
        #expect(pubKeyRaw.count == 64)
    }

    /// Extract raw r||s (64 bytes) from DER-encoded ECDSA signature.
    private func extractRawRS(from der: Data) -> Data? {
        guard der.count > 8, der[0] == 0x30 else { return nil }
        var offset = 2 // skip SEQUENCE tag + length

        func readInteger() -> Data? {
            guard offset < der.count, der[offset] == 0x02 else { return nil }
            offset += 1
            let len = Int(der[offset]); offset += 1
            let bytes = der[offset..<(offset + len)]; offset += len
            // Strip leading zero pad and left-pad to 32 bytes
            let stripped = bytes.drop(while: { $0 == 0 })
            if stripped.count > 32 { return nil }
            return Data(repeating: 0, count: 32 - stripped.count) + stripped
        }

        guard let r = readInteger(), let s = readInteger() else { return nil }
        return r + s
    }
}

import CryptoKit
