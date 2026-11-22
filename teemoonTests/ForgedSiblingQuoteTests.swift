//
//  ForgedSiblingQuoteTests.swift
//  teemoonTests
//
//  Audit 1.1.1 interim (2026-11-20), the shared-key MEDIUM's root cause: a quote whose body is signed by a key the
//  quote carries itself, with a genuine Intel chain copied in, read as verified. Nothing bound the attestation key to
//  the chain: the QE report's signature under the PCK leaf and its report_data = sha256(attestation key || QE auth
//  data) were never checked. The fixture is audit's forge of live entry [1] (forge.py, sha256 61d22619…).
//

import Foundation
import Testing
import TDXQuoteVerifier
@testable import teemoon

enum ForgedSibling {
    struct Forge {
        let entry: [String: Any]
        let nonce: String
        let sealedKey: Data
        var quoteHex: String { entry["intel_quote"] as! String }
        /// The gateway's `?model=` answer listing only the forged enclave.
        var listBody: Data { try! JSONSerialization.data(withJSONObject: ["model_attestations": [entry]]) }
    }

    static func load() throws -> Forge {
        let root = try JSONSerialization.jsonObject(with: TestFixture.data("audit_forged_sibling_entry_20261120.json")) as! [String: Any]
        return Forge(entry: root["entry"] as! [String: Any], nonce: root["nonce"] as! String,
                     sealedKey: try Data(hexString: root["sealed_key"] as! String))
    }
}

@Suite("A forged listed enclave (audit 1.1.1)")
struct ForgedSiblingQuoteTests {

    @Test func everyGenuineListedQuoteStillVerifiesLocally() throws {
        for c in try LiveCandidates.load().list {
            #expect(try TDXQuoteVerifier.verify(quoteHex: c["intel_quote"] as! String).isVerified)
        }
    }

    @Test func aQuoteSignedByAKeyItCarriesItselfIsNotVerified() throws {
        let f = try ForgedSibling.load()
        #expect(try TDXQuoteVerifier.verify(quoteHex: f.quoteHex).isVerified == false)
    }

    @Test func theForgedEnclaveIsAMismatch() throws {
        let f = try ForgedSibling.load()
        #expect(ModelCandidates.check(f.entry, sealedKey: f.sealedKey, nonceHex: f.nonce) == .mismatch(.quoteInvalid))
    }

    /// Records every quote DCAP was asked about; Intel unreachable, so each reads "couldn't check".
    final class RecordingCollateral: CollateralProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Data] = []
        var quotes: [Data] { lock.withLock { seen } }
        func collateralJSON(forQuote rawQuote: Data) async throws -> Data {
            lock.withLock { seen.append(rawQuote) }
            throw URLError(.timedOut)
        }
    }

    /// Each listed enclave's quote goes through the model leg's DCAP path, not only the local parse.
    @Test func everyListedQuoteGoesThroughDCAP() async throws {
        let c = try LiveCandidates.load()
        var record = AttestationRecord.preview
        record.modelCandidates = ModelCandidates.enclaves(body: c.body, nonce: c.nonce, sealedKey: c.key)
        let collateral = RecordingCollateral()
        let result = await DCAPService(collateral: collateral).verify(record: record)
        for listed in c.list {
            let quote = try Data(hexString: listed["intel_quote"] as! String)
            #expect(collateral.quotes.contains(quote), "a listed quote never reached DCAP")
        }
        #expect(result.hasUnchecked)
    }
}
