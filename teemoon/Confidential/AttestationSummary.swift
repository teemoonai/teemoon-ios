//
//  AttestationSummary.swift
//  teemoon
//
//  Plain value type that interprets an AttestationRecord plus session state
//  into the pass/fail checks, labels, and detail strings shown by the
//  attestation sheet. Pure logic — no SwiftUI, no app state objects — so it's testable.
//

import Foundation

/// Resolution state of a single verification step.
enum StepState: Equatable {
    /// `unchecked`: the check couldn't run (Intel unreachable): orange, never the red ✕ (trust-unchecked-glyph).
    case done, live, pending, stuck, unchecked
}

/// Roll-up state of one attestation pillar.
enum PillarState: Equatable {
    case verified    // every relevant check passed
    case attention   // a check failed (degrades the badge)
    case checking    // still verifying
}

/// One technical check inside a pillar's expanded detail.
struct PillarCheck: Identifiable, Equatable {
    let label: String
    let state: StepState
    let detail: String
    var id: String { label }
}

/// A user-facing pillar: a plain-language claim, its status, and the exact
/// technical checks that back it. The attestation sheet groups every check
/// under one of three of these (genuine hardware / published code / private
/// to you) so the meaning leads and the jargon is one tap down.
struct AttestationPillar: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let state: PillarState
    let summaryLine: String
    let chipLabel: String
    let checks: [PillarCheck]
}

/// Pass/fail interpretation of attestation data for the attestation sheet.
///
/// Construct one per render from the current attestation record and the
/// session state values the checks read (passed in as plain values —
/// never referencing `ConfidentialSession` directly).
struct AttestationSummary {
    /// The attestation record to interpret (nil when none has been fetched).
    let attestation: AttestationRecord?
    /// Combined security state driving header copy and progressive resolution.
    let state: AttestationState
    /// Whether the initial verification timed out (view-owned timer state).
    let timedOut: Bool
    /// The provider in use — determines whether a separate GPU node exists.
    let provider: Provider?
    /// Whether the last request actually used E2EE (nil before any request,
    /// or when no live session data is available).
    let lastRequestUsedE2EE: Bool?
    /// Brief reason when `lastRequestUsedE2EE` is false.
    let lastE2EEFailReason: String?
    /// Responses whose signatures verified this session.
    let verifiedResponseCount: Int
    /// Responses whose signatures mismatched this session.
    let mismatchedResponseCount: Int
    /// Responses accepted via gateway trust only this session — the signer was
    /// not individually attested. Deliberately not counted as verified.
    var gatewayTrustResponseCount: Int = 0
    /// Whether the most recent attestation refresh failed.
    let attestationFetchFailed: Bool
    /// Image-provenance result for the manifest (nil = pending / not checked).
    var imageProvenance: ProvenanceService.ManifestProvenance? = nil
    /// Real DCAP verification result for the record's quotes (nil = pending).
    var dcapVerification: RecordDCAPVerification? = nil
    /// NVIDIA NRAS outcome for the record's GPU evidence (nil = pending).
    var nrasVerification: NRASVerification? = nil
    /// Trust scope for each listed enclave (nil = pending or no list).
    var listedTrustScopes: [TrustScope]? = nil
    /// teemoon's separate TLS probe of the model node's direct host, not the chat's gateway connection (nil = pending).
    var tlsAttestation: TLSAttestation? = nil
    /// Verdict of the model-layer (inner) compose hash check (nil = pending /
    /// not attempted). `.hashMismatch` is an adversarial integrity break;
    /// `.fetchFailed` is transient/advisory.
    var modelLayerVerification: ModelLayerVerification? = nil
    /// Whether a `.degraded` state is a HARD adversarial integrity break (→ red)
    /// rather than a transient/operational degrade (→ orange advisory). Supplied
    /// by the session; defaults false so previews/tests read as advisory.
    var degradeIsHardFailure: Bool = false
    /// Whether the SEND PATH is still sealed while the session is degraded —
    /// the model key is 32 bytes and bound to a verified model TEE, with no
    /// GPU/TLS check in an unverified state (`ConfidentialSession
    /// .e2eeBindingIntact`, the same signal `e2eeDegradedReason` reads through
    /// `unpublishedOnlyButE2EEIntact`).
    ///
    /// Not every degrade is an encryption failure. An unpublished image (a
    /// clean GitHub 404) and an incomplete provenance trace both degrade the
    /// verdict while the bytes on the wire stay end-to-end encrypted — telling
    /// that user "E2EE is unavailable" is false, and false in the direction
    /// that makes them stop using the encryption they still have. Defaults
    /// false so a caller that does not supply it gets the cautious reading
    /// rather than an unearned claim.
    var e2eeIntact: Bool = false
    /// `ConfidentialSession.provenanceInconclusive`: the code check settled without an answer.
    var provenanceInconclusive: Bool = false
    /// `ConfidentialSession.deadlinePassed`: a listed check still missing then reads "couldn't finish", never "checking".
    var deadlinePassed: Bool = false
    /// `ModelNodeAudit`: "only you … can read" is said only over a reviewed build (trust-leaks-wording).
    var auditState: EverydayAuditState? = nil
    var leaksExposure: String? = nil

