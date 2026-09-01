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
        session.refreshAttestation(keepExisting: true)
        // The 5.1 artifact must be gone — the switch invalidates it even though
        // the caller asked to keep existing state for a same-context refresh.
        #expect(session.modelArtifact == nil)
        // And a same-context keepExisting refresh must NOT clear: re-seed and refresh.
        session.modelArtifact = ModelArtifact(
            modelPath: "PhalaCloud/GLM-5.2-W4AFP8", revision: nil,
            servedName: "z-ai/glm-5.2", quant: "W4AFP8")
        session.refreshAttestation(keepExisting: true)
        #expect(session.modelArtifact != nil)
    }

    /// The provenance-blocked-but-E2EE-intact discriminator drives the honest
    /// send alert ("still encrypted — code unverified" vs "send unencrypted").
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
}

@Suite("AppSettings")
struct AppSettingsTests {

    @Test func defaultSystemPrompt_containsDatetimePlaceholder() {
        #expect(AppSettings.defaultSystemPrompt.contains("{{datetime}}"))
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
