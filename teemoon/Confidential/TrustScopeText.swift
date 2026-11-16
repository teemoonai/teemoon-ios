//
//  TrustScopeText.swift
//  teemoon
//
//  Trust scope's words, as approved on the review page (near-trust-scope, the maintainer 2026-11-06). Android
//  vendors the same lines; change them only through the review page.
//

import Foundation

enum TrustScopeText {
    // (a)
    static let actionLogBound = "action log bound to this enclave's hardware ✓"
    static let actionLogBoundDetail = "the compose manager's own quote signs this log, inside the same enclave as the model."
    static let actionLogNotBound = "action log not bound: near.ai didn't send the compose manager's quote, so the log below is what near.ai reports, not proven."
    static let actionLogNotBoundShort = "action log not bound"
    static let actionLogNotChecked = "action log not checked: intel's check couldn't be completed, so the log below is what near.ai reports, not proven."
    static let actionLogNotCheckedShort = "action log not checked"
    static let actionLogMismatch = "action log doesn't match its quote. do not trust."
    static let actionLogBanner = "the action log doesn't match the compose manager's hardware quote."
    static func actionLogMismatchDetail(_ m: ActionLogBinding.Mismatch) -> String {
        switch m {
        case .quote: "the quote didn't verify."
        case .actionsHash: "the log was changed after it was signed."
        case .nonce: "the quote answers a different request."
        case .sameTD: "the quote comes from a different enclave."
        case .tcbDiffers: "the two quotes disagree about the hardware's patch level."
        }
    }

    // (b)
    static let bootLogMeasured = "compose file and guest os measured into the quote ✓"
    static let bootLogMeasuredDetail = "replayed from the boot event log (rtmr3)."
    static let bootLogAbsent = "boot event log missing: the compose file matches its hash, but that hash isn't tied to the quote."
    static let bootLogMismatch = "boot event log doesn't match the quote. do not trust."
    static let bootLogBanner = "the boot event log doesn't match the model's hardware quote."
    static let osImageInQuoteSuffix = " · in the quote ✓"

    // "signed" only once (a) is bound (near-trust-scope).
    static func seamCaption(_ b: ActionLogBinding.Result?) -> String {
        b == .bound ? "pinned by the signed action log" : "pinned by the action log"
    }
    static func deploymentSuffix(_ b: ActionLogBinding.Result?) -> String {
        b == .bound ? " · per the signed action log" : " · per the action log"
    }
    static func measuredBindingNote(_ b: ActionLogBinding.Result?) -> String {
        b == .bound ? MeasuredConfig.bindingNote
            : "parsed live from the inner compose \u{2014} pinned by the action log and hash-checked on this device. the CPU's boot measurement alone does not cover this file."
    }
    static func recipeDeclaresCaption(_ b: ActionLogBinding.Result?) -> String {
        (b == .bound ? "the images the signed action log\u{2019}s recipe declares" : "the images the action log\u{2019}s recipe declares")
            + " \u{2014} checked on this device against its `file_sha256`."
    }
    // One line for every binding: even a bound log can pin no recipe.
    static let noActionLogDetail = "the action log pins no engine + proxy recipe for this enclave, so it can\u{2019}t be hash-checked on this device \u{2014} it isn\u{2019}t pinned by anything you can verify here."

    // (2)
    static let runningPerActionLogSuffix = " · running per the action log"
    static func composeManagerDiffers(declared: String, running: String) -> String {
        "declared sha256:\(declared.prefix(8)) · running sha256:\(running.prefix(8))"
    }
    static let composeManagerDiffersDetail = "the action log names the running compose manager. the measured launcher only requires near.ai's signature on it, so this image isn't measured."
    static let composeManagerNoStart = "no start recorded in the action log: showing the declared image."
    // running-manager-unreviewed (the maintainer 2026-11-06). Never gates.
    static let runningManagerUnreviewed = "running manager unreviewed: teemoon has no review of this build yet."

    // Changed lines: what the log names is not what it pins.
    static func namesImages(_ n: Int, of m: Int) -> String { "names \(n) of \(m) images by content digest" }
    static let imagesTheActionLogNames = "the images the action log names"