    // MARK: Header content

    /// Severity of the hero verdict, for tinting and glyph choice.
    enum HeaderSeverity: Equatable {
        case ok, advisory, failed, neutral
    }

    /// The hero verdict is never greener than the worst check below it
    /// (design review: a flagged gateway under a green "end-to-end encrypted"
    /// shield is exactly the moment a security-conscious user loses trust).
    /// A flagged run demotes an otherwise-ok verdict to advisory; a failed
    /// check demotes it to failed.
    var headerSeverity: HeaderSeverity {
        if state == .verifying && timedOut { return .advisory }
        switch state {
        case .none:      return .neutral
        case .verifying: return .neutral
        // A degrade is orange (advisory) only when it's operational/transient.
        // A HARD adversarial break — tamper, replay, MITM, an unbound key — is
        // red: it must never render as the same benign advisory as an
        // out-of-date TCB note.
        case .degraded:  return degradeIsHardFailure ? .failed : .advisory
        case .ok:
            switch runResult {
            case .failed:  return .failed
            case .flagged: return .advisory
            default:       return .ok
            }
        }
    }

    var headerTitle: String {
        if state == .verifying && timedOut { return "can\u{2019}t reach verifier" }
        switch state {
        case .ok:
            switch runResult {
            case .failed:  return "verification failed"
            case .flagged: return "verified \u{2014} with a warning"
            default:       return "end-to-end encrypted"
            }
        case .degraded:
            if degradeIsHardFailure { return "verification failed" }
            // NOTHING WAS VERIFIED. `attestationState` degrades on
            // `attestation == nil && attestationFetchFailed` — the report never
            // arrived — and `degradeIsHardFailure` returns false there because it
            // needs a record to find a hard break in. That combination used to
            // land on "verified hardware": the one claim this screen exists to
            // make, in the one state with no evidence behind it.
            if attestation == nil { return "verification unavailable" }
            return "verified hardware"
        case .verifying: return "verifying\u{2026}"
        case .none:      return "connection info"
        }
    }

    var headerSubtitle: String {
        // Only with a key in hand is anything encrypted yet (trust-pending-state, the maintainer 2026-11-06).
        if state == .verifying && timedOut, attestation?.modelEd25519PubKey != nil {
            return "messages are encrypted, but the destination can\u{2019}t be confirmed yet."
        }
        switch state {
        case .ok:
            switch runResult {
            case .failed:  return "we couldn\u{2019}t confirm this conversation is sealed. treat it as unencrypted until it re-verifies."
            case .flagged: return "your session is sealed, but one check couldn\u{2019}t be completed. read it before you trust this chat."
            default:
                if auditState == .leaks, let leaksExposure { return "\(AuditedSealText.leaksLead) \(leaksExposure)" }
                if provenanceState == .unchecked { return ProvenanceUncheckedText.header }
                guard auditState == .reviewed else { return AuditedSealText.notReviewed }
                return "sealed to the attested enclave key. near.ai's key service decides which enclaves hold it."
            }
        case .degraded:
            if degradeIsHardFailure {
                return "a security check failed — treat this chat as unverified until it re-verifies."
            }
            if attestation == nil {
                return "we couldn’t reach the attestation service, so none of this connection has been checked yet."
            }
            // Sealed, but not fully verified: an unpublished image, or a
            // provenance trace that came back incomplete. Name the check that
            // failed instead of retracting a guarantee that still holds.
            if e2eeIntact {
                return "your messages are still sealed to attested hardware, but one check couldn’t be completed."
            }
            return "tamper-proof hardware verified, but E2EE is unavailable."
        case .verifying: return "confirming this conversation runs inside sealed hardware."
        case .none:      return "this provider does not support hardware attestation."
        }
    }

    /// SF Symbol name for the hero header icon. One shield metaphor whose
    /// state resolves (glyph changes with severity, not just hue).
    var headerIcon: String {
        if state == .verifying && timedOut { return "exclamationmark.triangle.fill" }
        switch state {
        case .ok:
            // one shield family whose glyph resolves with severity — the
            // prototype's verified hero is a checkmark shield, not a lock
            // (a lock here just duplicated the E2EE lock metaphor)
            switch runResult {
            case .failed:  return "xmark.shield.fill"
            case .flagged: return "exclamationmark.shield.fill"
            default:       return "checkmark.shield.fill"
            }
        case .degraded:
            if degradeIsHardFailure { return "xmark.shield.fill" }
            // No record — the same situation as the timed-out hero above: the
            // verifier is unreachable. A lock glyph would picture a guarantee
            // that was never established.
            if attestation == nil { return "exclamationmark.triangle.fill" }
            return "lock.trianglebadge.exclamationmark.fill"
        case .verifying: return "lock.fill"
        case .none:      return "globe"
        }
    }

    // MARK: Verification state

