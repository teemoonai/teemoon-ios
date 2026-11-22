//
//  KeyCustodyListedStatesTests.swift
//  teemoonTests
//
//  Audit 1.1.1 A7: "teemoon checked every enclave near.ai listed" only when the list was read and every entry passed,
//  DCAP included. Card key-custody-listed-states v2 (approved 2026-11-19): five states, everyday = expert, no "chips".
//

import Foundation
import Testing
@testable import teemoon

@Suite("Key custody: the listed enclaves' state (A7)")
struct KeyCustodyListedStatesTests {

    static let upToDate = DCAPVerification.verified(tcbStatus: .upToDate, mrConfigIdHex: "", reportDataHex: "")

    static func record(_ results: [ModelCandidates.Result]?, listFailed: Bool = false) -> AttestationRecord {
        var r = AttestationRecord.preview
        r.modelCandidates = results.map(ModelCandidatesGateTests.listed)
        r.modelCandidatesListFailed = listFailed
        return r
    }

    static func clean(_ n: Int) -> [TrustScope] { Array(repeating: TrustScope(binding: .bound, boot: .matches), count: n) }

    static func dcap(_ listed: [DCAPVerification]) -> RecordDCAPVerification {
        var d = RecordDCAPVerification()
        d.model = upToDate
        d.listed = listed
        return d
    }

