//
//  TrustLadderView.swift
//  teemoon
//
//  The "who can read this?" screen — the SwiftUI port of Direction D (trust
//  ladder). It answers one load-bearing question — "my plaintext is reachable
//  only by a specific, known model, and no one else holds the key" — and backs
//  it with a connected chain of evidence, disclosed at the reader's chosen rung
//  (everyday / expert).
//
//  The chain is disclosed at two rungs: `everydayChain` is a curated five-node
//  story (your message → sealed to the model → it's the real published model →
//  a grey compression aside → every reply comes back signed), and `expertChain`
//  is the full technical spine. The return trip (response signatures) is the
//  chain's terminus at both rungs; transport (TLS) stays off the rail as an
//  expert-only card; a `disclosed limits` card names what the build does *not*
//  do. Same verdict at both rungs — only the amount of exposed proof changes.
//
//  Presentation pieces (TrustRung, ChainNode, ChainRailView, RungPicker) live
//  in TrustLadder.swift; this file is the data binding.
//

import SwiftUI

// UN-GATED. This screen is the product's central claim; it was iOS-only
// for four platform-specific calls, not for its design.

struct TrustLadderView: View {
    @Environment(ConfidentialSession.self) var session
    @Environment(ProviderStore.self) var providerStore
    @Environment(\.dismiss) var dismiss

    /// Phones open on `everyday` (the plain-language front door); the reader can
    /// flip up to `expert`. The verdict is identical at every rung — only the
    /// amount of exposed proof changes. `initialRung` lets previews/tours seed a
    /// rung; production passes nil.
    @State var rung: TrustRung
    @State var timedOut = false
    @State var showEncryptedModelPicker = false
    @State var pickedEncryptedModel = ""

    /// Optional scroll-to-id for previews/tours (e.g. "reverify"). Production nil.
    let initialScroll: String?

    /// Whether this instance draws its own everyday/expert picker.
    ///
    /// FALSE when embedded in the Mac trust popover. The popover ends in a
    /// `show the proof…` push button instead, because both rungs do not fit a
    /// popover — and a segmented control swaps content INSIDE a container, it
    /// never dissolves the container it lives in. The segments belong in the
    /// inspector window, where both rungs actually fit.
    let showsRungPicker: Bool

    init(initialRung: TrustRung? = nil, initialScroll: String? = nil, showsRungPicker: Bool = true) {
        self.showsRungPicker = showsRungPicker
        #if os(iOS)
        _rung = State(initialValue: initialRung ?? DesignTour.initialRung ?? .everyday)
        #else
        // DesignTour is the iOS capture harness — `simctl launch` flags. Its
        // absence changes nothing a user sees; the default rung is the same.
        _rung = State(initialValue: initialRung ?? .everyday)
        #endif
        self.initialScroll = initialScroll
    }

    var summary: AttestationSummary {
        AttestationSummary(
            attestation: session.attestation, state: session.attestationState, timedOut: timedOut,
            provider: providerStore.activeProvider,
            lastRequestUsedE2EE: session.lastRequestUsedE2EE, lastE2EEFailReason: session.lastE2EEFailReason,
            verifiedResponseCount: session.verifiedResponseCount, mismatchedResponseCount: session.effectiveMismatchCount,
            gatewayTrustResponseCount: session.gatewayTrustResponseCount,
            attestationFetchFailed: session.attestationFetchFailed, imageProvenance: session.imageProvenance,
            dcapVerification: session.dcapVerification, nrasVerification: session.gpuAttestation,
            tlsAttestation: session.tlsAttestation,
            modelLayerVerification: session.modelLayerVerification,
            degradeIsHardFailure: session.degradeIsHardFailure,
            e2eeIntact: session.e2eeBindingIntact)
    }

    /// Everyday claims live on `TrustVerdict`. This view renders them.
    var verdict: TrustVerdict {
        TrustVerdict.make(.init(
            attestationState: session.attestationState,
            requiresConfirmation: isPaused,
            degradeIsHardFailure: session.degradeIsHardFailure,
            mismatchedResponseCount: session.effectiveMismatchCount,
            modelName: modelName,
            quant: quant,
            providerDisplayName: providerDisplayName,
            isLocal: isOnDevice,
            isSelfHosted: isSelfHosted,
            e2eeKeyBound: summary.e2eeKeyBound,
            provenanceState: summary.provenanceState,
            provenanceDetail: summary.provenanceDetail,
            responseSigState: summary.responseSigState,
            hasSigningAddress: session.attestation?.signingAddress != nil,
            quantDrift: session.modelArtifact?.quantDrift == true,
            auditState: modelNodeAuditState,
            deviceBoundary: DeviceNoun.boundary,
            deviceSubject: DeviceNoun.subject,
            e2eeDegradedReason: session.e2eeDegradedReason,
            unpublishedButSealed: session.unpublishedOnlyButE2EEIntact
        ))
    }

