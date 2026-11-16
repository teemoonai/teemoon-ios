//
//  VerdictDeadlineTests.swift
//  teemoonTests
//
//  Verification always ends in a verdict (the maintainer 2026-11-14). The 1.1.0 regression: with no saved near.ai list and no
//  key (or under --uitesting) nothing loaded near.ai's tier list, the tier stayed unknown, `verdictsPending` held it,
//  and the chat read "verifying…" forever with every verifier answered. Shipped 1.0.6 did not have it (ea192326,
//  ae1430ef, 38647a07 added the unknown-tier hold). formal/ TierTimeout, PendingSettles (TeemoonTrust_tier.cfg).
//

import Foundation
import Testing
@testable import teemoon

@Suite("Every check ends in a verdict")
@MainActor struct VerdictDeadlineTests {

    private func verifiedSession(model: String, deadline: VerdictDeadline) -> ConfidentialSession {
        var provider = Provider.nearAI
        provider.model = model
        provider.requiresAPIKey = false
        let store = ProviderStore(inMemory: true)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let session = ConfidentialSession(providers: store, deadline: deadline)
        session.attestationTask?.cancel()
        var record = AttestationRecord.preview
        record.model = model
        session.attestation = record
        session.lastRequestUsedE2EE = true
        session.imageProvenance = .allVerified(verified: [], thirdParty: [])
        session.provenanceSettled = true
        let ok = DCAPVerification.verified(tcbStatus: .upToDate, mrConfigIdHex: "", reportDataHex: "")
        var dcap = RecordDCAPVerification()
        dcap.gateway = ok; dcap.model = ok
        session.dcapVerification = dcap
        session.gpuAttestation = .verified
        session.tlsAttestation = .verified
        session.trustScope = TrustScope(binding: .bound, boot: .matches)
        return session
    }