    /// E2EE: true only if encryption is active AND the key is bound to an attested model TEE.
    /// The model_attestations response includes the model TEE's own TDX quote with the
    /// Ed25519 key in report_data — this proves the key belongs to genuine TEE hardware.
    var e2eePassed: Bool? {
        // Hide row entirely for non-attestation providers.
        guard state != .none else { return nil }
        // No Ed25519 key means E2EE is unavailable → show as failed.
        guard attestation?.modelEd25519PubKey != nil else {
            return state == .verifying ? nil : false
        }
        // After a request: reflect actual E2EE result.
        if let actual = lastRequestUsedE2EE {
            if !actual { return false }
        }
        // Model TEE attestation is the primary check — Ed25519 key bound to a verified TDX quote.
        if let mqv = attestation?.modelQuoteVerification {
            if !mqv.isVerified { return false }
            if attestation?.e2eeKeyBoundToModelTEE == false { return false }
            return true
        }
        // No model attestation available — E2EE key is unverified.
        return false
    }

    var e2eeFailDetail: String {
        if attestation?.modelEd25519PubKey == nil {
            return "Ed25519 encryption key unavailable"
        }
        if let used = lastRequestUsedE2EE, !used {
            if let reason = lastE2EEFailReason {
                return reason
            }
            return "Encryption failed on last request"
        }
        if let mqv = attestation?.modelQuoteVerification {
            if !mqv.signatureValid { return "Model TDX signature verification failed" }
            if !mqv.certChainValid { return mqv.certChainError ?? "Model cert chain invalid" }
            if attestation?.e2eeKeyBoundToModelTEE == false {
                return "Ed25519 key not found in model TDX report_data"
            }
        }
        if attestation?.modelQuoteVerification == nil {
            return "Model TEE attestation unavailable"
        }
        return "Encryption target is unverified"
    }

    /// Gateway TDX quote ECDSA signature.
    var gwTdxSignatureValid: Bool? {
        attestation?.quoteVerification?.signatureValid
    }

    /// Gateway TDX quote Intel certificate chain.
    var gwCertChainValid: Bool? {
        attestation?.quoteVerification?.certChainValid
    }

    /// Gateway signing key is embedded in TDX report_data (binds key to hardware).
    var keyBoundToHardware: Bool? {
        attestation?.signingKeyBoundToHardware
    }

    /// Model TEE TDX quote verified + Ed25519 key bound to it.
    var modelTdxValid: Bool? {
        attestation?.modelQuoteVerification?.isVerified
    }

    /// E2EE key cryptographically bound to the model TEE's TDX quote report_data.
    var e2eeKeyBound: Bool? {
        attestation?.e2eeKeyBoundToModelTEE
    }

    /// The key matches report_data but the quote's signature or chain failed (T6): not bound, and said so.
    var keyInUnverifiedQuote: Bool {
        attestation?.e2eeKeyInModelReportData == true && attestation?.modelQuoteVerification?.isVerified == false
    }

    /// The enclaves near.ai lists for the model, as the key-custody lines word them (A7).
    var listedEnclaves: KeyCustodyCopy.Listed { KeyCustodyCopy.listed(record: attestation, dcap: dcapVerification, gpu: nrasVerification,
                                                                       scopes: listedTrustScopes, deadlinePassed: deadlinePassed) }

    /// DCAP or NVIDIA hasn't answered: the seal can't be claimed yet, however the key binding reads (Q4).
    var hardwareChecksPending: Bool {
        [dcapState, nrasState].contains { $0 == .live || $0 == .pending }
    }

    /// Whether the provider routes through a separate GPU node.
    var hasGPUNode: Bool {
        guard let p = provider else { return false }
        guard let inference = p.inferenceBaseURL else { return false }
        return inference != p.openAIBaseURL
    }

    /// Whether the GPU row should be shown at all.
    var showGPURow: Bool {
        // Show when we have GPU info from the gateway (gpuArch) or a GPU node exists.
        guard attestation != nil else { return false }
        return hasGPUNode || attestation?.gpuArch != nil
    }

    /// The expert card's GPU row is NVIDIA's result in every state; never the GPU node's Intel TDX line.
    /// A listed enclave's rejection or couldn't-check keeps NVIDIA's own reason here, and only here.
    var gpuRowDetail: String {
        if case .listedFailed(let nvidia)? = nrasVerification { return "\(nrasDetail) \(nvidia)" }
        if case .listedInconclusive(let nvidia)? = nrasVerification {
            return "\(nrasDetail) \(nvidia == NRASVerification.evidenceAbsent ? Self.noNVIDIAEvidence : nvidia)"
        }
        return nrasDetail
    }

    /// Response ECDSA signature — true if all verified, false if any mismatch, nil if no data yet.
    /// Gateway-trust-only responses surface the row (data exists) but never turn it green
    /// on their own: with zero individually verified responses the check stays indeterminate
    /// rather than claiming per-response verification that didn't happen.
    var responseSigValid: Bool? {
        switch responseSigState {
        case .done: true
        case .stuck: false
        default: nil
        }
    }