    // (c)
    static let runningHeader = "running now, per the action log"
    static func runningRow(service: String, file: String, commit: String) -> String {
        "\(service) · \(file) @ \(commit.prefix(7))"
    }
    static func runningCaption(tag: String, since: String) -> String { "\(tag) · since \(since)" }
    static let runningFooter = "what the action log names as up, not a container list. a full restart may have removed services the log can't show."
    static let notFetched = "not fetched"
    // trust-running-undecidable (the maintainer 2026-11-06). Never gates.
    static let undecidable = "the action log can't tell whether this is still running"
    static let undecidableDetail = "a later full redeploy of another model may have removed it"
    static let notPublishedAtCommit = "not published at this commit: near.ai's compose-files repo has no such file, so it can't be checked."
    static let runningMismatchUnsignedBanner = "the running recipe doesn't match the action log, so the launched configuration is unverified."
    // Reused as-is from the recipe card.
    static let fileVerified = "verified on this device ✓"
    static let fileMismatch = "✗ does not match the action log — recipe unverified, do not trust"
    static let fileUnreachable = "source unreachable — could not verify (transient)"

    // (d)
    static func launcherViaIndex(_ index: String) -> String { "attested via its linux/amd64 index \(index.prefix(8))" }
    static let launcherChecking = "finding the launcher's published index…"
    static let launcherNotFound = "not in any index near.ai published"

    static func runningOutcome(_ o: RunningPairCheck.Outcome) -> String {
        switch o {
        case .verified: fileVerified
        case .mismatch: fileMismatch
        case .unpublished: notPublishedAtCommit
        case .inconclusive: fileUnreachable
        case .notFetched: notFetched
        }
    }
}

/// One trust-scope line as the screen draws it: words, an optional detail, and how sure it is.
struct TrustScopeLine: Equatable {
    enum Tone: Equatable { case proven, caution, broken, quiet }
    let text: String
    var detail: String? = nil
    let tone: Tone
}

/// Which line each result gets. Pure, so the choice is tested and android maps the same results the same way.
extension TrustScopeText {
    static func actionLogLine(_ b: ActionLogBinding.Result?) -> TrustScopeLine? {
        switch b {
        case nil: nil
        case .bound: .init(text: actionLogBound, detail: actionLogBoundDetail, tone: .proven)
        case .notBound: .init(text: actionLogNotBound, tone: .caution)
        case .unchecked: .init(text: actionLogNotChecked, tone: .caution)
        case .mismatch(let m): .init(text: actionLogMismatch, detail: actionLogMismatchDetail(m), tone: .broken)
        }
    }

    static func bootLogLine(_ b: BootLogReplay.Result?) -> TrustScopeLine? {
        switch b {
        case nil: nil
        case .matches: .init(text: bootLogMeasured, detail: bootLogMeasuredDetail, tone: .proven)
        case .absent: .init(text: bootLogAbsent, tone: .caution)
        case .mismatch: .init(text: bootLogMismatch, tone: .broken)
        }
    }

    /// Appended to the guest OS's os_image value when the boot log puts it in the quote.
    static func osImageSuffix(_ b: BootLogReplay.Result?) -> String { b == .matches ? osImageInQuoteSuffix : "" }

    /// The compose manager's row: what the action log says is running. Nothing from an unbound log.
    static func composeManagerLine(_ seat: ActionLogReading.ComposeManagerSeat?) -> TrustScopeLine? {
        guard let seat else { return nil }
        guard let running = seat.running else { return .init(text: composeManagerNoStart, tone: .caution) }
        if seat.differs {
            return .init(text: composeManagerDiffers(declared: seat.declared, running: running),
                         detail: composeManagerDiffersDetail, tone: .caution)
        }
        return .init(text: String(runningPerActionLogSuffix.dropFirst(3)), tone: .proven)
    }

    /// Every line under the compose manager's row.
    static func composeManagerLines(_ seat: ActionLogReading.ComposeManagerSeat?,
                                    pageFor: (String) -> URL?) -> [TrustScopeLine] {
        var lines = [composeManagerLine(seat)].compactMap { $0 }
        if TrustScope.runningManagerUnreviewed(seat, pageFor: pageFor) {
            lines.append(.init(text: runningManagerUnreviewed, tone: .caution))
        }
        return lines
    }

    struct RunningRowText: Equatable {
        let title: String
        let caption: String?
        let state: TrustScopeLine
        var liveness: TrustScopeLine? = nil
    }

    static func runningRow(_ row: TrustScope.RunningRow) -> RunningRowText {
        let s = row.service
        let caption = s.tag.map { runningCaption(tag: $0, since: String((s.since ?? "").prefix(10))) }
        let tone: TrustScopeLine.Tone = switch row.outcome {
        case .verified: .proven
        case .mismatch: .broken
        case .unpublished, .inconclusive: .caution
        case .notFetched: .quiet
        }
        return .init(title: runningRow(service: s.service.isEmpty ? "(whole file)" : s.service, file: s.source.file,
                                       commit: s.source.commit),
                     caption: caption, state: .init(text: runningOutcome(row.outcome), tone: tone),
                     liveness: row.undecidable ? .init(text: undecidable, detail: undecidableDetail, tone: .caution) : nil)
    }
}
