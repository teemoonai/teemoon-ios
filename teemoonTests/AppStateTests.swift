import Foundation
import Testing
@testable import teemoon

/// Every store here MUST be `inMemory: true`.
///
/// `teemoonTests` is app-hosted (`TEST_HOST` is the teemoon binary), so the
/// bundle runs inside the app process and shares its sandbox. A persisting
/// store therefore writes the REAL config of whatever it is running on — on the
/// simulator that is junk nobody misses, but on a device it is the user's own
/// setups. These tests add providers named "Test" and point the selection at a
/// random UUID, so a device run would leave the app with junk rows and nothing
/// selected. It is why the suite could not be run on hardware at all.
///
/// The second reason is older and documented on `ConfidentialSessionTests`: a
/// persisting store backs `currentProviderID` with app-wide state, so under
/// parallel execution these races any other test that sets an active provider.
@Suite("ProviderStore")
struct ProviderStoreTests {

    // MARK: - Provider management

    @Test @MainActor func addProvider_addsToList() {
        let store = ProviderStore(inMemory: true)
        let provider = Provider(name: "Test", endpoint: "https://test.com/v1", model: "m1")
        store.addProvider(provider)
        #expect(store.providers.contains(where: { $0.id == provider.id }))
    }

    @Test @MainActor func addProvider_duplicateID_doesNotAdd() {
        let store = ProviderStore(inMemory: true)
        let provider = Provider(name: "Test", endpoint: "https://test.com/v1", model: "m1")
        store.addProvider(provider)
        store.addProvider(provider)
        #expect(store.providers.filter({ $0.id == provider.id }).count == 1)
    }

    @Test @MainActor func removeProvider_removesFromList() {
        let store = ProviderStore(inMemory: true)
        let provider = Provider(name: "Test", endpoint: "https://test.com/v1", model: "m1")
        store.addProvider(provider)
        store.removeProvider(provider)
        #expect(!store.providers.contains(where: { $0.id == provider.id }))
    }

    @Test @MainActor func removeProvider_clearsCurrentProviderIfActive() {
        let store = ProviderStore(inMemory: true)
        let provider = Provider(name: "Test", endpoint: "https://test.com/v1", model: "m1")
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        store.removeProvider(provider)
        #expect(store.currentProviderID != provider.id.uuidString)
    }

    /// Forgetting a model must not take the setup with it — INCLUDING the last
    /// one on that setup.
    ///
    /// This is the invariant behind Where having no setup-level action on a model
    /// row: every row there names a model, and the only destructive thing a
    /// gesture on one may do is remove that model. The endpoint survives, so the
    /// Keychain entry keyed to it (`ProviderStore.endpointKey`) survives too, and
    /// the setup keeps its place in `get`.
    @Test @MainActor func forgetModel_keepsTheSetupAndItsEndpoint() {
        let store = ProviderStore(inMemory: true)
        var provider = Provider(name: "Test", endpoint: "https://test.com/v1", model: "m1")
        provider.equippedModels = ["m1", "m2"]
        store.addProvider(provider)

        store.forget(modelID: "m2", on: provider)
        var kept = try! #require(store.providers.first { $0.id == provider.id })
        #expect(kept.equipped == ["m1"])

        // The LAST model — the case that used to delete the provider and its key.
        store.forget(modelID: "m1", on: kept)
        kept = try! #require(store.providers.first { $0.id == provider.id })
        #expect(kept.equipped.isEmpty)
        #expect(kept.endpoint == "https://test.com/v1")
    }

    @Test @MainActor func updateProvider_updatesExisting() {
        let store = ProviderStore(inMemory: true)
        var provider = Provider(name: "Old", endpoint: "https://test.com/v1", model: "m1")
        store.addProvider(provider)
        provider.name = "New"
        store.updateProvider(provider)
        #expect(store.providers.first(where: { $0.id == provider.id })?.name == "New")
    }

    // MARK: - activeProvider

    @Test @MainActor func activeProvider_returnsMatchingProvider() {
        let store = ProviderStore(inMemory: true)
        let provider = Provider(name: "Test", endpoint: "https://test.com/v1", model: "m1")
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        #expect(store.activeProvider?.id == provider.id)
    }

    @Test @MainActor func activeProvider_nilWhenNoMatch() {
        let store = ProviderStore(inMemory: true)
        store.currentProviderID = UUID().uuidString
        #expect(store.activeProvider == nil)
    }

    /// Regression (persistent switch-staleness): editing the ACTIVE provider
    /// in place (model change via Settings) never touched currentProviderID,
    /// so the change hook stayed silent and no attestation refresh ran — the
    /// previous model's record lingered on screen. updateProvider must fire
    /// the hook for the active provider (and only for the active one).
    @Test @MainActor func updateProvider_firesHookWhenActive() {
        let store = ProviderStore(inMemory: true)
        var active = Provider(name: "near.ai", endpoint: "https://completions.near.ai/v1",
                              model: "zai-org/GLM-5.1-FP8")
        let other = Provider(name: "other", endpoint: "https://x.test/v1", model: "m")
        store.addProvider(active)
        store.addProvider(other)
        store.currentProviderID = active.id.uuidString
        var fired = 0
        var seenModel: String?
        store.onActiveProviderChanged = { fired += 1; seenModel = $0?.model }
        active.model = "z-ai/glm-5.2"
        store.updateProvider(active)
        #expect(fired == 1)
        #expect(seenModel == "z-ai/glm-5.2")
        // Editing a non-active provider must stay silent.
        store.updateProvider(other)
        #expect(fired == 1)
    }

    @Test @MainActor func activeProviderChangeHook_fires() {
        let store = ProviderStore(inMemory: true)
        let provider = Provider(name: "Test", endpoint: "https://test.com/v1", model: "m1")
        store.addProvider(provider)
        var observedID: UUID?
        store.onActiveProviderChanged = { observedID = $0?.id }
        store.currentProviderID = provider.id.uuidString
        #expect(observedID == provider.id)
    }
}

@Suite("ConfidentialSession")
struct ConfidentialSessionTests {
    /// Models near.ai set up with its list loaded: see `NearAIModelCatalog.tierListSeen`.
    init() { NearAIModelCatalog.seeTierListForTests() }


    /// A verifier handle that never answers within the test.
    private func neverAnswers() -> Task<Void, Never> {
        Task { try? await Task.sleep(for: .seconds(30)) }
    }

    // These tests read `attestationState`, which goes through the store's
    // `currentProviderID`. A persisting store backs that property with the
    // app-shared UserDefaults key — under parallel test execution any other
    // test setting an active provider races these and flips the expected
    // verdict (observed flake: `noneWhenNoProvider` seeing a provider).
    // In-memory stores keep each test's selection isolated.

