//
//  MeasuredConfig.swift
//  teemoon
//
//  The measured-configuration panel for each plaintext-touching image: the
//  safety-relevant launch flags / env, live-parsed from the hash-verified
//  INNER model-layer compose (the document compose-manager actually launched;
//  its SHA256 equals the attested `file_sha256` from the compose-manager
//  action log). Per the audit's principle that "sight is context, not a
//  finding", the payload here is what the measured config *forbids*.
//
//  Copy rules (from the plaintext-surfacing audit):
//  • never "can't log" — sglang exposes an unauthenticated
//    /configure_logging endpoint, so "can't" would be false. The true claim
//    is "not configured to log — and the operator can't reconfigure it
//    without a measurement change or a signed action-log trace."
//  • the binding is "pinned by the attested action log and hash-checked" —
//    NOT a hardware measurement (mr_config measures the outer harness
//    compose; the inner document is bound via the compose-manager action
//    log, which teemoon verifies by hash).
//
//  Every line renders only what was actually parsed: a "holds" line requires
//  the flag's absence to be established in a recognized service block, and
//  anything found instead is named literally. Pure and testable.
//
//  TODO(digest-gated audit links): cross-check the measured config against
//  published per-component proxy/sglang source audits once available, gated by
//  an audited commit/digest map. The seam is `Line.links` (populated only with
//  the compose YAML link today — do not fabricate audit URLs).
//

import Foundation

struct MeasuredConfig: Equatable, Sendable {

    /// One parsed fact about the toucher's measured configuration.
    struct Line: Equatable, Sendable, Identifiable {
        enum State: Equatable, Sendable {
            /// The safety property holds as configured — soft verified tint.
            case holds
            /// Something is present that the reader should see named.
            case attention
        }
        let id: String
        let state: State
        let title: String
        /// Sentence with backtick-marked literal tokens (renders via proofText).
        let detail: String
        var links: [RunLink] = []
    }

    let lines: [Line]

    // MARK: Pinned copy (tested — the two rules the design fixes)

    /// The operator-reconfiguration qualifier. Never "can't log": the honest
    /// claim is about configuration + the cost of changing it.
    static let reconfigureQualifier =
        "not configured to log — and the operator can't reconfigure it without a measurement change or a signed action-log trace."

    /// How the parsed document is bound. Deliberately not "hardware-measured":
    /// the CPU's measurement covers the outer harness compose only.
    static let bindingNote =
        "parsed live from the inner compose — pinned by the attested action log and hash-checked on this device. the CPU's boot measurement alone does not cover this file."

    // MARK: Building the panel

    /// The measured configuration for one toucher role, parsed from the
    /// hash-verified inner compose. `yamlLink` (the compose YAML at the
    /// attested commit, built by the caller's existing RunLink machinery) is
    /// attached to the engine's logging line so the reader can check the
    /// flags themselves. nil when the compose has no block matching the role
    /// — the panel simply doesn't render rather than claiming anything.
    static func forRole(_ role: PlaintextExposure.Role,
                        innerComposeYAML yaml: String,
                        yamlLink: RunLink? = nil) -> MeasuredConfig? {
        switch role {
        case .modelServer:    return engineConfig(innerComposeYAML: yaml, yamlLink: yamlLink)
        case .e2eeTerminator: return proxyConfig(innerComposeYAML: yaml)
        }
    }

