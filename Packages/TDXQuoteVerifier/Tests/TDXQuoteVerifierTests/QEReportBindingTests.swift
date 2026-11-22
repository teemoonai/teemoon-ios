//
//  QEReportBindingTests.swift
//  TDXQuoteVerifierTests
//
//  Audit 1.1.1: the attestation key must be the Quoting Enclave's (QE report signed by the PCK leaf, its report_data
//  committing to the key). Fixtures are the app's: live glm-5.3-flash enclaves and audit's forge of entry [1].
//

import Foundation
import Testing
@testable import TDXQuoteVerifier

private func fixtureAt(_ relative: String, file: String = #filePath) throws -> [String: Any] {
    let url = URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent(relative).standardized
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

private func fixture(_ name: String, file: String = #filePath) throws -> [String: Any] {
    let url = URL(fileURLWithPath: file).deletingLastPathComponent()
        .appendingPathComponent("../../../../teemoonTests/Fixtures/\(name)").standardized
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

@Suite("QE report binding")
struct QEReportBindingTests {

    @Test("Every live listed quote verifies, its attestation key bound to the chain")
    func liveQuotesVerify() throws {
        let report = try fixture("nearai_live_glm53flash_candidates_20261119.json")["report"] as! [String: Any]
        let list = report["model_attestations"] as! [[String: Any]]
        #expect(list.count == 3)
        for c in list {
            let r = try TDXQuoteVerifier.verify(quoteHex: c["intel_quote"] as! String)
            #expect(r.isVerified)
            #expect(TDXQuoteVerifier.attestationKeyIsBoundToChain(r.quote.signature))
        }
    }

    @Test("A body signed by a key the quote carries itself, beside a genuine chain, is not verified")
    func forgedAttestationKeyFails() throws {
        let entry = try fixture("audit_forged_sibling_entry_20261120.json")["entry"] as! [String: Any]
        let r = try TDXQuoteVerifier.verify(quoteHex: entry["intel_quote"] as! String)
        #expect(r.certChainValid)   // the copied chain is genuine
        #expect(!r.isVerified)
    }

    @Test("A QE report not signed by the PCK leaf is not verified")
    func tamperedQEReportFails() throws {
        let report = try fixture("nearai_live_glm53flash_candidates_20261119.json")["report"] as! [String: Any]
        let hex = (report["model_attestations"] as! [[String: Any]])[0]["intel_quote"] as! String
        var data = try #require(Data(hexString: hex))
        let qe = try #require(try TDXQuoteVerifier.verify(quoteData: data).quote.signature.qeReport)
        let at = try #require(data.range(of: qe)).lowerBound + 16   // inside the QE report body, not its report_data
        data[at] ^= 0x01
        #expect(!(try TDXQuoteVerifier.verify(quoteData: data)).isVerified)
    }

    private func liveQEReport() throws -> Data {
        let report = try fixture("nearai_live_glm53flash_candidates_20261119.json")["report"] as! [String: Any]
        let hex = (report["model_attestations"] as! [[String: Any]])[0]["intel_quote"] as! String
        return try #require(try TDXQuoteVerifier.verify(quoteHex: hex).quote.signature.qeReport)
    }

    @Test("The live QE report is Intel's TD Quoting Enclave")
    func liveReportIsTheTDQE() throws {
        #expect(TDXQuoteVerifier.reportIsIntelsTDQuotingEnclave(try liveQEReport()))
    }

    @Test("Another signer, another product, or a debug enclave is not the TD Quoting Enclave")
    func otherEnclavesAreNot() throws {
        let good = try liveQEReport()
        var signer = good; signer[signer.startIndex + 140] ^= 0x01
        var prod = good; prod[prod.startIndex + 256] = 1
        var debug = good; debug[debug.startIndex + 48] |= 0x02
        var misc = good; misc[misc.startIndex + 16] ^= 0x01
        for (name, report) in [("mrsigner", signer), ("isvprodid", prod), ("debug", debug), ("miscselect", misc)] {
            #expect(!TDXQuoteVerifier.reportIsIntelsTDQuotingEnclave(report), "\(name)")
        }
    }

    @Test("The pinned TD QE identity is Intel's signed qe_identity in the conformance kit")
    func pinnedIdentityMatchesTheKit() throws {
        let kit = try fixtureAt("../../../../conformance/collateral.json")
        let fields = (kit["vectors"] as! [String: Any])["assembledCollateralFields"] as! [String: Any]
        let raw = fields["qe_identity"] as! String
        let identity = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
        #expect(identity["id"] as? String == "TD_QE")
        #expect((identity["mrsigner"] as! String).lowercased() == TDXQuoteVerifier.tdQEMRSigner.map { String(format: "%02x", $0) }.joined())
        #expect(identity["isvprodid"] as? Int == Int(TDXQuoteVerifier.tdQEProdID))
        #expect((identity["attributes"] as! String).lowercased() == TDXQuoteVerifier.tdQEAttributes.map { String(format: "%02x", $0) }.joined())
        #expect((identity["attributesMask"] as! String).lowercased() == TDXQuoteVerifier.tdQEAttributesMask.map { String(format: "%02x", $0) }.joined())
        #expect((identity["miscselect"] as! String).lowercased() == TDXQuoteVerifier.tdQEMiscSelect.map { String(format: "%02x", $0) }.joined())
        #expect((identity["miscselectMask"] as! String).lowercased() == TDXQuoteVerifier.tdQEMiscSelectMask.map { String(format: "%02x", $0) }.joined())
    }

    @Test("A genuine quote whose QE report is not the TD Quoting Enclave's is not bound")
    func bindingAsksWhichEnclave() throws {
        let report = try fixture("nearai_live_glm53flash_candidates_20261119.json")["report"] as! [String: Any]
        let hex = (report["model_attestations"] as! [[String: Any]])[0]["intel_quote"] as! String
        let sig = try TDXQuoteVerifier.verify(quoteHex: hex).quote.signature
        #expect(TDXQuoteVerifier.attestationKeyIsBoundToChain(sig))
        #expect(!TDXQuoteVerifier.attestationKeyIsBoundToChain(sig, isTDQE: { _ in false }))
    }

    /// Every leg's captured quote (gateway, model, GPU node, TLS, PCS snapshot, kit) still verifies with the binding;
    /// only the two built to fail don't.
    @Test("Every genuine fixture quote still verifies")
    func everyFixtureQuoteStillVerifies() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized
        let builtToFail: Set<String> = ["teemoonTests/Fixtures/audit_forged_sibling_entry_20261120.json#0",
                                        "conformance/quotes.json#1"]
        let re = try NSRegularExpression(pattern: "\"(?:0x)?(0[45]000[0-9a-f]{3}[0-9a-f]{1200,})\"")
        var seen = 0
        for dir in ["conformance", "teemoonTests/Fixtures"] {
            let e = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil))
            for case let url as URL in e where url.pathExtension == "json" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let ns = text as NSString
                let name = url.path.replacingOccurrences(of: root.path + "/", with: "")
                for (i, m) in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).enumerated() {
                    seen += 1
                    let verified = (try? TDXQuoteVerifier.verify(quoteHex: ns.substring(with: m.range(at: 1))))?.isVerified == true
                    #expect(verified == !builtToFail.contains("\(name)#\(i)"), "\(name)#\(i)")
                }
            }
        }
        #expect(seen >= 20)
    }
}
