//
//  CollateralServiceTests.swift
//  teemoonTests
//
//  Exercises the Intel PCS collateral assembler against a REAL captured
//  snapshot (Fixtures/dcap_pcs_snapshot.json): a live near.ai gateway quote
//  plus the four Intel PCS responses fetched for it, with now_secs pinned
//  inside the collateral validity window (collateral is time-varying).
//
//  The end-to-end test feeds the assembled JSON to the real dcap-qvl
//  verifier, so QE-report binding, TCB evaluation, and the byte-exact
//  tcb_info/qe_identity extraction are all validated against production data.
//

import Foundation
import Testing
@testable import teemoon

@Suite("CollateralService")
struct CollateralServiceTests {

    // MARK: - Fixture plumbing

    struct Snapshot: Decodable {
        let quoteHex: String
        let nowSecs: UInt64
        let responses: [String: Response]

        struct Response: Decodable {
            let bodyB64: String
            let headers: [String: String]

            enum CodingKeys: String, CodingKey {
                case bodyB64 = "body_b64", headers
            }
        }

        enum CodingKeys: String, CodingKey {
            case quoteHex = "quote_hex", nowSecs = "now_secs", responses
        }
    }

    /// Serves the captured PCS responses by exact URL; throws on anything else.
    struct StubHTTP: CollateralHTTPClient {
        let responses: [String: Snapshot.Response]
        /// URLs whose response body should be tampered with (bit-flipped).
        var tamper: Set<String> = []

        struct UnexpectedURL: Error { let url: String }

        func get(_ url: URL) async throws -> (body: Data, headers: [String: String]) {
            guard let response = responses[url.absoluteString] else {
                throw UnexpectedURL(url: url.absoluteString)
            }
            guard var body = Data(base64Encoded: response.bodyB64) else {
                throw UnexpectedURL(url: "bad fixture body for \(url)")
            }
            if tamper.contains(url.absoluteString), !body.isEmpty {
                body[body.count / 2] ^= 0x01
            }
            return (body, response.headers)
        }
    }

    static func loadSnapshot(file: String = #filePath) throws -> Snapshot {
        let data = try TestFixture.data("dcap_pcs_snapshot.json", file: file)
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func provider(_ snapshot: Snapshot, tamper: Set<String> = []) -> IntelPCSCollateralProvider {
        IntelPCSCollateralProvider(http: StubHTTP(responses: snapshot.responses, tamper: tamper))
    }

    // MARK: - End-to-end: assembled collateral is accepted by dcap-qvl

    @Test func realQuote_verifiesWithAssembledCollateral() async throws {
        let snapshot = try Self.loadSnapshot()
        let verifier = DCAPVerifier(collateral: Self.provider(snapshot))
        let result = await verifier.verify(quoteHex: snapshot.quoteHex, nowSecs: snapshot.nowSecs)
        guard case .verified(let tcbStatus, let mrConfigIdHex, let reportDataHex) = result else {
            Issue.record("expected .verified, got \(result)")
            return
        }
        // Genuine TDX hardware, behind on TCB patches at capture time — the
        // degrade case, not a failure (matches near.ai's own verifier).
        #expect(tcbStatus == .outOfDate || tcbStatus == .upToDate)
        // MRCONFIGID carries "01" + compose_hash (code-identity binding).
        #expect(mrConfigIdHex.hasPrefix("01"))
        #expect(reportDataHex.count == 128)
    }

    @Test func collateralJSON_hasAllQuoteCollateralV3Fields() async throws {
        let snapshot = try Self.loadSnapshot()
        let quote = try Data(hexString: snapshot.quoteHex)
        let json = try await Self.provider(snapshot).collateralJSON(forQuote: quote)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        for field in ["pck_crl_issuer_chain", "root_ca_crl", "pck_crl",
                      "tcb_info_issuer_chain", "tcb_info", "tcb_info_signature",
                      "qe_identity_issuer_chain", "qe_identity", "qe_identity_signature",
                      "pck_certificate_chain"] {
            #expect(object[field] != nil, "missing \(field)")
        }
        // The raw sub-objects must be byte-exact JSON objects, not re-serializations.
        let tcbInfo = try #require(object["tcb_info"] as? String)
        #expect(tcbInfo.hasPrefix("{") && tcbInfo.hasSuffix("}"))
    }

    // MARK: - Fail-closed paths

    @Test func expiredCollateralWindow_failsVerification() async throws {
        let snapshot = try Self.loadSnapshot()
        let verifier = DCAPVerifier(collateral: Self.provider(snapshot))
        // Two years after capture — far outside every nextUpdate window.
        let result = await verifier.verify(
            quoteHex: snapshot.quoteHex, nowSecs: snapshot.nowSecs + 2 * 365 * 86400)
        #expect(!result.isVerified)
    }

    @Test func tamperedTCBInfo_failsVerification() async throws {
        let snapshot = try Self.loadSnapshot()
        let tcbURL = try #require(snapshot.responses.keys.first { $0.contains("/tcb?") })
        let verifier = DCAPVerifier(collateral: Self.provider(snapshot, tamper: [tcbURL]))
        let result = await verifier.verify(quoteHex: snapshot.quoteHex, nowSecs: snapshot.nowSecs)
        #expect(!result.isVerified)
    }

    @Test func unavailableCollateral_failsClosed() async throws {
        let snapshot = try Self.loadSnapshot()
        let verifier = DCAPVerifier(collateral: IntelPCSCollateralProvider(http: StubHTTP(responses: [:])))
        let result = await verifier.verify(quoteHex: snapshot.quoteHex, nowSecs: snapshot.nowSecs)
        guard case .failed(let reason) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.contains("collateral"))
    }

    // MARK: - Byte-exact sub-object extraction

    @Test func rawJSONObject_extractsByteExactSubobject() throws {
        let body = Data(#"{"tcbInfo":{"a":1,"z":{"nested":"br{ce\" }"},"b":[1,2]},"signature":"aabb"}"#.utf8)
        let raw = IntelPCSCollateralProvider.rawJSONObject(forKey: "tcbInfo", in: body)
        #expect(raw == #"{"a":1,"z":{"nested":"br{ce\" }"},"b":[1,2]}"#)
    }

    @Test func rawJSONObject_missingKeyReturnsNil() {
        let body = Data(#"{"other":{}}"#.utf8)
        #expect(IntelPCSCollateralProvider.rawJSONObject(forKey: "tcbInfo", in: body) == nil)
    }

    @Test func crlDistributionPoint_extractsIntelURL() throws {
        let snapshot = try Self.loadSnapshot()
        let qeURL = try #require(snapshot.responses.keys.first { $0.contains("qe/identity") })
        let chainHeader = try #require(snapshot.responses[qeURL]?.headers["SGX-Enclave-Identity-Issuer-Chain"])
        let pem = try #require(chainHeader.removingPercentEncoding)
        let rootDER = try #require(IntelPCSCollateralProvider.pemCertificatesDER(pem).last)
        let uri = IntelPCSCollateralProvider.crlDistributionPointURI(certDER: rootDER)
        #expect(uri == "https://certificates.trustedservices.intel.com/IntelSGXRootCA.der")
    }
}
