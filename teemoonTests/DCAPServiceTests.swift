//
//  DCAPServiceTests.swift
//  teemoonTests
//
//  Record-level DCAP verification: the real captured quote verifies through
//  the whole DCAPService path (including the cross-check tripwire against
//  the hand-rolled Swift parser), hard-failure policy matches the plan
//  (failed/revoked = hard, out-of-date = flagged not hard), and collateral
//  is fetched once per platform, not once per quote.
//

import Foundation
import TDXQuoteVerifier
import Testing
@testable import teemoon

@Suite("DCAPService")
struct DCAPServiceTests {

    /// Minimal record carrying the fixture's real gateway quote, with the
    /// Swift parser's verification attached so the cross-check runs.
    static func record(from snapshot: CollateralServiceTests.Snapshot,
                       quoteHex: String? = nil,
                       swiftParse: TDXVerificationResult? = nil) -> AttestationRecord {
        AttestationRecord(
            composeHash: "", mrtd: "", osImageHash: "",
            intelQuote: quoteHex ?? snapshot.quoteHex,
            composeManifest: nil, gpuArch: nil, gpuNodeComposeHash: nil,
            modelFileHash: nil, signingAddress: nil, gpuSigningAddress: nil,
            modelEd25519PubKey: nil,
            quoteVerification: swiftParse,
            gpuQuoteVerification: nil, modelQuoteVerification: nil,
            fetchedAt: Date(timeIntervalSince1970: TimeInterval(snapshot.nowSecs)),
            providerID: UUID()
        )
    }

    @Test func realQuote_verifiesThroughService_withCrossCheck() async throws {
        let snapshot = try CollateralServiceTests.loadSnapshot()
        // Attach the Swift parser's result so the cross-check tripwire runs.
        let swiftParse = try TDXQuoteVerifier.verify(quoteHex: snapshot.quoteHex)
        let service = DCAPService(collateral: CollateralServiceTests.provider(snapshot))
        let result = await service.verify(record: Self.record(from: snapshot, swiftParse: swiftParse))
        guard case .verified(let tcb, _, _) = result.gateway else {
            Issue.record("expected gateway .verified, got \(String(describing: result.gateway))")
            return
        }
        #expect(tcb == .outOfDate || tcb == .upToDate)
        #expect(result.model == nil)
        #expect(result.gpu == nil)
        #expect(!result.hasHardFailure)
        #expect(result.allPresentVerified)
    }

    @Test func crossCheckMismatch_failsTheQuote() async throws {
        let snapshot = try CollateralServiceTests.loadSnapshot()
        // A Swift-parse result whose measurements disagree with dcap-qvl's.
        let real = try TDXQuoteVerifier.verify(quoteHex: snapshot.quoteHex)
        let m = real.measurements
        let tampered = TDXMeasurements(
            mrtd: m.mrtd, mrSeam: m.mrSeam, mrConfigID: Data(count: 48), mrOwner: m.mrOwner,
            rtmr0: m.rtmr0, rtmr1: m.rtmr1, rtmr2: m.rtmr2, rtmr3: m.rtmr3,
            reportData: m.reportData)
        let mismatch = TDXVerificationResult(
            quote: real.quote, measurements: tampered,
            signatureValid: true, certChainValid: true, certChainError: nil)
        let service = DCAPService(collateral: CollateralServiceTests.provider(snapshot))
        let result = await service.verify(record: Self.record(from: snapshot, swiftParse: mismatch))
        guard case .failed(let reason) = result.gateway else {
            Issue.record("expected .failed on cross-check mismatch, got \(String(describing: result.gateway))")
            return
        }
        #expect(reason.contains("cross-check"))
        #expect(result.hasHardFailure)
    }

    @Test func hardFailurePolicy_matchesPlan() {
        // Verified + out-of-date TCB: flagged, NOT a hard failure (near.ai parity).
        let outOfDate = DCAPVerification.verified(tcbStatus: .outOfDate, mrConfigIdHex: "01", reportDataHex: "")
        #expect(!outOfDate.isHardFailure)
        // Revoked TCB and failed verification are hard failures.
        let revoked = DCAPVerification.verified(tcbStatus: .revoked, mrConfigIdHex: "01", reportDataHex: "")
        #expect(revoked.isHardFailure)
        #expect(DCAPVerification.failed("no collateral").isHardFailure)

        var record = RecordDCAPVerification()
        record.gateway = outOfDate
        #expect(!record.hasHardFailure)
        #expect(record.worstTcbStatus == .outOfDate)
        record.model = revoked
        #expect(record.hasHardFailure)
        #expect(record.worstTcbStatus == .revoked)
    }

    @Test func emptyQuotes_produceNoOutcomes() async throws {
        let snapshot = try CollateralServiceTests.loadSnapshot()
        let service = DCAPService(collateral: CollateralServiceTests.provider(snapshot))
        let result = await service.verify(record: Self.record(from: snapshot, quoteHex: ""))
        #expect(result.gateway == nil && result.model == nil && result.gpu == nil)
        #expect(!result.hasHardFailure)
        #expect(!result.allPresentVerified)
    }

    // MARK: Collateral caching

    /// Counts the underlying PCS HTTP GETs so we can assert same-FMSPC quotes
    /// reuse the cached per-FMSPC collateral instead of refetching.
    actor CountingHTTP: CollateralHTTPClient {
        let wrapped: CollateralHTTPClient
        var count = 0
        init(_ wrapped: CollateralHTTPClient) { self.wrapped = wrapped }
        func get(_ url: URL) async throws -> (body: Data, headers: [String: String]) {
            count += 1
            return try await wrapped.get(url)
        }
    }

    @Test func sameFMSPCQuotes_fetchPerFMSPCCollateralOnce() async throws {
        let snapshot = try CollateralServiceTests.loadSnapshot()
        let http = CountingHTTP(CollateralServiceTests.StubHTTP(responses: snapshot.responses))
        let provider = IntelPCSCollateralProvider(http: http)
        let quote = try Data(hexString: snapshot.quoteHex)
        _ = try await provider.collateralJSON(forQuote: quote)
        let afterFirst = await http.count
        _ = try await provider.collateralJSON(forQuote: quote)
        let afterSecond = await http.count
        #expect(afterFirst > 0)
        // Second assembly reuses the cached per-FMSPC fields — no new PCS GETs.
        #expect(afterSecond == afterFirst)
    }

    // MARK: Summary row

    @Test func summaryDCAPRow_states() throws {
        let snapshot = try CollateralServiceTests.loadSnapshot()
        let record = Self.record(from: snapshot)
        var verified = RecordDCAPVerification()
        verified.gateway = .verified(tcbStatus: .outOfDate, mrConfigIdHex: "01", reportDataHex: "")

        func summary(_ dcap: RecordDCAPVerification?) -> AttestationSummary {
            AttestationSummary(
                attestation: record, state: .degraded, timedOut: false, provider: nil,
                lastRequestUsedE2EE: nil, lastE2EEFailReason: nil,
                verifiedResponseCount: 0, mismatchedResponseCount: 0,
                attestationFetchFailed: false, dcapVerification: dcap)
        }
        #expect(summary(nil).dcapState == .pending)
        #expect(summary(verified).dcapState == .done)
        #expect(summary(verified).dcapDetail.contains("behind on Intel platform updates"))

        var failed = RecordDCAPVerification()
        failed.gateway = .failed("PCCS collateral unavailable")
        #expect(summary(failed).dcapState == .stuck)
        // Definitive results join the pass/fail banner; pending does not.
        #expect(summary(verified).allChecks.count == summary(nil).allChecks.count + 1)
    }
}