    @Test func everyStateFromWhatTeemoonKnows() {
        let clean: [ModelCandidates.Result] = [.clean, .clean]
        #expect(KeyCustodyCopy.listed(record: Self.record(clean), dcap: Self.dcap([Self.upToDate, Self.upToDate]), gpu: .verified, scopes: Self.clean(2)) == .checked)
        #expect(KeyCustodyCopy.listed(record: Self.record(nil, listFailed: true), dcap: Self.dcap([]), gpu: .verified, scopes: Self.clean(2)) == .listFailed)
        #expect(KeyCustodyCopy.listed(record: Self.record(clean), dcap: nil, gpu: .verified, scopes: Self.clean(2)) == .checking)
        #expect(KeyCustodyCopy.listed(record: Self.record(nil), dcap: Self.dcap([]), gpu: .verified, scopes: Self.clean(2)) == .checking)
        #expect(KeyCustodyCopy.listed(record: Self.record(clean), dcap: Self.dcap([Self.upToDate]), gpu: .verified, scopes: Self.clean(2)) == .checking)
        #expect(KeyCustodyCopy.listed(record: Self.record(clean), dcap: Self.dcap([Self.upToDate, .unchecked("pcs")]), gpu: .verified, scopes: Self.clean(2)) == .unfinished)
        #expect(KeyCustodyCopy.listed(record: Self.record([.clean, .mismatch(.bootLog)]),
                                      dcap: Self.dcap([Self.upToDate, Self.upToDate]), gpu: .verified, scopes: Self.clean(2)) == .failed)
        #expect(KeyCustodyCopy.listed(record: Self.record(clean), dcap: Self.dcap([Self.upToDate, .failed("x")]), gpu: .verified, scopes: Self.clean(2)) == .failed)
    }

    @Test func aListThatDidNotLoadNeverReadsChecked() {
        let input = TrustVerdict.Input(attestationState: .ok, e2eeKeyBound: true, listedEnclaves: .listFailed)
        let sealed = TrustVerdict.make(input).everydayClaims.first { $0.id == "sealed" }
        #expect(sealed?.detail.hasSuffix("teemoon couldn't load near.ai's list of enclaves, so it couldn't check them.") == true)
        #expect(sealed?.detail.contains("checked every") == false)
        #expect(KeyCustodyCopy.keyHeldEveryday(listed: .listFailed)
                .hasSuffix("teemoon couldn't load near.ai's list, so it couldn't check them."))
        #expect(!KeyCustodyCopy.keyInQuoteExpert(model: "m", listed: .listFailed).contains("checked every"))
    }

    @Test func theApprovedSentences() {
        #expect(KeyCustodyCopy.listedSentence(.checked) == "teemoon checked every enclave near.ai listed.")
        #expect(KeyCustodyCopy.listedSentence(.checking) == "teemoon is checking the enclaves near.ai listed…")
        #expect(KeyCustodyCopy.listedSentence(.unfinished) == "teemoon couldn't finish checking the enclaves near.ai listed.")
        #expect(KeyCustodyCopy.listedSentence(.failed) == "one of the enclaves near.ai listed failed teemoon's check.")
        #expect(KeyCustodyCopy.listedTail(.checked) == "teemoon checked each one near.ai listed.")
        #expect(KeyCustodyCopy.listedTail(.unfinished) == "teemoon couldn't finish checking the ones near.ai listed.")
        #expect(KeyCustodyCopy.keyHeldEverydayTitle == "near.ai's secure enclaves hold the key")
    }

    @Test func noKeyCustodyLineSaysChips() {
        let states: [KeyCustodyCopy.Listed] = [.checked, .listFailed, .checking, .unfinished, .failed]
        for s in states {
            for line in [KeyCustodyCopy.sealedDetail(device: "d", model: "m", listed: s),
                         KeyCustodyCopy.keyInQuoteExpert(model: "m", listed: s),
                         KeyCustodyCopy.keyHeldEveryday(listed: s), KeyCustodyCopy.keyHeldEverydayTitle] {
                #expect(!line.contains("chip"), "\(line)")
            }
        }
    }

    /// Audit read of a6f11ac7: the GPU verdict is one of the listed checks too (A3 covers every listed enclave).
    @Test func theGPUVerdictIsAListedCheck() {
        let r = Self.record([.clean, .clean]), d = Self.dcap([Self.upToDate, Self.upToDate])
        #expect(KeyCustodyCopy.listed(record: r, dcap: d, gpu: .failed("NVIDIA rejected the evidence"), scopes: Self.clean(2)) == .failed)
        #expect(KeyCustodyCopy.listed(record: r, dcap: d, gpu: .inconclusive(NRASVerification.evidenceAbsent), scopes: Self.clean(2)) == .unfinished)
        #expect(KeyCustodyCopy.listed(record: r, dcap: d, gpu: .inconclusive("NRAS unreachable"), scopes: Self.clean(2)) == .unfinished)
        #expect(KeyCustodyCopy.listed(record: r, dcap: d, gpu: .listedInconclusive(nvidia: "NRAS unreachable"), scopes: Self.clean(2)) == .unfinished)
        #expect(KeyCustodyCopy.listed(record: r, dcap: d, gpu: nil, scopes: Self.clean(2)) == .checking)
        #expect(KeyCustodyCopy.listed(record: r, dcap: d, gpu: .verified, scopes: Self.clean(2)) == .checked)
    }

    /// Design review 2026-11-20: a green mark sat beside "teemoon is checking / couldn't load / couldn't finish …".
    /// The everyday sealed row and the expert "bound" node both take `TrustVerdict.sealedStatus`.
    @Test func theSealedMarkFollowsTheListedEnclaves() {
        let expected: [(KeyCustodyCopy.Listed, TrustClaim.Status)] = [
            (.checked, .ok), (.checking, .pending), (.listFailed, .alert), (.unfinished, .alert), (.failed, .fail)]
        for (listed, status) in expected {
            #expect(TrustVerdict.sealedStatus(hardwareChecksPending: false, listed: listed) == status, "\(listed)")
            let row = TrustVerdict.make(.init(attestationState: .ok, e2eeKeyBound: true, listedEnclaves: listed))
                .everydayClaims.first { $0.id == "sealed" }
            #expect(row?.status == status, "sealed row, \(listed)")
        }
        #expect(TrustVerdict.sealedStatus(hardwareChecksPending: true, listed: .checked) == .pending)
        #expect(TrustVerdict.sealedStatus(hardwareChecksPending: true, listed: .failed) == .fail)
    }

    /// Audit 1.1.1 A7 read: once the verdict deadline passed the send ask says the checks didn't finish, so a listed
    /// check still unanswered must not read "teemoon is checking…" beside it.
    @Test func aListedCheckStillMissingAtTheDeadlineReadsUnfinished() {
        let r = Self.record([.clean, .clean]), d = Self.dcap([Self.upToDate, Self.upToDate])
        let missing: [(RecordDCAPVerification?, NRASVerification?, [TrustScope]?)] = [
            (nil, .verified, Self.clean(2)), (Self.dcap([Self.upToDate]), .verified, Self.clean(2)),
            (d, nil, Self.clean(2)), (d, .verified, nil), (d, .verified, Self.clean(1))]
        for (dcap, gpu, scopes) in missing {
            #expect(KeyCustodyCopy.listed(record: r, dcap: dcap, gpu: gpu, scopes: scopes) == .checking)
            #expect(KeyCustodyCopy.listed(record: r, dcap: dcap, gpu: gpu, scopes: scopes, deadlinePassed: true) == .unfinished)
        }
        #expect(KeyCustodyCopy.listed(record: Self.record(nil), dcap: nil, gpu: nil, scopes: nil, deadlinePassed: true) == .unfinished)
        // What arrived still decides: the deadline never turns a pass or a failure into "couldn't finish".
        #expect(KeyCustodyCopy.listed(record: r, dcap: d, gpu: .verified, scopes: Self.clean(2), deadlinePassed: true) == .checked)
        #expect(KeyCustodyCopy.listed(record: r, dcap: d, gpu: .failed("x"), scopes: nil, deadlinePassed: true) == .failed)
        #expect(KeyCustodyCopy.listed(record: Self.record(nil, listFailed: true), dcap: nil, gpu: nil, scopes: nil,
                                      deadlinePassed: true) == .listFailed)

        func summary(_ passed: Bool) -> AttestationSummary {
            AttestationSummary(attestation: r, state: .ok, timedOut: false, provider: nil, lastRequestUsedE2EE: true,
                               lastE2EEFailReason: nil, verifiedResponseCount: 0, mismatchedResponseCount: 0,
                               attestationFetchFailed: false, dcapVerification: d, nrasVerification: nil,
                               listedTrustScopes: Self.clean(2), deadlinePassed: passed)
        }
        func sealed(_ s: AttestationSummary) -> TrustClaim? {
            TrustVerdict.make(.init(attestationState: .ok, e2eeKeyBound: true, listedEnclaves: s.listedEnclaves))
                .everydayClaims.first { $0.id == "sealed" }
        }
        #expect(summary(false).listedEnclaves == .checking)
        #expect(sealed(summary(false))?.status == .pending)
        #expect(summary(true).listedEnclaves == .unfinished)
        let row = sealed(summary(true))
        #expect(row?.status == .alert)
        #expect(row?.detail.hasSuffix("teemoon couldn't finish checking the enclaves near.ai listed.") == true)
        #expect(row?.detail.contains("is checking") == false)
    }
    /// Audit 1.1.1 (review of 65's source): a listed enclave's running compose file that couldn't be compared (fetch
    /// failed, past the pair cap, budget spent) left the sentence at "checked every enclave". It reads unfinished.
    @Test func aRunningFileThatCouldntBeComparedIsUnfinished() {
        let r = Self.record([.clean, .clean])
        let d = Self.dcap([Self.upToDate, Self.upToDate])
        let src = ActionLogReading.Source(commit: "c", file: "f", fileSHA256: "s")
        let svc = ActionLogReading.RunningService(service: "proxy", source: src, tag: nil, since: nil)
        func scopes(_ outcome: RunningPairCheck.Outcome) -> [TrustScope] {
            var s = TrustScope(binding: .bound, boot: .matches)
            s.running = [.init(service: svc, outcome: outcome)]
            return [TrustScope(binding: .bound, boot: .matches), s]
        }
        for outcome in [RunningPairCheck.Outcome.inconclusive, .notFetched, .unpublished] {
            #expect(KeyCustodyCopy.listed(record: r, dcap: d, gpu: .verified, scopes: scopes(outcome)) == .unfinished, "\(outcome)")
        }
        #expect(KeyCustodyCopy.listed(record: r, dcap: d, gpu: .verified, scopes: scopes(.verified)) == .checked)
        #expect(KeyCustodyCopy.listed(record: r, dcap: d, gpu: .verified, scopes: scopes(.mismatch)) == .failed)
    }
}