    /// Row state for the response-signatures row: nil = no data yet (row hidden),
    /// `.done` = all individually verified, `.stuck` = at least one mismatch,
    /// `.pending` = only gateway-trust responses so far (indeterminate, not green).
    var responseSigState: StepState? {
        guard verifiedResponseCount > 0 || mismatchedResponseCount > 0 || gatewayTrustResponseCount > 0 else { return nil }
        if mismatchedResponseCount > 0 { return .stuck }
        return verifiedResponseCount > 0 ? .done : .pending
    }

    /// Whether the enclave booted the manifest we're showing (the "running code"
    /// binding). nil when inputs are absent. See `AttestationRecord.codeIdentityVerified`.
    var codeIdentityValid: Bool? {
        attestation?.codeIdentityVerified
    }

    /// Detail line for the code-identity row.
    var codeIdentityDetail: String {
        switch codeIdentityValid {
        case true:  return "Enclave booted exactly this manifest"
        case false: return "Manifest does not match the booted measurement"
        default:    return "Manifest not available to verify"
        }
    }

    /// Image-provenance row state: nil = hidden (no manifest to check),
    /// `.done` = every image traces to a pinned near.ai workflow, `.stuck` =
    /// at least one image unverified, `.live` = still checking.
    var provenanceState: StepState? {
        guard codeIdentityValid != nil else { return nil }  // only meaningful with a manifest
        switch imageProvenance {
        case .allVerified: return .done
        case .incomplete:  return .stuck
        case nil where provenanceInconclusive: return .unchecked
        case nil:          return state == .verifying ? .live : .pending
        }
    }

    var provenanceDetail: String {
        switch imageProvenance {
        case .allVerified(let refs, let thirdParty):
            let sidecars = thirdParty.isEmpty ? "" : " · \(Self.counted(thirdParty.count, "third-party sidecar")) pinned by manifest"
            return "\(Self.counted(refs.count, "near.ai image")) signed by its published workflow\(sidecars)"
        case .incomplete(let verified, let failures, _):
            let total = verified.count + failures.count
            return "\(failures.count) of \(Self.counted(total, "near.ai image")) unverified — \(Self.namedFailures(failures))"
        case nil:
            return "Checking image provenance…"
        }
    }

    /// "1 image" / "2 images" — never "(s)".
    static func counted(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }

    /// Names the failing images and why, bounded so the line stays readable:
    /// e.g. "`glm51-sgl-awq-tp4-patched` (no published attestation (GitHub
    /// 404)); `mesh` (couldn't reach GitHub …) · +1 more".
    static func namedFailures(_ failures: [ProvenanceService.Failure], limit: Int = 2) -> String {
        let shown = failures.prefix(limit).map { f -> String in
            let name = f.ref.image.split(separator: "/").last.map(String.init) ?? f.ref.image
            let why = f.reason.failureReason ?? "unverified"
            return "\(name) (\(why))"
        }
        let more = failures.count > limit ? " · +\(failures.count - limit) more" : ""
        return shown.joined(separator: "; ") + more
    }

    /// Nonce-echo (anti-replay) check: every fetched quote must echo the
    /// nonce teemoon sent in report_data[32..64]. nil = not checkable.
    var nonceEchoed: Bool? {
        attestation?.nonceEchoed
    }

    var nonceDetail: String {
        switch nonceEchoed {
        case true:  return "Quote was generated for this request, not replayed"
        case false: return "Quote does not echo the request nonce — possible replay"
        default:    return "Nonce not available to verify"
        }
    }

    /// Intel DCAP row state: nil = hidden (no quote to verify), `.done` =
    /// every present quote verified via dcap-qvl (QE binding + TCB), `.stuck`
    /// = a hard failure (unverified quote, no collateral, or revoked TCB),
    /// `.live`/`.pending` = still checking.
    var dcapState: StepState? {
        guard let attestation, !attestation.intelQuote.isEmpty else { return nil }
        switch dcapVerification {
        case .some(let v) where v.hasHardFailure: return .stuck
        case .some(let v) where v.allPresentVerified: return .done
        case .some(let v) where v.hasUnchecked: return .unchecked
        case .some: return .stuck
        case nil: return state == .verifying ? .live : .pending
        }
    }

    var dcapDetail: String {
        guard let dcap = dcapVerification else { return "Checking quote with Intel PCS…" }
        if dcap.hasHardFailure {
            return dcap.failureReason ?? "Quote failed DCAP verification (or collateral unavailable)"
        }
        if dcap.hasUnchecked { return "intel's hardware check couldn't be completed (service unreachable)." }
        switch dcap.worstTcbStatus {
        case .upToDate:
            return "QE binding + TCB verified, up to date"
        case .outOfDate:
            return "Genuine hardware — TCB behind on Intel platform updates"
        case .configurationNeeded:
            return "Genuine hardware — platform configuration update needed"
        default:
            return "Quote verified via dcap-qvl"
        }
    }

