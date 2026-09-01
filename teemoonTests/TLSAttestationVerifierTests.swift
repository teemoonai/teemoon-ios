//
//  TLSAttestationVerifierTests.swift
//  teemoonTests
//
//  TLS attestation bindings, exercised against a REAL captured exchange
//  (Fixtures/tls_attestation.json: a live include_tls_fingerprint=true
//  attestation from a near.ai model host, plus that connection's actual
//  server certificate). The SPKI walk, report_data binding, and freshness
//  all run on genuine production data.
//

import Foundation
import Testing
@testable import teemoon

@Suite("TLSAttestationVerifier")
struct TLSAttestationVerifierTests {

    struct Fixture: Decodable {
        let nonce: String
        let certDerB64: String
        let intelQuote: String
        let signingAddress: String
        let signingAlgo: String
        let tlsCertFingerprint: String
        enum CodingKeys: String, CodingKey {
            case nonce
            case certDerB64 = "cert_der_b64"
            case intelQuote = "intel_quote"
            case signingAddress = "signing_address"
            case signingAlgo = "signing_algo"
            case tlsCertFingerprint = "tls_cert_fingerprint"
        }
        var certDER: Data { Data(base64Encoded: certDerB64) ?? Data() }
    }

    static func load(file: String = #filePath) throws -> Fixture {
        let data = try TestFixture.data("tls_attestation.json", file: file)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    /// The probe rides a connection whose delegate accepts ANY
    /// server trust, and the fingerprint binding is only checked AFTER the
    /// response lands — so a bearer token attached to it would be disclosed
    /// to an on-path attacker. The report is public evidence (the bundled
    /// self-verify script fetches the same URL with no credential); the
    /// probe request must carry NO Authorization header, ever.
    @Test func probeRequest_carriesNoAuthorizationHeader() throws {
        let url = try #require(URL(string:
            "https://model.example/v1/attestation/report?include_tls_fingerprint=true&signing_algo=ecdsa&nonce=00"))
        let request = TLSAttestationVerifier.makeProbeRequest(url: url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let headerNames = (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
        #expect(!headerNames.contains("authorization"))
    }

    @Test func spkiHashMatchesAttestedFingerprint() throws {
        let f = try Self.load()
        #expect(TLSAttestationVerifier.spkiSHA256(certDER: f.certDER) == f.tlsCertFingerprint)
    }

    @Test func realExchangeVerifies() throws {
        let f = try Self.load()
        let result = TLSAttestationVerifier.verifyBindings(
            quoteHex: f.intelQuote, signingAddress: f.signingAddress, signingAlgo: f.signingAlgo,
            tlsCertFingerprintHex: f.tlsCertFingerprint, liveCertDER: f.certDER, nonceHex: f.nonce)
        #expect(result == .verified)
    }

    @Test func wrongNonce_failsFreshness() throws {
        let f = try Self.load()
        let result = TLSAttestationVerifier.verifyBindings(
            quoteHex: f.intelQuote, signingAddress: f.signingAddress, signingAlgo: f.signingAlgo,
            tlsCertFingerprintHex: f.tlsCertFingerprint, liveCertDER: f.certDER,
            nonceHex: String(repeating: "00", count: 32))
        guard case .failed(let why) = result else { Issue.record("expected failure"); return }
        #expect(why.contains("nonce"))
    }

    @Test func differentCert_failsSPKIMatch() throws {
        let f = try Self.load()
        // A syntactically-valid but different cert (self-signed) → SPKI mismatch.
        let otherCertB64 = TLSAttestationVerifierTests.throwawayCertBase64
        let result = TLSAttestationVerifier.verifyBindings(
            quoteHex: f.intelQuote, signingAddress: f.signingAddress, signingAlgo: f.signingAlgo,
            tlsCertFingerprintHex: f.tlsCertFingerprint,
            liveCertDER: Data(base64Encoded: otherCertB64) ?? Data(), nonceHex: f.nonce)
        #expect(!result.isVerified)
    }

    @Test func tamperedFingerprint_failsBinding() throws {
        let f = try Self.load()
        // Flip the attested fingerprint: the live cert no longer matches it.
        var fp = Array(f.tlsCertFingerprint)
        fp[0] = fp[0] == "a" ? "b" : "a"
        let result = TLSAttestationVerifier.verifyBindings(
            quoteHex: f.intelQuote, signingAddress: f.signingAddress, signingAlgo: f.signingAlgo,
            tlsCertFingerprintHex: String(fp), liveCertDER: f.certDER, nonceHex: f.nonce)
        #expect(!result.isVerified)
    }

    @Test func malformedCert_returnsNilSPKI() {
        #expect(TLSAttestationVerifier.spkiSHA256(certDER: Data([0x30, 0x03, 0x02, 0x01, 0x00])) == nil)
        #expect(TLSAttestationVerifier.spkiSHA256(certDER: Data()) == nil)
    }

    // A minimal self-signed cert (DER, base64) unrelated to the fixture host —
    // used only to prove a different certificate fails the SPKI match.
    static let throwawayCertBase64 =
        "MIIBIjCBoAIJAKb7lM8m6d3rMAoGCCqGSM49BAMCMBIxEDAOBgNVBAMMB3Rlc3Rp" +
        "bmcwHhcNMjAwMTAxMDAwMDAwWhcNMzAwMTAxMDAwMDAwWjASMRAwDgYDVQQDDAd0" +
        "ZXN0aW5nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEq3l2p0y8b8Z0m0m0mHkR" +
        "5c9r0k7Q0k5w3rF9wF1t8s5x2s0y0v6a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q" +
        "7wIDAQABMAoGCCqGSM49BAMCA0gAMEUCIQD0"
}
