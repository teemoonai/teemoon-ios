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

/// Worst-verdict rollup for the model node (trust-audit-claim, the maintainer 2026-11-06). Any `leaks` wins. Green
/// only when every relevant page is covered, its class is known, and it is private or a qualified pass; a
/// compromisable page gives the caveat; a missing or unknown class (nil) is a gap, never dropped.
enum EverydayAuditState: Equatable { case leaks, reviewed, reviewedWithCaveat, incomplete }

func everydayAuditState(classes: [AuditIndex.VerdictClass?],
                        allTouchersCovered: Bool) -> EverydayAuditState {
    if classes.contains(.leaks) { return .leaks }
    guard allTouchersCovered, !classes.isEmpty,
          classes.allSatisfy({ $0 != nil && $0 != .inconclusive }) else { return .incomplete }
    return classes.contains(.compromisable) ? .reviewedWithCaveat : .reviewed
}

/// trust-provenance-unchecked (the maintainer 2026-11-06): GitHub didn't answer, so the running code wasn't checked.
enum ProvenanceUncheckedText {
    static let header = "sealed to the model's hardware on the way in. teemoon couldn't check the running code against public source just now."
    static let step = "couldn't check the running code right now \u{2014} github didn't answer. teemoon will try again."
}

/// trust-leaks-wording (the maintainer 2026-11-06): "only you … can read" is claimed only over a reviewed build.
enum AuditedSealText {
    static let notReviewed = "sealed to the model's hardware on the way in. not everything that handles it inside has been reviewed \u{2014} see below."
    static let leaksLead = "sealed to the model's hardware on the way in. a review of this exact build found:"
}

/// The model enclave's everyday audit state, from the rows whose code can read the unlocked message, and
/// the exposure summary of the first leaking page; with a list, the worst across every listed key holder too (A5).
/// Never read by the send gate.
@MainActor
enum ModelNodeAudit {
    typealias Rollup = (state: EverydayAuditState, leaksExposure: String?)

    static func state(groups: [EnclaveGroup], hasAttestation: Bool,
                      chatPath: ChatPath.Result? = nil, runningSources: [ActionLogReading.Source] = [],
                      composeManager: ActionLogReading.ComposeManagerSeat? = nil,
                      listed: ModelCandidates.Listed? = nil, listFailed: Bool = false, listedScopes: [TrustScope]? = nil,
                      audit: AuditIndex = .shared) -> (state: EverydayAuditState?, leaksExposure: String?) {
        guard hasAttestation, let group = groups.first(where: { $0.primary }) else { return (nil, nil) }
        let relevant = group.images.filter { $0.plaintextRole != nil || $0.kind == .local || $0.kind == .guestOS }
        guard !relevant.isEmpty else { return (nil, nil) }
        var urls = relevant.compactMap(\.auditURL)
        if let u = group.configAuditURL { urls.append(u) }
        if let u = group.recipe?.auditURL { urls.append(u) }
        var all = [rollup(urls, covered: relevant.allSatisfy { $0.auditURL != nil }, chatPath: chatPath,
                          runningSources: runningSources, wholeHost: false, composeManager: composeManager, audit: audit)]
        // A list that failed names no holder; a scope not in yet is not a review.
        if listFailed { all.append((.incomplete, nil)) }
        if let enclaves = listed?.enclaves, !enclaves.isEmpty {
            let scopes = listedScopes?.count == enclaves.count ? listedScopes : nil
            for (i, enclave) in enclaves.enumerated() {
                all.append(listedState(enclave, scope: scopes?[i], audit: audit))
            }
        }
        let worst = worst(all)
        return (worst.state, worst.leaksExposure)
    }

    /// One listed enclave, scoped by everything its host runs: its measured compose, its guest OS and every running
    /// revision must have a review. An off-path LEAKS page still drops out (`onPath`). nil scope: pending.
    static func listedState(_ enclave: ModelCandidates.Enclave, scope: TrustScope?, audit: AuditIndex) -> Rollup {
        guard let scope else { return (.incomplete, nil) }
        let measured = enclave.result == .clean ? audit.measuredAuditURL(composeHash: enclave.composeHash) : nil
        let os = enclave.osImageHash.flatMap { audit.osAuditURL(osImageHash: $0) }
        let sources = scope.running.map(\.service.source)
        let covered = measured != nil && os != nil && !scope.listedEvidenceAbsent
            && sources.allSatisfy { audit.manifestAuditURL(path: $0.file, fileSHA256: $0.fileSHA256) != nil }
        return rollup([measured, os].compactMap { $0 }, covered: covered, chatPath: scope.chatPath, runningSources: sources,
                      wholeHost: true, composeManager: scope.composeManager, audit: audit)
    }