    /// Polls until `done` or `bound` passes; true when `done` held.
    private func settles(within bound: Duration, _ done: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + bound
        while ContinuousClock.now < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    @Test func theDecidedDeadlineIsTwentySeconds() {
        #expect(VerdictDeadline.twentySeconds == .seconds(20))
        #expect(VerdictDeadline().after == .seconds(20))
    }

    @Test func anUnknownTierWithNoListEndsInCantCheck() async {
        let model = "zai-org/VD-NO-LIST-PROBE"
        await NearAIModelCatalog.$tierListSeenOverride.withValue(false) {
            let deadline = VerdictDeadline(after: .milliseconds(300), tierRetryDelays: [], loadTierList: { _ in false })
            let session = verifiedSession(model: model, deadline: deadline)
            #expect(session.attestationState == .verifying, "precondition: verifying while the tier is unknown")
            let ended = await settles(within: .seconds(3)) { session.attestationState != .verifying }
            #expect(ended, "still verifying with the tier unknown and no list coming")
            #expect(session.attestationState == .degraded, "read \(session.attestationState)")
            #expect(session.pendingKind == nil, "the given-up tier still holds the send")
            #expect(!session.degradeIsHardFailure, "can't check is soft")
            #expect(session.sendPolicy == .confirm, "the send asks, read \(session.sendPolicy)")
            #expect(session.e2eeDegradedReason == VerdictDeadline.tierReason)
        }
    }

    @Test func aTierListBeforeTheDeadlineGivesTheNormalVerdict() async {
        let model = "zai-org/VD-LIST-ARRIVES-PROBE"
        await NearAIModelCatalog.$tierListSeenOverride.withValue(false) {
            var asked = 0
            let deadline = VerdictDeadline(after: .milliseconds(600), tierRetryDelays: [.milliseconds(20)], loadTierList: { _ in
                asked += 1
                guard asked == 2 else { return false }    // one failure, then the retry lands
                NearAIModelCatalog.recordTiers([model: .teeOwn])
                return true
            })
            let session = verifiedSession(model: model, deadline: deadline)
            let ok = await settles(within: .milliseconds(500)) { session.attestationState == .ok }
            #expect(ok, "read \(session.attestationState); the list was asked \(asked) time(s) without a key")
            try? await Task.sleep(for: .milliseconds(400))
            #expect(session.attestationState == .ok, "the deadline overrode a tier that resolved")
        }
    }

    /// The Where row's green "e2ee" tag (`claimsEndToEndEncryption`) waits on the tier: with no saved list and no
    /// key, the keyless fetch is what lets it show.
    @Test func theKeylessTierFetchShowsTheWhereRowsE2EETag() async {
        let model = "zai-org/VD-WHERE-TAG-PROBE"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LiveCatalogStore(directory: dir)
        let sentKeys = LockedBox([String]())
        store.list = { _, _, key, _ in
            sentKeys.value = sentKeys.value + [key]
            NearAIModelCatalog.recordTiers([model: .teeOwn])   // what fetchLive records from owned_by "nearai"
            return .connected([KnownModel(id: model, displayName: "probe", vendor: "zai-org", price: "")])
        }
        await NearAIModelCatalog.$tierListSeenOverride.withValue(false) {
            let deadline = VerdictDeadline(after: .seconds(5), tierRetryDelays: [],
                                           loadTierList: VerdictDeadline.publicTierList(from: store))
            let session = verifiedSession(model: model, deadline: deadline)
            let provider = session.activeProvider!
            #expect(session.credential(for: provider).isEmpty, "precondition: no key")
            let tagged = await settles(within: .seconds(1)) { session.activeProvider?.claimsEndToEndEncryption == true }
            #expect(tagged, "the Where row's e2ee tag never showed; tier \(NearAIModelCatalog.confidentiality(forID: model))")
            #expect(sentKeys.value == [""], "the tier list must be asked for without a key: \(sentKeys.value)")
            #expect(session.attestationState == .ok)
        }
    }

    enum Input: String, CaseIterable { case dcap, gpu, tls, trustScope, provenance }

    /// Adopts the session's record (arming whatever `adopt` arms), then settles every leg as verified again.
    private func adoptSettled(_ session: ConfidentialSession) {
        session.adopt(session.attestation!, for: session.activeProvider!)
        session.provenanceTask?.cancel(); session.provenanceTask = nil
        session.provenanceRun = UUID()   // adopt's own pass, cancelled, must not settle the planted one
        session.dcapTask?.cancel(); session.dcapTask = nil
        session.nrasTask?.cancel(); session.nrasTask = nil
        session.tlsTask?.cancel(); session.tlsTask = nil
        session.trustScopeTask?.cancel(); session.trustScopeTask = nil
        session.imageProvenance = .allVerified(verified: [], thirdParty: [])
        session.provenanceSettled = true
        session.provenanceInconclusive = false
        let ok = DCAPVerification.verified(tcbStatus: .upToDate, mrConfigIdHex: "", reportDataHex: "")
        var dcap = RecordDCAPVerification()
        dcap.gateway = ok; dcap.model = ok
        session.dcapVerification = dcap
        session.gpuAttestation = .verified
        session.tlsAttestation = .verified
        session.trustScope = TrustScope(binding: .bound, boot: .matches)
    }

    /// the maintainer 2026-11-14, option (i): the 20 s deadline is the near.ai tier's alone. DCAP, NVIDIA (60 s), TLS (20 s),
    /// trust scope and provenance end at their OWN network bound (`eachLegHasItsOwnFiniteBound`), with what that
    /// timeout settles to; past the tier deadline they are still pending, never "couldn't check".
    /// Scaled: tier deadline 200 ms, the leg's own bound 700 ms.
    @Test(arguments: Input.allCases)
    func eachLegEndsAtItsOwnBoundNotTheTierDeadline(_ input: Input) async {
        let model = "zai-org/VD-LEG-\(input.rawValue)"
        NearAIModelCatalog.recordTiers([model: .teeOwn])
        let deadline = VerdictDeadline(after: .milliseconds(200), tierRetryDelays: [], loadTierList: { _ in false })
        let session = verifiedSession(model: model, deadline: deadline)
        adoptSettled(session)
        let ownBound = { (settle: @escaping @MainActor () -> Void) in
            Task<Void, Never> { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                settle()
            }
        }
        switch input {
        case .dcap:
            session.dcapVerification = nil
            session.dcapTask = ownBound {
                var dcap = RecordDCAPVerification()
                dcap.gateway = .unchecked("Intel PCS timed out")
                dcap.model = DCAPVerification.verified(tcbStatus: .upToDate, mrConfigIdHex: "", reportDataHex: "")
                session.dcapVerification = dcap
            }
        case .gpu:
            session.gpuAttestation = nil
            session.nrasTask = ownBound { session.gpuAttestation = .inconclusive("NVIDIA attestation service unreachable") }
        case .tls:
            session.tlsAttestation = nil
            session.tlsTask = ownBound { session.tlsAttestation = .inconclusive("timed out") }
        case .trustScope:
            session.trustScope = nil
            session.trustScopeTask = ownBound { session.trustScope = TrustScope(binding: .unchecked, boot: .absent) }
        case .provenance:
            session.imageProvenance = nil; session.provenanceSettled = false
            session.provenanceTask = ownBound { session.provenanceSettled = true; session.provenanceInconclusive = true }
        }
        #expect(session.sendPending, "precondition: \(input) pending")
        try? await Task.sleep(for: .milliseconds(450))
        #expect(session.sendPending, "\(input) settled at the tier deadline, before its own bound")
        #expect(session.attestationState == .verifying, "\(input): read \(session.attestationState) past the tier deadline")
        let ended = await settles(within: .seconds(3)) { !session.sendPending }
        #expect(ended, "\(input) still pending past its own bound")
        #expect(session.attestationState != .verifying, "\(input): read \(session.attestationState)")
        #expect(!session.degradeIsHardFailure, "\(input): a timed-out check is can't-check, never a hard failure")
        #expect(session.sendPolicy == .confirm, "\(input): the send asks, read \(session.sendPolicy)")
        #expect(!session.deadlinePassed, "\(input): only the tier's deadline changes the ask's words")
    }

    /// NVIDIA answering at 30 s (past the tier's 20 s, inside its own 60 s) is a verdict, not "couldn't check".
    @Test func aSlowNVIDIAAnswerIsStillPendingPastTheTierDeadline() async {
        let model = "zai-org/VD-SLOW-NVIDIA"
        NearAIModelCatalog.recordTiers([model: .teeOwn])
        let deadline = VerdictDeadline(after: .milliseconds(200), tierRetryDelays: [], loadTierList: { _ in false })
        let session = verifiedSession(model: model, deadline: deadline)
        adoptSettled(session)
        session.gpuAttestation = nil
        session.nrasTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            session.gpuAttestation = .verified
        }
        try? await Task.sleep(for: .milliseconds(450))
        #expect(session.gpuAttestation == nil, "NVIDIA was settled at the tier deadline: \(String(describing: session.gpuAttestation))")
        #expect(session.attestationState == .verifying)
        let ok = await settles(within: .seconds(3)) { session.attestationState == .ok }
        #expect(ok, "the late NVIDIA answer didn't land: \(session.attestationState)")
    }

