//
//  TrustVerdict.swift
//  teemoon
//
//  The everyday security sentences — hero, title-block caption, send policy,
//  and the five-node chain — as a plain value. TrustLadderView, E2EETitleBlock,
//  and ChatViewModel read this. They do not author the claims.
//
//  Inputs are plain values (never ConfidentialSession) so the quotes a
//  reviewer will copy can be unit-tested.
//

import Foundation

/// Worst-verdict rollup for the model node. Any `leaks` wins; full coverage
/// with no leaks/inconclusive is reviewed; anything else is a gap.
enum EverydayAuditState: Equatable { case leaks, reviewed, incomplete }

func everydayAuditState(classes: [AuditIndex.VerdictClass],
                        allTouchersCovered: Bool) -> EverydayAuditState {
    if classes.contains(.leaks) { return .leaks }
    if allTouchersCovered, !classes.isEmpty, !classes.contains(.inconclusive) {
        return .reviewed
    }
    return .incomplete
}

/// One everyday chain claim. The view maps this onto `ChainNode`.
struct TrustClaim: Equatable {
    enum Status: Equatable { case origin, ok, alert, info, fail, pending }
    let id: String
    let status: Status
    let title: String
    let detail: String
    var jumpTitle: String? = nil
    var jumpTarget: String? = nil
    var jumpAtEveryday: Bool = false
}

/// Send policy for an attested provider. Soft degrade asks; hard break refuses.
enum TrustSendPolicy: Equatable {
    case allow
    case confirm
    case block
}

/// Title-block / chip display mode. Richer than `AttestationState` so a red
/// integrity break never collapses into the same orange as a benign degrade.
enum TrustChipMode: Equatable {
    case verified, verifying, softDegrade, hardBlock, mismatch
    case onDevice, selfHosted, none
}

/// Everyday verdict: hero, chip, send policy, chain claims.
struct TrustVerdict: Equatable {
    var sendPolicy: TrustSendPolicy
    var heroTitle: String
    var heroSubtitle: String
    var chipMode: TrustChipMode
    var chipCaption: String
    var everydayClaims: [TrustClaim]

    struct Input: Equatable {
        var attestationState: AttestationState
        var requiresConfirmation: Bool = false
        var degradeIsHardFailure: Bool = false
        var mismatchedResponseCount: Int = 0
        var modelName: String = ""
        var quant: String? = nil
        var providerDisplayName: String = ""
        var isLocal: Bool = false
        var isSelfHosted: Bool = false
        var e2eeKeyBound: Bool? = nil
        var provenanceState: StepState? = nil
        var provenanceDetail: String = ""
        var responseSigState: StepState? = nil
        var hasSigningAddress: Bool = false
        var quantDrift: Bool = false
        var auditState: EverydayAuditState? = nil
        var deviceBoundary: String = ""
        var deviceSubject: String = ""
        var e2eeDegradedReason: String? = nil
        /// Clean GitHub 404s only, E2EE intact. Send is allowed; not fully verified.
        var unpublishedButSealed: Bool = false
    }

    static func sendPolicy(requiresConfirmation: Bool, hardFailure: Bool) -> TrustSendPolicy {
        guard requiresConfirmation else { return .allow }
        return hardFailure ? .block : .confirm
    }

    static func chipMode(_ input: Input) -> TrustChipMode {
        if input.degradeIsHardFailure { return .hardBlock }
        if input.mismatchedResponseCount > 0 && input.attestationState == .ok { return .mismatch }
        switch input.attestationState {
        case .ok:        return .verified
        case .verifying: return .verifying
        case .degraded:  return .softDegrade
        case .none:
            if input.isLocal { return .onDevice }
            return input.isSelfHosted ? .selfHosted : .none
        }
    }

    static func chipCaption(mode: TrustChipMode, state: AttestationState,
                            unpublishedButSealed: Bool = false) -> String {
        switch mode {
        case .hardBlock:  return "verification failed \u{2014} sending blocked"
        case .mismatch:   return "a reply didn\u{2019}t check out"
        case .onDevice:   return "on this device"
        case .selfHosted: return "on your own machine"
        case .verified:   return state.caption
        case .verifying:  return state.caption
        case .softDegrade:
            if unpublishedButSealed { return "encrypted \u{2014} image unpublished" }
            return state.caption
        case .none:       return state.caption
        }
    }

    static func make(_ input: Input) -> TrustVerdict {
        let policy = sendPolicy(
            requiresConfirmation: input.requiresConfirmation,
            hardFailure: input.degradeIsHardFailure
        )
        let mode = chipMode(input)
        return TrustVerdict(
            sendPolicy: policy,
            heroTitle: heroTitle(input, paused: input.requiresConfirmation),
            heroSubtitle: heroSubtitle(input, paused: input.requiresConfirmation),
            chipMode: mode,
            chipCaption: chipCaption(mode: mode, state: input.attestationState,
                                     unpublishedButSealed: input.unpublishedButSealed),
            everydayClaims: everydayClaims(input)
        )
    }

    private static func heroTitle(_ input: Input, paused: Bool) -> String {
        if input.attestationState == .verifying { return "verifying…" }
        if paused { return input.degradeIsHardFailure ? "sending blocked" : "sending paused" }
        if input.mismatchedResponseCount > 0 {
            return input.mismatchedResponseCount == 1
                ? "one reply didn't check out"
                : "\(input.mismatchedResponseCount) replies didn't check out"
        }
        let label = input.quant.map { "\(input.modelName) · \($0)" } ?? input.modelName
        if input.unpublishedButSealed {
            return "encrypted to \(label) — one image unpublished"
        }
        if input.auditState == .leaks {
            return "encrypted to \(label) — but its logs copy what you type"
        }
        return "encrypted to \(label) — only it can read this"
    }

