//
//  ModelCandidatesTests.swift
//  teemoonTests
//
//  SDK track C3a (docs/NEARAI_SDK_C.md §C3): every enclave near.ai lists for a model holds the key a sealed request
//  goes to, so each must pass the checks the one teemoon read always passed. Live capture 2026-11-19: three
//  glm-5.3-flash enclaves, one key, three compose hashes. teemoon checks every LISTED enclave; enclaves the key
//  service admits but near.ai doesn't list stay a residual (the key is derived from app_id).
//

import Foundation
import Testing
@testable import teemoon

enum LiveCandidates {
    struct Capture {
        let body: Data
        let nonce: String
        let list: [[String: Any]]
        var key: Data { try! Data(hexString: list[0]["signing_public_key"] as! String) }
    }

    static func load() throws -> Capture {
        let root = try JSONSerialization.jsonObject(with: TestFixture.data("nearai_live_glm53flash_candidates_20261119.json")) as! [String: Any]
        let report = root["report"] as! [String: Any]
        return Capture(body: try JSONSerialization.data(withJSONObject: report), nonce: root["nonce"] as! String,
                       list: report["model_attestations"] as! [[String: Any]])
    }

    static func editTcb(_ c: [String: Any], _ edit: (inout [String: Any]) -> Void) -> [String: Any] {
        var c = c
        var info = c["info"] as! [String: Any]
        var tcb = info["tcb_info"] as! [String: Any]
        edit(&tcb)
        info["tcb_info"] = tcb; c["info"] = info
        return c
    }
}

@Suite("Every listed enclave (C3a)")
struct ModelCandidatesTests {

    @Test func theLiveListIsThreeEnclavesWithOneKey() throws {
        let c = try LiveCandidates.load()
        let list = ModelCandidates.list(fromGatewayReport: c.body)
        #expect(list.count == 3)
        #expect(Set(list.map { $0["signing_public_key"] as? String }).count == 1)
    }

    @Test func everyLiveEnclavePasses() throws {
        let c = try LiveCandidates.load()
        for candidate in c.list {
            #expect(ModelCandidates.check(candidate, sealedKey: c.key, nonceHex: c.nonce) == .clean)
        }
    }

