//
//  GuestOSProvenanceTests.swift
//  teemoonTests
//
//  Two regressions for the guest-OS row:
//   1. The model node's `os_image_hash` must be extracted from the model
//      attestation — in BOTH wire shapes it arrives in — not from the gateway
//      report (the app's gateway request sends no `model=`, so that envelope
//      has no model node data). This was a live bug: the row silently didn't
//      render because the hash came back nil.
//   2. The verified hash→source map is fail-closed: only a hash we actually
//      matched to a published release yields a link.
//

import Foundation
import Testing
@testable import teemoon

@Suite("GuestOSProvenance")
struct GuestOSProvenanceTests {

    static let modelOSHash = "9b69bb1698bacbb6985409a2c272bcb892e09cdcea63d5399c6768b67d3ff677"

    // MARK: model-attestation os_image_hash extraction (both wire shapes)

    @Test func directHostFlatReport_yieldsModelOSImageHash() {
        // The direct completions host returns a flat report with top-level `info`.
        let json = """
        {"model_name":"zai-org/GLM-5.1-FP8",
         "signing_public_key":"40ef1aadbb12f26cf4c2d499b9e7a7b043da4388200715abed573fa135a561bb",
         "info":{"compose_hash":"0fccab4eb7ff","os_image_hash":"\(Self.modelOSHash)"}}
        """.data(using: .utf8)!
        #expect(AttestationService._testModelOSImageHash(fromModelReport: json) == Self.modelOSHash)
    }

    @Test func gatewayWithModelEnvelope_yieldsModelOSImageHash() {
        // The gateway queried WITH ?model= returns model_attestations[].info.
        let json = """
        {"model_attestations":[
          {"model_name":"zai-org/GLM-5.1-FP8",
           "signing_public_key":"40ef1aadbb12f26cf4c2d499b9e7a7b043da4388200715abed573fa135a561bb",
           "info":{"os_image_hash":"\(Self.modelOSHash)"}}]}
        """.data(using: .utf8)!
        #expect(AttestationService._testModelOSImageHash(fromModelReport: json) == Self.modelOSHash)
    }

    @Test func reportWithoutInfo_yieldsNil() {
        // A model attestation carrying no info block must not fabricate a hash —
        // the row then simply doesn't render (fail-safe, never the wrong node).
        let json = """
        {"model_name":"zai-org/GLM-5.1-FP8",
         "signing_public_key":"40ef1aadbb12f26cf4c2d499b9e7a7b043da4388200715abed573fa135a561bb"}
        """.data(using: .utf8)!
        #expect(AttestationService._testModelOSImageHash(fromModelReport: json) == nil)
    }

    // MARK: verified hash → source map (fail-closed)

    @Test func knownHash_mapsToPublishedRelease() {
        let src = GuestOSProvenance.source(forOSImageHash: Self.modelOSHash)
        #expect(src?.tag == "v0.5.5")
        #expect(src?.commit == "25c25025c556ab2f797eeda3bab433f38a8ffb7a")
        #expect(src?.releaseURL == "https://github.com/nearai/private-ml-sdk/releases/tag/v0.5.5")
    }

    @Test func sha256PrefixAndCaseAreNormalized() {
        #expect(GuestOSProvenance.source(forOSImageHash: "sha256:\(Self.modelOSHash)")?.tag == "v0.5.5")
        #expect(GuestOSProvenance.source(forOSImageHash: Self.modelOSHash.uppercased())?.tag == "v0.5.5")
    }

    @Test func unknownHash_yieldsNoSource() {
        // The gateway node's hash (da9a3d5c…) is NOT a dstack-nvidia release —
        // it must not resolve to a source link.
        #expect(GuestOSProvenance.source(
            forOSImageHash: "da9a3d5cc196a1a76d953fb27069be428ddf60a1ce10b0534c3cf968d3053fde") == nil)
        #expect(GuestOSProvenance.source(forOSImageHash: "deadbeef") == nil)
    }
}
