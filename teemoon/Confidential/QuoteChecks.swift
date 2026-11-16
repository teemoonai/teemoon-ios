//
//  QuoteChecks.swift
//  teemoon
//
//  teemoon's own checks on a TDX quote (near.ai inference-sdk ff591054 policies). DCAPService runs them before
//  Intel is asked, so their verdict never waits on PCS or on dcap-qvl's policy.
//

import Foundation
import TDXQuoteVerifier

enum QuoteChecks {
    /// dcap-qvl's own words for a debug TD (verify.rs:970): the DCAP row reads the same whichever check caught it.
    static let debugTD = "Debug mode is enabled"
    /// The parser/dcap-qvl tripwire's words, reused: two readings of one quote's report_data disagree.
    static let reportDataDisagrees = "measurement cross-check mismatch between verifiers"

    /// TDATTRIBUTES byte 0 is TUD and its bit 0 is DEBUG. Do not widen this to other bits: dcap-qvl owns those.
    static func debugEnabled(tdAttributes: Data) -> Bool {
        guard let tud = tdAttributes.first else { return true }
        return tud & 0x01 != 0
    }

    /// A report_data the report advertises must be the quote's own. Absent is nothing to compare.
    static func advertisedMatches(_ advertised: String?, quoteReportDataHex: String) -> Bool {
        guard let advertised else { return true }
        return advertised.lowercased() == quoteReportDataHex.lowercased()
    }

    /// dstack's MRCONFIGID: 0x01 ‖ sha256(app_compose), zero-padded.
    static func mrConfigCommits(_ mrConfigID: Data, toComposeSHA256 hex: String) -> Bool {
        mrConfigID.hexString.lowercased().hasPrefix("01" + hex.lowercased())
    }

    /// Evidence in the quote's own bytes; nil when there is none or it doesn't parse (dcap-qvl then fails it).
    static func failure(quoteHex: String, advertisedReportData: String? = nil) -> String? {
        guard let quote = try? QuoteParser.parse(hex: quoteHex) else { return nil }
        if debugEnabled(tdAttributes: quote.body.tdAttributes) { return debugTD }
        if !advertisedMatches(advertisedReportData, quoteReportDataHex: quote.body.reportData.hexString) {
            return reportDataDisagrees
        }
        return nil
    }
}
