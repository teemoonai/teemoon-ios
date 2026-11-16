//
//  ActionLogReading.swift
//  teemoon
//
//  Trust scope (2) and (c), 1.1.0: what the action log names as running — the compose manager's own
//  image, and which compose file each service came from. Read only once ActionLogBinding says .bound;
//  anything from this log is "names", never "pins". Spec: conformance/nearai-trust.
//

import Foundation

enum ActionLogReading {
    struct ComposeManagerSeat: Equatable, Sendable {
        enum Source: Equatable, Sendable { case actionLog, declaredOnly }
        /// The digest the measured compose defaults to (`${COMPOSE_MANAGER_IMAGE:-…}`).
        let declared: String
        /// The digest of the last `compose_manager_started`, when the log has one.
        let running: String?
        var source: Source { running == nil ? .declaredOnly : .actionLog }
        var differs: Bool { running.map { $0 != declared } ?? false }

        enum Review: Equatable, Sendable { case reviewed(URL), unreviewed }
        /// The audit page for the manager that RUNS. The declared image's page never stands in for it: since
        /// 2026-11-04 the fleet runs a0c07308, which has none, over a declared 6e035c8f that has one.
        func review(pageFor page: (String) -> URL?) -> Review {
            page(running ?? declared).map(Review.reviewed) ?? .unreviewed
        }
    }

    /// The LAST `compose_manager_started` in array order: the log is append-only.
    static func composeManager(actions: [[String: Any]], declared: String) -> ComposeManagerSeat {
        let started = actions.last { $0["action"] as? String == "compose_manager_started" }
        let running = (started?["image"] as? String).flatMap(digest(of:))
        return ComposeManagerSeat(declared: declared, running: running)
    }

    /// "nearaidev/compose-manager@sha256:<64>" → "<64>".
    static func digest(of image: String) -> String? {
        guard let r = image.range(of: "@sha256:") else { return nil }
        let hex = String(image[r.upperBound...])
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex.lowercased() : nil
    }

    struct Source: Hashable, Sendable {
        let commit: String
        let file: String
        let fileSHA256: String
    }

    struct RunningService: Equatable, Sendable {
        let service: String
        let source: Source
        let tag: String?
        /// The operator's clock, from the log: label it as such.
        let since: String?
        /// The log entry that attributed it (its index): liveness asks what came after.
        var entry: Int = 0
    }

    /// What the log names as up, walked newest first (audit 2026-11-06): an entry naming services decides the
    /// ones no newer entry decided (up attributes, down retires). An entry naming none is the whole file —
    /// compose-manager runs `up -d --remove-orphans` per model project — so it decides every service
    /// `servicesIn` reads from that revision, and every older entry of that file is ignored. A whole file it
    /// can't read is one "(whole file)" row, services unknown; the walk never stops early. Every up also runs
    /// `--remove-orphans`, so an older entry of F only keeps services in every newer up revision of F (rule 3).
    /// Cross-file eviction (two files sharing one project) isn't in the log and isn't modelled.
    static func runningServices(actions: [[String: Any]],
                                servicesIn: (Source) -> [String]?) -> [RunningService] {
        let pinned = pinnedHashes(actions)
        var decided: Set<String> = []
        var deadFiles: Set<String> = []
        var bound: [String: Set<String>] = [:]
        var rows: [RunningService] = []
        for (index, a) in actions.enumerated().reversed() {
            let action = a["action"] as? String
            guard action == "compose_up" || action == "compose_down",
                  let file = a["file"] as? String, let commit = a["commit"] as? String,
                  !deadFiles.contains(file) else { continue }
            let source = Source(commit: commit, file: file, fileSHA256: a["file_sha256"] as? String ?? pinned[commit + "/" + file] ?? "")
            let named = a["services"] as? [String]
            if named == nil { deadFiles.insert(file) }
            let limit = bound[file]
            if action == "compose_up", let revision = servicesIn(source).map(Set.init) {
                bound[file] = limit.map { $0.intersection(revision) } ?? revision
            }
            guard let all = named ?? servicesIn(source) else {
                if action == "compose_up" {
                    rows.append(RunningService(service: "", source: source, tag: a["tag"] as? String,
                                               since: a["timestamp"] as? String, entry: index))
                }
                continue
            }
            // A name a newer up's revision lacks was removed as an orphan: this entry still decides it, as gone.
            let retired = limit.map { l in all.filter { !l.contains($0) } } ?? []
            for name in retired { decided.insert(name) }
            for name in all where !retired.contains(name) && decided.insert(name).inserted && action == "compose_up" {
                rows.append(RunningService(service: name, source: source, tag: a["tag"] as? String,
                                           since: a["timestamp"] as? String, entry: index))
            }
        }
        return rows
    }

