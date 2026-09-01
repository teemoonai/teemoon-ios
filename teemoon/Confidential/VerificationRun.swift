//
//  VerificationRun.swift
//  teemoon
//
//  Structures the attestation data as a "verification run" that mirrors
//  near.ai's documented process (docs.near.ai/cloud/verification): one section
//  per documented verification (model / gateway / tls / chat), plus teemoon's
//  own provenance check. Each section carries a plain-language "why", the
//  technical steps with real results, a link to the exact doc page, and a
//  rolled-up result. Pure/testable — the sheet just renders it.
//

import Foundation

/// Status of one step within a verification section.
enum RunStepStatus: Equatable, Sendable {
    case pass, flag, fail, running, pending
}

/// A small named destination rendered under a step's detail.
struct RunLink: Identifiable, Equatable, Sendable {
    let title: String
    let url: String
    var id: String { title + "·" + url }
}

/// One technical step in a section (the real check + its result).
///
/// `detail` is a plain sentence that wraps; literal attested tokens inside it
/// (`UpToDate`, `mr_config`, digests) are marked with backticks and rendered
/// as monospaced chips — so the eye lands on the crypto, not all-mono prose
/// (design review: proof rows must wrap, mono only the literal values).
struct RunStep: Identifiable, Equatable, Sendable {
    let label: String
    let detail: String
    let status: RunStepStatus
    /// Primary destination: tapping the step opens this (e.g. the exact
    /// source code the attested build ran from).
    var url: String? = nil
    /// Secondary destinations backing the step's claim (e.g. the release
    /// page and the digest's public-log entry).
    var links: [RunLink] = []
    var id: String { label + "·" + detail }
}

/// Rolled-up result of a section.
///
/// Chip taxonomy (design review): one consistent register — passed /
/// advisory / failed / checking / pending — and every chip carries a glyph,
/// never color alone (colorblind safety). `failed` is defined at full
/// severity even when unused, so a hard break has somewhere to land.
enum SectionResult: Equatable, Sendable {
    case passed, flagged, failed, running, notRun

    var chipLabel: String {
        switch self {
        case .passed:  return "passed"
        case .flagged: return "advisory"
        case .failed:  return "failed"
        case .running: return "checking"
        case .notRun:  return "pending"
        }
    }

    /// SF Symbol paired with the chip label — state never rides on hue alone.
    var chipIcon: String {
        switch self {
        case .passed:  return "checkmark.circle.fill"
        case .flagged: return "exclamationmark.triangle.fill"
        case .failed:  return "xmark.octagon.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .notRun:  return "circle.dotted"
        }
    }
}

/// One documented verification, rendered as a `❯ verify …` section.
struct VerificationSection: Identifiable, Equatable, Sendable {
    let id: String            // "model" | "gateway" | "tls" | "chat" | "provenance"
    let command: String       // e.g. "verify model"
    let isExtra: Bool         // teemoon addition beyond near.ai's docs
    let why: String           // plain-language "why this matters"
    let docURL: String
    let result: SectionResult
    let steps: [RunStep]
}

extension AttestationSummary {

    /// The whole verification run, in near.ai's documented order. Sections
    /// with no data yet (e.g. gateway on a direct-only path) are dropped.
    var verificationRun: [VerificationSection] {
        [modelSection, gatewaySection, tlsSection, chatSection, provenanceSection]
            .compactMap { $0 }
    }

    private static let docBase = "https://docs.near.ai/cloud/verification"

    private func rollup(_ steps: [RunStep]) -> SectionResult {
        if steps.contains(where: { $0.status == .fail }) { return .failed }
        if steps.contains(where: { $0.status == .running }) { return .running }
        if steps.contains(where: { $0.status == .flag }) { return .flagged }
        if steps.allSatisfy({ $0.status == .pending }) { return .running }
        return .passed
    }

    /// Maps a `Bool?` to a step status (nil → pending while verifying).
    private func stepStatus(_ value: Bool?) -> RunStepStatus {
        switch value {
        case .some(true):  return .pass
        case .some(false): return .fail
        case .none:        return state == .verifying ? .pending : .pending
        }
    }