    /// NVIDIA NRAS row state: nil = hidden (no GPU evidence in the record),
    /// `.done` = NVIDIA verdict PASS + evidence nonce matched, `.stuck` =
    /// failed (bad verdict, nonce mismatch, or NRAS unreachable — fail-closed),
    /// `.live`/`.pending` = still checking.
    var nrasState: StepState? {
        // A verdict with no payload is the missing-evidence couldn't-check: the row must show it.
        guard attestation?.nvidiaPayload != nil || nrasVerification != nil else { return nil }
        switch nrasVerification {
        case .verified: return .done
        // An unreachable NVIDIA couldn't check (orange); only a rejection is red (near-send-gate-rule).
        case .failed, .listedFailed: return .stuck
        case .inconclusive, .listedInconclusive: return .unchecked
        case nil: return state == .verifying ? .live : .pending
        }
    }

    /// The TLS card describes teemoon's separate probe of the model node; never say the chat's connection is pinned.
    static let transportTitle = "model node's tls key"
    static let transportSubtitle = "teemoon's own probe, separate from your chat. your messages go through near.ai's gateway over ordinary tls, sealed end-to-end to the model's key."
    static let transportLabel = "model node's certificate"

    /// The probe row: an unreachable probe couldn't check (orange); a mismatch is red.
    var tlsRow: (state: StepState, detail: String)? {
        switch tlsAttestation {
        case .verified?:
            return (.done, "teemoon's probe of the model node's host saw a certificate whose key is bound into that node's attestation (`report_data`). your chat doesn't use this connection: it goes through near.ai's gateway, which isn't pinned.")
        case .failed(let why)?: return (.stuck, "probe of the model node: \(why)")
        case .inconclusive(let why)?:
            return (.unchecked, why == NRASVerification.teemoonFault ? why : "probe of the model node: \(why) — could not complete")
        case .notPerformed?, nil: return nil
        }
    }

    /// The GPU row for a model node that sent no `nvidia_payload`; the banner keeps `NRASVerification.evidenceAbsent`.
    static let noNVIDIAEvidence = "no nvidia evidence in this attestation"

    var nrasDetail: String {
        switch nrasVerification {
        case .verified: return "NVIDIA confirmed genuine attested GPUs for this request"
        case .inconclusive(NRASVerification.evidenceAbsent): return Self.noNVIDIAEvidence
        case .failed(let reason), .inconclusive(let reason): return reason
        case .listedInconclusive: return KeyCustodyCopy.listedSentence(.unfinished)
        case .listedFailed: return ListedEnclaveReason.enclaveFailed
        case nil: return "Checking GPU evidence with NVIDIA…"
        }
    }

    /// Detail line for the response-signatures row, covering the gateway-trust case.
    var responseSigDetail: String {
        if mismatchedResponseCount > 0 {
            let total = verifiedResponseCount + mismatchedResponseCount + gatewayTrustResponseCount
            return "\(mismatchedResponseCount) mismatch of \(total)"
        }
        var parts: [String] = []
        if verifiedResponseCount > 0 { parts.append("\(verifiedResponseCount) verified this session") }
        if gatewayTrustResponseCount > 0 { parts.append("\(gatewayTrustResponseCount) via gateway trust (not individually verified)") }
        return parts.isEmpty ? "no signed responses yet" : parts.joined(separator: " · ")
    }

    var allChecks: [Bool?] {
        var checks: [Bool?] = []
        if let e2ee = e2eePassed { checks.append(e2ee) }
        if let sig = gwTdxSignatureValid { checks.append(sig) }
        if let cert = gwCertChainValid { checks.append(cert) }
        if let key = keyBoundToHardware { checks.append(key) }
        if let model = modelTdxValid { checks.append(model) }
        if let bound = e2eeKeyBound { checks.append(bound) }
        if let code = codeIdentityValid { checks.append(code) }
        // Provenance counts only once a definitive result exists (pending → excluded).
        switch imageProvenance {
        case .allVerified: checks.append(true)
        case .incomplete:  checks.append(false)
        case nil:          break
        }
        // DCAP counts only once a definitive result exists (pending → excluded).
        if let dcap = dcapVerification {
            checks.append(!dcap.hasHardFailure && dcap.allPresentVerified)
        }
        if let nonce = nonceEchoed { checks.append(nonce) }
        // NRAS counts only once a definitive result exists (pending → excluded).
        if let nras = nrasVerification { checks.append(nras.isVerified) }
        // GPU row is supplementary — excluded from the pass/fail banner.
        // It provides additional assurance but the model TEE via gateway
        // already proves the E2EE key belongs to genuine TEE hardware.
        if let resp = responseSigValid { checks.append(resp) }
        return checks
    }

    var checksTotal: Int { allChecks.count }
    var checksPassed: Int { allChecks.compactMap { $0 }.filter { $0 }.count }
    var allChecksPassed: Bool { checksPassed == checksTotal }

    var timestampText: String {
        guard let attestation else { return "No attestation data" }
        let elapsed = Date().timeIntervalSince(attestation.fetchedAt)
        let staleNote = attestationFetchFailed ? " (refresh failed)" : ""
        if elapsed < 60 {
            return "verified just now\(staleNote)"
        } else if elapsed < 3600 {
            let mins = Int(elapsed / 60)
            return "verified \(mins) min\(mins == 1 ? "" : "s") ago\(staleNote)"
        } else {
            return "verified \(attestation.fetchedAt.formatted(date: .omitted, time: .shortened))\(staleNote)"
        }
    }