    /// sglang: request logging off, no crash/disk-dump flags, weights pinned.
    static func engineConfig(innerComposeYAML yaml: String, yamlLink: RunLink? = nil) -> MeasuredConfig? {
        // Anchor expansion first: in production the engine's launch flags live
        // in an `x-…-cmd: &cmd` anchor referenced via `command: *cmd` (see
        // PlaintextExposure.analyze) — the raw block carries no signal.
        let anchors = PlaintextExposure.anchorBlocks(in: yaml)
        guard let block = PlaintextExposure.serviceBlocks(in: yaml)
            .map({ PlaintextExposure.expand($0, anchors: anchors) })
            .first(where: { PlaintextExposure.hasModelServerSignal($0) }) else { return nil }
        let tokens = flagTokens(inBlock: block)
        var lines: [Line] = []

        // Request logging. `--log-requests` must be matched as an exact flag —
        // `--log-requests-level` shares the prefix and means something else.
        let logRequestsOn = tokens.contains { $0 == "--log-requests" || $0.hasPrefix("--log-requests=") }
        let level = value(of: "--log-requests-level", in: tokens)
        if !logRequestsOn && (level == nil || level == "0") {
            let evidence = level == "0"
                ? "`--log-requests` absent, `--log-requests-level 0` (the minimum)"
                : "`--log-requests` absent"
            lines.append(Line(
                id: "logging", state: .holds,
                title: "request logging off",
                detail: "\(evidence) — \(reconfigureQualifier)",
                links: yamlLink.map { [$0] } ?? []))
        } else {
            let found = ([logRequestsOn ? "--log-requests" : nil,
                          level.map { "--log-requests-level \($0)" }]
                .compactMap { $0 }).joined(separator: ", ")
            lines.append(Line(
                id: "logging", state: .attention,
                title: "request-logging flags present",
                detail: "the launch command carries `\(found)` — request logging is configured on.",
                links: yamlLink.map { [$0] } ?? []))
        }

        // Crash / disk dump flags — named literally when present.
        let dumpFlags = tokens.filter { t in
            guard t.hasPrefix("--") else { return false }
            let l = t.lowercased()
            return l.contains("dump") || l.contains("crash")
        }
        if dumpFlags.isEmpty {
            lines.append(Line(
                id: "dumps", state: .holds,
                title: "no crash or disk-dump flags",
                detail: "no launch flag writes requests or crash state to disk (`dump`/`crash` flags absent from the command)."))
        } else {
            lines.append(Line(
                id: "dumps", state: .attention,
                title: "dump flags present",
                detail: "the launch command carries `\(dumpFlags.joined(separator: " "))`."))
        }

        // Weights pinned to an immutable revision.
        if let rev = value(of: "--revision", in: tokens) {
            lines.append(Line(
                id: "revision", state: .holds,
                title: "weights pinned to an immutable revision",
                detail: "`--revision \(rev.prefix(12))…` — the exact weight files are fixed; a swapped model is a different document hash."))
        } else {
            lines.append(Line(
                id: "revision", state: .attention,
                title: "weights not revision-pinned",
                detail: "the launch command carries no `--revision` — the model path could serve moving weights."))
        }

        return MeasuredConfig(lines: lines)
    }

    /// vllm-proxy-rs: OHTTP on — E2EE terminates here, by literal env.
    static func proxyConfig(innerComposeYAML yaml: String) -> MeasuredConfig? {
        let anchors = PlaintextExposure.anchorBlocks(in: yaml)
        guard let block = PlaintextExposure.serviceBlocks(in: yaml)
            .map({ PlaintextExposure.expand($0, anchors: anchors) })
            .first(where: { PlaintextExposure.hasTerminatorSignal($0) }) else { return nil }
        let ohttp = envValue("OHTTP_ENABLED", inBlock: block)
        var lines: [Line] = []
        if ohttp?.lowercased() == "true" {
            lines.append(Line(
                id: "ohttp", state: .holds,
                title: "end-to-end encryption terminates here",
                detail: "`OHTTP_ENABLED=true` is literal in this compose — your sealed request is decrypted only inside this service, next to the model."))
        } else if let ohttp {
            lines.append(Line(
                id: "ohttp", state: .attention,
                title: "OHTTP not enabled",
                detail: "this block sets `OHTTP_ENABLED=\(ohttp)` — the E2EE terminator role isn't backed by this value."))
        } else {
            // Terminator signal came from TLS_CERT only; say what's known.
            lines.append(Line(
                id: "ohttp", state: .attention,
                title: "OHTTP flag not found",
                detail: "this block terminates TLS but sets no `OHTTP_ENABLED` — the E2EE claim rests on the key-binding check above, not this compose."))
        }
        return MeasuredConfig(lines: lines)
    }

    // MARK: Group-level invariant — allowed_envs (outer measured compose)