    // MARK: Sections

    private var modelSection: VerificationSection? {
        guard attestation != nil else { return nil }
        var steps: [RunStep] = []
        if let nras = nrasState {
            steps.append(RunStep(label: "GPU check", detail: nrasDetail,
                                 status: nras == .done ? .pass : nras == .stuck ? .fail : .running))
        }
        if let dcap = dcapVerification {
            let modelDcap = dcap.model ?? dcap.gateway
            switch modelDcap {
            case .verified(.upToDate, _, _): steps.append(RunStep(label: "hardware quote", detail: "dcap-qvl verifies the TDX quote → `UpToDate`", status: .pass))
            // Genuine hardware behind on Intel platform updates (outOfDate /
            // configurationNeeded) is a note, not a warning — the quote proves
            // real sealed silicon and the E2EE binding holds. Matches the green
            // expert "genuine hardware" row; only `revoked` breaks (degraded via
            // dcapVerification.hasHardFailure, a separate path).
            case .verified(let tcb, _, _):   steps.append(RunStep(label: "hardware quote", detail: "dcap-qvl → `\(tcb.rawValue)` (genuine hardware, behind on Intel platform updates)", status: .pass))
            case .failed(let why):           steps.append(RunStep(label: "hardware quote", detail: why, status: .fail))
            case .none: break
            }
        } else {
            steps.append(RunStep(label: "hardware quote", detail: "verifying with Intel dcap-qvl…", status: .pending))
        }
        if let bound = e2eeKeyBound {
            steps.append(RunStep(label: "key + freshness",
                                 detail: bound ? "`report_data` binds the encryption key + nonce" : "encryption key not bound to the quote",
                                 status: bound ? .pass : .fail))
        }
        if let code = codeIdentityValid {
            steps.append(RunStep(label: "code identity",
                                 detail: code ? "`mr_config` == `sha256(compose)`" : codeIdentityDetail,
                                 status: code ? .pass : .fail))
        }
        guard !steps.isEmpty else { return nil }
        return VerificationSection(
            id: "model", command: "verify model", isExtra: false,
            why: "proves the AI model runs inside sealed hardware — so its operator can’t swap in a version that logs your chats.",
            docURL: "\(Self.docBase)/model", result: rollup(steps), steps: steps)
    }

    private var gatewaySection: VerificationSection? {
        // Only when the request actually goes through the gateway.
        guard let att = attestation, !att.intelQuote.isEmpty, att.signingAddress != nil else { return nil }
        var steps: [RunStep] = []
        if let dcap = dcapVerification, let gw = dcap.gateway {
            switch gw {
            case .verified(.upToDate, _, _): steps.append(RunStep(label: "hardware quote", detail: "dcap-qvl → `UpToDate`", status: .pass))
            case .verified(let tcb, _, _):   steps.append(RunStep(label: "hardware quote", detail: "dcap-qvl → `\(tcb.rawValue)` (genuine, behind on patches)", status: .pass))
            case .failed(let why):           steps.append(RunStep(label: "hardware quote", detail: why, status: .fail))
            }
        } else {
            steps.append(RunStep(label: "hardware quote", detail: "verifying with Intel dcap-qvl…", status: .pending))
        }
        if let bound = keyBoundToHardware {
            steps.append(RunStep(label: "key + freshness",
                                 detail: bound ? "`report_data` binds the signing address + nonce" : "signing address not in `report_data`",
                                 status: bound ? .pass : .fail))
        }
        guard !steps.isEmpty else { return nil }
        return VerificationSection(
            id: "gateway", command: "verify gateway", isExtra: false,
            why: "proves the entry point routing your request is itself sealed hardware, not a server that could snoop before handing off.",
            docURL: "\(Self.docBase)/gateway", result: rollup(steps), steps: steps)
    }

