//
//  ListedTrustScopeTests.swift
//  teemoonTests
//
//  Audit 1.1.1 A4: every enclave near.ai lists holds the sealed key, so each gets the read enclave's trust scope
//  (compose-manager action-log binding, boot-log replay, running pairs) through TrustScope.run, on its own entry, its
//  own quote and the list's nonce. A mismatch blocks like the read one's; a log teemoon couldn't check asks. Before
//  A4 a listed enclave with no boot event log passed as clean (BootLogReplay.check's `.absent` is not a mismatch).
//

import Foundation
import Testing
@testable import teemoon

@Suite("Every listed enclave's trust scope (A4)", .serialized)
@MainActor
struct ListedTrustScopeTests {
    /// Models near.ai set up with its list loaded: see `NearAIModelCatalog.tierListSeen` (else the tier reads pending).
    init() { NearAIModelCatalog.seeTierListForTests() }


    static let ok = SendGateRuleTests.upToDate
    static let clean = TrustScope(binding: .bound, boot: .matches)

    /// Every DCAP question asked, with its label.
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(quote: String, label: String)] = []
        var all: [(quote: String, label: String)] { lock.withLock { seen } }
        func add(_ q: String, _ l: String) { lock.withLock { seen.append((q, l)) } }
    }

    static func offlinePairs() -> RunningPairCheck {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ListedOffline.self]
        return RunningPairCheck(session: URLSession(configuration: config),
                                defaults: UserDefaults(suiteName: "listed-scope-\(UUID().uuidString)")!)
    }

    static func listed(_ list: [[String: Any]], nonce: String, key: Data) throws -> ModelCandidates.Listed {
        let body = try JSONSerialization.data(withJSONObject: ["model_attestations": list])
        return try #require(ModelCandidates.enclaves(body: body, nonce: nonce, sealedKey: key))
    }

    static func scopes(_ listed: ModelCandidates.Listed, asked: Asked = Asked()) async -> [TrustScope] {
        await ModelCandidates.trustScopes(listed, dcap: { q, l in asked.add(q, l); return Self.ok }, pairs: offlinePairs())
    }

    /// The gate's baseline (everything verified, every listed enclave's own checks clean), with these listed scopes.
    static func session(_ scopes: [TrustScope]?) -> ConfidentialSession {
        let s = ModelCandidatesGateTests.session(ModelCandidatesGateTests.listed([.clean, .clean]))
        s.listedTrustScopes = scopes
        return s
    }

    // MARK: the run, on the live list

    @Test func theLiveListIsBoundAndReplaysOnEachEntrysOwnQuote() async throws {
        let c = try LiveCandidates.load()
        let asked = Asked()
        let scopes = await Self.scopes(try Self.listed(c.list, nonce: c.nonce, key: c.key), asked: asked)
        #expect(scopes.count == 3)
        for (i, scope) in scopes.enumerated() {
            #expect(scope.binding == .bound, "entry \(i): \(scope.binding)")
            #expect(scope.boot == .matches, "entry \(i): \(scope.boot)")
            #expect(!scope.hardBreak && !scope.listedEvidenceAbsent)
        }
        for entry in c.list {
            let quote = entry["intel_quote"] as! String
            #expect(asked.all.contains { $0.quote == quote }, "an entry's own quote never reached DCAP as its node quote")
            let cm = (entry["compose_manager_attestation"] as! [String: Any])["quote"] as! String
            #expect(asked.all.contains { $0.quote == cm }, "an entry's compose-manager quote never reached DCAP")
        }
    }

    @Test func theRunChecksTheListsNonce() async throws {
        let c = try LiveCandidates.load()
        var listed = try Self.listed(c.list, nonce: c.nonce, key: c.key)
        listed.nonce = String(repeating: "00", count: 32)
        let scopes = await Self.scopes(listed)
        #expect(scopes.allSatisfy { $0.binding == .mismatch(.nonce) && $0.hardBreak })
    }

    @Test func aListedActionLogThatIsNotItsQuotesIsAHardBreak() async throws {
        let c = try LiveCandidates.load()
        var bad = c.list[1]
        var cma = bad["compose_manager_attestation"] as! [String: Any]
        var actions = cma["actions"] as! [[String: Any]]
        actions.removeLast()
        cma["actions"] = actions
        bad["compose_manager_attestation"] = cma
        let listed = try Self.listed([c.list[0], bad, c.list[2]], nonce: c.nonce, key: c.key)
        #expect(listed.enclaves.allSatisfy { $0.result == .clean }, "the local checks never read the action log")
        let scopes = await Self.scopes(listed)
        #expect(scopes[1].binding == .mismatch(.actionsHash))
        #expect(!scopes[0].hardBreak && !scopes[2].hardBreak)
        let s = Self.session(scopes)
        #expect(s.sendPolicy == .block)
        #expect(s.degradeIsHardFailure)
    }

    @Test func aListedEntryWithNoBootLogIsCouldntCheck() async throws {
        let c = try LiveCandidates.load()
        let bare = LiveCandidates.editTcb(c.list[2]) { $0.removeValue(forKey: "event_log") }
        let listed = try Self.listed([c.list[0], bare], nonce: c.nonce, key: c.key)
        let scopes = await Self.scopes(listed)
        #expect(scopes[1].boot == .absent && scopes[1].listedEvidenceAbsent && !scopes[1].hardBreak)
        let s = Self.session(scopes)
        #expect(s.sendPolicy == .confirm, "no boot log read as clean")
        #expect(!s.degradeIsHardFailure)
    }

    // MARK: the gate

    @Test func everyCleanListedScopeAllows() {
        #expect(Self.session([Self.clean, Self.clean]).sendPolicy == .allow)
    }

    @Test func aListedBindingMismatchBlocks() {
        let s = Self.session([Self.clean, TrustScope(binding: .mismatch(.actionsHash), boot: .matches)])
        #expect(s.attestationState == .degraded)
        #expect(s.degradeIsHardFailure)
        #expect(s.sendPolicy == .block)
        #expect(s.e2eeDegradedReason == "another enclave near.ai lists for this model failed verification.")
        s.trustScope = TrustScope(binding: .mismatch(.actionsHash), boot: .matches)
        #expect(s.e2eeDegradedReason == TrustScopeText.actionLogBanner, "the read enclave's own line is unchanged")
    }

    @Test func aListedBootLogMismatchBlocks() {
        let s = Self.session([Self.clean, TrustScope(binding: .bound, boot: .mismatch(.rtmr3))])
        #expect(s.degradeIsHardFailure)
        #expect(s.sendPolicy == .block)
        #expect(s.e2eeDegradedReason == "another enclave near.ai lists for this model runs code its boot log doesn't match.")
        s.trustScope = TrustScope(binding: .bound, boot: .mismatch(.rtmr3))
        #expect(s.e2eeDegradedReason == TrustScopeText.bootLogBanner, "the read enclave's own line is unchanged")
    }

    @Test func aListedBindingIntelCouldNotCheckAsks() {
        let s = Self.session([TrustScope(binding: .unchecked, boot: .matches), Self.clean])
        #expect(!s.degradeIsHardFailure)
        #expect(s.sendPolicy == .confirm)
        #expect(s.softButSealed)
    }

    @Test func aListedEnclaveWithNoBootLogOrNoManagerQuoteAsks() {
        for scope in [TrustScope(binding: .bound, boot: .absent), TrustScope(binding: .notBound, boot: .matches)] {
            let s = Self.session([Self.clean, scope])
            #expect(!s.degradeIsHardFailure)
            #expect(s.sendPolicy == .confirm, "\(scope)")
            #expect(s.e2eeDegradedReason == NRASVerification.evidenceAbsent)
        }
    }

    @Test func listedScopesStillRunningHoldTheSend() {
        let s = Self.session(nil)
        #expect(!s.verdictsPending)
        s.listedTrustScopeTask = Task {}
        #expect(s.verdictsPending)
        s.listedTrustScopes = [Self.clean, Self.clean]
        #expect(!s.verdictsPending)
    }

    /// The session starts the listed scopes with the record's own verifiers.
    @Test func adoptingARecordWithAListStartsItsScopes() throws {
        let c = try LiveCandidates.load()
        let s = ConfidentialSession(providers: ConfidentialSessionTests.storeMatchingPreviewRecord(),
                                    dcapService: DCAPService(collateral: ForgedSiblingQuoteTests.RecordingCollateral()),
                                    runningPairCheck: Self.offlinePairs())
        s.attestationTask?.cancel()
        var record = AttestationRecord.preview
        record.modelCandidates = try Self.listed(c.list, nonce: c.nonce, key: c.key)
        s.verifyTrustScope(for: record)
        #expect(s.listedTrustScopeTask != nil)
        #expect(s.verdictsPending)
        s.listedTrustScopeTask?.cancel()
    }

    /// Audit read of 1fe69e3d: the listed verdicts and the listed trust scopes ask about the same quote bytes, so one
    /// record's quotes each go to Intel once (listed nodes, compose managers, the record's own legs).
    @Test func eachQuoteOfARecordGoesToIntelOnce() async throws {
        let c = try LiveCandidates.load()
        let collateral = ForgedSiblingQuoteTests.RecordingCollateral()
        let s = ConfidentialSession(providers: ConfidentialSessionTests.storeMatchingPreviewRecord(),
                                    dcapService: DCAPService(collateral: collateral), runningPairCheck: Self.offlinePairs())
        s.attestationTask?.cancel()
        var record = AttestationRecord.preview
        record.modelCandidates = try Self.listed(c.list, nonce: c.nonce, key: c.key)
        s.verifyQuotes(for: record)
        await waitFor(timeout: .seconds(30)) { s.dcapVerification != nil && s.listedTrustScopes != nil }
        #expect(s.dcapVerification?.listed.count == 3)
        #expect(s.listedTrustScopes?.count == 3)
        let asked = collateral.quotes
        for listed in c.list {
            let quote = try Data(hexString: listed["intel_quote"] as! String)
            #expect(asked.filter { $0 == quote }.count == 1, "a listed quote went to Intel \(asked.filter { $0 == quote }.count) times")
        }
        #expect(asked.count > 3, "the compose managers' quotes were never asked")
        #expect(Set(asked).count == asked.count, "\(asked.count - Set(asked).count) quote(s) went to Intel twice")
    }

    // MARK: the key-custody line

    @Test func theListedStateReadsTheListedScopes() {
        let r = KeyCustodyListedStatesTests.record([.clean, .clean])
        let d = KeyCustodyListedStatesTests.dcap([Self.ok, Self.ok])
        func state(_ scopes: [TrustScope]?) -> KeyCustodyCopy.Listed {
            KeyCustodyCopy.listed(record: r, dcap: d, gpu: .verified, scopes: scopes)
        }
        #expect(state([Self.clean, Self.clean]) == .checked)
        #expect(state(nil) == .checking)
        #expect(state([Self.clean]) == .checking)
        #expect(state([Self.clean, TrustScope(binding: .bound, boot: .absent)]) == .unfinished)
        #expect(state([Self.clean, TrustScope(binding: .unchecked, boot: .matches)]) == .unfinished)
        #expect(state([Self.clean, TrustScope(binding: .notBound, boot: .matches)]) == .unfinished)
        #expect(state([Self.clean, TrustScope(binding: .mismatch(.nonce), boot: .matches)]) == .failed)
        #expect(state([TrustScope(binding: .bound, boot: .mismatch(.composeHash)), Self.clean]) == .failed)
    }
}

private final class ListedOffline: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}
