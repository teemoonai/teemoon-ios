//
//  DCAPService.swift
//  teemoon
//
//  Runs real DCAP verification (DCAPVerifier → dcap-qvl) over every TDX
//  quote in an attestation record — gateway, model TEE, and direct GPU node.
//  This is the authoritative quote verdict; the hand-rolled TDXQuoteVerifier
//  stays as the display parser and a cross-check tripwire: if its parse of
//  MRCONFIGID/report_data ever disagrees with dcap-qvl's, the quote is
//  treated as failed and the disagreement logged loudly.
//
//  TCB policy: a quote that fails DCAP or
//  has revoked TCB is a hard failure (degrades the session, fail-closed —
//  including when collateral is unreachable). Out-of-date TCB means genuine
//  hardware behind on Intel platform updates: near.ai's own verifier treats
//  it as non-fatal but flagged, and the sheet surfaces it the same way.
//

import DcapQvl
import Foundation
import TDXQuoteVerifier
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "dcap")

/// DCAP outcomes for each quote present in an attestation record.
/// nil per slot = that quote wasn't in the record.
struct RecordDCAPVerification: Equatable, Sendable {
    var gateway: DCAPVerification?
    var model: DCAPVerification?
    var gpu: DCAPVerification?

    /// True when any present quote hard-fails DCAP — verification failure
    /// (incl. unavailable collateral) or revoked TCB. Out-of-date is not hard.
    var hasHardFailure: Bool {
        [gateway, model, gpu].compactMap { $0 }.contains { $0.isHardFailure }
    }

    /// The least-trusted TCB status among verified quotes (for the sheet row).
    var worstTcbStatus: DCAPTcbStatus? {
        let statuses = [gateway, model, gpu].compactMap { outcome -> DCAPTcbStatus? in
            if case .verified(let tcb, _, _) = outcome { return tcb }
            return nil
        }
        if statuses.contains(.revoked) { return .revoked }
        if statuses.contains(.other) { return .other }
        if statuses.contains(.outOfDate) { return .outOfDate }
        if statuses.contains(.configurationNeeded) { return .configurationNeeded }
        return statuses.isEmpty ? nil : .upToDate
    }

    /// All present quotes verified (regardless of TCB status).
    var allPresentVerified: Bool {
        let present = [gateway, model, gpu].compactMap { $0 }
        return !present.isEmpty && present.allSatisfy(\.isVerified)
    }

    /// The first hard-failure reason, tagged with which quote failed — surfaced
    /// verbatim in the sheet so a DCAP failure is diagnosable without logs.
    var failureReason: String? {
        for (label, outcome) in [("gateway", gateway), ("model", model), ("gpu", gpu)] {
            switch outcome {
            case .failed(let why):            return "\(label) quote — \(why)"
            case .verified(.revoked, _, _):   return "\(label) quote — TCB revoked by Intel"
            default:                          continue
            }
        }
        return nil
    }
}

extension DCAPVerification {
    /// Hard failure = quote didn't verify (incl. no collateral) or TCB revoked.
    var isHardFailure: Bool {
        switch self {
        case .verified(let tcb, _, _): return tcb == .revoked
        case .failed: return true
        }
    }
}

struct DCAPService {
    let verifier: DCAPVerifier

    // IntelPCSCollateralProvider caches the shareable per-FMSPC collateral
    // itself, so a record's gateway/model/GPU quotes cost one PCS round trip
    // while each still verifies against its own PCK chain.
    init(collateral: CollateralProvider = IntelPCSCollateralProvider()) {
        self.verifier = DCAPVerifier(collateral: collateral)
    }

    /// DCAP-verifies every quote in `record`. `nowSecs` defaults to the
    /// record's fetch time — collateral is fetched fresh, so that time is
    /// inside its validity window.
    func verify(record: AttestationRecord, nowSecs: UInt64? = nil) async -> RecordDCAPVerification {
        let now = nowSecs ?? UInt64(record.fetchedAt.timeIntervalSince1970)
        var result = RecordDCAPVerification()
        result.gateway = await verifyQuote(record.intelQuote, label: "gateway",
                                           crossCheck: record.quoteVerification, nowSecs: now)
        result.model = await verifyQuote(record.modelIntelQuote, label: "model",
                                         crossCheck: record.modelQuoteVerification, nowSecs: now)
        result.gpu = await verifyQuote(record.gpuIntelQuote, label: "gpu",
                                       crossCheck: record.gpuQuoteVerification, nowSecs: now)
        return result
    }

    private func verifyQuote(
        _ quoteHex: String?, label: String,
        crossCheck: TDXVerificationResult?, nowSecs: UInt64
    ) async -> DCAPVerification? {
        guard let quoteHex, !quoteHex.isEmpty else { return nil }
        let outcome = await verifier.verify(quoteHex: quoteHex, nowSecs: nowSecs)
        guard case .verified(let tcb, let mrConfig, let reportData) = outcome else {
            logger.warning("[dcap] \(label, privacy: .public) quote failed: \(String(describing: outcome), privacy: .public)")
            return outcome
        }
        // Cross-check tripwire: the Swift parser and dcap-qvl must agree on
        // the measurements. A disagreement means one of them is wrong about
        // security-critical bytes — fail the quote and say so.
        if let swiftParse = crossCheck?.measurements {
            let swiftMrConfig = swiftParse.mrConfigID.hexString.lowercased()
            let swiftReportData = swiftParse.reportData.hexString.lowercased()
            if swiftMrConfig != mrConfig.lowercased() || swiftReportData != reportData.lowercased() {
                logger.fault("[dcap] \(label, privacy: .public) CROSS-CHECK MISMATCH — Swift parser and dcap-qvl disagree on measurements")
                return .failed("measurement cross-check mismatch between verifiers")
            }
        }
        logger.info("[dcap] \(label, privacy: .public) quote verified — tcb=\(tcb.rawValue, privacy: .public)")
        return outcome
    }
}