    /// Maps a check result to a step state during progressive verification.
    /// `isLiveGroup` = this group of checks is the current frontier.
    /// `isFirst` = this is the first row in the group (gets the spinner).
    func resolveState(_ result: Bool?, ready: Bool, isLiveGroup: Bool = false, isFirst: Bool = false) -> StepState {
        if state == .verifying && !ready {
            if timedOut { return .stuck }
            return isLiveGroup && isFirst ? .live : .pending
        }
        guard let result else { return .pending }
        return result ? .done : .stuck
    }

    // MARK: - Pillars (grouped, meaning-first view)

    /// The three pillars, in trust order. Empty-check pillars are dropped by
    /// the sheet. Each pillar's state is derived from its checks: any failed
    /// check ⇒ `.attention`; otherwise `.checking` while still verifying, else
    /// `.verified`.
    var pillars: [AttestationPillar] {
        [hardwarePillar, codePillar, privacyPillar].filter { !$0.checks.isEmpty }
    }

    private func pillarState(_ checks: [PillarCheck]) -> PillarState {
        if checks.contains(where: { $0.state == .stuck }) { return .attention }
        if state == .verifying || checks.contains(where: { $0.state == .pending || $0.state == .live }) { return .checking }
        return .verified
    }

    /// Maps a `Bool?` check value to a row. `nil` → a pending row only while
    /// verifying (and only when `showWhilePending`), otherwise the row is
    /// omitted so post-verification pillars don't carry blank rows.
    private func row(_ label: String, _ value: Bool?, detail: String, showWhilePending: Bool = true) -> PillarCheck? {
        switch value {
        case .some(true):  return PillarCheck(label: label, state: .done, detail: detail)
        case .some(false): return PillarCheck(label: label, state: .stuck, detail: detail)
        case .none:
            guard state == .verifying, showWhilePending else { return nil }
            return PillarCheck(label: label, state: .pending, detail: detail)
        }
    }

    /// Maps an already-resolved optional `StepState` (nil = hidden) to a row.
    private func row(_ label: String, _ stepState: StepState?, detail: String) -> PillarCheck? {
        stepState.map { PillarCheck(label: label, state: $0, detail: detail) }
    }

    private var hardwarePillar: AttestationPillar {
        let checks = [
            row("Intel DCAP verification", dcapState, detail: dcapDetail),
            row("TDX quote signature", gwTdxSignatureValid,
                detail: gwTdxSignatureValid == false ? "ECDSA signature verification failed"
                    : "Signed by TEE hardware, not fabricated"),
            row("Intel certificate chain", gwCertChainValid,
                detail: gwCertChainValid == false ? (attestation?.quoteVerification?.certChainError ?? "Chain invalid")
                    : "Chains to Intel’s SGX Root CA"),
            row("Attestation freshness", nonceEchoed, detail: nonceDetail),
            row("NVIDIA GPU attestation", nrasState, detail: nrasDetail),
        ].compactMap { $0 }
        let st = pillarState(checks)
        let line: String
        switch st {
        case .verified:
            line = hasNVIDIA
                ? "Genuine Intel TDX + \(gpuName) secure hardware, confirmed by Intel and NVIDIA."
                : "Genuine Intel TDX secure hardware, confirmed against Intel."
        case .attention: line = "The hardware quote could not be fully verified."
        case .checking:  line = "Confirming this is genuine Intel TDX hardware…"
        }
        return AttestationPillar(id: "hardware", title: "genuine hardware", systemImage: "cpu.fill",
                                 state: st, summaryLine: line, chipLabel: chip(st), checks: checks)
    }

    private var codePillar: AttestationPillar {
        let checks = [
            row("Running code matches manifest", codeIdentityValid, detail: codeIdentityDetail),
            row("Images built from near.ai source", provenanceState, detail: provenanceDetail),
        ].compactMap { $0 }
        let st = pillarState(checks)
        let line: String
        switch st {
        // Placeholder words (review page: trust-code-claim). Must not claim the running manager: the phone checks the
        // compose's default image, not the digest compose-manager logged starting (1.2).
        case .verified:  line = "Every image the measured launch config names traces to near.ai’s published source."
        case .attention: line = "Some running code could not be traced to near.ai’s published source."
        case .checking:  line = "Tracing the running images to near.ai’s published source…"
        }
        return AttestationPillar(id: "code", title: "published code", systemImage: "chevron.left.forwardslash.chevron.right",
                                 state: st, summaryLine: line, chipLabel: chip(st), checks: checks)
    }

