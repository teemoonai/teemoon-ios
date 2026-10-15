//
//  ConformanceVectorTests.swift
//  teemoonTests
//
//  The Android port's Phase 0 gate: every vector the kit ships is
//  asserted against the production code path HERE, on every CI run, whether or
//  not anyone regenerates. A vector that stops describing the app fails in this
//  repo — long before teemoon-android inherits it as the definition of correct.
//
//  `emitConformanceVectors` is the writer, and it is off unless asked: it writes
//  into the source tree, so it belongs to a local `make conformance`, never to a
//  CI or on-device run. CI's job is the freshness check (§13.2) — regenerate,
//  then `git diff --exit-code conformance/`.
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

@Suite("Conformance vectors — round-trip against production")
struct ConformanceRoundTripTests {

    // MARK: The published KATs

    @Test func hchacha20MatchesTheDraft() throws {
        let v = try ConformanceVectors.crypto().hchacha20[0]
        #expect(v.output == "82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc")
    }

    @Test func aeadMatchesTheDraft() throws {
        let v = try ConformanceVectors.crypto().xchachaAEAD[0]
        #expect(v.ciphertext ==
            "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb" +
            "731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b452" +
            "2f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff9" +
            "21f9664c97637da9768812f615c68b13b52e")
        #expect(v.tag == "c0875924c1c7987947deafd8780acf49")
    }

    @Test func keccakMatchesTheEthereumVectors() throws {
        let vs = try ConformanceVectors.crypto().keccak256
        #expect(vs[0].digest == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        #expect(vs[1].digest == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        #expect(vs[2].digest == "4d741b6f1eb29cb2a9b9911c82f56fa8d73b04959d3d9d222895df6c0b28aa15")
        #expect(vs[3].digest.count == 64)
    }

    // MARK: The two derivations must agree

    /// Scalar derivation (RFC 8032 §5.1.5) and the birational map (RFC 7748
    /// §4.1) reach the same X25519 public key, or the peer silently cannot
    /// decrypt. A JVM port that gets one of the two wrong passes every unit
    /// test it writes for itself and fails only against a live model.
    @Test func bothKeyConversionsAgree() throws {
        let vs = try ConformanceVectors.crypto().ed25519ToX25519
        #expect(vs.count == 4)
        for v in vs {
            #expect(v.x25519PublicKeyFromPrivate == v.x25519PublicKeyFromEdPublic,
                    "seed \(v.ed25519Seed): scalar and birational derivations disagree")
        }
    }

    // MARK: ecrecover against the real signature

    @Test func productionSignatureRecoversItsSigner() throws {
        let vs = try ConformanceVectors.crypto().ecrecover
        let production = vs[0]
        let recovered = EthereumSignature.recoverAddress(
            text: production.text, signatureHex: production.signature)
        #expect(recovered == production.expectedAddress)
        #expect(recovered != nil)
    }

    @Test func tamperedTextNeverRecoversTheSigner() throws {
        let vs = try ConformanceVectors.crypto().ecrecover
        #expect(vs[1].expectedAddress != vs[0].expectedAddress)
    }

    @Test func malformedSignaturesRecoverNothing() throws {
        for v in try ConformanceVectors.crypto().ecrecover where v.expectedAddress == nil {
            #expect(EthereumSignature.recoverAddress(text: v.text, signatureHex: v.signature) == nil)
        }
    }

    // MARK: The envelope vector is real

    /// The assembled wire bytes are handed to the PRODUCTION opener. If the
    /// generator's HKDF parameters or byte layout ever drift from
    /// `E2EEEnvelope.deriveKey`/`open`, this fails here rather than shipping a
    /// fiction to the JVM.
    @Test func envelopeOpensUnderProduction() throws {
        let v = try ConformanceVectors.crypto().e2eeEnvelope[0]
        let priv = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: try Data(hexString: v.recipientX25519PrivateKey))
        let opened = try E2EEEnvelope.open(
            wireFormat: try Data(hexString: v.wireFormat), privateKey: priv)
        #expect(String(data: opened, encoding: .utf8) == v.plaintextUTF8)
    }

    @Test func envelopeWireLayoutIsWellFormed() throws {
        let v = try ConformanceVectors.crypto().e2eeEnvelope[0]
        let wire = try Data(hexString: v.wireFormat)
        #expect(wire.prefix(32).hexString == v.ephemeralX25519PublicKey)
        #expect(wire.dropFirst(32).prefix(24).hexString == v.nonce)
        #expect(wire.count == 32 + 24 + Data(v.plaintextUTF8.utf8).count + 16)
    }

    // MARK: Determinism — the property the freshness gate rests on

    /// Regenerating without changing anything must produce identical bytes, or
    /// CI's `git diff --exit-code conformance/` reports drift on every run and
    /// stops meaning anything.
    @Test func generationIsByteStable() throws {
        let a = try ConformanceEncoder.encode(ConformanceDocument(
            kitVersion: ConformanceVectors.kitVersion, fixtureClass: "crypto",
            sourceOfTruth: "teemoon-ios", vectors: try ConformanceVectors.crypto()))
        let b = try ConformanceEncoder.encode(ConformanceDocument(
            kitVersion: ConformanceVectors.kitVersion, fixtureClass: "crypto",
            sourceOfTruth: "teemoon-ios", vectors: try ConformanceVectors.crypto()))
        #expect(a == b)
    }
}