    private var tlsSection: VerificationSection? {
        guard let tls = tlsAttestation else {
            // pending
            return VerificationSection(id: "tls", command: "verify tls attestation", isExtra: false,
                why: tlsWhy, docURL: "\(Self.docBase)/tls", result: .running,
                steps: [RunStep(label: "checking", detail: "verifying the connection terminates in the enclave…", status: .pending)])
        }
        switch tls {
        case .notPerformed:
            return nil   // no direct host — not applicable, don't clutter the run
        case .verified:
            let steps = [
                RunStep(label: "cert bound to hardware", detail: "`report_data[0:32]` == `sha256(address ‖ tls fingerprint)`", status: .pass),
                RunStep(label: "live cert matches", detail: "live `SPKI` hash == attested fingerprint", status: .pass),
            ]
            return VerificationSection(id: "tls", command: "verify tls attestation", isExtra: false,
                why: tlsWhy, docURL: "\(Self.docBase)/tls", result: .passed, steps: steps)
        case .failed(let why):
            return VerificationSection(id: "tls", command: "verify tls attestation", isExtra: false,
                why: tlsWhy, docURL: "\(Self.docBase)/tls", result: .failed,
                steps: [RunStep(label: "connection binding", detail: why, status: .fail)])
        case .inconclusive(let why):
            // Couldn't complete (unreachable/unparseable) — advisory, not a
            // MITM verdict. Fail-closed elsewhere, but shown orange here.
            return VerificationSection(id: "tls", command: "verify tls attestation", isExtra: false,
                why: tlsWhy, docURL: "\(Self.docBase)/tls", result: .flagged,
                steps: [RunStep(label: "connection binding", detail: "\(why) — could not complete", status: .flag)])
        }
    }
    private var tlsWhy: String {
        "proves your encrypted connection ends inside the sealed hardware — so nothing in between (network, load balancers, near.ai’s own infra) can read it."
    }

    private var chatSection: VerificationSection? {
        guard let resp = responseSigState else { return nil }
        let steps: [RunStep]
        switch resp {
        case .done:
            steps = [
                RunStep(label: "request + response hash", detail: "`sha256` of what was sent/received matches the signed value", status: .pass),
                RunStep(label: "signature", detail: responseSigEvidence ?? "`ecrecover(sig)` == attested signer", status: .pass),
            ]
        case .stuck:
            steps = [RunStep(label: "signature", detail: responseSigDetail, status: .fail)]
        case .live, .pending:
            steps = [RunStep(label: "signature", detail: "waiting for a signed response…", status: .pending)]
        }
        return VerificationSection(
            id: "chat", command: "verify chat", isExtra: false,
            why: "proves each answer came from the verified model, unaltered — signed by a key only the enclave holds.",
            docURL: "\(Self.docBase)/chat", result: rollup(steps), steps: steps)
    }

    private var provenanceSection: VerificationSection? {
        guard let state = provenanceState else { return nil }
        let steps: [RunStep]
        switch state {
        case .done:
            var built = [RunStep(label: "image provenance", detail: provenanceEvidence ?? "images trace to github.com/nearai ✓", status: .pass)]
            // One step per verified image: the running digest, the attested
            // version, and links to the exact source, release, and public log —
            // everything needed to compare the instance to a verifiable build.
            if case .allVerified(let verified, _) = imageProvenance {
                // Grouped by machine: gateway, then shared, then model —
                // the host tag leads each detail line.
                let ordered = verified.sorted {
                    (Self.hostTag($0), $0.image) < (Self.hostTag($1), $1.image)
                }
                for image in ordered where image.sourceRepo != nil {
                    built.append(Self.imageStep(image))
                }
            }
            if let engine = engineStep { built.append(engine) }
            steps = built
        case .stuck:
            steps = [RunStep(label: "image provenance", detail: provenanceDetail, status: .fail)]
        case .live, .pending:
            steps = [RunStep(label: "image provenance", detail: "checking Sigstore / Rekor…", status: .pending)]
        }
        return VerificationSection(
            id: "provenance", command: "verify provenance", isExtra: true,
            why: "proves the running images were built from near.ai’s public source, not modified in secret. (beyond near.ai’s docs — teemoon adds this.)",
            docURL: "https://search.sigstore.dev", result: rollup(steps), steps: steps)
    }