    private var privacyPillar: AttestationPillar {
        let checks = [
            row("End-to-end encryption", e2eePassed,
                detail: e2eePassed == false ? e2eeFailDetail : "Encrypted to the model enclave’s key on this device"),
            row("Model TEE verified", modelTdxValid,
                detail: modelTdxValid == false ? "Model TDX signature verification failed"
                    : "The model runs inside its own attested enclave"),
            row("Encryption key bound to TEE", e2eeKeyBound,
                detail: e2eeKeyBound == false ? "Ed25519 key not in model TDX report_data"
                    : "The key is in that enclave's hardware quote"),
            row("Signing key bound to hardware", keyBoundToHardware,
                detail: keyBoundToHardware == false ? "Address not in TDX report_data"
                    : "The response-signing key is in that enclave's hardware quote"),
            row("Response signatures", responseSigState, detail: responseSigDetail),
        ].compactMap { $0 }
        let st = pillarState(checks)
        let line: String
        switch st {
        case .verified:  line = "Messages are end-to-end encrypted to this enclave's key. near.ai's key service can give that key to other enclaves; teemoon checks the ones near.ai lists."
        case .attention: line = privacyAttentionLine
        case .checking:  line = "Establishing the encrypted channel to the model enclave…"
        }
        return AttestationPillar(id: "private", title: "private to you", systemImage: "lock.fill",
                                 state: st, summaryLine: line, chipLabel: chip(st, verified: "encrypted"), checks: checks)
    }

    private func chip(_ st: PillarState, verified: String = "verified") -> String {
        switch st {
        case .verified:  return verified
        case .attention: return "needs attention"
        case .checking:  return "checking"
        }
    }

    /// Human GPU name for the hardware line (from arch), defaulting generically.
    private var gpuName: String { attestation?.gpuModelName ?? "NVIDIA GPU" }
    private var hasNVIDIA: Bool { attestation?.gpuArch != nil || attestation?.nvidiaPayload != nil }

    /// Plain-language reason the privacy pillar is degraded, reusing the
    /// existing E2EE fail detail where it's meaningful.
    private var privacyAttentionLine: String {
        if attestation?.modelEd25519PubKey == nil {
            return "Encryption to the model is unavailable right now — messages go to near.ai's gateway over ordinary TLS, not sealed to the model."
        }
        if lastRequestUsedE2EE == false, let reason = lastE2EEFailReason { return reason }
        return "The model’s encryption could not be fully verified."
    }

    // MARK: - Advanced evidence (raw technical detail for the advanced section)

    /// dcap-qvl verdict, e.g. "verified · TCB up to date". nil if not run.
    var dcapEvidence: String? {
        guard let dcap = dcapVerification else { return nil }
        if dcap.hasHardFailure { return dcap.failureReason ?? "failed verification" }
        switch dcap.worstTcbStatus {
        case .upToDate:            return "verified · TCB up to date"
        case .outOfDate:           return "verified · TCB out of date (genuine hardware, behind on patches)"
        case .configurationNeeded: return "verified · platform configuration update needed"
        case .revoked:             return "revoked by Intel"
        case .other, .none:        return "verified"
        }
    }

    /// Anti-replay evidence — whether the quote echoed our request nonce.
    var nonceEvidence: String? {
        guard let echoed = nonceEchoed else { return nil }
        return echoed ? "echoed in report_data[32:64] — generated for this request"
                      : "mismatch — possible replay"
    }

    /// NVIDIA NRAS GPU attestation verdict.
    var nrasEvidence: String? {
        switch nrasVerification {
        case .verified:              return "NVIDIA verdict PASS · evidence nonce matched"
        case .failed(let why):       return "failed — \(why)"
        case .listedFailed:          return "failed — \(ListedEnclaveReason.enclaveFailed)"
        case .inconclusive(let why): return "couldn't complete — \(why)"
        case .listedInconclusive:    return "couldn't complete — \(KeyCustodyCopy.listedSentence(.unfinished))"
        case nil:                    return nil
        }
    }

    /// Image-provenance evidence — the specific source repos the images'
    /// Sigstore certificates name, falling back to the org when unknown.
    var provenanceEvidence: String? {
        switch imageProvenance {
        case .allVerified(let verified, let thirdParty):
            let sidecars = thirdParty.isEmpty ? "" : " · \(Self.counted(thirdParty.count, "third-party sidecar")) pinned"
            let repos = Set(verified.compactMap(\.sourceRepo)).sorted()
                .map { $0.replacingOccurrences(of: "https://github.com/", with: "") }
            let source = repos.isEmpty ? "github.com/nearai" : repos.joined(separator: ", ")
            return "\(Self.counted(verified.count, "image")) → \(source)\(sidecars)"
        case .incomplete(let verified, let failures, _):
            return "\(failures.count) of \(verified.count + failures.count) unverified — \(Self.namedFailures(failures))"
        case nil:
            return nil
        }
    }

    /// Per-response signature verification mode this session.
    var responseSigEvidence: String? {
        guard verifiedResponseCount > 0 || mismatchedResponseCount > 0 || gatewayTrustResponseCount > 0 else { return nil }
        if mismatchedResponseCount > 0 {
            return "SHA-256 content binding + EIP-191 ecrecover — \(mismatchedResponseCount) mismatch"
        }
        if verifiedResponseCount > 0 {
            return "SHA-256 content binding + EIP-191 ecrecover · \(verifiedResponseCount) verified this session"
        }
        return "gateway trust only — signer not individually attested"
    }

    /// The actual E2EE cipher suite (matches near.ai's published v2 protocol).
    static let cipherSuiteLabel = "X25519 ECDH · HKDF-SHA256 · XChaCha20-Poly1305 (Ed25519→X25519)"