    /// The read enclave's computation, on one enclave's pages.
    static func rollup(_ base: [URL], covered: Bool, chatPath: ChatPath.Result?, runningSources: [ActionLogReading.Source],
                       wholeHost: Bool, composeManager: ActionLogReading.ComposeManagerSeat?, audit: AuditIndex) -> Rollup {
        let urls = onPath(base, chatPath: chatPath, runningSources: runningSources, wholeHost: wholeHost, audit: audit)
        // A week-old index is no index for the everyday claim; the expert stamp still shows its age.
        guard audit.isFreshForEveryday else { return (.incomplete, nil) }
        let classes = urls.map { audit.verdictClass(for: $0) }
        let managerUnreviewed = TrustScope.runningManagerUnreviewed(composeManager) {
            audit.imageAuditURL(image: "nearaidev/compose-manager", digest: "sha256:\($0)")
        }
        let state = everydayAuditState(classes: classes, allTouchersCovered: covered && !managerUnreviewed)
        let exposure = state == .leaks
            ? urls.first { audit.verdictClass(for: $0) == .leaks }.flatMap(audit.exposureSummary(for:)) : nil
        return (state, exposure)
    }

    /// leaks > incomplete > reviewedWithCaveat > reviewed; the first leaking enclave's sentence.
    static func worst(_ all: [Rollup]) -> Rollup {
        let order: [EverydayAuditState] = [.leaks, .incomplete, .reviewedWithCaveat, .reviewed]
        let state = order.first { s in all.contains { $0.state == s } } ?? .incomplete
        return (state, state == .leaks ? all.lazy.compactMap { $0.state == .leaks ? $0.leaksExposure : nil }.first : nil)
    }
}

extension ModelNodeAudit {
    /// The pages that judge this chat (audit 2026-11-06, chat_path): add the pages of every revision and image on
    /// the path, and drop a recipe LEAKS page whose services the path never touches. Ambiguous: every running
    /// revision's page counts, so a leak anywhere on the CVM counts. A page without `services` always counts.
    /// `wholeHost` (a listed enclave, A5): every running revision's page counts too, before the off-path filter.
    static func onPath(_ urls: [URL], chatPath: ChatPath.Result?, runningSources: [ActionLogReading.Source],
                       wholeHost: Bool = false, audit: AuditIndex) -> [URL] {
        var out = urls
        if wholeHost {
            for source in runningSources {
                if let u = audit.manifestAuditURL(path: source.file, fileSHA256: source.fileSHA256) { out.append(u) }
            }
        }
        switch chatPath {
        case .path(let hops)?:
            for source in Set(hops.map(\.source)) {
                if let u = audit.manifestAuditURL(path: source.file, fileSHA256: source.fileSHA256) { out.append(u) }
            }
            for image in hops.compactMap(\.image) {
                if let u = audit.imageAuditURL(image: image.image, digest: "sha256:\(image.digest)") { out.append(u) }
            }
            let path = Set(hops.map(\.service))
            out = out.filter { url in
                guard audit.verdictClass(for: url) == .leaks, let e = audit.exposure(for: url), e.scope_kind == "recipe",
                      let services = e.services else { return true }
                return !path.isDisjoint(with: services)
            }
        case .ambiguous?:
            for source in Set(runningSources) {
                if let u = audit.manifestAuditURL(path: source.file, fileSHA256: source.fileSHA256) { out.append(u) }
            }
        case nil:
            break
        }
        var seen = Set<URL>()
        return out.filter { seen.insert($0).inserted }
    }
}

