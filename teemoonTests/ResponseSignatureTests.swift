//
//  ResponseSignatureTests.swift
//  teemoonTests
//
//  Phase 4 response-signature verification, exercised against a REAL signed
//  near.ai exchange (Fixtures/nearai_signed_response.json — a live streaming
//  request, its raw SSE lines, and the production signature payload):
//  keccak256, EIP-191 ecrecover, and the request/response content binding
//  all validated against genuine production data.
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

// MARK: - Keccak-256

@Suite("Keccak256")
struct Keccak256Tests {

    @Test func standardVectors() {
        // Original Keccak (0x01 padding), not SHA3-256.
        // Ethereum's ubiquitous empty-input hash (the empty account code hash).
        #expect(Keccak256.hash(Data()).hexString
                == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        #expect(Keccak256.hash(Data("abc".utf8)).hexString
                == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        #expect(Keccak256.hash(Data("The quick brown fox jumps over the lazy dog".utf8)).hexString
                == "4d741b6f1eb29cb2a9b9911c82f56fa8d73b04959d3d9d222895df6c0b28aa15")
    }

    @Test func multiBlockInput() {
        // > 136-byte rate forces multiple absorb blocks.
        let input = Data(String(repeating: "a", count: 300).utf8)
        #expect(Keccak256.hash(input).count == 32)
        // Deterministic: same input, same output.
        #expect(Keccak256.hash(input) == Keccak256.hash(input))
    }
}

// MARK: - EIP-191 ecrecover

@Suite("EthereumSignature")
struct EthereumSignatureTests {

    static func loadFixture(file: String = #filePath) throws -> SignedResponseFixture {
        let data = try TestFixture.data("nearai_signed_response.json", file: file)
        return try JSONDecoder().decode(SignedResponseFixture.self, from: data)
    }

    struct SignedResponseFixture: Decodable {
        let bodyJson: String
        let lines: [String]
        let sig: Sig

        struct Sig: Decodable {
            let text: String
            let signature: String
            let signingAddress: String
            enum CodingKeys: String, CodingKey {
                case text, signature, signingAddress = "signing_address"
            }
        }

        enum CodingKeys: String, CodingKey {
            case bodyJson = "body_json", lines, sig
        }

        /// The response text the signature covers: each raw line + "\n".
        var responseText: String { lines.map { $0 + "\n" }.joined() }
    }

    @Test func recoversProductionSigner() throws {
        let fixture = try Self.loadFixture()
        let recovered = EthereumSignature.recoverAddress(
            text: fixture.sig.text, signatureHex: fixture.sig.signature)
        #expect(recovered == fixture.sig.signingAddress.lowercased())
    }

    @Test func tamperedTextRecoversDifferentAddress() throws {
        let fixture = try Self.loadFixture()
        let recovered = EthereumSignature.recoverAddress(
            text: fixture.sig.text + "x", signatureHex: fixture.sig.signature)
        // Tampering the message yields a different (or no) signer — never the real one.
        #expect(recovered != fixture.sig.signingAddress.lowercased())
    }

    @Test func malformedSignaturesReturnNilWithoutCrashing() {
        // Garbage r values (~half have no curve point) must be an error, not a crash.
        for filler in ["00", "ff", "aa", "7f"] {
            let sig = "0x" + String(repeating: filler, count: 64) + "1b"
            _ = EthereumSignature.recoverAddress(text: "x", signatureHex: sig)
        }
        #expect(EthereumSignature.recoverAddress(text: "x", signatureHex: "0xdead") == nil)  // wrong length
        #expect(EthereumSignature.recoverAddress(text: "x", signatureHex: "zz") == nil)      // not hex
        let badRecid = "0x" + String(repeating: "11", count: 64) + "63"  // v = 99
        #expect(EthereumSignature.recoverAddress(text: "x", signatureHex: badRecid) == nil)
    }
}

// MARK: - Content binding

@Suite("ContentBinding")
struct ContentBindingTests {