    private static func heroSubtitle(_ input: Input, paused: Bool) -> String {
        if input.attestationState == .verifying {
            return "confirming this conversation runs inside \(input.modelName)'s sealed hardware."
        }
        if paused {
            let cause = input.e2eeDegradedReason ?? "end-to-end encryption isn't established."
            let tail = input.degradeIsHardFailure
                ? "sending is blocked until it re-verifies."
                : "nothing is sent without your confirmation."
            return "\(cause) \(tail)"
        }
        if input.mismatchedResponseCount > 0 {
            let phrase = input.mismatchedResponseCount == 1 ? "one reply" : "\(input.mismatchedResponseCount) replies"
            return "your session is still sealed and encrypted to \(input.modelName), but \(phrase) couldn't be verified — read below."
        }
        if input.unpublishedButSealed {
            return "your message is still sealed to \(input.modelName)'s hardware key. one running image has no published attestation — see the ladder."
        }
        if input.auditState == .leaks {
            return "the seal holds on the way in, but a review of this exact build found your messages are copied into its operator's monitoring logs — see the ladder below."
        }
        return "only you and \(input.modelName)'s sealed hardware can read this chat."
    }

    private static func everydayClaims(_ input: Input) -> [TrustClaim] {
        let verifying = input.attestationState == .verifying
        var nodes: [TrustClaim] = []

        nodes.append(TrustClaim(id: "msg", status: .origin,
            title: "your message", detail: "readable only here"))

        switch input.e2eeKeyBound {
        case .some(true):
            nodes.append(TrustClaim(id: "sealed", status: .ok,
                title: "sealed so only \(input.modelName) can open it",
                detail: "before anything leaves \(input.deviceBoundary) it's locked to a key that lives inside \(input.modelName)'s sealed chip and never comes out — not \(input.providerDisplayName), not the network, nobody else can open it."))
        case .some(false):
            nodes.append(TrustClaim(id: "sealed", status: .fail,
                title: "couldn't seal this chat",
                detail: "\(input.deviceSubject) couldn't confirm \(input.modelName) holds the key — so nothing has been sent."))
        case .none:
            nodes.append(TrustClaim(id: "sealed", status: .pending,
                title: "sealing this chat to \(input.modelName)",
                detail: "locking it to a key only \(input.modelName)'s sealed chip holds…"))
        }

        switch input.provenanceState {
        case .some(.stuck):
            nodes.append(TrustClaim(id: "identity", status: .fail,
                title: "couldn't confirm it's the published \(input.modelName)",
                detail: input.provenanceDetail))
        case .some(.done):
            nodes.append(TrustClaim(id: "identity", status: .ok,
                title: "it's the real, published \(input.modelName)",
                detail: "it's the pinned, published build — checked, so a swap would show up as a mismatch."))
        case .some, .none:
            nodes.append(TrustClaim(id: "identity", status: .pending,
                title: "checking it's the real, published \(input.modelName)",
                detail: "the model checks out — one code check is still finishing."))
        }

        if let audit = auditClaim(input.auditState) {
            nodes.append(audit)
        }

        if input.quantDrift {
            nodes.append(TrustClaim(id: "drift", status: .info,
                title: "it's more compressed than the name says",
                detail: "answers may be slightly lower quality than the full-size model — your privacy isn't affected."))
        }

        if input.hasSigningAddress || verifying {
            switch input.responseSigState {
            case .some(.stuck):
                nodes.append(TrustClaim(id: "signed", status: .fail,
                    title: "a reply didn't come back signed",
                    detail: "one answer didn't carry a valid signature from \(input.modelName)'s sealed chip."))
            case .some(.done):
                nodes.append(TrustClaim(id: "signed", status: .ok,
                    title: "every reply comes back signed by \(input.modelName)",
                    detail: "each answer carries a signature only \(input.modelName)'s sealed chip can make, so you know it really came from the model."))
            case .some(.live), .some(.pending), .none:
                nodes.append(TrustClaim(id: "signed", status: verifying ? .pending : .ok,
                    title: verifying ? "checking each reply's signature" : "every reply comes back signed by \(input.modelName)",
                    detail: verifying ? "still confirming — not yet green."
                                      : "each answer carries a signature only \(input.modelName)'s sealed chip can make, so you know it really came from the model."))
            }
        }

        return nodes
    }

    private static func auditClaim(_ state: EverydayAuditState?) -> TrustClaim? {
        guard let state else { return nil }
        switch state {
        case .leaks:
            return TrustClaim(id: "audit", status: .alert,
                title: "this setup copies what you type into its operator's logs",
                detail: "a review of this exact build found your messages are copied somewhere others can read — near.ai's monitoring systems can see what you type here. The seal still protects your message on the way in; this is about what happens after it's unlocked.",
                jumpTitle: "see the proof", jumpTarget: "known code", jumpAtEveryday: true)
        case .reviewed:
            return TrustClaim(id: "audit", status: .ok,
                title: "the code that can read your message was reviewed",
                detail: "teemoon read the software that handles your unlocked message — in this exact setup, none of it is set to copy your words anywhere else.",
                jumpTitle: "see the proof", jumpTarget: "known code", jumpAtEveryday: true)
        case .incomplete:
            return TrustClaim(id: "audit", status: .info,
                title: "not everything here has been reviewed yet",
                detail: "some of the software that can see your unlocked message hasn't been reviewed — a gap in the checking, not an all-clear.")
        }
    }
}