    /// Each leg's own bound, the reason "always a verdict" holds without a 20 s give-up for them.
    @Test func eachLegHasItsOwnFiniteBound() {
        #expect(URLSessionNRASHTTP.requestTimeout == 60, "NVIDIA")
        #expect(TLSAttestationVerifier.makeProbeRequest(url: URL(string: "https://example.com")!).timeoutInterval == 20, "TLS")
        // DCAP collateral, trust scope's compose-manager quote and provenance ride URLSession.shared.
        #expect(URLSession.shared.configuration.timeoutIntervalForRequest == 60, "DCAP, trust scope, provenance")
    }

    /// 83b8d527 cached the peer per record, so every send within one record (up to 10 min) carried the same
    /// X-Client-Pub-Key. Each request context gets its own keypair, as before.
    @Test func eachRequestOnOneRecordGetsAFreshClientKey() {
        let model = "zai-org/VD-FRESH-KEY-PROBE"
        NearAIModelCatalog.recordTiers([model: .teeOwn])
        let session = verifiedSession(model: model, deadline: VerdictDeadline(loadTierList: { _ in false }))
        let first = session.currentTEEContext()?.e2eePeer?.headers["X-Client-Pub-Key"]
        let second = session.currentTEEContext()?.e2eePeer?.headers["X-Client-Pub-Key"]
        #expect(first != nil, "precondition: the record carries a key")
        #expect(first != second, "two sends on one record shared client key \(first ?? "nil")")
    }

