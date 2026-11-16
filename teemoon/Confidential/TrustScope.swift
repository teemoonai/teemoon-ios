//
//  TrustScope.swift
//  teemoon
//
//  Trust scope (a)(b)(2)(c) for one record, from the GPU node's report as served. A plain value the session
//  keeps and the screens read; the checks themselves live in ActionLogBinding, ActionLogReading and
//  RunningPairCheck.
//

import Foundation

struct TrustScope: Equatable, Sendable {
    struct RunningRow: Equatable, Sendable {
        let service: ActionLogReading.RunningService
        let outcome: RunningPairCheck.Outcome
        /// The log can't say whether it's still up (`ActionLogReading.undecidableServices`).
        var undecidable = false
    }

    var binding: ActionLogBinding.Result
    var boot: BootLogReplay.Result
    var composeManager: ActionLogReading.ComposeManagerSeat?
    var running: [RunningRow] = []
    /// Which running services this chat's requests pass through, from the host the app connected to.
    var chatPath: ChatPath.Result? = nil

    /// The sheet's "running now" list: what the log vouches for plus this chat's path; with no path, every row.
    /// Display only: hash checks and the hard break read `running`.
    var activeRunning: [RunningRow] {
        guard case .path(let hops) = chatPath else { return running }
        return running.filter { row in !row.undecidable || hops.contains { $0.service == row.service.service && $0.source == row.service.source } }
    }

    /// (c) from what the fetches returned: every running row with its outcome and liveness, and this chat's path.
    static func runningSection(actions: [[String: Any]], services: [ActionLogReading.RunningService],
                               names: [ActionLogReading.Source: [String]], texts: [ActionLogReading.Source: String],
                               outcomes: [(ActionLogReading.Source, RunningPairCheck.Outcome)],
                               model: String?, host: String?) -> ([RunningRow], ChatPath.Result?) {
        let alive = services.filter { s in
            model != nil && texts[s.source].map { ChatPath.Compose($0).services[s.service]?.modelName == model } == true
        }
        let undecidable = ActionLogReading.undecidableServices(actions: actions, running: services,
                                                                servicesIn: { names[$0] }, alive: alive)
        let rows = services.map { s in
            RunningRow(service: s, outcome: outcomes.first { $0.0 == s.source }?.1 ?? .notFetched,
                       undecidable: undecidable[s.service] != nil)
        }
        return (rows, host.map { h in ChatPath.resolve(host: h, running: services) { texts[$0] } })
    }

    /// A running file that doesn't match its pinned hash.
    var runningMismatch: Bool { running.contains { $0.outcome == .mismatch } }

    /// Fail closed, like a replayed quote: the send is blocked.
    var hardBreak: Bool {
        if case .mismatch = binding { return true }
        if case .mismatch = boot { return true }
        return runningMismatch
    }

    /// The compose manager's row when another one runs: the declared image stays shown but unlinked — its
    /// provenance, project and audit are about an image that isn't running (audit, 2026-11-06).
    /// A different running manager never wears the declared image's links or review; it wears its own review
    /// when the audits have one for its digest.
    static func managerRow(_ image: ImageEntry, seat: ActionLogReading.ComposeManagerSeat?,
                           pageFor: (String) -> URL?) -> ImageEntry {
        guard let seat, seat.differs, let running = seat.running else { return image }
        var declared = image
        // The pill shows the image the review is about; the declared one is named in the scope line only.
        declared.digest = "sha256:\(running.prefix(12))…"
        declared.digestFull = "sha256:\(running)"
        declared.links = []
        declared.projectPointer = nil
        if case .reviewed(let url) = seat.review(pageFor: pageFor) { declared.auditURL = url } else { declared.auditURL = nil }
        return declared
    }

    /// The action log names a running manager and the audits have no page for that build. Never the declared one's.
    static func runningManagerUnreviewed(_ seat: ActionLogReading.ComposeManagerSeat?,
                                         pageFor: (String) -> URL?) -> Bool {
        guard let seat, seat.running != nil else { return false }
        return seat.review(pageFor: pageFor) == .unreviewed
    }