// MARK: - Emission

@Suite("Conformance vectors — emit")
struct ConformanceEmitTests {

    /// Writes `conformance/crypto.json` at the repo root. Off unless
    /// CONFORMANCE_EMIT is set AND the source tree is reachable (a device run
    /// has no repo to write to — see TestFixture's comment on #filePath).
    ///
    /// Invoke it as `make conformance`, never by hand. xcodebuild does not pass
    /// the host environment into the simulator's test process: the variable has
    /// to be spelled `TEST_RUNNER_CONFORMANCE_EMIT=1`, and xcodebuild strips the
    /// prefix. Get that wrong and the test SKIPS while the run still reports
    /// "** TEST SUCCEEDED **" — stale vectors behind a green build, which is the
    /// one outcome this kit cannot afford. The make target fails if the file was
    /// not actually rewritten.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONFORMANCE_EMIT"] != nil
                   && TestFixture.sourceTreeAvailable()))
    func emitConformanceVectors() async throws {
        let out = Self.outputDirectory()
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func write<T: Encodable>(_ fixtureClass: String, _ vectors: T) throws {
            let document = ConformanceDocument(
                kitVersion: ConformanceVectors.kitVersion, fixtureClass: fixtureClass,
                sourceOfTruth: "teemoon-ios", vectors: vectors)
            let url = out.appendingPathComponent("\(fixtureClass).json")
            try ConformanceEncoder.encode(document).write(to: url)
            print("[conformance] wrote \(url.path)")
        }
        try write("crypto", try ConformanceVectors.crypto())
        try write("quotes", try await ConformanceAttestationVectors.quotes())
        try write("collateral", try await ConformanceAttestationVectors.collateral())
        try write("sigstore", try ConformanceAttestationVectors.sigstore())
        try write("nras", try await ConformanceAttestationVectors.nras())
        try write("tls", try ConformanceAttestationVectors.tls())
        try write("streams", try ConformanceFixtureVectors.streams())
        try write("catalogs", try ConformanceFixtureVectors.catalogs())
        try write("brave", try ConformanceFixtureVectors.brave())
    }

    /// CONFORMANCE_OUT, else `<repo>/conformance` derived from this file.
    static func outputDirectory(file: String = #filePath) -> URL {
        if let override = ProcessInfo.processInfo.environment["CONFORMANCE_OUT"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: file)
            .deletingLastPathComponent()   // teemoonTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("conformance")
    }
}