    /// Env names the operator can set without a new measurement, parsed from
    /// the outer app_compose's `allowed_envs` (JSON array or YAML list form).
    /// nil when no `allowed_envs` section is present — no claim then.
    static func allowedEnvs(inOuterManifest text: String) -> [String]? {
        guard let keyRange = text.range(of: "allowed_envs") else { return nil }
        let after = text[keyRange.upperBound...]
        // JSON form: "allowed_envs": ["A", "B", …] — only when the bracket
        // directly follows the key (just quote/colon/whitespace between).
        if let open = after.firstIndex(of: "["),
           after[after.startIndex..<open].allSatisfy({ "\": \n\t".contains($0) }),
           let close = after[open...].firstIndex(of: "]") {
            let inner = after[after.index(after: open)..<close]
            let names = inner.split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'\n\t")) }
                .filter { !$0.isEmpty }
            return names
        }
        // YAML list form:
        //   allowed_envs:
        //     - NAME
        var names: [String] = []
        var seenList = false
        for rawLine in after.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") {
                seenList = true
                names.append(String(line.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))
            } else if line.isEmpty || line.hasPrefix("#") {
                continue
            } else {
                break // next key ends the list
            }
        }
        return seenList ? names : nil
    }

    /// The allowed envs that look like logging/debug switches — the invariant
    /// is that this comes back empty.
    static func loggingSuspects(inAllowedEnvs envs: [String]) -> [String] {
        envs.filter { name in
            let u = name.uppercased()
            return ["LOG", "DEBUG", "TRACE", "DUMP", "VERBOSE"].contains { u.contains($0) }
        }
    }

    /// The group-level caption for the model enclave: whether any operator-
    /// settable env (no measurement change needed) is a logging/debug switch.
    /// nil when the outer manifest exposes no allowed_envs to check — teemoon
    /// then makes no claim.
    static func allowedEnvsCaption(outerManifest: String) -> String? {
        guard let envs = allowedEnvs(inOuterManifest: outerManifest) else { return nil }
        let suspects = loggingSuspects(inAllowedEnvs: envs)
        if suspects.isEmpty {
            return "none of the \(envs.count) operator-settable env vars (`allowed_envs`, outer measured compose) is a logging or debug switch — every log knob in the launch config is a literal the operator can't reach without a new measurement or a signed action-log trace."
        }
        return "operator-settable env vars include \(suspects.map { "`\($0)`" }.joined(separator: ", ")) — a logging/debug-shaped switch reachable without a measurement change."
    }

    // MARK: Egress (disclosed limit)

    /// Whether the compose shows NO network-layer egress confinement: no
    /// `internal: true` network anywhere in the document. true = the absence
    /// is established (disclose it); false = some confinement is declared.
    /// This derives a *disclosed limit*, not a finding — confinement of the
    /// plaintext-handling containers rests on their audited code behavior.
    static func lacksEgressConfinement(composeYAML yaml: String) -> Bool {
        for rawLine in yaml.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "internal: true" || line.hasPrefix("internal: true") { return false }
        }
        return true
    }

    // MARK: Token helpers (launch-command parsing, list or inline form)

    /// Flattens a service block into whitespace tokens with YAML list markers
    /// and quotes stripped — same normalization ModelArtifact uses, local so
    /// the two parsers stay independently testable.
    private static func flagTokens(inBlock block: String) -> [String] {
        var tokens: [String] = []
        for rawLine in block.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)) }
            else if line == "-" { continue }
            for part in line.split(separator: " ") {
                let t = String(part).trimmingCharacters(in: CharacterSet(charactersIn: "\"',[]"))
                if !t.isEmpty { tokens.append(t) }
            }
        }
        return tokens
    }

    /// The value following `flag`, supporting `--flag value` and `--flag=value`.
    private static func value(of flag: String, in tokens: [String]) -> String? {
        for (i, t) in tokens.enumerated() {
            if t == flag, i + 1 < tokens.count { return tokens[i + 1] }
            if t.hasPrefix("\(flag)=") { return String(t.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    /// The literal value of `NAME=` in the block's environment entries.
    private static func envValue(_ name: String, inBlock block: String) -> String? {
        for rawLine in block.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)) }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if line.hasPrefix("\(name)=") {
                return String(line.dropFirst(name.count + 1))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
            // mapping form: `NAME: value`
            if line.hasPrefix("\(name):") {
                return String(line.dropFirst(name.count + 1))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
        }
        return nil
    }
}