    /// A store whose active provider is the one `AttestationRecord.preview` was
    /// stamped for — so a seeded record survives the READ GATE.
    ///
    /// Do not inline `Provider.nearAI` here. Its `model` is the *current
    /// flagship* and moves (`ac59824` took it to `z-ai/glm-5.2`), while
    /// `.preview` stays stamped for the attestable `zai-org/GLM-5.1-FP8`. When
    /// they diverge the gate does its job and nils the record — and every
    /// assertion downstream fails with no hint as to why, since the tests are
    /// about degrade policy, not about model identity. That is exactly how
    /// five tests here went red and stayed undiagnosed. Deriving the provider
    /// from the record means the next flagship bump cannot repeat it.
    @MainActor
    static func storeMatchingPreviewRecord() -> ProviderStore {
        var provider = Provider.nearAI
        provider.model = AttestationRecord.preview.model ?? provider.model
        let store = ProviderStore(inMemory: true)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        return store
    }

    /// A verdict still in flight is neutral in `attestationState`, so a send
    /// in that window rode an unsettled gate: on the phone, every other
    /// message to a host whose TLS check fails (2026-09-09). `prepareTurn`
    /// now waits for the hard-block-capable verdicts before the caller
    /// re-reads the policy.
    @Test @MainActor func prepareTurnWaitsForAnInFlightVerdictBeforeTheGateIsRead() async {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.attestation = .preview
        session.lastRequestUsedE2EE = true
        #expect(session.sendPolicy == .allow, "precondition: the preview record verifies")
        session.tlsTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            session.tlsAttestation = .failed("live TLS certificate does not match the attested fingerprint")
        }
        #expect(session.verdictsPending)
        #expect(session.sendPolicy == .allow, "the unsettled gate still reads allow — the hole")

        _ = await session.prepareTurn()

