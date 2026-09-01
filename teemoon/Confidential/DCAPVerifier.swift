//
//  DCAPVerifier.swift
//  teemoon
//
//  Real Intel TDX quote verification via Phala's dcap-qvl (the exact library
//  near.ai's own verifier uses), imported as the DcapQvl Swift package. This
//  performs the full DCAP verification the hand-rolled TDXQuoteVerifier does
//  NOT: Quoting-Enclave report binding and TCB-status evaluation.
//
//  dcap-qvl's verify() takes PCCS collateral as JSON bytes — the host fetches
//  it (see CollateralProvider) so the offline/trust policy stays in Swift.
//  The hand-rolled TDXQuoteVerifier is kept as a display parser and a
//  cross-check tripwire.
//

import DcapQvl
import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "dcap")

/// The outcome of real DCAP quote verification.
enum DCAPVerification: Sendable, Equatable {
    /// Quote verified; `tcbStatus` is Intel's TCB verdict ("UpToDate", "OutOfDate", …).
    case verified(tcbStatus: DCAPTcbStatus, mrConfigIdHex: String, reportDataHex: String)
    case failed(String)

    var isVerified: Bool { if case .verified = self { return true }; return false }
}

/// Intel TCB status, mapped from dcap-qvl. `upToDate` is ideal; `outOfDate`
/// variants mean the hardware is genuine but behind on patches (degrade, don't
/// reject — matching near.ai's own verifier); `revoked` fails.
enum DCAPTcbStatus: String, Sendable, Equatable {
    case upToDate
    case outOfDate
    case configurationNeeded
    case revoked
    case other

    /// Whether this status should count as fully trusted (green) vs. degraded.
    var isFullyTrusted: Bool { self == .upToDate }

    init(rawStatus: String) {
        switch rawStatus.lowercased().replacingOccurrences(of: "_", with: "") {
        case "uptodate": self = .upToDate
        case let s where s.contains("revoked"): self = .revoked
        case let s where s.contains("configuration"): self = .configurationNeeded
        case let s where s.contains("outofdate"): self = .outOfDate
        default: self = .other
        }
    }
}

/// Supplies PCCS collateral for a quote. The concrete Intel-PCS/Phala-PCCS
/// implementation (fetch TCB info, QE identity, CRLs by FMSPC and assemble
/// dcap-qvl's collateral JSON) is the remaining integration step — it needs a
/// live quote + PCS round trip to validate, so it is intentionally behind this
/// seam rather than written untested.
protocol CollateralProvider: Sendable {
    /// Returns dcap-qvl collateral JSON for the given raw quote. Throws with a
    /// descriptive reason (which PCS call, HTTP status, parse error) so a
    /// failure is diagnosable from the UI, not swallowed into a bare nil.
    func collateralJSON(forQuote rawQuote: Data) async throws -> Data
}

struct DCAPVerifier {
    let collateral: CollateralProvider

    /// Verifies a hex-encoded TDX quote. `nowSecs` is the verification time
    /// (use the attestation's fetch time / Rekor-style trusted time).
    func verify(quoteHex: String, nowSecs: UInt64) async -> DCAPVerification {
        guard let rawQuote = try? Data(hexString: quoteHex) else {
            return .failed("quote hex undecodable")
        }
        let collateralJSON: Data
        do {
            collateralJSON = try await collateral.collateralJSON(forQuote: rawQuote)
        } catch {
            // Fail-closed, but keep the specific reason for the UI/logs.
            logger.error("[dcap] collateral unavailable: \(error)")
            return .failed("collateral: \(error)")
        }
        do {
            let report: VerifiedReport = try DcapQvl.verify(
                rawQuote: rawQuote, collateralJson: collateralJSON, nowSecs: nowSecs)
            let status = DCAPTcbStatus(rawStatus: report.status)
            let (mrConfig, reportData) = Self.measurements(from: report.report)
            logger.info("[dcap] verified — tcb=\(report.status, privacy: .public)")
            return .verified(tcbStatus: status, mrConfigIdHex: mrConfig, reportDataHex: reportData)
        } catch {
            logger.error("[dcap] verification failed: \(error)")
            return .failed("\(error)")
        }
    }

    /// Extracts mrConfigId + reportData hex from either TD report variant.
    private static func measurements(from report: Report) -> (mrConfigId: String, reportData: String) {
        switch report {
        case .td10(let r): return (r.mrConfigId.hexString, r.reportData.hexString)
        case .td15(let r): return (r.base.mrConfigId.hexString, r.base.reportData.hexString)
        case .sgx(let r): return ("", r.reportData.hexString)
        }
    }
}