    /// ChatView reads these every body pass; each peer is an X25519 keypair, so a read must make none.
    @Test func verdictReadsMakeNoPeer() {
        let model = "zai-org/VD-NO-PEER-PROBE"
        NearAIModelCatalog.recordTiers([model: .teeOwn])
        let session = verifiedSession(model: model, deadline: VerdictDeadline(loadTierList: { _ in false }))
        var made = 0
        session.makePeer = { made += 1; return try E2EEPeer(modelEd25519PubKey: $0) }
        #expect(session.attestation?.modelEd25519PubKey != nil, "precondition: the record carries a key")
        func readVerdicts() {
            for _ in 0..<20 {
                _ = session.softButSealed
                _ = session.sealedButHardwareUnconfirmed
                _ = session.canSeal
                _ = session.chipState
                _ = session.sendPolicy
                _ = session.deadlinePassed
            }
        }
        readVerdicts()
        var next = session.attestation!
        next.gatewayNonce = (next.gatewayNonce ?? "") + "-next"
        session.attestation = next
        readVerdicts()
        #expect(made == 0, "verdict reads built \(made) peer(s)")
        #expect(session.canSeal, "the record still reads as sealing")
        _ = session.currentTEEContext()
        #expect(made == 1, "a request context builds its peer through the seam")
    }

    /// The send ask may say "still checking" only while something is: past the deadline the checks have ended.
    @Test func theDeadlinePassingIsVisibleToTheAsk() async {
        let model = "zai-org/VD-ASK-WORDS-PROBE"
        await NearAIModelCatalog.$tierListSeenOverride.withValue(false) {
            let deadline = VerdictDeadline(after: .milliseconds(300), tierRetryDelays: [], loadTierList: { _ in false })
            let session = verifiedSession(model: model, deadline: deadline)
            #expect(!session.deadlinePassed, "precondition: still checking")
            @MainActor func ask() -> E2EEAsk {
                E2EEAsk.make(hardFailure: session.degradeIsHardFailure, pendingAsk: nil,
                             provenanceUnchecked: session.provenanceUncheckedAsks, softButSealed: session.softButSealed,
                             provenanceBlocked: session.provenanceBlockedButE2EEIntact, cause: session.e2eeDegradedReason,
                             deadlinePassed: session.deadlinePassed)
            }
            #expect(ask().title == "still checking near.ai's hardware")
            let ended = await settles(within: .seconds(3)) { session.deadlinePassed }
            #expect(ended, "the tier gave up but the session doesn't say the deadline passed")
            #expect(ask().title == "couldn't confirm near.ai's hardware")
            #expect(ask().choices.map(\.label) == ["send anyway", "don't send"])
        }
    }

    /// The tier's reason is the mildest: a worse one beside a given-up tier must name itself in the hero.
    @Test(arguments: ["gpu", "tls", "lastRequest"])
    func aWorseReasonBesideAGivenUpTierWins(_ worse: String) async {
        let model = "zai-org/VD-REASON-\(worse)"
        await NearAIModelCatalog.$tierListSeenOverride.withValue(false) {
            let deadline = VerdictDeadline(after: .milliseconds(200), tierRetryDelays: [], loadTierList: { _ in false })
            let session = verifiedSession(model: model, deadline: deadline)
            let gaveUp = await settles(within: .seconds(3)) { session.tierGaveUp }
            #expect(gaveUp, "precondition: the tier gave up")
            #expect(session.e2eeDegradedReason == VerdictDeadline.tierReason, "precondition: alone it names itself")
            let expected: String
            switch worse {
            case "gpu":
                session.gpuAttestation = .failed("x"); expected = "nvidia gpu attestation failed verification."
            case "tls":
                session.tlsAttestation = .failed("x"); expected = "the model node's tls certificate doesn't match its attestation."
            default:
                session.lastRequestUsedE2EE = false; session.lastE2EEFailReason = "the seal failed."
                expected = "the seal failed."
            }
            #expect(session.e2eeDegradedReason == expected, "\(worse): read \(session.e2eeDegradedReason ?? "nil")")
        }
    }

    @Test func aCancelledRaceLoserIsNotANetworkFailure() {
        #expect(AttestationService.requestWasCancelled(CancellationError(), taskCancelled: false))
        #expect(AttestationService.requestWasCancelled(URLError(.cancelled), taskCancelled: false))
        #expect(AttestationService.requestWasCancelled(URLError(.timedOut), taskCancelled: true))
        #expect(!AttestationService.requestWasCancelled(URLError(.timedOut), taskCancelled: false))
    }
}