        #expect(!session.verdictsPending)
        #expect(session.tlsAttestation?.isHardFailure == true)
        #expect(session.sendPolicy == .block)
        #expect(ChatViewModel.postPrepareRefusal(policy: session.sendPolicy, acceptedDegrade: true,
                                                 verdictsPending: false) != nil)
    }

    /// A hung attestation fetch used to hold the send past the 15 s wait:
    /// the wait awaited the fetch task before its deadline loop.
    @Test @MainActor func aHungAttestationFetchDoesNotOutlastTheKeyWait() async {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.clearDerivedState(resetCounts: true)
        session.attestationTask = neverAnswers()
        defer { session.attestationTask?.cancel() }
        let started = ContinuousClock.now
        let key = await session.e2eeKey(waitingUpTo: .milliseconds(300))
        await session.attestationOutcome(waitingUpTo: .milliseconds(300))
        #expect(key == nil)
        #expect(ContinuousClock.now - started < .seconds(3), "the wait followed the hung fetch, not its deadline")
    }

    /// The model leg's 15 s cap raced the fetch in a task group, which waits
    /// for every child, so the cap bounded nothing.
    @Test func awaitValueGivesUpAtItsTimeout() async {
        let hung = Task<Int?, Never> { try? await Task.sleep(for: .seconds(30)); return 1 }
        defer { hung.cancel() }
        let started = ContinuousClock.now
        let value = await AttestationService.awaitValue(of: hung, timeout: 200_000_000)
        #expect(value == nil)
        #expect(ContinuousClock.now - started < .seconds(3))
        let quick = Task<Int?, Never> { 7 }
        #expect(await AttestationService.awaitValue(of: quick, timeout: 5_000_000_000) == 7)
    }

    /// Android found a window where a check not yet launched did not count as
    /// pending. iOS adopts the record and launches its verifiers in one
    /// main-actor step, so a send can never see a record without them.
    @Test @MainActor func adoptingARecordLeavesNoUnlaunchedCheck() async {
        let store = Self.storeMatchingPreviewRecord()
        let session = ConfidentialSession(providers: store)
        session.attestationTask?.cancel()
        session.clearDerivedState(resetCounts: true)
        #expect(!session.verdictsPending, "precondition: nothing launched, nothing adopted")
        session.adopt(.preview, for: store.activeProvider!)
        #expect(session.attestation != nil)
        #expect(session.dcapTask != nil && session.tlsTask != nil, "a verifier was left unlaunched")
        #expect(session.verdictsPending, "an adopted record must hold the send until its checks answer")
        session.dcapTask?.cancel(); session.nrasTask?.cancel(); session.tlsTask?.cancel()
    }

    /// A verdict that never lands is not a pass: the wait is bounded and the
    /// caller learns it is still pending.
    @Test @MainActor func prepareTurnReportsAVerdictStillPendingAtTheDeadline() async {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.attestation = .preview
        session.lastRequestUsedE2EE = true
        let previous = ConfidentialSession.verifierSettleTimeout
        ConfidentialSession.verifierSettleTimeout = .milliseconds(250)
        defer { ConfidentialSession.verifierSettleTimeout = previous }
        session.tlsTask = neverAnswers()
        defer { session.tlsTask?.cancel() }

        let started = ContinuousClock.now
        _ = await session.prepareTurn()

        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(session.verdictsPending)
        #expect(ChatViewModel.postPrepareRefusal(policy: session.sendPolicy, acceptedDegrade: false,
                                                 verdictsPending: session.verdictsPending) != nil)
    }

    /// F2 (TLA+ model, 2026-11-06): a record with GPU evidence followed by one without left the cancelled
    /// NVIDIA handle behind, so verdictsPending read true for the new record's whole life: the chip stayed
    /// "verifying" and every send waited out the settle and asked.
    @Test @MainActor func aRecordWithoutGPUEvidenceAfterOneWithItLeavesNothingPending() async {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.attestation = .preview
        session.lastRequestUsedE2EE = true
        #expect(session.attestationState == .ok, "precondition: the preview record verifies")

        var withGPU = AttestationRecord.preview
        withGPU.nvidiaPayload = "{\"evidence_list\":[]}"
        session.verifyGPU(for: withGPU)
        #expect(session.verdictsPending, "precondition: record A's NVIDIA check is in flight")

        var withoutGPU = AttestationRecord.preview
        withoutGPU.nvidiaPayload = nil
        session.verifyGPU(for: withoutGPU)
        #expect(!session.verdictsPending, "record B has no NVIDIA check to wait for")
        #expect(session.attestationState != .verifying)

        try? await Task.sleep(for: .milliseconds(200))
        #expect(!session.verdictsPending, "the cancelled check for record A must not hold record B")
        #expect(session.gpuAttestation == nil)
        #expect(session.attestationState == .ok)
    }

    /// The simulator, 2026-09-12: "end-to-end encrypted" at 1.4 s, "image
    /// unpublished" at 4.5 s. A sealed session read green while its image
    /// provenance was still being fetched; now it reads verifying until the
    /// pass writes its result, and the send gate does not change.
    @Test @MainActor func aSealedSessionIsVerifyingUntilProvenanceSettles() async {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.attestation = .preview
        session.lastRequestUsedE2EE = true
        #expect(session.attestationState == .ok, "precondition: the preview record verifies")
        #expect(session.sendPolicy == .allow)

        session.provenanceSettled = false
        session.provenanceTask = neverAnswers()
        defer { session.provenanceTask?.cancel() }
        #expect(session.attestationState == .verifying)
        #expect(session.sendPolicy == .allow, "in-flight provenance never gates a send")

        session.imageProvenance = .allVerified(verified: [], thirdParty: [])
        session.provenanceSettled = true
        #expect(session.attestationState == .ok)

        // An inconclusive pass leaves no result but does settle: not verifying forever.
        session.imageProvenance = nil
        #expect(session.attestationState == .ok)
    }

    /// T1 (pm's state-machine sweep, 2026-11-06; also in 1.0.6): the chip went green while DCAP, the GPU
    /// check or TLS was still running — only provenance had a verifying path. The send gate was never wrong
    /// (it asks `verdictsPending`); the screens were. A pending hard verdict reads as verifying everywhere.
    @Test @MainActor func aPendingHardVerdictNeverReadsAsVerified() {
        for pending in ["dcap", "gpu", "tls"] {
            let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
            session.attestationTask?.cancel()
            session.attestation = .preview
            session.lastRequestUsedE2EE = true
            session.imageProvenance = .allVerified(verified: [], thirdParty: [])
            session.provenanceSettled = true
            #expect(session.attestationState == .ok, "precondition: the preview record verifies")
            switch pending {
            case "dcap": session.dcapTask = neverAnswers()
            case "gpu": session.nrasTask = neverAnswers()
            default: session.tlsTask = neverAnswers()
            }
            #expect(session.verdictsPending)
            #expect(session.attestationState == .verifying, "\(pending) in flight read as \(session.attestationState)")
            #expect(session.sendPolicy == .allow, "the gate's own wait is unchanged")
            let summary = AttestationSummary(
                attestation: session.attestation, state: session.attestationState, timedOut: false,
                provider: session.activeProvider, lastRequestUsedE2EE: true, lastE2EEFailReason: nil,
                verifiedResponseCount: 0, mismatchedResponseCount: 0, attestationFetchFailed: false,
                imageProvenance: session.imageProvenance, dcapVerification: nil)
            #expect(summary.headerSeverity != .ok)
            #expect(!summary.pillars.contains { $0.state == .verified && $0.checks.contains { $0.state == .pending } })
            session.dcapTask?.cancel(); session.nrasTask?.cancel(); session.tlsTask?.cancel()
        }
    }

    /// Found in the T1 capture (2026-11-06): with an unpublished image (a GitHub 404, which asks nothing at the
    /// gate) the hero read "encrypted — one image unpublished · verified just now" while DCAP was still running.
    @Test @MainActor func anUnpublishedImageDoesNotSkipThePendingHardwareChecks() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.attestation = .preview
        session.lastRequestUsedE2EE = true
        let ref = ProvenanceService.ImageRef(image: "nearaidev/compose-manager-launcher", digest: String(repeating: "a", count: 64))
        session.imageProvenance = .incomplete(verified: [], failures: [.init(ref: ref, reason: .unverified(.fetchFailed("HTTP 404")))],
                                              thirdParty: [])
        session.provenanceSettled = true
        #expect(session.imageProvenance?.isUnpublishedOnly == true, "precondition")
        #expect(session.attestationState == .degraded, "precondition: unpublished-only reads orange once verified")
        session.dcapTask = neverAnswers()
        defer { session.dcapTask?.cancel() }
        #expect(session.attestationState == .verifying)
    }

    /// T1 knock-on (android, 2026-11-06): the expert GPU row read "GPU node unreachable — verified via gateway"
    /// beside its spinner while NVIDIA hadn't answered. Pending says it is checking.
    @Test func theGPURowSaysCheckingUntilNVIDIAAnswers() {
        func summary(_ nras: NRASVerification?) -> AttestationSummary {
            AttestationSummary(attestation: .preview, state: .verifying, timedOut: false, provider: nil,
                               lastRequestUsedE2EE: true, lastE2EEFailReason: nil, verifiedResponseCount: 0,
                               mismatchedResponseCount: 0, attestationFetchFailed: false, nrasVerification: nras)
        }
        #expect(summary(nil).gpuRowDetail == "Checking GPU evidence with NVIDIA…")
        // Freeze A2 (the maintainer 2026-11-08) supersedes trust-blocked-chain-and-gateway-row (b): a pass is NVIDIA's.
        #expect(summary(.verified).gpuRowDetail == "NVIDIA confirmed genuine attested GPUs for this request")
        // trust-hardware-fail-lines (the maintainer 2026-11-06): a failed or inconclusive check says why, not "verified via gateway".
        #expect(summary(.failed("NVIDIA rejected the evidence")).gpuRowDetail == "NVIDIA rejected the evidence")
        #expect(summary(.inconclusive("NRAS unreachable")).gpuRowDetail == "NRAS unreachable")
    }

    /// Q4 of trust-pending-state (the maintainer, 2026-11-06): "sealed so only <model> can open it" drew a pass while
    /// DCAP and NVIDIA were still checking. It reads checking until both answer; no new words.
    @Test func theSealStepWaitsForTheHardwareChecks() {
        func summary(dcap: RecordDCAPVerification?, nras: NRASVerification?) -> AttestationSummary {
            AttestationSummary(attestation: .preview, state: .verifying, timedOut: false, provider: nil,
                               lastRequestUsedE2EE: true, lastE2EEFailReason: nil, verifiedResponseCount: 0,
                               mismatchedResponseCount: 0, attestationFetchFailed: false,
                               dcapVerification: dcap, nrasVerification: nras)
        }
        var ok = RecordDCAPVerification()
        ok.gateway = .verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
        ok.model = .verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
        #expect(summary(dcap: nil, nras: .verified).hardwareChecksPending)
        #expect(!summary(dcap: ok, nras: nil).hardwareChecksPending, "the preview record has no NVIDIA evidence: nothing to wait for")
        #expect(!summary(dcap: ok, nras: .verified).hardwareChecksPending)
        func sealed(_ pending: Bool) -> TrustClaim? {
            TrustVerdict.make(.init(attestationState: .verifying, requiresConfirmation: false, degradeIsHardFailure: false,
                                    mismatchedResponseCount: 0, modelName: "m", quant: nil, providerDisplayName: "near.ai",
                                    isLocal: false, isSelfHosted: false, e2eeKeyBound: true, hardwareChecksPending: pending,
                                    listedEnclaves: .checked))
                .everydayClaims.first { $0.id == "sealed" }
        }
        #expect(sealed(true)?.status == .pending && sealed(false)?.status == .ok)
        #expect(sealed(true)?.title == sealed(false)?.title, "no new words")
    }

    /// T6's expert node: a key in a quote that didn't verify is named as such, not as "not found".
    @Test func aKeyInAFailedQuoteIsTheExpertNodesOwnFailure() {
        #expect(!AttestationSummary(attestation: .preview, state: .ok, timedOut: false, provider: nil,
                                    lastRequestUsedE2EE: true, lastE2EEFailReason: nil, verifiedResponseCount: 0,
                                    mismatchedResponseCount: 0, attestationFetchFailed: false).keyInUnverifiedQuote)
    }

    /// T4 (pm's state-machine sweep): a cancelled TLS check whose directory lookup found no host wrote
    /// `.notPerformed` over the newer check's pending verdict, ending the wait early.
    @Test @MainActor func aCancelledTLSLookupWritesNothing() async {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.directBase = { _ in try? await Task.sleep(for: .milliseconds(300)); return nil }
        let provider = Provider.nearAI
        session.verifyTLS(for: provider)
        session.verifyTLS(for: provider)   // the second cancels the first
        try? await Task.sleep(for: .milliseconds(100))
        #expect(session.tlsAttestation == nil, "the cancelled lookup ended the newer check's wait")
        session.tlsTask?.cancel()
    }

    /// trust-pending-state (the maintainer 2026-11-06, android's fix): timed out with no record or no key, nothing is
    /// encrypted yet, so the hero must not say it is.
    @Test func aTimedOutHeroClaimsEncryptionOnlyWithAKey() {
        func subtitle(_ record: AttestationRecord?) -> String {
            AttestationSummary(attestation: record, state: .verifying, timedOut: true, provider: nil,
                               lastRequestUsedE2EE: nil, lastE2EEFailReason: nil, verifiedResponseCount: 0,
                               mismatchedResponseCount: 0, attestationFetchFailed: false).headerSubtitle
        }
        #expect(subtitle(.preview).hasPrefix("messages are encrypted"))
        #expect(subtitle(nil) == "confirming this conversation runs inside sealed hardware.")
        #expect(!subtitle(.previewDegraded).contains("encrypted"), "no key: \(subtitle(.previewDegraded))")
    }

    /// The run's rollup: one step still pending among passes is still running, never passed.
    @Test func aRunWithAPendingStepIsStillRunning() {
        let summary = AttestationSummary(
            attestation: .preview, state: .ok, timedOut: false, provider: nil, lastRequestUsedE2EE: true,
            lastE2EEFailReason: nil, verifiedResponseCount: 0, mismatchedResponseCount: 0,
            attestationFetchFailed: false, dcapVerification: nil)
        let model = summary.verificationRun.first { $0.id == "model" }
        #expect(model?.steps.contains { $0.status == .pending } == true, "precondition: DCAP has no verdict")
        #expect(model?.result != .passed)
    }

    /// NVIDIA, 2026-09-12: every send was refused with "Verification is still
    /// running, so nothing was sent". The near.ai session before it had its
    /// TLS probe cancelled by the switch; the handle stayed, no verdict ever
    /// came, and the chat path — unlike the Siri intent — asked the pending
    /// predicate for a provider that has no verdicts at all.
    @Test @MainActor func aPlainTLSProviderNeverWaitsOnAnotherSessionsVerifiers() {
        let store = Self.storeMatchingPreviewRecord()
        let session = ConfidentialSession(providers: store)
        session.attestationTask?.cancel()
        session.attestation = .preview
        session.tlsTask = neverAnswers()
        defer { session.tlsTask?.cancel() }
        #expect(session.verdictsPending, "precondition: the near.ai probe is in flight")

        // The stale handle is still there; only the active provider changed.
        let nvidia = Provider.nvidia
        store.addProvider(nvidia)
        store.currentProviderID = nvidia.id.uuidString
        #expect(!nvidia.capabilities.contains(.attestation))
        #expect(!session.verdictsPending)
        #expect(ChatViewModel.postPrepareRefusal(policy: session.sendPolicy, acceptedDegrade: false,
                                                 verdictsPending: session.verdictsPending) == nil)
    }

    /// A cancelled verifier never answers, so a switch must drop its handle —
    /// otherwise the next near.ai session inherits a verdict that is "pending"
    /// forever, and even its own sends wait the full settle timeout.
    @Test @MainActor func aSwitchDropsCancelledVerifierHandles() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.attestation = .preview
        session.tlsTask = neverAnswers()
        session.dcapTask = neverAnswers()
        #expect(session.verdictsPending)

        session.clearDerivedState(resetCounts: true)

        #expect(session.tlsTask == nil)
        #expect(session.dcapTask == nil)
        #expect(session.nrasTask == nil)
        #expect(!session.verdictsPending)
    }

    /// THE GATE MATRIX. Every kind of provider crossed with every prior state
    /// the session can be in when a send starts. A gate change that widens —
    /// like build 34's pending-verdict refusal, which reached plain-TLS
    /// providers through a cancelled near.ai probe — has to fail a cell here
    /// before it can reach a phone.
    @Test @MainActor func theSendGateAnswersEveryProviderKindInEveryPriorState() {
        enum Kind: String, CaseIterable { case attested, plainCloud, selfHosted, onDevice }
        enum Prior: String, CaseIterable { case fresh, staleHandleNoReset, afterSwitchReset, hardFailure }

        func makeSession(_ kind: Kind) -> ConfidentialSession {
            let store: ProviderStore
            switch kind {
            case .attested:
                store = Self.storeMatchingPreviewRecord()
            case .plainCloud:
                store = ProviderStore(inMemory: true)
                let p = Provider.nvidia
                store.addProvider(p); store.currentProviderID = p.id.uuidString
            case .selfHosted:
                store = ProviderStore(inMemory: true)
                let p = Provider(name: "box", endpoint: "http://box.local:11434/v1",
                                 model: "gemma4:e4b", requiresAPIKey: false)
                store.addProvider(p); store.currentProviderID = p.id.uuidString
            case .onDevice:
                store = ProviderStore(inMemory: true)
                let p = Provider(name: "this phone", endpoint: "", model: "gemma-4-e2b",
                                 requiresAPIKey: false, localModelID: "gemma-4-e2b")
                store.addProvider(p); store.currentProviderID = p.id.uuidString
            }
            let session = ConfidentialSession(providers: store)
            session.attestationTask?.cancel()
            return session
        }

        for kind in Kind.allCases {
            for prior in Prior.allCases {
                let session = makeSession(kind)
                let cell = "kind=\(kind.rawValue) prior=\(prior.rawValue)"
                if kind == .attested {
                    session.attestation = .preview
                    session.lastRequestUsedE2EE = true
                }
                switch prior {
                case .fresh:
                    break
                case .staleHandleNoReset:
                    session.tlsTask = neverAnswers()
                case .afterSwitchReset:
                    session.tlsTask = neverAnswers()
                    session.dcapTask = neverAnswers()
                    session.clearDerivedState(resetCounts: true)
                    if kind == .attested {   // the new session's own record
                        session.attestation = .preview
                        session.lastRequestUsedE2EE = true
                    }
                case .hardFailure:
                    session.tlsAttestation = .failed("live TLS certificate does not match the attested fingerprint")
                }
                defer { session.tlsTask?.cancel(); session.dcapTask?.cancel() }

                let refusal = ChatViewModel.postPrepareRefusal(policy: session.sendPolicy, acceptedDegrade: false,
                                                               verdictsPending: session.verdictsPending)
                switch (kind, prior) {
                case (.attested, .staleHandleNoReset):
                    #expect(session.verdictsPending, "\(cell)")
                    #expect(refusal != nil, "\(cell)")          // a real verdict is in flight
                case (.attested, .hardFailure):
                    #expect(session.sendPolicy == .block, "\(cell)")
                    #expect(refusal != nil, "\(cell)")
                case (.attested, _):
                    #expect(!session.verdictsPending, "\(cell)")
                    #expect(session.sendPolicy == .allow, "\(cell)")
                    #expect(refusal == nil, "\(cell)")
                default:
                    // No verdicts exist for these providers: nothing pending,
                    // nothing blocked, whatever a previous session left behind.
                    #expect(!session.verdictsPending, "\(cell)")
                    #expect(session.sendPolicy == .allow, "\(cell)")
                    #expect(refusal == nil, "\(cell)")
                }
            }
        }
    }

    /// A refusal before the wire sent nothing. It used to be booked as an
    /// unsealed request, and once the key was present that read as
    /// plaintext-went-out: a hard block only a provider switch cleared.
    @Test @MainActor func aRefusalBeforeTheWireDoesNotReadAsAnUnsealedRequest() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.attestation = .preview
        // The old bookkeeping, for contrast: this is the poison.
        session.beginRequest(expectingE2EE: false)
        session.finishTurn(debugInfo: nil, error: nil)
        #expect(session.degradeIsHardFailure, "precondition: the old shape reads as a hard break")

        session.abandonTurn(reason: "nothing was sent")
        #expect(session.lastRequestUsedE2EE == nil)
        #expect(!session.degradeIsHardFailure)
        #expect(session.sendPolicy == .allow)
        #expect(session.lastE2EEFailReason == "nothing was sent")
    }

    /// Guards the pairing above directly, so the *cause* is what fails rather
    /// than five unrelated policy assertions.
    @Test @MainActor func previewRecordSurvivesTheReadGateOnItsOwnProvider() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestation = .preview
        // If this fails: `.preview` no longer matches the provider it is seeded
        // on, the read gate is nilling it, and every test that seeds it fails.
        #expect(session.attestation != nil)
    }

    @Test func liveFetchSkipsPreviewAndDesignTourNotOrdinaryLaunches() {
        #expect(!ConfidentialSession.skipsLiveAttestation(
            environment: [:], arguments: ["teemoon"]))
        #expect(ConfidentialSession.skipsLiveAttestation(
            environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"], arguments: ["teemoon"]))
        #expect(ConfidentialSession.skipsLiveAttestation(
            environment: [:], arguments: ["teemoon", "-DesignTour", "run-verified"]))
    }

    @Test @MainActor func attestationState_noneWhenNoProvider() {
        let store = ProviderStore(inMemory: true)
        store.currentProviderID = nil
        let session = ConfidentialSession(providers: store)
        #expect(session.attestationState == .none)
    }

    @Test @MainActor func attestationState_noneForNonAttestationProvider() {
        let store = ProviderStore(inMemory: true)
        let provider = Provider(name: "OpenAI", endpoint: "https://api.openai.com/v1", model: "gpt-4")
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let session = ConfidentialSession(providers: store)
        #expect(session.attestationState == .none)
    }

    /// A near.ai model that is classified attestable but has no confidential
    /// endpoint (e.g. a retired model like deepseek-v3.2) must resolve to `.none`
    /// — a plain non-attestable model — not stall on `.verifying` then fail
    /// closed. (Regression: deepseek-v3.2 stall.)
    @Test @MainActor func attestationState_noneWhenNoConfidentialEndpoint() {
        let store = ProviderStore(inMemory: true)
        let provider = Provider(name: "near.ai", endpoint: "https://completions.near.ai/v1",
                                model: "zai-org/GLM-5.1-FP8")
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let session = ConfidentialSession(providers: store)
        // Precondition: this provider IS attestation-capable, so a `.none` verdict
        // can only come from the no-confidential-endpoint short-circuit here —
        // not from the capability guard (which would make the test vacuous).
        #expect(provider.capabilities.contains(.attestation))
        #expect(session.attestationState == .verifying)   // no record yet, flag off
        session.noConfidentialEndpoint = true
        #expect(session.attestationState == .none)         // non-attestable, not a stall
    }

    /// Regression (observed on device): switching GLM-5.1 → 5.2 kept showing
    /// 5.1. The trap: the first refresh after a model switch came from a
    /// keepExisting caller (the re-verify button / pre-send staleness check),
    /// which recorded the new context WITHOUT clearing — so no later refresh
    /// ever saw a change, and the old model's derived state stuck permanently.
    /// A context change must clear even on a keepExisting refresh.
    @Test @MainActor func modelSwitch_clearsDerivedState_evenOnKeepExistingRefresh() {
        let store = ProviderStore(inMemory: true)
        var provider = Provider(name: "near.ai", endpoint: "https://completions.near.ai/v1",
                                model: "zai-org/GLM-5.1-FP8")
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let session = ConfidentialSession(providers: store)
        // Seed derived state as if 5.1 verified (the artifact drives the shown name).
        session.modelArtifact = ModelArtifact(
            modelPath: "QuantTrio/GLM-5.1-AWQ", revision: nil,
            servedName: "zai-org/GLM-5.1-FP8", quant: "AWQ")
        // Switch the model, then refresh the way the re-verify button does.
        provider.model = "z-ai/glm-5.2"
        store.updateProvider(provider)
        session.refreshAttestation()
        // The 5.1 artifact must be gone — the switch invalidates it even though
        // the caller asked to keep existing state for a same-context refresh.
        #expect(session.modelArtifact == nil)
        // And a same-context keepExisting refresh must NOT clear: re-seed and refresh.
        session.modelArtifact = ModelArtifact(
            modelPath: "PhalaCloud/GLM-5.2-W4AFP8", revision: nil,
            servedName: "z-ai/glm-5.2", quant: "W4AFP8")
        session.refreshAttestation()
        #expect(session.modelArtifact != nil)
    }

    /// The provenance-blocked-but-E2EE-intact discriminator drives the honest
    /// send alert ("still encrypted — code unverified" vs "send without encryption").
    /// It must be true exactly when provenance is the only blocking failure
    /// over an established E2EE binding (node-lottery 404 case), and false
    /// whenever provenance is fine or E2EE itself isn't established.
    @Test @MainActor func provenanceBlockDiscriminator_tracksE2EEIntactness() {
        // The read gate only exposes records matching the active (provider,
        // model) — use the provider the preview record was stamped for.
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        // No attestation at all → false.
        session.imageProvenance = .incomplete(verified: [], failures: [], thirdParty: [])
        #expect(!session.provenanceBlockedButE2EEIntact)
        // Bound-verified record + provenance failure → true.
        session.attestation = .preview
        #expect(session.attestation?.modelEd25519PubKey?.count == 32)
        #expect(session.provenanceBlockedButE2EEIntact)
        // Provenance fine → false.
        session.imageProvenance = .allVerified(verified: [], thirdParty: [])
        #expect(!session.provenanceBlockedButE2EEIntact)
    }

    /// Fail-loud (F1): an inner-compose hash mismatch is an ADVERSARIAL
    /// integrity break — it must fail closed (degraded), classify as a HARD
    /// failure (red hero, not orange advisory), gate the send, and name the
    /// recipe as the cause. A TRANSIENT fetch failure must do none of that
    /// (no false tamper accusation on a GitHub blip). This is the check that
    /// was almost-silent before: detected, then discarded.
    @Test @MainActor func recipeHashMismatch_failsClosedAndHard_fetchFailureDoesNot() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestation = .preview
        // Baseline: verified, sending open.
        #expect(session.attestationState == .ok)
        #expect(!session.requiresE2EEConfirmation)

        // Tamper: the recipe on disk ≠ the action log's pin.
        session.modelLayerVerification = .hashMismatch
        #expect(session.modelComposeIntegrityFailed)
        #expect(session.attestationState == .degraded)     // fail-closed
        #expect(session.degradeIsHardFailure)              // RED, not advisory
        #expect(session.requiresE2EEConfirmation)          // send actually gated
        #expect(session.e2eeDegradedReason?.contains("recipe") == true)

        // Transient fetch failure: NOT tamper — must not degrade or accuse.
        session.modelLayerVerification = .fetchFailed
        #expect(!session.modelComposeIntegrityFailed)
        #expect(session.attestationState == .ok)
        #expect(!session.requiresE2EEConfirmation)
    }

    /// A transient outage of the GPU/TLS verifier must degrade
    /// fail-closed but NOT be branded a hard integrity break — a network blip to
    /// NVIDIA/the enclave is not tamper/MITM, and must never trigger the
    /// no-bypass hard block. Only a genuine negative verdict is hard.
    @Test @MainActor func transientVerifierOutage_isSoft_genuineVerdictIsHard() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestation = .preview

        // NRAS unreachable → degrades, but SOFT.
        session.gpuAttestation = .inconclusive("NVIDIA attestation service unreachable")
        #expect(session.attestationState == .degraded)
        #expect(!session.degradeIsHardFailure)
        // A real NVIDIA rejection → HARD.
        session.gpuAttestation = .failed("NVIDIA attestation verdict: FAIL")
        #expect(session.degradeIsHardFailure)

        // TLS unreachable → soft; fingerprint mismatch → hard.
        session.gpuAttestation = .verified
        session.tlsAttestation = .inconclusive("TLS attestation request failed")
        #expect(session.attestationState == .degraded)
        #expect(!session.degradeIsHardFailure)
        session.tlsAttestation = .failed("live TLS certificate does not match the attested fingerprint")
        #expect(session.degradeIsHardFailure)
    }

    /// Send policy: a SOFT degrade (an image's provenance couldn't be traced,
    /// but E2EE is fully intact) is confirm-to-proceed — gated, but NOT a hard
    /// block, because the message is still sealed. Distinct from a hard integrity
    /// break, which has no bypass.
    @Test @MainActor func softDegrade_provenanceGap_isConfirmNotHardBlock() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestation = .preview
        session.imageProvenance = .incomplete(verified: [], failures: [], thirdParty: [])
        #expect(session.attestationState == .degraded)
        #expect(session.requiresE2EEConfirmation)     // gated…
        #expect(!session.degradeIsHardFailure)        // …but soft: bypass allowed (still encrypted)
        #expect(session.provenanceBlockedButE2EEIntact)
        #expect(!session.unpublishedOnlyButE2EEIntact)
    }

    /// A clean GitHub 404 (unpublished digest) must not gate send or claim
    /// "unencrypted" when the model key is bound. It also must not read as
    /// fully verified.
    @Test @MainActor func unpublishedImage_doesNotGateSealedSend() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestation = .preview
        let fail = ProvenanceService.Failure(
            ref: .init(image: "nearaidev/compose-manager-launcher",
                       digest: String(repeating: "d", count: 64)),
            reason: .unverified(.fetchFailed("GitHub attestations HTTP 404"))
        )
        session.imageProvenance = .incomplete(verified: [], failures: [fail], thirdParty: [])
        #expect(session.unpublishedOnlyButE2EEIntact)
        #expect(session.attestationState == .degraded)   // not fully verified
        #expect(!session.requiresE2EEConfirmation)       // no modal
        #expect(!session.degradeIsHardFailure)
        #expect(session.e2eeDegradedReason?.contains("still sealed") == true)
    }

    /// A bad Sigstore / identity failure is not "unpublished" — still confirm.
    @Test @MainActor func signatureInvalidProvenance_stillConfirms() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestation = .preview
        let fail = ProvenanceService.Failure(
            ref: .init(image: "nearaidev/compose-manager",
                       digest: String(repeating: "e", count: 64)),
            reason: .unverified(.signatureInvalid)
        )
        session.imageProvenance = .incomplete(verified: [], failures: [fail], thirdParty: [])
        #expect(!session.unpublishedOnlyButE2EEIntact)
        #expect(session.requiresE2EEConfirmation)
        #expect(session.attestationState == .degraded)
    }

    /// Fail-loud (Bug 2): a reply-signature mismatch is loud in the run
    /// (headerSeverity → failed elsewhere) but must NOT falsely claim "sending
    /// paused" — it is not an attestation degrade, so the send-gate stays open.
    /// Regression: the hero returned "sending paused" with a mis-attributed
    /// cause while sending was in fact not gated.
    @Test @MainActor func signatureMismatch_doesNotFalselyGateSending() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestation = .preview
        session.mismatchedResponseCount = 1
        #expect(session.attestationState == .ok)          // not an attestation degrade
        #expect(!session.requiresE2EEConfirmation)        // isPaused proxy → NOT paused
        #expect(!session.degradeIsHardFailure)
    }

    /// THE structural guarantee after three stale-display bugs: the session
    /// never exposes a record fetched for a different model than the active
    /// one. Whatever refresh trigger or task race slips through, a mismatched
    /// record reads as nil — stale attestation display is impossible by
    /// construction, not by whack-a-mole.
    @Test @MainActor func attestationReadGate_blocksMismatchedModel() {
        let store = ProviderStore(inMemory: true)
        var provider = Provider(name: "near.ai", endpoint: "https://completions.near.ai/v1",
                                model: "zai-org/GLM-5.1-FP8")
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let session = ConfidentialSession(providers: store)
        // A record stamped for GLM-5.1 on the matching provider: visible.
        var rec = AttestationRecord.preview        // model = zai-org/GLM-5.1-FP8
        rec = AttestationRecord(
            composeHash: rec.composeHash, mrtd: rec.mrtd, osImageHash: rec.osImageHash,
            intelQuote: rec.intelQuote, modelIntelQuote: rec.modelIntelQuote,
            modelNonce: rec.modelNonce, composeManifest: rec.composeManifest,
            gpuArch: rec.gpuArch, gpuNodeComposeHash: rec.gpuNodeComposeHash,
            modelFileHash: rec.modelFileHash, signingAddress: rec.signingAddress,
            gpuSigningAddress: rec.gpuSigningAddress, modelEd25519PubKey: rec.modelEd25519PubKey,
            quoteVerification: rec.quoteVerification, gpuQuoteVerification: rec.gpuQuoteVerification,
            modelQuoteVerification: rec.modelQuoteVerification,
            fetchedAt: rec.fetchedAt, providerID: provider.id, model: "zai-org/GLM-5.1-FP8")
        session.attestation = rec
        #expect(session.attestation != nil)
        // The user switches the model: the same stored record must vanish
        // from every reader instantly — no refresh required.
        provider.model = "z-ai/glm-5.2"
        store.updateProvider(provider)
        #expect(session.attestation == nil)
        #expect(session.attestationState == .verifying)
        // Switching back restores visibility (the record was for 5.1).
        provider.model = "zai-org/GLM-5.1-FP8"
        store.updateProvider(provider)
        #expect(session.attestation != nil)
    }

    @Test @MainActor func recordVerification_countsHonestly() {
        let store = ProviderStore(inMemory: true)
        store.currentProviderID = nil
        let session = ConfidentialSession(providers: store)
        session.recordVerification(.verified(.init(signingAddress: "0xA")))
        session.recordVerification(.unverified(.gatewayTrustOnly(signingAddress: "0xB")))
        session.recordVerification(.unverified(.signatureMismatch(expected: "0xA", got: "0xC")))
        session.recordVerification(.unverified(.signatureUnavailable))
        #expect(session.verifiedResponseCount == 1)
        #expect(session.gatewayTrustResponseCount == 1)
        #expect(session.mismatchedResponseCount == 1)
    }

    /// The VM must not write E2EE fields. `prepareTurn` derives the context
    /// and opens the books; `finishTurn` closes them from the turn's result.
    @Test @MainActor func canSeal_tracksTheDerivedPeer() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        #expect(!session.canSeal)
        session.attestation = .preview
        #expect(session.canSeal == (session.currentTEEContext()?.e2eePeer != nil))
    }

    @Test @MainActor func prepareTurn_opensBookkeepingFromTheDerivedContext() async {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestation = .preview
        #expect(session.lastRequestUsedE2EE == nil)
        let ctx = await session.prepareTurn()
        #expect(ctx != nil)
        #expect(session.lastRequestUsedE2EE == (ctx?.e2eePeer != nil))
        #expect(session.lastE2EEFailReason == nil)
    }

    @Test @MainActor func finishTurn_recordsOutcomeAndVerification() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestation = .preview
        session.beginRequest(expectingE2EE: true)
        let info = LastRequestDebugInfo(
            providerName: "near.ai",
            modelID: "m",
            url: URL(string: "https://example.com")!,
            requestHeaders: nil,
            requestBodyJSON: nil,
            responseBody: "hi",
            toolCalls: [],
            threadID: UUID(),
            totalDuration: nil,
            timeToFirstToken: nil,
            outputTokens: nil,
            isE2EEActive: true,
            teeVerification: .unverified(.gatewayTrustOnly(signingAddress: "0xabc"))
        )
        session.finishTurn(debugInfo: info, error: nil)
        #expect(session.lastRequestUsedE2EE == true)
        #expect(session.e2eeMessageCount == 2)
        #expect(session.gatewayTrustResponseCount == 1)
        #expect(session.verifiedResponseCount == 0)
    }

    /// T3 (pm's state-machine sweep): a turn's outcome was booked to whatever model was selected when it
    /// finished. Switch mid-stream and model B showed "E2EE used", A's message count and A's signatures.
    @Test @MainActor func aTurnFinishingAfterASwitchCreditsNothingToTheNewProvider() {
        let store = Self.storeMatchingPreviewRecord()
        let session = ConfidentialSession(providers: store)
        session.attestation = .preview
        let place = ConfidentialSession.TurnPlace(try! #require(store.activeProvider))
        var other = try! #require(store.activeProvider)
        other.model = "another-model"
        store.updateProvider(other)          // same server, another model: not this turn's place
        #expect(!session.ownsTurn(place))
        let info = LastRequestDebugInfo(
            providerName: "near.ai", modelID: "m", url: URL(string: "https://example.com")!, requestHeaders: nil,
            requestBodyJSON: nil, responseBody: "hi", toolCalls: [], threadID: UUID(), totalDuration: nil,
            timeToFirstToken: nil, outputTokens: nil, isE2EEActive: true,
            teeVerification: .unverified(.gatewayTrustOnly(signingAddress: "0xabc")))
        session.finishTurn(for: place, debugInfo: info, error: nil)
        session.abandonTurn(for: place, reason: "x")
        #expect(session.lastRequestUsedE2EE == nil && session.lastE2EEFailReason == nil)
        #expect(session.e2eeMessageCount == 0 && session.gatewayTrustResponseCount == 0)
    }

    /// T5 (trust-stale-record, the maintainer 2026-11-06): a record older than 10 minutes whose refetch failed stayed
    /// green with no age cap. It now degrades SOFTLY — the send asks — with the existing reason.
    @Test @MainActor func aStaleRecordWhoseRefetchFailedIsNoLongerVerified() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.attestation = .preview
        session.lastRequestUsedE2EE = true
        session.imageProvenance = .allVerified(verified: [], thirdParty: [])
        session.provenanceSettled = true
        #expect(session.attestationState == .ok, "precondition")
        session.attestationFetchFailed = true
        #expect(session.attestationState == .ok, "a fresh record with a failed refetch is still good")
        let fetched = AttestationRecord.preview.fetchedAt
        session.now = { fetched.addingTimeInterval(ConfidentialSession.attestationMaxAge + 1) }
        #expect(session.attestationState == .degraded)
        #expect(!session.degradeIsHardFailure && session.sendPolicy == .confirm, "soft: the send asks")
        #expect(session.e2eeDegradedReason == "couldn't reach the attestation server.")
        session.attestationFetchFailed = false
        #expect(session.attestationState == .ok, "old but not failed: the next send refreshes it")
    }

    /// T5: a same-context refresh left the last fetch's "no confidential endpoint" standing.
    @Test @MainActor func everyRefreshAsksAgainWhetherThereIsAConfidentialEndpoint() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.refreshAttestation()
        session.attestationTask?.cancel()
        session.noConfidentialEndpoint = true
        session.refreshAttestation()
        session.attestationTask?.cancel()
        #expect(!session.noConfidentialEndpoint)
    }

    /// near-trust-scope (the maintainer 2026-11-06): (a) or (b) mismatching, or a running compose file that doesn't
    /// match its hash, blocks the send like a replayed quote, each with its own approved banner line.
    @Test @MainActor func aTrustScopeBreakBlocksTheSendAndNamesItsCause() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.attestation = .preview
        session.lastRequestUsedE2EE = true
        session.imageProvenance = .allVerified(verified: [], thirdParty: [])
        session.provenanceSettled = true
        session.trustScope = TrustScope(binding: .bound, boot: .matches)
        #expect(session.attestationState == .ok, "precondition: a clean scope changes nothing")
        let src = ActionLogReading.Source(commit: "c", file: "f", fileSHA256: "s")
        let svc = ActionLogReading.RunningService(service: "proxy", source: src, tag: nil, since: nil)
        let cases: [(TrustScope, String)] = [
            (TrustScope(binding: .mismatch(.actionsHash), boot: .matches), "the action log doesn't match the compose manager's hardware quote."),
            (TrustScope(binding: .bound, boot: .mismatch(.rtmr3)), "the boot event log doesn't match the model's hardware quote."),
            (TrustScope(binding: .bound, boot: .matches, running: [.init(service: svc, outcome: .mismatch)]),
             "the running recipe doesn't match the signed action log, so the launched configuration is unverified."),
            (TrustScope(binding: .notBound, boot: .matches, running: [.init(service: svc, outcome: .mismatch)]),
             "the running recipe doesn't match the action log, so the launched configuration is unverified."),
        ]
        for (scope, reason) in cases {
            session.trustScope = scope
            #expect(session.attestationState == .degraded && session.degradeIsHardFailure && session.sendPolicy == .block)
            #expect(session.e2eeDegradedReason == reason)
        }
        session.trustScope = TrustScope(binding: .notBound, boot: .absent,
                                        running: [.init(service: svc, outcome: .unpublished)])
        #expect(session.attestationState == .ok && session.sendPolicy == .allow, "not bound, absent and unpublished never block")
    }

    @Test @MainActor func aRunningTrustScopeCheckIsPending() {
        let session = ConfidentialSession(providers: Self.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.attestation = .preview
        session.trustScopeTask = neverAnswers()
        defer { session.trustScopeTask?.cancel() }
        #expect(session.verdictsPending)
        session.trustScope = TrustScope(binding: .bound, boot: .matches)
        #expect(!session.verdictsPending)
    }

    @Test @MainActor func prepareTurnForAPlaceNoLongerSelectedOpensNothing() async {
        let store = Self.storeMatchingPreviewRecord()
        let session = ConfidentialSession(providers: store)
        session.attestationTask?.cancel()
        session.attestation = .preview
        let place = ConfidentialSession.TurnPlace(try! #require(store.activeProvider))
        let nvidia = Provider.nvidia
        store.addProvider(nvidia)
        store.currentProviderID = nvidia.id.uuidString
        let ctx = await session.prepareTurn(for: place)
        #expect(ctx == nil, "no context for a turn whose model is no longer selected")
        #expect(session.lastRequestUsedE2EE == nil, "nothing opened")
    }
}

@Suite("AppSettings")
struct AppSettingsTests {

    @Test func defaultSystemPrompt_containsDatePlaceholder() {
        #expect(AppSettings.defaultSystemPrompt.contains("{{date}}"))
    }

    @Test func defaultSystemPrompt_isNotEmpty() {
        #expect(!AppSettings.defaultSystemPrompt.isEmpty)
    }

    @Test @MainActor func groundingAPIKey_isNilWhenOffOrEmpty() {
        let settings = AppSettings()
        let previous = settings.braveGroundingEnabled
        settings.braveGroundingEnabled = false
        #expect(settings.groundingAPIKey == nil)
        settings.braveGroundingEnabled = previous
    }
}

@Suite("MoonPhase")
struct MoonPhaseTests {

    @Test func currentSymbolName_isValidSFSymbol() {
        #expect(MoonPhase.currentSymbolName.hasPrefix("moonphase."))
    }
}

/// near.ai's endpoints directory is the only host map. What a miss means
/// depends on the tier, and getting it wrong sends in the clear.
@Suite("a missing direct host")
struct MissingDirectHostTests {
    /// Models near.ai set up with its list loaded: see `NearAIModelCatalog.tierListSeen`.
    init() { NearAIModelCatalog.seeTierListForTests() }


    @Test func anOwnFleetModelWithNoHostDegrades() {
        #expect(NearAIModelCatalog.confidentiality(forID: "z-ai/glm-5.3-flash") == .teeOwn)
        #expect(ConfidentialSession.outcome(whenNoDirectHostFor: "z-ai/glm-5.3-flash") == .degraded)
    }

    /// An id the guess has never seen also classifies own-fleet, so it degrades
    /// too. That is the fail-closed direction: the send asks.
    @Test func anUnknownIdDegrades() {
        #expect(ConfidentialSession.outcome(whenNoDirectHostFor: "z-ai/glm-6-preview") == .degraded)
    }

    /// Tiers that never had a confidential endpoint stay ordinary: no lock, no
    /// spinner, no block.
    @Test func proxiedAndThirdPartyModelsAreOrdinary() {
        #expect(ConfidentialSession.outcome(whenNoDirectHostFor: "anthropic/claude-sonnet-5") == .ordinary)
        #expect(ConfidentialSession.outcome(whenNoDirectHostFor: "moonshotai/kimi-k3") == .ordinary)
    }

/// A missing directory host used to read "Could not reach the attestation
/// server" although the server answered, and stayed that way until a provider
/// switch. It names itself now, and the pre-send staleness check retries it.
@Suite("a missing direct host — reason and retry")
@MainActor
struct MissingDirectHostReasonTests {
    /// Models near.ai set up with its list loaded: see `NearAIModelCatalog.tierListSeen`.
    init() { NearAIModelCatalog.seeTierListForTests() }

    @Test func theReasonNamesTheDirectoryNotTheServer() {
        let session = ConfidentialSession(providers: ConfidentialSessionTests.storeMatchingPreviewRecord())
        session.attestationFetchFailed = true
        session.directHostMissing = true
        #expect(session.e2eeDegradedReason?.contains("no confidential host") == true)
        session.directHostMissing = false
        #expect(session.e2eeDegradedReason == "couldn't reach the attestation server.")
    }

    @Test func aFailedFetchIsRetriedAfterTheInterval() {
        let session = ConfidentialSession(providers: ConfidentialSessionTests.storeMatchingPreviewRecord())
        session.attestationFetchFailed = true
        session.attestationAttemptedAt = Date().addingTimeInterval(-ConfidentialSession.attestationRetryInterval - 1)
        session.refreshAttestationIfStale()
        #expect(session.attestationAttemptedAt.map { Date().timeIntervalSince($0) < 5 } == true)
        // Too soon after the last try: left alone.
        let stamp = Date().addingTimeInterval(-5)
        session.attestationAttemptedAt = stamp
        session.refreshAttestationIfStale()
        #expect(session.attestationAttemptedAt == stamp)
    }
}
}

/// Trust ladder: "retry" after the 8 s wait re-ran the fetch, but the state stayed
/// `.verifying`, so the timer keyed on it never restarted and the screen spun forever.
@MainActor
@Suite("Trust ladder — re-verify restarts the wait")
struct FirstRecordWaitTests {
    @Test func aRerunWithTheSameStateRestartsTheWait() {
        let session = ConfidentialSession(providers: ConfidentialSessionTests.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        #expect(session.attestationState == .verifying)
        let before = session.firstRecordWaitID
        session.refreshAttestation()
        session.attestationTask?.cancel()
        #expect(session.attestationState == .verifying)
        #expect(session.firstRecordWaitID != before)
    }
}