    @Test func anEnclaveWithAnotherKeyIsEvidence() throws {
        let c = try LiveCandidates.load()
        #expect(ModelCandidates.check(c.list[1], sealedKey: Data(repeating: 0xAB, count: 32), nonceHex: c.nonce)
                == .mismatch(.keyDiffers))
    }

    @Test func anEnclaveThatDidNotAnswerOurNonceIsEvidence() throws {
        let c = try LiveCandidates.load()
        #expect(ModelCandidates.check(c.list[2], sealedKey: c.key, nonceHex: String(repeating: "00", count: 32))
                == .mismatch(.nonce))
    }

    @Test func aQuoteThatDoesNotVerifyIsEvidence() throws {
        let c = try LiveCandidates.load()
        var bad = c.list[0]
        var quote = Array((bad["intel_quote"] as! String))
        quote[700] = quote[700] == "0" ? "1" : "0"   // inside the TD report body: the signature no longer covers it
        bad["intel_quote"] = String(quote)
        let result = ModelCandidates.check(bad, sealedKey: c.key, nonceHex: c.nonce)
        #expect(result != .clean)
    }

    @Test func aComposeTheQuoteDoesNotCommitToIsEvidence() throws {
        let c = try LiveCandidates.load()
        let bad = LiveCandidates.editTcb(c.list[1]) { $0["app_compose"] = ($0["app_compose"] as! String) + " " }
        let result = ModelCandidates.check(bad, sealedKey: c.key, nonceHex: c.nonce)
        #expect(result == .mismatch(.mrConfig))
    }

    @Test func aBootLogThatDoesNotReplayIsEvidence() throws {
        let c = try LiveCandidates.load()
        let bad = LiveCandidates.editTcb(c.list[2]) { tcb in
            var events = tcb["event_log"] as! [[String: Any]]
            events.remove(at: events.firstIndex { ($0["event"] as? String) == "instance-id" }!)
            tcb["event_log"] = events
        }
        #expect(ModelCandidates.check(bad, sealedKey: c.key, nonceHex: c.nonce) == .mismatch(.bootLog))
    }

    /// Audit 1.1.1 A15: the entry names the sealed key, its genuine quote binds another: the key isn't the hardware's.
    @Test func aKeyItsQuoteDoesNotBindIsEvidence() throws {
        let c = try LiveCandidates.load()
        let other = Data(repeating: 0xAB, count: 32)
        var bad = c.list[0]
        bad["signing_public_key"] = other.hexString
        #expect(ModelCandidates.check(bad, sealedKey: other, nonceHex: c.nonce) == .mismatch(.keyNotInQuote))
    }

    /// Audit 1.1.1 A15: teemoon's own quote checks run on every listed quote. The debug-TD arm can't be reached on a
    /// genuine signed quote (the bit is under Intel's signature), so the advertised-report_data arm pins the step.
    @Test func teemoonsQuoteChecksRunOnAListedQuote() throws {
        let c = try LiveCandidates.load()
        var bad = c.list[1]
        bad["report_data"] = String(repeating: "ab", count: 64)
        #expect(ModelCandidates.check(bad, sealedKey: c.key, nonceHex: c.nonce) == .mismatch(.quotePolicy))
    }

    /// The fetch keeps the list and each enclave's result; the expert view (C4) reads instance, compose and key service.
    @Test func aFetchKeepsEveryEnclave() async throws {
        let c = try LiveCandidates.load()
        let record = AttestationService.adoptCandidates(body: c.body, nonce: c.nonce, sealedKey: c.key)
        #expect(record?.enclaves.count == 3)
        #expect(record?.enclaves.allSatisfy { $0.result == .clean } == true)
        #expect(Set(record?.enclaves.map(\.composeHash) ?? []).count == 3)
        #expect(record?.enclaves.allSatisfy { $0.mrKMS?.isEmpty == false } == true)
    }

    // MARK: one key, one key service (audit 1.1.1 A13)

    static func enclave(_ provider: String?, _ kms: String?, _ result: ModelCandidates.Result = .clean) -> ModelCandidates.Enclave {
        ModelCandidates.Enclave(instanceID: "i", composeHash: "c", appID: "a", keyProviderID: provider, mrKMS: kms, result: result)
    }

    static func results(_ enclaves: [ModelCandidates.Enclave]) -> [ModelCandidates.Result] {
        ModelCandidates.sameKeyService(enclaves).map(\.result)
    }

    /// Live 2026-11-19: the three glm-5.3-flash enclaves name one key provider (near.ai's KMS, a P-256 key) and one mr-kms.
    @Test func everyLiveEnclaveNamesOneKeyService() throws {
        let c = try LiveCandidates.load()
        let listed = try #require(AttestationService.adoptCandidates(body: c.body, nonce: c.nonce, sealedKey: c.key))
        #expect(Set(listed.enclaves.map(\.keyProviderID)).count == 1)
        #expect(Set(listed.enclaves.map(\.mrKMS)).count == 1)
        #expect(listed.enclaves[0].keyProviderID?.hasPrefix("3059301306072a8648ce3d0201") == true)
        #expect(listed.enclaves[0].mrKMS == "22a6652c0ce74e50b549c0f9c21d53c5861598ec4d58cf3286d158104923bc56")
        #expect(listed.enclaves.allSatisfy { $0.result == .clean })
    }

    @Test func anEnclaveWithAnotherKeyServiceIsEvidence() {
        func e(_ p: String?, _ k: String?, _ r: ModelCandidates.Result = .clean) -> ModelCandidates.Enclave { Self.enclave(p, k, r) }
        #expect(Self.results([e("kms", "aa"), e("kms", "aa"), e("other", "aa")]) == [.clean, .clean, .mismatch(.keyProviderDiffers)])
        #expect(Self.results([e("kms", "aa"), e("kms", "bb")]) == [.clean, .mismatch(.keyProviderDiffers)])
    }

    @Test func aSplitListMarksEveryEnclaveUnlikeTheFirst() {
        func e(_ p: String?, _ k: String?, _ r: ModelCandidates.Result = .clean) -> ModelCandidates.Enclave { Self.enclave(p, k, r) }
        #expect(Self.results([e("a", "k"), e("b", "k"), e("b", "k")])
                == [.clean, .mismatch(.keyProviderDiffers), .mismatch(.keyProviderDiffers)])
        #expect(Self.results([e("a", "k"), e("a", "k"), e("b", "k"), e("b", "k")])
                == [.clean, .clean, .mismatch(.keyProviderDiffers), .mismatch(.keyProviderDiffers)])
    }

    @Test func anEnclaveMissingTheKeyServiceTheOthersNameIsEvidence() {
        func e(_ p: String?, _ k: String?, _ r: ModelCandidates.Result = .clean) -> ModelCandidates.Enclave { Self.enclave(p, k, r) }
        #expect(Self.results([e("kms", "aa"), e(nil, "aa")]) == [.clean, .mismatch(.keyProviderDiffers)])
        #expect(Self.results([e("kms", "aa"), e("kms", nil)]) == [.clean, .mismatch(.keyProviderDiffers)])
        #expect(Self.results([e(nil, nil), e("kms", "aa"), e("kms", "aa")])
                == [.clean, .mismatch(.keyProviderDiffers), .mismatch(.keyProviderDiffers)])
    }

    @Test func noKeyServiceOnAnyEnclaveIsNothingToCompare() {
        func e(_ p: String?, _ k: String?, _ r: ModelCandidates.Result = .clean) -> ModelCandidates.Enclave { Self.enclave(p, k, r) }
        #expect(Self.results([e(nil, nil), e(nil, nil), e(nil, nil)]) == [.clean, .clean, .clean])
    }

    @Test func anEnclaveAlreadyBrokenKeepsItsReason() {
        func e(_ p: String?, _ k: String?, _ r: ModelCandidates.Result = .clean) -> ModelCandidates.Enclave { Self.enclave(p, k, r) }
        #expect(Self.results([e("a", "k"), e("b", "k", .mismatch(.mrConfig))]) == [.clean, .mismatch(.mrConfig)])
    }

    /// Through the list as served: the first enclave's mr-kms event rewritten, the other two no longer agree with it.
    @Test func aLiveListWhoseFirstEnclaveNamesAnotherKMSMarksTheRest() throws {
        let c = try LiveCandidates.load()
        var list = c.list
        list[0] = LiveCandidates.editTcb(list[0]) { tcb in
            var events = tcb["event_log"] as! [[String: Any]]
            let i = events.lastIndex { ($0["event"] as? String) == "mr-kms" }!
            events[i]["event_payload"] = String(repeating: "00", count: 32)
            tcb["event_log"] = events
        }
        let body = try JSONSerialization.data(withJSONObject: ["model_attestations": list])
        let listed = try #require(ModelCandidates.enclaves(body: body, nonce: c.nonce, sealedKey: c.key))
        #expect(listed.enclaves[0].mrKMS == String(repeating: "00", count: 32))
        #expect(listed.enclaves[1].result == .mismatch(.keyProviderDiffers))
        #expect(listed.enclaves[2].result == .mismatch(.keyProviderDiffers))
    }
}

