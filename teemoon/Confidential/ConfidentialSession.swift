//
//  ConfidentialSession.swift
//  teemoon
//
//  The attested, end-to-end-encrypted inference session — the app's core
//  concept, as one type. Owns the attestation lifecycle for the active
//  provider, the E2EE availability state machine, and the per-session
//  verification history. What that state *means* lives in
//  ConfidentialSession+Verdict.swift. Fetch lives in
//  ConfidentialSession+Refresh.swift; the four post-fetch checks live
//  in ConfidentialSession+Verifiers.swift.
//

import Foundation

@Observable
@MainActor
final class ConfidentialSession {

    private let providers: ProviderStore

    /// Attestation record for the currently active near.ai provider.
    /// `nil` while loading or when the active provider doesn't support attestation.
    ///
    /// READ GATE: the getter refuses to expose a record fetched for a
    /// different (provider, model) than the currently active one. After
    /// three distinct stale-display bugs (missed trigger, keepExisting trap,
    /// adoption race), the invariant lives at the type level: no matter which
    /// refresh path or task ordering slips through, a mismatched record reads
    /// as nil — the UI shows "verifying" and the E2EE context can never seal
    /// to a stale key. Records without a model stamp (legacy/tests) gate on
    /// provider id alone.
    var attestation: AttestationRecord? {
        get {
            guard let rec = attestationStored else { return nil }
            // DesignTour / Canvas fixtures plant a full verified record; the
            // live (provider, model) read gate would hide it when the preset's
            // default model differs from the fixture stamp (observed: near.ai
            // defaults to glm-5.2 while preview is GLM-5.1-FP8 → permanent
            // "verifying…", and live provenance then rewrote the artifact).
            if freezeAttestationFixtures { return rec }
            guard let p = providers.activeProvider else { return nil }
            guard rec.providerID == p.id else { return nil }
            if let model = rec.model, model != p.model { return nil }
            return rec
        }
        set { attestationStored = newValue }
    }
    /// Backing storage (tracked; the public accessor applies the read gate).
    private var attestationStored: AttestationRecord?

    /// Set to `true` when the attestation fetch fails, so the UI can stop showing a spinner.
    var attestationFetchFailed = false

    /// `true` when the active model is classified attestable but near.ai serves
    /// no confidential endpoint for it (absent from the `/endpoints` directory —
    /// e.g. a retired model like deepseek-v3.2). It can't be attested, so rather
    /// than stalling on "verifying" then failing closed, it's treated as a plain
    /// non-attestable model (state `.none`, no lock, no send block).
    var noConfidentialEndpoint = false

    /// Whether the most recent completed request used application-layer E2EE.
    /// `nil` = no request made yet, `true` = E2EE succeeded, `false` = E2EE failed.
    var lastRequestUsedE2EE: Bool? = nil
    /// Brief reason when `lastRequestUsedE2EE` is false (e.g. "Server rejected key (HTTP 421)").
    var lastE2EEFailReason: String? = nil

    /// Number of responses in this session whose TEE signature was verified.
    var verifiedResponseCount: Int = 0
    /// Number of responses in this session with a TEE signature mismatch (even after re-fetch).
    var mismatchedResponseCount: Int = 0
    /// Number of responses in this session accepted via gateway trust only —
    /// the signer was not individually attested, so these are NOT counted as verified.
    var gatewayTrustResponseCount: Int = 0
    /// Number of messages (sent + received) in this session that used E2EE.
    var e2eeMessageCount: Int = 0

    /// Image-provenance result for the active attestation's manifest.
    /// nil = not yet checked (pending or no manifest); set once verification
    /// completes. A definitive `.incomplete` degrades the security state.
    var imageProvenance: ProvenanceService.ManifestProvenance?
    /// Verdict of the model-layer (inner) compose hash check against the action
    /// log's pinned `file_sha256` (nil = not attempted yet). `.hashMismatch` is
    /// an adversarial integrity break and degrades the session (see
    /// `modelComposeIntegrityFailed`); `.fetchFailed` is transient/advisory only.
    var modelLayerVerification: ModelLayerVerification?

    /// The running recipe (inner compose) failed its on-device hash check
    /// against the signed action log — the launched config is NOT what was
    /// pinned. An adversarial integrity break, distinct from a transient fetch
    /// failure. Fail-closed: this degrades the session (see `attestationState`).
    var modelComposeIntegrityFailed: Bool { modelLayerVerification == .hashMismatch }
    /// The hash-verified model-layer (inner) compose YAML text itself — the
    /// document compose-manager actually launched inside the model enclave
    /// (its SHA256 equals the attested `file_sha256`). In production THIS is
    /// the document that names the engine + E2EE proxy; the outer
    /// `gpuNodeComposeManifest` is the management harness only. Ephemeral,
    /// like the rest of the attestation state; never persisted.
    var modelLayerManifest: String?
    /// The pinned model artifact parsed from that hash-verified model-layer
    /// YAML — the real HF repo + revision + quant vs the served alias, and any
    /// quantization drift between them (nil = not parsed / not available).
    /// Ephemeral, like the rest of the attestation state; never persisted.
    var modelArtifact: ModelArtifact?