    /// The compose manager's default in the measured compose: `${COMPOSE_MANAGER_IMAGE:-…@sha256:<64>}`.
    static func declaredComposeManager(in appCompose: String) -> String? {
        guard let r = appCompose.range(of: #"nearaidev/compose-manager@sha256:[0-9a-fA-F]{64}"#, options: .regularExpression)
        else { return nil }
        return ActionLogReading.digest(of: String(appCompose[r]))
    }

    static func hardware(_ v: DCAPVerification?) -> ActionLogBinding.Hardware {
        switch v {
        case .verified(let tcb, _, _): tcb.isAccepted ? .verified : .failed
        case .unchecked, nil: .unchecked
        case .failed: .failed
        }
    }

    /// Either side not checked is not a disagreement.
    static func tcb(_ a: DCAPVerification?, _ b: DCAPVerification?) -> ActionLogBinding.TCB {
        guard case .verified(let x, _, _) = a, case .verified(let y, _, _) = b else { return .unchecked }
        return x == y ? .agree : .differ
    }

    /// Runs every check that needs no network except DCAP and the compose-file fetch, both passed in.
    static func run(reportJSON: Data, nodeQuoteHex: String?, nonceHex: String?,
                    dcap: (String) async -> DCAPVerification?,
                    nodeDCAP: DCAPVerification?,
                    pairs: RunningPairCheck, host: String? = nil) async -> TrustScope? {
        guard let report = try? JSONSerialization.jsonObject(with: reportJSON) as? [String: Any] else { return nil }
        let cma = report["compose_manager_attestation"] as? [String: Any]
        let actions = cma?["actions"] as? [[String: Any]]
        let cmQuoteHex = cma?["quote"] as? String
        let nodeQuote = nodeQuoteHex.flatMap { try? Data(hexString: $0) }
        let nonce = nonceHex.flatMap { try? Data(hexString: $0) } ?? Data()
        let info = report["info"] as? [String: Any]
        var tcb = info?["tcb_info"] as? [String: Any]
        if tcb == nil, let s = info?["tcb_info"] as? String, let d = s.data(using: .utf8) {
            tcb = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }

        // (a): DCAP on the compose manager's quote exactly as on the node's; their TCB verdicts must agree.
        var binding = ActionLogBinding.Result.notBound
        if let cmQuoteHex, let actions {
            let cmDCAP = await dcap(cmQuoteHex)
            binding = ActionLogBinding.check(actions: actions, cmQuote: try? Data(hexString: cmQuoteHex), nodeQuote: nodeQuote,
                                             nonce: nonce, hardware: Self.hardware(cmDCAP),
                                             tcb: Self.tcb(cmDCAP, nodeDCAP))
        }

        // (b)
        let entries = BootLogReplay.entries(from: tcb?["event_log"])
        let osImage = (info?["os_image_hash"] as? String).flatMap { try? Data(hexString: $0) }
        let boot: BootLogReplay.Result = {
            guard let nodeQuote, let node = TDReport(quote: nodeQuote) else { return .absent }
            return BootLogReplay.check(entries: entries, nodeRTMR3: node.rtmr3,
                                       appCompose: tcb?["app_compose"] as? String, osImageHash: osImage)
        }()

        var scope = TrustScope(binding: binding, boot: boot)
        // (2) only once the log is bound.
        if binding == .bound, let actions, let declared = (tcb?["app_compose"] as? String).flatMap(declaredComposeManager(in:)) {
            scope.composeManager = ActionLogReading.composeManager(actions: actions, declared: declared)
        }
        // (c)
        if let actions {
            let sources = Set(ActionLogReading.wholeFileSources(actions: actions) + ActionLogReading.upRevisionSources(actions: actions))
            let names = await pairs.serviceNames(for: Array(sources))
            let services = ActionLogReading.runningServices(actions: actions) { names[$0] }
            let outcomes = await pairs.check(pairs: ActionLogReading.pairsToCheck(services))
            let texts = binding == .bound ? await pairs.bodies(for: services.map(\.source)) : [:]
            (scope.running, scope.chatPath) = runningSection(actions: actions, services: services, names: names, texts: texts,
                                                             outcomes: outcomes, model: report["model_name"] as? String,
                                                             host: binding == .bound ? host : nil)
        }
        return scope
    }
}