@MainActor
@Suite("Every listed enclave in the gate (C3a)")
struct ModelCandidatesGateTests {

    static func session(_ candidates: ModelCandidates.Listed?, listFailed: Bool = false) -> ConfidentialSession {
        let s = ConfidentialSession(providers: ConfidentialSessionTests.storeMatchingPreviewRecord())
        s.attestationTask?.cancel()
        var record = AttestationRecord.preview
        record.modelCandidates = candidates
        record.modelCandidatesListFailed = listFailed
        s.attestation = record
        s.lastRequestUsedE2EE = true
        s.imageProvenance = .allVerified(verified: [], thirdParty: [])
        s.provenanceSettled = true
        var dcap = RecordDCAPVerification()
        dcap.gateway = SendGateRuleTests.upToDate; dcap.model = SendGateRuleTests.upToDate
        s.dcapVerification = dcap
        s.gpuAttestation = .verified
        s.tlsAttestation = .verified
        s.trustScope = TrustScope(binding: .bound, boot: .matches)
        return s
    }

    static func listed(_ results: [ModelCandidates.Result]) -> ModelCandidates.Listed {
        ModelCandidates.Listed(enclaves: results.enumerated().map {
            ModelCandidates.Enclave(instanceID: "i\($0.offset)", composeHash: "c\($0.offset)", appID: "a",
                                    keyProviderID: nil, mrKMS: nil, result: $0.element)
        })
    }