    /// Short display name for the model. Prefers the *pinned* artifact's clean
    /// name (from the hash-verified model-layer YAML) — "GLM-5.1" — over the
    /// provider's served alias, which can misstate the model.
    var modelName: String {
        // The artifact is derived state from a specific record; only let it
        // name the model while that record passes the session's read gate —
        // otherwise fall through to the active provider's own model id.
        if session.attestation != nil,
           let base = session.modelArtifact?.baseModelName, !base.isEmpty { return base }
        // A downloaded model carries a HuggingFace repo id, and the split below
        // yields "gemma-4-E2B-it-litert-lm" — two of those suffixes name a file
        // format and a runtime, neither of which is what the user downloaded. The
        // catalog's own name is what every other surface prints, and this screen
        // says it in a sentence, so it has to read like a name.
        if let provider = providerStore.activeProvider,
           let localID = provider.localModelID,
           let model = LocalModelCatalog.model(id: localID) {
            return model.displayName
        }
        let raw = providerStore.activeProvider?.model ?? "the model"
        return raw.split(separator: "/").last.map(String.init) ?? raw
    }

    /// Quantization of the pinned weights (from the model path, never the
    /// served alias). nil until the model-layer YAML is parsed.
    var quant: String? { session.modelArtifact?.quant }

    /// Whether sending is actually blocked pending re-verification. This is the
    /// REAL gate — `ConfidentialSession.requiresE2EEConfirmation` (attestation
    /// degraded) — nothing else. A reply-signature mismatch demotes the run to
    /// `.failed` (red) but does NOT block sending, so it must not read as
    /// "paused": conflating the two produced a hero that claimed "sending
    /// paused" while sending was in fact open, with a mis-attributed cause.
    var isPaused: Bool {
        session.requiresE2EEConfirmation
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // EAGER, AND IT MUST STAY THAT WAY. A LazyVStack estimates the
                // height of every off-screen section and revises it on
                // realization; these sections vary far too much for that. The
                // offset lurched while scrolling toward the script and once
                // wedged the main thread for 18 minutes in a layout pass that
                // never converged. Laziness bought ~37 ms of warm render here
                // (measured) — nowhere near the price. See
                // `TrustLadderLayoutTests`.
                VStack(alignment: .leading, spacing: 26) {
                    // `.none` = nothing to attest (a non-attestation provider, or
                    // a near.ai model with no confidential endpoint). Show the
                    // honest "not encrypted" state — NEVER the chain, which would
                    // fabricate a proof the provider can't back.
                    // On device FIRST, and it cannot be folded into the
                    // self-hosted branch below: a local provider's endpoint is
                    // the literal string "on-device", which has no host, so
                    // `isSelfHosted` is false for it (see `WhereLocality`, and
                    // the same trap filed every downloaded model under CLOUD in
                    // the picker).
                    if session.attestationState == .none && isOnDevice {
                        onDeviceView
                    } else if session.attestationState == .none && isSelfHosted {
                        selfHostedView
                    } else if session.attestationState == .none {
                        notAttestableView
                    } else {
                        hero
                        if showsRungPicker { RungPicker(rung: $rung) }
                        chainSection(proxy)
                        knownCodeSection
                        hardwareSection
                        transportSection
                        disclosedLimitsSection
                        residualTrustSection
                        reverifySection
                    }
                }
                .padding(20)
                // Pin the document to exactly the scroll view's width. Left to
                // itself it measured 402.667pt inside a 402.333pt viewport —
                // sub-pixel, but UIScrollView enables an axis on ANY overflow,
                // so the whole sheet rubber-banded sideways. No test can hold
                // this: a hosted window lays out on integral widths, so the
                // overflow is zero there by construction. Check it on device.
                .containerRelativeFrame(.horizontal)
            }
            // Preview/tour convenience: `initialScroll` starts the view at the
            // bottom so the re-verify block is snapshot-visible without waiting
            // on the async scroll. Production (nil) keeps the natural top anchor.
            .defaultScrollAnchor(initialScroll == nil ? .top : .bottom)
            .navigationTitle("who can read this?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(iOS)
            // The Mac shows this in its own window, which carries a close
            // control already — an in-content ✕ beside it is the same mistake
            // the Where picker and the settings window both had removed.
            .toolbar {
                ToolbarItem(placement: .barLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityIdentifier("attestation.close")
                }
            }
            #endif
            .task(id: session.attestationState) {
                timedOut = false
                guard session.attestationState == .verifying else { return }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !Task.isCancelled && session.attestationState == .verifying { timedOut = true }
            }
            // inert in normal runs; -DesignTourBottom scrolls to the known-code
            // section so the capture pipeline can screenshot it.
            .task {
                // fetch the audit index so digest-gated "audit" links can
                // appear on known-code rows (no entry -> no link, fail closed)
                AuditIndex.shared.loadIfNeeded()
                #if os(iOS)
                let target = DesignTour.scrollTarget ?? initialScroll ?? (DesignTour.scrollToBottom ? "known code" : nil)
                #else
                let target = initialScroll
                #endif
                guard let target else { return }
                try? await Task.sleep(nanoseconds: 900_000_000)
                withAnimation { proxy.scrollTo(target, anchor: .top) }
            }
        }
    }
}