    /// The whole-file entries the walk can reach: the newest of each file, since it kills the older ones.
    /// Fetched together before the walk, inside the send gate's settle.
    static func wholeFileSources(actions: [[String: Any]]) -> [Source] {
        let pinned = pinnedHashes(actions)
        var seen: Set<String> = []
        return actions.reversed().compactMap { a in
            guard ["compose_up", "compose_down"].contains(a["action"] as? String), a["services"] == nil,
                  let file = a["file"] as? String, let commit = a["commit"] as? String,
                  seen.insert(file).inserted else { return nil }
            return Source(commit: commit, file: file, fileSHA256: a["file_sha256"] as? String ?? pinned[commit + "/" + file] ?? "")
        }
    }

    /// Every up revision: rule 3 bounds older entries by each one's services. Fetched with the whole files.
    static func upRevisionSources(actions: [[String: Any]]) -> [Source] {
        var seen: Set<Source> = []
        return actions.reversed().compactMap { a in
            guard a["action"] as? String == "compose_up", let file = a["file"] as? String,
                  let commit = a["commit"] as? String, let sha = a["file_sha256"] as? String else { return nil }
            let source = Source(commit: commit, file: file, fileSHA256: sha)
            return seen.insert(source).inserted ? source : nil
        }
    }

    /// A down pins no hash; an up of the same (commit, file) elsewhere in the log does, and binds the down too.
    private static func pinnedHashes(_ actions: [[String: Any]]) -> [String: String] {
        var out: [String: String] = [:]
        for a in actions where a["action"] as? String == "compose_up" {
            if let c = a["commit"] as? String, let f = a["file"] as? String, let sha = a["file_sha256"] as? String {
                out[c + "/" + f] = sha
            }
        }
        return out
    }

    /// Running services the log can't vouch for (audit 2026-11-06, per service), each with the entry that may
    /// have removed it: the first later up of ANOTHER file whose revision lacks the name. Every up removes
    /// orphans; whether that file shares the project isn't in the log. An unreadable revision counts. Downs
    /// never count. A proxy that answered this report is alive, so a later up of a file lacking its name
    /// didn't evict its file: that file's ups count against nothing in the proxy's file.
    static func undecidableServices(actions: [[String: Any]], running: [RunningService],
                                    servicesIn: (Source) -> [String]?,
                                    alive: [RunningService] = []) -> [String: Int] {
        let pinned = pinnedHashes(actions)
        let ups: [(index: Int, file: String, names: Set<String>?)] = actions.enumerated().compactMap { i, a in
            guard a["action"] as? String == "compose_up", let file = a["file"] as? String,
                  let commit = a["commit"] as? String else { return nil }
            let source = Source(commit: commit, file: file, fileSHA256: a["file_sha256"] as? String ?? pinned[commit + "/" + file] ?? "")
            return (i, file, servicesIn(source).map(Set.init))
        }
        func evictor(_ name: String, file: String, after entry: Int, refuted: Set<String>) -> Int? {
            ups.first { $0.index > entry && $0.file != file && !refuted.contains($0.file) && !($0.names?.contains(name) ?? false) }?.index
        }
        var refuted: [String: Set<String>] = [:]   // proxy's file → files shown not to evict it
        for proxy in alive {
            for up in ups where up.index > proxy.entry && up.file != proxy.source.file && !(up.names?.contains(proxy.service) ?? false) {
                refuted[proxy.source.file, default: []].insert(up.file)
            }
        }
        var out: [String: Int] = [:]
        for s in running where !s.service.isEmpty {
            if let i = evictor(s.service, file: s.source.file, after: s.entry, refuted: refuted[s.source.file] ?? []) {
                out[s.service] = i
            }
        }
        return out
    }

    /// The service names of a compose file, as `servicesIn` hands them to `runningServices`.
    static func serviceNames(inCompose text: String) -> [String] {
        PlaintextExposure.serviceBlocks(in: PlaintextExposure.dockerComposeYAML(from: text)).compactMap { block in
            let header = block.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
            return header.hasSuffix(":") ? String(header.dropLast()) : nil
        }
    }

    /// Option A (audit 2026-11-04): every distinct (commit, file) the table names, newest attributing up
    /// first, at most `cap`. The rest show as "not fetched".
    static func pairsToCheck(_ services: [RunningService], cap: Int = 10) -> (check: [Source], notFetched: [Source]) {
        var latest: [Source: String] = [:]
        for s in services {
            let t = s.since ?? ""
            if latest[s.source].map({ t > $0 }) ?? true { latest[s.source] = t }
        }
        let ordered = latest.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.file < $1.key.file }.map(\.key)
        return (Array(ordered.prefix(cap)), Array(ordered.dropFirst(cap)))
    }
}