    @Test func everyCleanEnclaveAllows() {
        #expect(Self.session(Self.listed([.clean, .clean, .clean])).sendPolicy == .allow)
    }

    @Test func oneBrokenEnclaveBlocks() {
        let s = Self.session(Self.listed([.clean, .mismatch(.mrConfig), .clean]))
        #expect(s.degradeIsHardFailure)
        #expect(s.sendPolicy == .block)
        #expect(s.e2eeDegradedReason == "another enclave near.ai lists for this model failed verification.")
    }

    /// Audit 1.1.1 A12 (card trust-copy-sweep-111 v4): an enclave near.ai lists with another key keeps blocking, and says so.
    @Test func anEnclaveWithAnotherKeyBlocksAndSaysSo() {
        let s = Self.session(Self.listed([.clean, .mismatch(.keyDiffers)]))
        #expect(s.sendPolicy == .block)
        #expect(s.e2eeDegradedReason == "near.ai lists an enclave for this model that holds a different key.")
    }

    /// Audit 1.1.1 A10: each check a listed enclave fails on its own names the listed enclave, never the read one.
    @Test(arguments: [ModelCandidates.Mismatch.quoteInvalid, .keyNotInQuote, .nonce, .quotePolicy, .mrConfig])
    func aListedEnclavesOwnCheckNamesTheListedEnclave(_ bad: ModelCandidates.Mismatch) {
        let s = Self.session(Self.listed([.clean, .mismatch(bad)]))
        #expect(s.sendPolicy == .block)
        #expect(s.e2eeDegradedReason == "another enclave near.ai lists for this model failed verification.", "\(bad)")
    }

    /// Audit 1.1.1 A10: a listed enclave whose boot log doesn't replay to its quote has its own line.
    @Test func aListedEnclavesBootLogMismatchHasItsOwnLine() {
        let s = Self.session(Self.listed([.clean, .mismatch(.bootLog)]))
        #expect(s.sendPolicy == .block)
        #expect(s.e2eeDegradedReason == "another enclave near.ai lists for this model runs code its boot log doesn't match.")
    }

    /// Audit 1.1.1 A10: a listed enclave's DCAP rejection names the listed enclave; the read enclave's keeps its line.
    @Test func aListedEnclavesDCAPFailureNamesTheListedEnclave() {
        let s = Self.session(Self.listed([.clean, .clean]))
        s.dcapVerification?.listed = [SendGateRuleTests.upToDate, .failed("signature invalid")]
        #expect(s.sendPolicy == .block)
        #expect(s.e2eeDegradedReason == "another enclave near.ai lists for this model failed verification.")
        s.dcapVerification?.model = .failed("signature invalid")
        #expect(s.e2eeDegradedReason == "the hardware quote failed intel dcap verification.")
    }

    /// Audit 1.1.1 A13: listed enclaves that hold one key but name different key services block like any other mismatch.
    @Test func anEnclaveWithAnotherKeyServiceBlocks() {
        let s = Self.session(Self.listed([.clean, .mismatch(.keyProviderDiffers), .clean]))
        #expect(s.degradeIsHardFailure)
        #expect(s.sendPolicy == .block)
        #expect(s.e2eeDegradedReason == "near.ai's enclaves for this model name different key services for the same key.")
    }

    /// The list couldn't be fetched: an outage, so the send asks; never blocks, never reads verified. Audit 1.1.1 A10:
    /// the reason names the list, not the model's hardware.
    @Test func aListThatNeverCameAsks() {
        let s = Self.session(nil, listFailed: true)
        #expect(!s.degradeIsHardFailure)
        #expect(s.sendPolicy == .confirm)
        #expect(s.e2eeDegradedReason == "teemoon couldn't load near.ai's list of enclaves for this model.")
    }
}