    /// "gateway", "model", or "gateway + model" for a shared image; empty
    /// when host membership wasn't recorded. Sorts groups in that order.
    private static func hostTag(_ image: ProvenanceService.ImageRef) -> String {
        image.hosts.sorted().joined(separator: " + ")
    }

    /// The inference engine itself: built in-enclave from the compose-files
    /// repo at the commit the compose-manager's action log attests. The
    /// engine image has no registry digest (`:local`), so its identity is the
    /// attested YAML — hash-verified against the fetched file — rather than a
    /// Sigstore record.
    private var engineStep: RunStep? {
        guard let att = attestation, let path = att.modelComposePath,
              let commit = att.modelComposeCommit else { return nil }
        let status: RunStepStatus
        let note: String
        switch modelLayerVerification {
        case .some(.verified):     status = .pass;    note = "hash verified on this device"
        case .some(.hashMismatch): status = .fail;    note = "does NOT match the action log’s pinned hash — recipe unverified, do not trust"
        case .some(.fetchFailed):  status = .flag;    note = "source unreachable — could not verify (transient)"
        case .none:                status = .pending; note = "verifying…"
        }
        let tag = att.modelComposeTag.map { " · \($0)" } ?? ""
        var links = [RunLink(
            title: "source",
            url: "https://github.com/\(ProvenanceService.modelComposeRepo)/blob/\(commit)/\(path)")]
        if let t = att.modelComposeTag {
            links.append(RunLink(
                title: "release",
                url: "https://github.com/\(ProvenanceService.modelComposeRepo)/releases/tag/\(t)"))
        }
        return RunStep(
            label: "inference engine (built in-enclave)",
            detail: "runs on model · \(path)\(tag) @ \(commit.prefix(7)) · \(note)",
            status: status,
            url: "https://github.com/\(ProvenanceService.modelComposeRepo)/blob/\(commit)/\(path)",
            links: links)
    }

    /// One provenance step for a verified image: which machine runs it, the
    /// running digest + attested version in the detail, with links to the
    /// exact source commit, the release (tag builds only), and the digest's
    /// public Sigstore log entry.
    private static func imageStep(_ image: ProvenanceService.ImageRef) -> RunStep {
        let repo = image.sourceRepo ?? ""
        let shortRef = image.sourceRef.map {
            $0.replacingOccurrences(of: "refs/tags/", with: "")
              .replacingOccurrences(of: "refs/heads/", with: "")
        }
        // Primary destination = the code that's running: the repo tree at the
        // attested commit, falling back to the tag's tree, then the repo root.
        let isTag = image.sourceRef?.hasPrefix("refs/tags/") == true
        let sourceURL: String
        if let commit = image.sourceCommit {
            sourceURL = "\(repo)/tree/\(commit)"
        } else if isTag, let tag = shortRef {
            sourceURL = "\(repo)/tree/\(tag)"
        } else {
            sourceURL = repo
        }
        var links: [RunLink] = []
        if isTag, let tag = shortRef {
            links.append(RunLink(title: "release", url: "\(repo)/releases/tag/\(tag)"))
        }
        links.append(RunLink(title: "sigstore", url: "https://search.sigstore.dev/?hash=\(image.digest)"))
        let version = shortRef.map { " · \($0)" } ?? ""
        let commit = image.sourceCommit.map { " @ \($0.prefix(7))" } ?? ""
        let host = Self.hostTag(image).isEmpty ? "" : "runs on \(Self.hostTag(image)) · "
        return RunStep(
            label: image.image,
            detail: "\(host)sha256:\(image.digest.prefix(12))…\(version)\(commit) → \(repo.replacingOccurrences(of: "https://github.com/", with: ""))",
            status: .pass, url: sourceURL, links: links)
    }

    /// Overall run status for the console header dot.
    var runResult: SectionResult {
        let results = verificationRun.map(\.result)
        if results.contains(.failed) { return .failed }
        if results.contains(.running) { return .running }
        if results.contains(.flagged) { return .flagged }
        return results.isEmpty ? .running : .passed
    }
}