    @Test func productionExchangeBinds() throws {
        let fixture = try EthereumSignatureTests.loadFixture()
        let exchange = SignedExchange(
            requestBodyCandidates: [Data(fixture.bodyJson.utf8)],
            responseText: fixture.responseText)
        let binding = try #require(ContentBinding.check(text: fixture.sig.text, exchange: exchange))
        #expect(binding.requestHashMatches)
        #expect(binding.responseHashMatches)
        #expect(binding.isBound)
    }

    @Test func tamperedResponseDoesNotBind() throws {
        let fixture = try EthereumSignatureTests.loadFixture()
        let exchange = SignedExchange(
            requestBodyCandidates: [Data(fixture.bodyJson.utf8)],
            responseText: fixture.responseText + " ")
        let binding = try #require(ContentBinding.check(text: fixture.sig.text, exchange: exchange))
        #expect(binding.requestHashMatches)
        #expect(!binding.responseHashMatches)
        #expect(!binding.isBound)
    }

    @Test func tamperedRequestDoesNotBind() throws {
        let fixture = try EthereumSignatureTests.loadFixture()
        let exchange = SignedExchange(
            requestBodyCandidates: [Data((fixture.bodyJson + " ").utf8)],
            responseText: fixture.responseText)
        let binding = try #require(ContentBinding.check(text: fixture.sig.text, exchange: exchange))
        #expect(!binding.requestHashMatches)
        #expect(!binding.isBound)
    }

    @Test func secondRequestCandidateBinds() throws {
        // Under E2EE both wire and plaintext bodies are offered — either may match.
        let fixture = try EthereumSignatureTests.loadFixture()
        let exchange = SignedExchange(
            requestBodyCandidates: [Data("something else".utf8), Data(fixture.bodyJson.utf8)],
            responseText: fixture.responseText)
        let binding = try #require(ContentBinding.check(text: fixture.sig.text, exchange: exchange))
        #expect(binding.requestHashMatches)
    }

    @Test func droppingTheBlankLineAfterDoneBreaksTheProductionHash() throws {
        // The production fixture's last two lines are `data: [DONE]` and "".
        // Hashing without that empty line is the live "didn't check out" bug.
        let fixture = try EthereumSignatureTests.loadFixture()
        #expect(fixture.lines.last == "")
        #expect(fixture.lines.dropLast().last == "data: [DONE]")

        let early = fixture.lines.dropLast().map { $0 + "\n" }.joined()
        let earlyExchange = SignedExchange(
            requestBodyCandidates: [Data(fixture.bodyJson.utf8)],
            responseText: early)
        let earlyBinding = try #require(ContentBinding.check(text: fixture.sig.text, exchange: earlyExchange))
        #expect(earlyBinding.requestHashMatches)
        #expect(!earlyBinding.responseHashMatches)

        let fullExchange = SignedExchange(
            requestBodyCandidates: [Data(fixture.bodyJson.utf8)],
            responseText: fixture.responseText)
        let fullBinding = try #require(ContentBinding.check(text: fixture.sig.text, exchange: fullExchange))
        #expect(fullBinding.isBound)
    }

    @Test func twoPartTextParses() throws {
        // Legacy "req:resp" without model prefix.
        let exchange = SignedExchange(requestBodyCandidates: [Data("req".utf8)], responseText: "resp")
        let reqHash = SHA256.hash(data: Data("req".utf8)).map { String(format: "%02x", $0) }.joined()
        let binding = try #require(ContentBinding.check(
            text: "\(reqHash):0000", exchange: exchange))
        #expect(binding.requestHashMatches)
        #expect(!binding.responseHashMatches)
    }

    @Test func malformedTextReturnsNil() {
        let exchange = SignedExchange(requestBodyCandidates: [Data()], responseText: "")
        #expect(ContentBinding.check(text: "onlyonepart", exchange: exchange) == nil)
        #expect(ContentBinding.check(text: "a:b:c:d", exchange: exchange) == nil)
    }
}