    /// DesignTour / Canvas fixtures only. When true, skip live provenance /
    /// DCAP / NRAS re-fetch that would clear the planted `modelArtifact`
    /// (GLM-5.1 AWQ vs served FP8 drift) and replace it with whatever
    /// production currently serves.
    var freezeAttestationFixtures = false

    /// Verifier used for image provenance (overridable in tests).
    let provenanceService: ProvenanceService

    /// Real DCAP verification (dcap-qvl) outcome for the active record's
    /// quotes. nil = not yet checked; a hard failure degrades the state.
    var dcapVerification: RecordDCAPVerification?

    /// Verifier used for DCAP (overridable in tests).
    let dcapService: DCAPService

    /// NVIDIA NRAS outcome for the record's GPU evidence. nil = not yet
    /// checked or no GPU evidence; .failed degrades the security state.
    var gpuAttestation: NRASVerification?

    /// Verifier used for NRAS (overridable in tests).
    let nrasService: NRASService

    /// TLS-attestation outcome (HTTPS terminates inside the model TEE).
    /// nil = not yet checked; `.failed` degrades; `.notPerformed` is neutral.
    var tlsAttestation: TLSAttestation?

    /// Verifier used for TLS attestation (overridable in tests).
    let tlsService: TLSAttestationVerifier

    @ObservationIgnored
    var provenanceTask: Task<Void, Never>?

    @ObservationIgnored
    var dcapTask: Task<Void, Never>?

    @ObservationIgnored
    var nrasTask: Task<Void, Never>?

    @ObservationIgnored
    var tlsTask: Task<Void, Never>?

    /// The (provider, model) the current attestation-derived state belongs to.
    /// A change means a real switch → every derived field must be reset so the
    /// previous model's name/images/verdict can't bleed into the new selection.
    @ObservationIgnored
    var attestedContext: String?

    init(providers: ProviderStore,
         provenanceService: ProvenanceService = ProvenanceService(),
         dcapService: DCAPService = DCAPService(),
         nrasService: NRASService = NRASService(),
         tlsService: TLSAttestationVerifier = TLSAttestationVerifier()) {
        self.providers = providers
        self.provenanceService = provenanceService
        self.dcapService = dcapService
        self.nrasService = nrasService
        self.tlsService = tlsService
        refreshAttestation()
    }

    // MARK: Request lifecycle

    /// The provider this session is currently attesting.
    var activeProvider: Provider? { providers.activeProvider }

    /// Key the TLS verifier sends to the model's direct host.
    func credential(for provider: Provider) -> String {
        providers.credential(for: provider)
    }

    /// Whether a send right now would be application-layer sealed.
    var canSeal: Bool { currentTEEContext()?.e2eePeer != nil }

    /// The TEE request context for the active provider, or nil when the
    /// provider doesn't support attestation or no record has landed yet.
    /// The single place a `TEEContext` is derived.
    func currentTEEContext() -> TEEContext? {
        guard let provider = providers.activeProvider,
              provider.capabilities.contains(.attestation),
              let attestation else { return nil }
        return TEEContext(provider: provider,
                          apiKey: providers.credential(for: provider),
                          attestation: attestation)
    }

    /// One turn: refresh a stale record, wait for the E2EE key if this
    /// provider attests, derive the context, and open the bookkeeping.
    /// `ChatViewModel` must not write E2EE fields itself.
    func prepareTurn() async -> TEEContext? {
        refreshAttestationIfStale()
        if providers.activeProvider?.capabilities.contains(.attestation) == true {
            _ = await e2eeKey(waitingUpTo: .seconds(15))
        }
        let context = currentTEEContext()
        beginRequest(expectingE2EE: context?.e2eePeer != nil)
        return context
    }

    /// Close the turn. Outcome and (optional) signature check are
    /// recorded here so the view-model does not increment counters.
    func finishTurn(debugInfo: LastRequestDebugInfo?, error: LLMError?,
                    verification: ResponseVerification? = nil) {
        recordRequestOutcome(debugInfo: debugInfo, error: error)
        if let verification {
            recordVerification(verification)
        } else if let verification = debugInfo?.teeVerification {
            recordVerification(verification)
        }
    }

    /// Optimistically records that a request is starting. `expectingE2EE`
    /// reflects whether an E2EE peer was available at send time; the actual
    /// outcome arrives via `recordRequestOutcome`.
    func beginRequest(expectingE2EE: Bool) {
        lastRequestUsedE2EE = expectingE2EE
        lastE2EEFailReason = nil
    }

    /// Records the actual outcome of a completed request: whether E2EE was
    /// active on the wire, the session message count, and a human-readable
    /// reason when E2EE failed.
    func recordRequestOutcome(debugInfo: LastRequestDebugInfo?, error: LLMError?) {
        if let debugInfo {
            lastRequestUsedE2EE = debugInfo.isE2EEActive
            if debugInfo.isE2EEActive { e2eeMessageCount += 2 }  // one sent + one received
        }
        if lastRequestUsedE2EE != true, let error {
            lastE2EEFailReason = error.httpStatus.map { "Server rejected request (HTTP \($0))" }
                ?? error.userMessage
        }
    }