    // MARK: Share report

    /// Plain-text attestation report for the "Copy Report" share action.
    ///
    /// The session counts are passed explicitly (rather than read from the
    /// stored live counts) to preserve the sheet's original behavior of
    /// reporting the counts it was initialized with.
    func shareText(e2eeMessageCount: Int, verifiedResponseCount: Int, mismatchedResponseCount: Int, gatewayTrustResponseCount: Int = 0) -> String {
        guard let attestation else { return "near.ai TEE Attestation\nNo data available." }
        let fetched = attestation.fetchedAt.formatted(date: .abbreviated, time: .shortened)
        let verified = attestation.quoteVerification?.isVerified == true ? "VERIFIED" : "NOT VERIFIED"
        var lines = [
            "near.ai TEE Attestation (\(verified))",
            "Fetched: \(fetched)",
            "",
        ]
        if e2eeMessageCount > 0 {
            lines.append("E2EE messages this session: \(e2eeMessageCount)")
        }
        if verifiedResponseCount > 0 {
            lines.append("Signed responses this session: \(verifiedResponseCount)")
        }
        if mismatchedResponseCount > 0 {
            lines.append("Signature mismatches this session: \(mismatchedResponseCount)")
        }
        if gatewayTrustResponseCount > 0 {
            lines.append("Accepted via gateway trust (not individually verified): \(gatewayTrustResponseCount)")
        }
        if e2eeMessageCount > 0 || verifiedResponseCount > 0 || mismatchedResponseCount > 0 || gatewayTrustResponseCount > 0 {
            lines.append("")
        }
        if let v = attestation.quoteVerification {
            lines.append("Gateway TDX Signature: \(v.signatureValid ? "Valid" : "Invalid")")
            lines.append("Gateway Cert Chain: \(v.certChainValid ? "Valid" : "Invalid")")
        }
        if let v = attestation.gpuQuoteVerification {
            lines.append("GPU Node TDX Signature: \(v.signatureValid ? "Valid" : "Invalid")")
            lines.append("GPU Node Cert Chain: \(v.certChainValid ? "Valid" : "Invalid")")
        }
        if let dcap = dcapVerification {
            let verdict = dcap.hasHardFailure ? "FAILED"
                : (dcap.allPresentVerified ? "Verified" : "Incomplete")
            let tcb = dcap.worstTcbStatus.map { " (TCB: \($0.rawValue))" } ?? ""
            lines.append("Intel DCAP (dcap-qvl): \(verdict)\(tcb)")
        }
        if let code = codeIdentityValid {
            lines.append("Code identity (manifest ↔ MRCONFIGID): \(code ? "Verified" : "FAILED")")
        }
        switch imageProvenance {
        case .allVerified(let refs, let thirdParty):
            let sidecars = thirdParty.isEmpty ? "" : ", \(Self.counted(thirdParty.count, "third-party sidecar")) digest-pinned"
            lines.append("Image provenance (Sigstore/Rekor): Verified (\(Self.counted(refs.count, "near.ai image"))\(sidecars))")
        case .incomplete(let verified, let failures, _):
            lines.append("Image provenance (Sigstore/Rekor): INCOMPLETE (\(failures.count) of \(Self.counted(verified.count + failures.count, "near.ai image")) unverified)")
        case nil: break
        }
        if let nonce = nonceEchoed {
            lines.append("Attestation freshness (nonce echo): \(nonce ? "Verified" : "FAILED")")
        }
        if let nras = nrasVerification {
            lines.append("NVIDIA GPU attestation (NRAS): \(nras.isVerified ? "PASS" : "FAILED")")
        }
        if let resp = responseSigValid {
            lines.append("Response signatures (content binding + ecrecover): \(resp ? "Verified" : "MISMATCH")")
        }
        lines.append("Checks passed: \(checksPassed)/\(checksTotal) (pending checks excluded)")
        lines.append("")
        if !attestation.mrtd.isEmpty                           { lines.append("MRTD (Intel TDX):         \(attestation.mrtd)") }
        if !attestation.composeHash.isEmpty                    { lines.append("Compose hash (mr_config): \(attestation.composeHash)") }
        if let h = attestation.gpuNodeComposeHash, !h.isEmpty  { lines.append("GPU TEE compose hash:     \(h)") }
        if let h = attestation.modelFileHash, !h.isEmpty        { lines.append("Model YAML SHA256:        \(h)") }
        if let key = attestation.modelEd25519PubKey {
            lines.append("Model Ed25519 pubkey:     \(key.map { String(format: "%02x", $0) }.joined())")
        }
        if let addr = attestation.signingAddress, !addr.isEmpty {
            lines.append("Gateway signing address:  \(addr)")
        }
        if let addr = attestation.gpuSigningAddress, !addr.isEmpty {
            lines.append("GPU signing address:      \(addr)")
        }
        lines.append("")
        lines.append("Verify: https://cloud-api.near.ai/v1/attestation/report?nonce=manual&signing_algo=ecdsa")
        return lines.joined(separator: "\n")
    }
}