/// One everyday chain claim. The view maps this onto `ChainNode`.
struct TrustClaim: Equatable {
    /// `notChecked`: grey, after a halt (trust-blocked-chain-and-gateway-row).
    enum Status: Equatable { case origin, ok, alert, info, fail, pending, notChecked }
    let id: String
    var status: Status
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
    var chainHalted = false

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
        /// DCAP or NVIDIA still checking: the seal step reads checking, not proven.
        var hardwareChecksPending = false
        var listedEnclaves: KeyCustodyCopy.Listed = .checking
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
        /// `ConfidentialSession.softButSealed`: a hardware check couldn't run, the send is still sealed.
        var hardwareUnconfirmedButSealed: Bool = false
        /// A LEAKS review's own exposure summary (`ModelNodeAudit`); nil when the index has none.
        var leaksExposure: String? = nil
        /// `ConfidentialSession.recordIsStaleAndUnrefreshable`: halts the chain like a block.
        var recordStale = false
    }

    /// Under a block or a stale record nothing reads green, and every step after the first failure is not checked.
    static func settleChain(_ statuses: [TrustClaim.Status], halted: Bool) -> [TrustClaim.Status] {
        if let failAt = statuses.firstIndex(of: .fail) {
            return statuses.enumerated().map { i, status in i > failAt ? .notChecked : status }
        }
        guard halted else { return statuses }
        return statuses.map { $0 == .ok || $0 == .pending ? .notChecked : $0 }
    }

    /// Per step: whether the rail below it, into the next step, is grey.
    static func greyRails(_ statuses: [TrustClaim.Status], halted: Bool) -> [Bool] {
        statuses.indices.map { i in
            guard i + 1 < statuses.count, statuses[i] != .fail else { return false }
            return halted || [.fail, .notChecked].contains(statuses[i + 1])
        }
    }

    /// The sealed step's mark, everyday row and expert "bound" node alike.
    /// Never green beside a listed-enclaves sentence that says otherwise; .alert is the ladder's soft couldn't-check.
    static func sealedStatus(hardwareChecksPending: Bool, listed: KeyCustodyCopy.Listed) -> TrustClaim.Status {
        switch listed {
        case .checked: hardwareChecksPending ? .pending : .ok
        case .checking: .pending
        case .listFailed, .unfinished: .alert
        case .failed: .fail
        }
    }

    /// Whether the chain stops proving anything: a blocked send or a stale record.
    static func chainHalted(_ input: Input) -> Bool {
        sendPolicy(requiresConfirmation: input.requiresConfirmation, hardFailure: input.degradeIsHardFailure) == .block
            || input.recordStale
    }

    static func sendPolicy(requiresConfirmation: Bool, hardFailure: Bool) -> TrustSendPolicy {
        guard requiresConfirmation else { return .allow }
        return hardFailure ? .block : .confirm
    }

    static func chipMode(_ input: Input) -> TrustChipMode {
        if input.degradeIsHardFailure { return .hardBlock }
        // A sealed session that is re-sweeping provenance reads .verifying;
        // a reply that failed its check must not vanish for the sweep.
        if input.mismatchedResponseCount > 0,
           input.attestationState == .ok || input.attestationState == .verifying { return .mismatch }
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
                            unpublishedButSealed: Bool = false,
                            hardwareUnconfirmedButSealed: Bool = false) -> String {
        switch mode {
        case .hardBlock:  return "verification failed \u{2014} sending blocked"
        case .mismatch:   return "a reply didn\u{2019}t check out"
        case .onDevice:   return "on this device"
        case .selfHosted: return "on your own machine"
        case .verified:   return state.caption
        case .verifying:  return state.caption
        case .softDegrade:
            if hardwareUnconfirmedButSealed { return "encrypted \u{00B7} hardware not confirmed" }
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
                                     unpublishedButSealed: input.unpublishedButSealed,
                                     hardwareUnconfirmedButSealed: input.hardwareUnconfirmedButSealed),
            everydayClaims: settled(everydayClaims(input), halted: chainHalted(input)),
            chainHalted: chainHalted(input)
        )
    }

    private static func settled(_ claims: [TrustClaim], halted: Bool) -> [TrustClaim] {
        var out = claims
        for (i, status) in settleChain(claims.map(\.status), halted: halted).enumerated() { out[i].status = status }
        return out
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
        // A reviewed leak outranks a provenance gap: "your words are copied"
        // is the stronger claim, and an unpublished image must not hide it.
        if input.unpublishedButSealed, input.auditState != .leaks {
            return "encrypted to \(label) — one image unpublished"
        }
        // The enclave-key tail only over a reviewed build whose code was checked (trust-leaks-wording).
        guard input.auditState == .reviewed, input.provenanceState != .unchecked else { return "encrypted to \(label)" }
        // The possessive goes on the model, never the quant ("GLM-5.1 · AWQ's enclave key").
        return "encrypted to \(input.modelName)'s enclave key" + (input.quant.map { " · \($0)" } ?? "")
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
        if input.auditState == .leaks {
            return input.leaksExposure.map { "\(AuditedSealText.leaksLead) \($0)" } ?? AuditedSealText.notReviewed
        }
        if input.provenanceState == .unchecked { return ProvenanceUncheckedText.header }
        if input.unpublishedButSealed {
            return "your message is still sealed to \(input.modelName)'s hardware key. one running image has no published attestation — see the ladder."
        }
        guard input.auditState == .reviewed else { return AuditedSealText.notReviewed }
        return "sealed to \(input.modelName)'s enclave key. near.ai's key service decides which secure enclaves hold it."
    }

    private static func everydayClaims(_ input: Input) -> [TrustClaim] {
        let verifying = input.attestationState == .verifying
        var nodes: [TrustClaim] = []

        nodes.append(TrustClaim(id: "msg", status: .origin,
            title: "your message", detail: "readable only here"))

        switch input.e2eeKeyBound {
        case .some(true):
            nodes.append(TrustClaim(id: "sealed",
                status: sealedStatus(hardwareChecksPending: input.hardwareChecksPending, listed: input.listedEnclaves),
                title: "sealed to \(input.modelName)'s enclave key",
                detail: KeyCustodyCopy.sealedDetail(device: input.deviceBoundary, model: input.modelName, listed: input.listedEnclaves)))
        case .some(false):
            nodes.append(TrustClaim(id: "sealed", status: .fail,
                title: "couldn't seal this chat",
                detail: "\(input.deviceSubject) couldn't confirm \(input.modelName) holds the key — so nothing has been sent."))
        case .none:
            nodes.append(TrustClaim(id: "sealed", status: .pending,
                title: "sealing this chat to \(input.modelName)",
                detail: KeyCustodyCopy.sealingPending(model: input.modelName)))
        }

        switch input.provenanceState {
        case .some(.stuck):
            nodes.append(TrustClaim(id: "identity", status: .fail,
                title: "couldn't confirm it's the published \(input.modelName)",
                detail: input.provenanceDetail))
        case .some(.unchecked):
            nodes.append(TrustClaim(id: "identity", status: .alert, title: ProvenanceUncheckedText.step, detail: ""))
        case .some(.done):
            nodes.append(TrustClaim(id: "identity", status: .ok,
                title: "it's the real, published \(input.modelName)",
                detail: "it's the pinned, published build — checked, so a swap would show up as a mismatch."))
        case .some, .none:
            nodes.append(TrustClaim(id: "identity", status: .pending,
                title: "checking it's the real, published \(input.modelName)",
                detail: "the model checks out — one code check is still finishing."))
        }

        if let audit = auditClaim(input.auditState, leaksExposure: input.leaksExposure) {
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
                    detail: KeyCustodyCopy.replySignatureFailed(model: input.modelName)))
            case .some(.done):
                nodes.append(TrustClaim(id: "signed", status: .ok,
                    title: "every reply comes back signed by \(input.modelName)",
                    detail: KeyCustodyCopy.replySigned(model: input.modelName)))
            case .some(.live), .some(.pending), .some(.unchecked), .none:
                nodes.append(TrustClaim(id: "signed", status: verifying ? .pending : .ok,
                    title: verifying ? "checking each reply's signature" : "every reply comes back signed by \(input.modelName)",
                    detail: verifying ? "still confirming — not yet green."
                                      : KeyCustodyCopy.replySigned(model: input.modelName)))
            }
        }

        return nodes
    }

    private static func auditClaim(_ state: EverydayAuditState?, leaksExposure: String?) -> TrustClaim? {
        guard let state else { return nil }
        switch state {
        case .leaks:
            // The reviewer's own sentence; with none recorded, the not-reviewed words (trust-leaks-wording).
            return TrustClaim(id: "audit", status: .alert,
                title: leaksExposure ?? "not everything here has been reviewed yet",
                detail: "The seal still protects your message on the way in; this is about what happens after it's unlocked.",
                jumpTitle: "see the proof", jumpTarget: "known code", jumpAtEveryday: true)
        case .reviewed:
            return TrustClaim(id: "audit", status: .ok,
                title: "the code that can read your message was reviewed",
                detail: "teemoon read the software that handles your unlocked message — in this exact setup, none of it is set to copy your words anywhere else.",
                jumpTitle: "see the proof", jumpTarget: "known code", jumpAtEveryday: true)
        case .reviewedWithCaveat:
            return TrustClaim(id: "audit", status: .info,
                title: "the code that can read your message was reviewed, with a catch",
                detail: "teemoon's AI-assisted review found nothing set to copy your words in this exact setup, but someone with near.ai's operator access could change that.",
                jumpTitle: "see the proof", jumpTarget: "known code", jumpAtEveryday: true)
        case .incomplete:
            return TrustClaim(id: "audit", status: .info,
                title: "not everything here has been reviewed yet",
                detail: "some of the software that can see your unlocked message hasn't been reviewed — a gap in the checking, not an all-clear.")
        }
    }
}