    /// Records the outcome of one response's signature verification in the
    /// session history counters.
    func recordVerification(_ verification: ResponseVerification) {
        switch verification {
        case .verified: verifiedResponseCount += 1
        case .unverified(.gatewayTrustOnly): gatewayTrustResponseCount += 1
        case .unverified(.signatureMismatch): mismatchedResponseCount += 1
        case .unverified(.contentMismatch): mismatchedResponseCount += 1
        case .unverified: break
        }
    }

    // MARK: Awaitable operations

    /// The model's Ed25519 E2EE key, waiting up to `timeout` for the in-flight
    /// attestation fetch (which retries with backoff — the model TEE may be
    /// cold-starting). Returns nil if the key is still unavailable.
    func e2eeKey(waitingUpTo timeout: Duration) async -> Data? {
        #if DEBUG
        // `e2eeUnavailable` seed: no key is ever coming (the live fetch is
        // suppressed) — return immediately instead of burning the full wait
        // in the UI test that forces the 4.1 refusal.
        if Self.seededState?.suppressLiveAttestation == true {
            return attestation?.modelEd25519PubKey
        }
        #endif
        if let key = attestation?.modelEd25519PubKey { return key }
        let deadline = ContinuousClock.now + timeout
        _ = await attestationTask?.value
        while ContinuousClock.now < deadline {
            if let key = attestation?.modelEd25519PubKey { return key }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return attestation?.modelEd25519PubKey
    }

    /// Waits (up to `timeout`) until the current refresh produced a record or
    /// failed, so callers can react to the outcome instead of polling fields.
    func attestationOutcome(waitingUpTo timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        _ = await attestationTask?.value
        while ContinuousClock.now < deadline {
            if attestation != nil || attestationFetchFailed { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: Derived state

    #if DEBUG
    /// A FORCED ATTESTATION STATE, FOR CAPTURE RUNS ONLY.
    ///
    /// The Mac trust surfaces have five chip states and only one of them can be
    /// reached by a fixture: the happy path. `verifying` is a race, `degraded`
    /// and hard failure need a server that fails in a specific way, and a design
    /// review can only review what a capture can reach — so the loop was
    /// silently covering the good case and nothing else.
    ///
    /// Forced attestation, for capture and product E2E only.
    ///
    /// `UITEST_SEED_ATTESTATION=verifying|degraded|hardFailure|none|mismatch`.
    /// DEBUG-only AND `--uitesting`-gated: a shipping build cannot reach it, and
    /// there is no path where a real session reports a state it did not compute.
    /// That gate matters more here than anywhere else in the app — this is the
    /// one value teemoon exists to be honest about.
    ///
    /// Not platform-gated. Mac used this first for chip captures; iOS product
    /// E2E uses the same door so "sending blocked" / "didn't check out" can be
    /// asserted without a live TEE.
    struct SeededAttestation {
        var state: AttestationState
        var hardFailure: Bool
        var mismatchCount: Int = 0
        /// When true, the live attestation fetch is suppressed so no REAL
        /// record (and so no E2EE peer) can ever land — while the seeded
        /// verdict still answers for the UI/send gate. This is the forcing
        /// state for the finding-4.1 fail-closed test: `sendPolicy == .allow`
        /// with `currentTEEContext()?.e2eePeer == nil`.
        var suppressLiveAttestation: Bool = false
    }

    static var seededState: SeededAttestation? {
        guard ProcessInfo.processInfo.arguments.contains("--uitesting"),
              let raw = ProcessInfo.processInfo.environment["UITEST_SEED_ATTESTATION"]
        else { return nil }
        switch raw {
        case "ok":          return SeededAttestation(state: .ok, hardFailure: false)
        case "verifying":   return SeededAttestation(state: .verifying, hardFailure: false)
        case "degraded":    return SeededAttestation(state: .degraded, hardFailure: false)
        case "hardFailure": return SeededAttestation(state: .degraded, hardFailure: true)
        case "none":        return SeededAttestation(state: .none, hardFailure: false)
        case "mismatch":    return SeededAttestation(state: .ok, hardFailure: false, mismatchCount: 1)
        // Verdict green, but NO real record/key can ever arrive: the exact
        // window the fail-closed gate covers (gate allows, peer nil → refusal).
        case "e2eeUnavailable":
            return SeededAttestation(state: .ok, hardFailure: false, suppressLiveAttestation: true)
        default:            return nil
        }
    }
    #endif

    // MARK: Attestation lifecycle

    @ObservationIgnored
    var attestationTask: Task<Void, Never>?

    /// Maximum age before the Ed25519 key is considered stale and refetched.
    static let attestationMaxAge: TimeInterval = 600 // 10 minutes

    /// True inside an Xcode Preview render — used to keep previews offline.
    nonisolated static var isRunningInPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// Preview and the `-DesignTour` capture harness must not fetch.
    /// Process flags only — this type must not import Views to ask `DesignTour`.
    nonisolated static func skipsLiveAttestation(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return true }
        #if DEBUG
        return arguments.contains("-DesignTour")
        #else
        return false
        #endif
    }

}
