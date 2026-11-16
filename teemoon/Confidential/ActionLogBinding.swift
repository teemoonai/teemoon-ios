//
//  ActionLogBinding.swift
//  teemoon
//
//  Trust scope (a) and (b), 1.1.0: the compose manager's own quote binds the action log, and the boot
//  event log binds compose_hash and os_image_hash to the model node's quote. Pure checks; the spec and
//  the live fixture are conformance/nearai-trust (audit, 2026-10-30).
//

import CryptoKit
import Foundation

/// The TD report inside a TDX quote: the fields the two checks compare.
struct TDReport: Equatable {
    let mrtd: Data
    let mrConfigID: Data
    let rtmr0: Data
    let rtmr1: Data
    let rtmr2: Data
    let rtmr3: Data
    let reportData: Data

    /// Body = quote[48..<632]; offsets inside it from the TDX spec.
    init?(quote: Data) {
        let q = Data(quote)
        guard q.count >= 632 else { return nil }
        let body = Data(q[48..<632])
        func field(_ r: Range<Int>) -> Data { Data(body[r]) }
        mrtd = field(136..<184)
        mrConfigID = field(184..<232)
        rtmr0 = field(328..<376)
        rtmr1 = field(376..<424)
        rtmr2 = field(424..<472)
        rtmr3 = field(472..<520)
        reportData = field(520..<584)
    }

    /// Same TD: never pinned to constants, they change with every OS or compose change.
    func sameTD(as other: TDReport) -> Bool {
        mrtd == other.mrtd && rtmr0 == other.rtmr0 && rtmr1 == other.rtmr1
            && rtmr2 == other.rtmr2 && rtmr3 == other.rtmr3
    }
}

enum ActionLogBinding {
    enum Mismatch: String, Equatable, Sendable {
        /// DCAP didn't verify the compose manager's quote.
        case quote
        /// report_data[0..<32] isn't SHA256 of the canonical actions.
        case actionsHash
        /// report_data[32..<64] isn't the nonce this app sent.
        case nonce
        /// The two quotes come from different TDs.
        case sameTD
        /// The two quotes' TCB verdicts differ.
        case tcbDiffers
    }

    enum Result: Equatable, Sendable {
        case bound
        /// No compose-manager quote in the report: the log is what near.ai reports, not proven.
        case notBound
        /// Intel couldn't be asked about one of the quotes; every local check passed. Soft, never hard.
        case unchecked
        case mismatch(Mismatch)
    }

    /// DCAP's answer, as (a) needs it.
    enum Hardware: Equatable, Sendable { case verified, failed, unchecked }
    /// The two quotes' TCB verdicts.
    enum TCB: Equatable, Sendable { case agree, differ, unchecked }

    /// JSON of the parsed actions array: keys sorted, compact, raw UTF-8. Built from the parsed value, never
    /// a typed struct, so fields this app doesn't know still count.
    static func canonical(_ actions: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(actions) else { return nil }
        return try? JSONSerialization.data(withJSONObject: actions, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// In the spec's order. `hardware` and `tcb` come from DCAP, run on the compose manager's quote exactly as
    /// on the model node's. `nonce` is what this app sent, never the response's own field. An Intel outage
    /// never reads as a mismatch (near-send-gate-rule); the local checks still break hard.
    static func check(actions: Any?, cmQuote: Data?, nodeQuote: Data?, nonce: Data,
                      hardware: Hardware, tcb: TCB) -> Result {
        guard let cmQuote, let actions else { return .notBound }
        guard hardware != .failed, let cm = TDReport(quote: cmQuote) else { return .mismatch(.quote) }
        guard let preimage = canonical(actions),
              Data(SHA256.hash(data: preimage)) == cm.reportData.prefix(32) else { return .mismatch(.actionsHash) }
        guard cm.reportData.suffix(32) == nonce else { return .mismatch(.nonce) }
        guard let nodeQuote, let node = TDReport(quote: nodeQuote), cm.sameTD(as: node) else { return .mismatch(.sameTD) }
        guard tcb != .differ else { return .mismatch(.tcbDiffers) }
        return hardware == .unchecked || tcb == .unchecked ? .unchecked : .bound
    }
}

enum BootLogReplay {
    enum Mismatch: String, Equatable, Sendable {
        case rtmr3
        case eventDigest
        case composeHash
        case osImageHash
    }

    enum Result: Equatable, Sendable {
        case matches
        /// No boot event log, or no compose-hash event in it.
        case absent
        case mismatch(Mismatch)
    }

    struct Entry: Equatable {
        let imr: Int
        let eventType: UInt32
        let digest: Data
        let event: String
        let payload: Data
    }

    /// `info.tcb_info.event_log`. imr and event_type arrive as numbers or as decimal strings.
    static func entries(from json: Any?) -> [Entry]? {
        guard let rows = json as? [[String: Any]] else { return nil }
        func int(_ v: Any?) -> Int? {
            if let n = v as? NSNumber { return n.intValue }
            if let s = v as? String { return Int(s) }
            return nil
        }
        var out: [Entry] = []
        for row in rows {
            guard let imr = int(row["imr"]), let type = int(row["event_type"]), let t = UInt32(exactly: type),
                  let digest = (row["digest"] as? String).flatMap({ try? Data(hexString: $0) }),
                  let payload = (row["event_payload"] as? String).flatMap({ try? Data(hexString: $0) }) else { return nil }
            out.append(Entry(imr: imr, eventType: t, digest: digest, event: row["event"] as? String ?? "", payload: payload))
        }
        return out
    }

    /// SHA384(u32le(event_type) || ":" || event || ":" || payload).
    static func digest(of e: Entry) -> Data {
        var bytes = withUnsafeBytes(of: e.eventType.littleEndian) { Data($0) }
        bytes.append(Data(":".utf8)); bytes.append(Data(e.event.utf8)); bytes.append(Data(":".utf8)); bytes.append(e.payload)
        return Data(SHA384.hash(data: bytes))
    }

    static func replay(_ entries: [Entry]) -> Data {
        entries.filter { $0.imr == 3 }.reduce(Data(count: 48)) { Data(SHA384.hash(data: $0 + $1.digest)) }
    }

    static func check(entries: [Entry]?, nodeRTMR3: Data, appCompose: String?, osImageHash: Data?) -> Result {
        guard let entries, !entries.isEmpty,
              let compose = entries.last(where: { $0.imr == 3 && $0.event == "compose-hash" }) else { return .absent }
        guard replay(entries) == nodeRTMR3 else { return .mismatch(.rtmr3) }
        let os = entries.last(where: { $0.imr == 3 && $0.event == "os-image-hash" })
        for relied in [compose, os].compactMap({ $0 }) where digest(of: relied) != relied.digest {
            return .mismatch(.eventDigest)
        }
        guard let appCompose, compose.payload == Data(SHA256.hash(data: Data(appCompose.utf8))) else {
            return .mismatch(.composeHash)
        }
        if let os, let osImageHash, os.payload != osImageHash { return .mismatch(.osImageHash) }
        return .matches
    }
}
