//
//  TcbAllowListTests.swift
//  teemoonTests
//
//  near.ai inference-sdk (core/dstack_attestation.py) accepts UpToDate and
//  OutOfDate only; the maintainer adopted that 2026-10-19. Before, only Revoked failed.
//  Live 2026-10-19: glm-5.3-flash gateway OutOfDate, model + GPU UpToDate;
//  Qwen3.6-35B OutOfDate on all three — all pass.
//

import Foundation
import Testing
@testable import teemoon

@Suite("TCB allow-list")
struct TcbAllowListTests {

    static func verdict(_ raw: String) -> DCAPVerification {
        .verified(tcbStatus: DCAPTcbStatus(rawStatus: raw), mrConfigIdHex: "", reportDataHex: "")
    }

    @Test(arguments: ["UpToDate", "OutOfDate"])
    func accepted(_ raw: String) {
        #expect(!Self.verdict(raw).isHardFailure, "\(raw)")
        #expect(RecordDCAPVerification(gateway: Self.verdict("OutOfDate"), model: Self.verdict(raw), gpu: Self.verdict("UpToDate")).failureReason == nil)
    }

    @Test(arguments: ["Revoked", "ConfigurationNeeded", "SWHardeningNeeded", "ConfigurationAndSWHardeningNeeded",
                      "OutOfDateConfigurationNeeded", "Unknown", ""])
    func rejected(_ raw: String) {
        #expect(Self.verdict(raw).isHardFailure, "\(raw)")
        let record = RecordDCAPVerification(gateway: Self.verdict("UpToDate"), model: Self.verdict(raw), gpu: nil)
        #expect(record.hasHardFailure, "\(raw)")
        #expect(record.failureReason?.hasPrefix("model quote") == true, "\(raw)")
    }

    @Test func liveStatusesPass() {
        let glm = RecordDCAPVerification(gateway: Self.verdict("OutOfDate"), model: Self.verdict("UpToDate"), gpu: Self.verdict("UpToDate"))
        let qwen = RecordDCAPVerification(gateway: Self.verdict("OutOfDate"), model: Self.verdict("OutOfDate"), gpu: Self.verdict("OutOfDate"))
        #expect(!glm.hasHardFailure && !qwen.hasHardFailure)
    }
}
