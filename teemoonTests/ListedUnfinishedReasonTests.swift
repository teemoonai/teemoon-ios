//
//  ListedUnfinishedReasonTests.swift
//  teemoonTests
//
//  2026-11-20 (reuses A7 copy): a LISTED enclave's DCAP that Intel couldn't check names the listed enclaves, never
//  the read enclave's "intel's hardware check couldn't be completed (service unreachable).", which keeps its own line.
//

import Foundation
import Testing
@testable import teemoon

@MainActor
@Suite("The listed-unfinished reason line")
struct ListedUnfinishedReasonTests {

    static let intel = "intel's hardware check couldn't be completed (service unreachable)."

    @Test func aListedEnclavesUncheckedDCAPNamesTheListedEnclaves() {
        let s = EnclaveListAskTests.session(ModelCandidatesGateTests.listed([.clean]))
        s.dcapVerification?.listed = [.unchecked("collateral: pcs unreachable")]
        #expect(s.e2eeDegradedReason == "teemoon couldn't finish checking the enclaves near.ai listed.")
        #expect(s.e2eeDegradedReason == KeyCustodyCopy.listedSentence(.unfinished))
    }

    @Test func theReadEnclavesUncheckedDCAPKeepsItsLine() {
        let read = EnclaveListAskTests.session(ModelCandidatesGateTests.listed([.clean]))
        read.dcapVerification?.listed = [SendGateRuleTests.upToDate]
        read.dcapVerification?.model = .unchecked("collateral: pcs unreachable")
        #expect(read.e2eeDegradedReason == Self.intel)

        let both = EnclaveListAskTests.session(ModelCandidatesGateTests.listed([.clean]))
        both.dcapVerification?.listed = [.unchecked("collateral: pcs unreachable")]
        both.dcapVerification?.gateway = .unchecked("collateral: pcs unreachable")
        #expect(both.e2eeDegradedReason == Self.intel, "the read leg is named first")
    }

    /// A10 gap (2026-11-20): a listed enclave's NVIDIA leg that couldn't be checked takes the same A7 line, and asks.
    @Test func aListedEnclavesUncheckedNVIDIANamesTheListedEnclaves() {
        for nvidia in ["NVIDIA attestation service unreachable", NRASVerification.evidenceAbsent, NRASVerification.teemoonFault] {
            let s = EnclaveListAskTests.session(ModelCandidatesGateTests.listed([.clean]))
            s.gpuAttestation = .listedInconclusive(nvidia: nvidia)
            #expect(s.e2eeDegradedReason == KeyCustodyCopy.listedSentence(.unfinished), "\(nvidia)")
            #expect(s.sendPolicy == .confirm, "\(nvidia)")
        }
        let read = EnclaveListAskTests.session(ModelCandidatesGateTests.listed([.clean]))
        read.gpuAttestation = .inconclusive(NRASVerification.evidenceAbsent)
        #expect(read.e2eeDegradedReason == NRASVerification.evidenceAbsent, "the read enclave's own line is unchanged")
    }
}
