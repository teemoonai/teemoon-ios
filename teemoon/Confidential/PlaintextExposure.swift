//
//  PlaintextExposure.swift
//  teemoon
//
//  Identifies which images in the model enclave's compose ever see the user's
//  message *decrypted* — the confidentiality question, distinct from the
//  integrity question (is all the code published) that provenance answers.
//
//  There is no attested "sees plaintext" field, so this reads it off the
//  compose the model quote measured, using two grounded signals:
//    • the E2EE / OHTTP terminator — the service that decrypts the request
//      sealed to the model key, identified by `OHTTP_ENABLED` / `TLS_CERT_PATH`.
//    • the model server — the service that runs the model over plaintext
//      tokens, identified by the inference-engine launch command
//      (`--model-path` / `launch_server`).
//  Everything else (gateway relay, ingress, telemetry sidecars) only ever
//  handles ciphertext or content-free metrics and is deliberately NOT named.
//
//  Fail-soft: if the compose can't be parsed into these roles, callers fall
//  back to honest generic copy rather than naming the wrong images. Pure and
//  testable.
//

import Foundation

struct PlaintextExposure: Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case e2eeTerminator
        case modelServer
        /// Short human phrase for what this component does with plaintext.
        var whatItDoes: String {
            switch self {
            case .e2eeTerminator: return "decrypts the request sealed to the model key"
            case .modelServer:    return "runs the model over your plaintext tokens"
            }
        }
        /// Capsule label for the known-code list — working-as-intended, not a
        /// warning: these images seeing your message is the design.
        var capsule: String {
            switch self {
            case .e2eeTerminator: return "decrypts your request"
            case .modelServer:    return "runs the model"
            }
        }
    }

    struct Toucher: Equatable, Sendable {
        let image: String   // short image name, e.g. "vllm-proxy-rs"
        let role: Role
    }

    /// Plaintext access *by capability* rather than by role: images whose
    /// attested privileges could reach the touchers' plaintext even though
    /// they never handle the data path. The scope rule of the audits repo,
    /// derived live from the same composes the hardware attests.
    enum Capability: String, Equatable, Sendable {
        /// Container-control privileges — a docker socket (any mount mode:
        /// the API is full-duplex over an :ro socket) or host-pid visibility.
        /// Could read plaintext straight out of process memory.
        case processAccess
        /// Elevated device privileges — `cap_add: SYS_ADMIN`, `privileged:
        /// true`, or the nvidia runtime with GPU device reservations (the
        /// dcgm-exporter shape). Not on the data path and no container
        /// control, but real kernel/device-level privilege inside the
        /// enclave — which is exactly why it must carry a tag rather than
        /// read as "safe to ignore".
        case devicePrivilege
        /// Container-log mounts — sees whatever the plaintext handlers choose
        /// to log (content-free at the audited flags; that flag posture is
        /// exactly what makes this capability benign).
        case logAccess

        var capsule: String {
            switch self {
            case .processAccess:   return "can reach enclave processes"
            case .devicePrivilege: return "GPU-privileged"
            case .logAccess:       return "reads container logs"
            }
        }
        var whatItDoes: String {
            switch self {
            case .processAccess:
                return "holds container-control privileges (docker socket / host pid) that could reach plaintext in process memory — control-plane by design, and why it's in audit scope"
            case .devicePrivilege:
                return "runs with SYS_ADMIN and GPU device access to scrape hardware metrics — an elevated privilege, which is why it's in audit scope"
            case .logAccess:
                return "tails other containers' logs — sees whatever the plaintext handlers log (content-free at the attested flags)"
            }
        }
    }

    struct Accessor: Equatable, Sendable {
        let image: String   // short image name, e.g. "compose-manager"
        let capability: Capability
    }

    /// The images that ever see plaintext, terminator first. Empty when the
    /// compose didn't yield a confident answer.
    let touchers: [Toucher]

    /// Capability-based accessors from BOTH attested documents (the harness
    /// carries most of them: deployer, watchdog, telemetry). Independent of
    /// `touchers` — an image is never listed in both.
    let accessors: [Accessor]

    init(touchers: [Toucher], accessors: [Accessor] = []) {
        self.touchers = touchers
        self.accessors = accessors
    }

    /// The role of the named image, matched on the short image name — so
    /// "nearaidev/vllm-proxy-rs@sha256:…" (a provenance ref) matches the
    /// toucher "vllm-proxy-rs" (parsed from the compose). nil = this image
    /// was not identified as seeing plaintext.
    func role(forImage name: String) -> Role? {
        touchers.first { $0.image == Self.shortName(name) }?.role
    }

    /// The capability of the named image, matched like `role(forImage:)`.
    /// nil = no attested privilege that reaches plaintext (or unanalyzed).
    func capability(forImage name: String) -> Capability? {
        accessors.first { $0.image == Self.shortName(name) }?.capability
    }

    private static func shortName(_ name: String) -> String {
        var short = name.split(separator: "/").last.map(String.init) ?? name
        if let at = short.firstIndex(of: "@") { short = String(short[..<at]) }
        if let colon = short.firstIndex(of: ":") { short = String(short[..<colon]) }
        return short
    }

    /// The one caption under the model-enclave group's image list. It states
    /// the counterpart of the role tags *positively* when the toucher set is
    /// known — and MUST flip to "couldn't determine…" when it's empty.
    ///
    /// INVARIANT: absence-of-badge must never
    /// read as "safe". An untagged image is only known-ciphertext-only when
    /// the analysis actually produced the toucher set; an empty set is an
    /// analysis gap, not an all-clear.
    var groupCaption: String {
        if touchers.isEmpty {
            return "couldn't determine which images see your message — the attested compose didn't yield the plaintext-handling set, so nothing here is tagged. that's an analysis gap, not an all-clear."
        }
        return "images without a tag only handle encrypted data or content-free telemetry, per the attested compose."
    }

    /// Analyzes plaintext exposure across the two attested documents.
    ///
    /// In production the engine and proxy live in the **inner** model-layer
    /// compose (the YAML compose-manager fetches at the attested commit, whose
    /// SHA256 matches the attested `file_sha256`) — the outer measured
    /// `app_compose` is the management harness only and carries NO toucher
    /// signals (verified live against glm-5-2.completions.near.ai,
    /// 2026-07-18). So the inner document is authoritative when it yields an
    /// answer; the outer manifest remains a fallback for older deployments
    /// that inlined the engine services there.
    static func analyze(innerComposeYAML inner: String?,
                        outerComposeYAML outer: String?) -> PlaintextExposure {
        // Capability accessors live mostly in the OUTER harness (deployer,
        // watchdog, telemetry), touchers in the inner stack — so accessors are
        // the union of BOTH documents, while touchers keep inner-first
        // precedence (the outer is a fallback for legacy inlined deployments).
        var accessors: [Accessor] = []
        var seen = Set<String>()
        for doc in [inner, outer].compactMap({ $0 }) {
            for a in Self.accessors(inComposeYAML: doc) where seen.insert(a.image).inserted {
                accessors.append(a)
            }
        }
        if let inner {
            let x = analyze(modelComposeYAML: inner)
            if !x.touchers.isEmpty {
                return PlaintextExposure(touchers: x.touchers, accessors: accessors.filter { acc in
                    !x.touchers.contains { $0.image == acc.image }
                })
            }
        }
        if let outer {
            let x = analyze(modelComposeYAML: outer)
            return PlaintextExposure(touchers: x.touchers, accessors: accessors.filter { acc in
                !x.touchers.contains { $0.image == acc.image }
            })
        }
        return PlaintextExposure(touchers: [], accessors: accessors)
    }

    /// Scans a compose document for images whose attested privileges could
    /// reach plaintext: docker-socket / host-pid container control, or
    /// container-log mounts. Same anchor-aware block parsing as the toucher
    /// analysis; fail-soft to the empty set.
    static func accessors(inComposeYAML rawYAML: String) -> [Accessor] {
        let yaml = dockerComposeYAML(from: rawYAML)
        var found: [Accessor] = []
        var seen = Set<String>()
        let anchors = anchorBlocks(in: yaml)
        for rawBlock in serviceBlocks(in: yaml) {
            let block = expand(rawBlock, anchors: anchors)
            guard let image = shortImageName(inBlock: block) else { continue }
            let capability: Capability?
            // Severity-ordered: container control subsumes device privilege
            // (compose-manager carries SYS_ADMIN *and* a docker socket — it
            // must classify as process access, the stronger claim), and
            // device privilege outranks a log mount.
            if hasProcessAccessSignal(block) { capability = .processAccess }
            else if hasDevicePrivilegeSignal(block) { capability = .devicePrivilege }
            else if hasLogAccessSignal(block) { capability = .logAccess }
            else { capability = nil }
            guard let capability, seen.insert(image).inserted else { continue }
            found.append(Accessor(image: image, capability: capability))
        }
        // Severity order (process → device → log), stable within each band.
        func rank(_ c: Capability) -> Int {
            switch c {
            case .processAccess:   return 0
            case .devicePrivilege: return 1
            case .logAccess:       return 2
            }
        }
        found = found.enumerated()
            .sorted { (rank($0.element.capability), $0.offset) < (rank($1.element.capability), $1.offset) }
            .map(\.element)
        return found
    }

    /// Container-control signals: a docker socket mount (any mode — the API
    /// is full-duplex over an :ro socket) or host-pid namespace visibility.
    static func hasProcessAccessSignal(_ block: String) -> Bool {
        let l = block.lowercased()
        return l.contains("docker.sock") || l.contains("pid: host")
    }

    /// Log-stream signals: the docker container-log directory or journald.
    static func hasLogAccessSignal(_ block: String) -> Bool {
        let l = block.lowercased()
        return l.contains("/var/lib/docker/containers") || l.contains("/run/log/journal")
    }

    /// Device-privilege signals — the dcgm-exporter shape: `cap_add` with
    /// SYS_ADMIN, `privileged: true`, or the nvidia runtime combined with a
    /// GPU device reservation. (Comment lines never reach here — the block
    /// splitter drops them — so a prose mention of SYS_ADMIN can't match.)
    static func hasDevicePrivilegeSignal(_ block: String) -> Bool {
        let l = block.lowercased()
        if l.contains("privileged: true") { return true }
        if l.contains("sys_admin") { return true }
        if l.contains("runtime: nvidia"),
           l.contains("driver: nvidia") || l.contains("capabilities: [gpu]") || l.contains("devices:") {
            return true
        }
        return false
    }

    /// Analyzes a model-enclave compose YAML. Returns an empty set (not a
    /// guess) when the structure isn't recognized.
    ///
    /// Production composes use YAML anchors for shared config (verified live
    /// against `prod/GLM-5.1-SGL-AWQ-TP4.yaml` @ c545c95, 2026-07-19): the
    /// proxy's `image:` lives in an `x-vllm-proxy-common: &vllm-proxy-common`
    /// block referenced via `<<: *vllm-proxy-common`, and the engine's launch
    /// flags live in `x-awq-cmd: &awq-cmd` referenced via `command: *awq-cmd`.
    /// Each service block is therefore expanded with the text of every anchor
    /// it references before image/signal extraction — a targeted alias
    /// resolution, not a YAML engine; unresolvable structure still fails soft
    /// to the empty set.
    static func analyze(modelComposeYAML rawYAML: String) -> PlaintextExposure {
        let yaml = dockerComposeYAML(from: rawYAML)
        var found: [Toucher] = []
        var seen = Set<String>()
        let anchors = anchorBlocks(in: yaml)
        // The terminators name the containers they hand decrypted plaintext to.
        // That is a stronger signal than matching engine image names, and it is
        // the only one that catches an engine which is neither vLLM nor sglang:
        // production `small-models.yaml` runs `model-privacy-filter`, an
        // in-enclave build `FROM pytorch/pytorch:…` serving `openai/privacy-filter`
        // over a FastAPI server, with no engine image name and no otel labels.
        // Every image-shaped heuristic missed it, so it rendered untagged — under
        // a group caption that says untagged images only handle encrypted data.
        let backends = backendServiceNames(inComposeYAML: yaml, anchors: anchors)
        for rawBlock in serviceBlocks(in: yaml) {
            let block = expand(rawBlock, anchors: anchors)
            guard let image = shortImageName(inBlock: block) else { continue }
            let role: Role?
            if hasTerminatorSignal(block) { role = .e2eeTerminator }
            else if hasModelServerSignal(block) { role = .modelServer }
            else if isNamedAsProxyBackend(rawBlock, backends: backends) { role = .modelServer }
            else { role = nil }
            guard let role else { continue }
            // Collapse replicas (r1/r2 of the same model image).
            let key = "\(image)·\(role.rawValue)"
            if seen.insert(key).inserted {
                found.append(Toucher(image: image, role: role))
            }
        }
        // Terminator before model server, for a natural read.
        found.sort { $0.role == .e2eeTerminator && $1.role != .e2eeTerminator }
        return PlaintextExposure(touchers: found)
    }

    // MARK: Parsing

    /// The docker-compose YAML to parse, unwrapped from its transport form.
    /// The model-layer INNER doc arrives as raw YAML, but near.ai's GPU-node
    /// OUTER `app_compose` (teemoon's `gpuNodeComposeManifest`) is a dstack
    /// manifest **JSON** carrying the compose in a `docker_compose_file` string
    /// field with escaped newlines. The block parser needs real `services:`
    /// lines, so pull that field out (JSONSerialization unescapes `\n`) when the
    /// input is that JSON; otherwise pass the text through unchanged. Fail-soft:
    /// anything that isn't the expected JSON shape is returned as-is.
    static func dockerComposeYAML(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.contains("\"docker_compose_file\"") else { return input }
        guard let data = input.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let compose = obj["docker_compose_file"] as? String else { return input }
        return compose
    }

    /// Collects every `&anchor` definition in the document: the defining line
    /// plus all following deeper-indented lines (covers `x-…: &name` mapping
    /// blocks and `x-…: &name >` folded scalars alike). Keyed by anchor name.
    static func anchorBlocks(in yaml: String) -> [String: String] {
        var map: [String: String] = [:]
        let lines = yaml.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let name = anchorName(definedIn: line) {
                let defIndent = line.prefix { $0 == " " }.count
                var block = [line]
                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    let trimmed = next.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { j += 1; continue }
                    let indent = next.prefix { $0 == " " }.count
                    if indent <= defIndent { break }
                    block.append(next)
                    j += 1
                }
                map[name] = block.joined(separator: "\n")
            }
            i += 1
        }
        return map
    }

    /// The `&name` an (uncommented) line defines, if any.
    private static func anchorName(definedIn line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let amp = trimmed.firstIndex(of: "&") else { return nil }
        let after = trimmed[trimmed.index(after: amp)...]
        let name = after.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return name.isEmpty ? nil : String(name)
    }

    /// Appends the text of every anchor a block references (`<<: *name`,
    /// `command: *name`, …) so image/signal extraction sees through the
    /// indirection. The block's own lines stay first, so an inline `image:`
    /// wins over an anchor's.
    static func expand(_ block: String, anchors: [String: String]) -> String {
        guard !anchors.isEmpty else { return block }
        var out = block
        var appended = Set<String>()
        for rawLine in block.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let star = line.firstIndex(of: "*") else { continue }
            let after = line[line.index(after: star)...]
            let name = String(after.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
            if !name.isEmpty, let anchor = anchors[name], appended.insert(name).inserted {
                out += "\n" + anchor
            }
        }
        return out
    }

    /// Splits the `services:` mapping into one text block per service, keyed by
    /// the indentation of the first service. Returns the block bodies.
    static func serviceBlocks(in yaml: String) -> [String] {
        let lines = yaml.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "services:"
        }) else { return [] }

        var blocks: [String] = []
        var current: [String] = []
        var serviceIndent: Int? = nil

        func flush() {
            if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
            current = []
        }

        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 { break }               // next top-level key ends services
            if serviceIndent == nil { serviceIndent = indent }
            if indent == serviceIndent {            // a new service header
                flush()
                current.append(line)
            } else {
                current.append(line)
            }
        }
        flush()
        return blocks
    }

    /// The `image:` value in a service block, reduced to its short name — no
    /// registry host, no `@sha256` digest, no tag: "…/vllm-proxy-rs@sha256:…"
    /// → "vllm-proxy-rs"; "glm51-sgl-awq-tp4-patched:local" → same, tag dropped.
    static func shortImageName(inBlock block: String) -> String? {
        for rawLine in block.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("image:") else { continue }
            var v = String(line.dropFirst("image:".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            // strip ${VAR:-default} wrapper, keeping the default
            if v.hasPrefix("${"), let dash = v.range(of: ":-"), let end = v.lastIndex(of: "}") {
                v = String(v[dash.upperBound..<end])
            }
            if let at = v.firstIndex(of: "@") { v = String(v[..<at]) }
            let lastPath = v.split(separator: "/").last.map(String.init) ?? v
            if let colon = lastPath.firstIndex(of: ":") { return String(lastPath[..<colon]) }
            return lastPath.isEmpty ? nil : lastPath
        }
        return nil
    }

    static func hasTerminatorSignal(_ block: String) -> Bool {
        let u = block.uppercased()
        return u.contains("OHTTP_ENABLED") || u.contains("TLS_CERT")
    }

    /// Every container an E2EE terminator forwards decrypted requests to, taken
    /// from its `VLLM_BASE_URL` / `VLLM_BACKEND_URLS` env (comma-separated
    /// `http://<service>:<port>` list). This is the data path stated by the
    /// component that holds the plaintext, so it identifies a model server even
    /// when the image name says nothing — the `model-privacy-filter` case.
    /// Fail-soft: no terminator, or no backend env, yields the empty set and the
    /// image-name signals stand alone.
    static func backendServiceNames(inComposeYAML yaml: String,
                                    anchors: [String: String]) -> Set<String> {
        var names: Set<String> = []
        for rawBlock in serviceBlocks(in: yaml) {
            let block = expand(rawBlock, anchors: anchors)
            guard hasTerminatorSignal(block) else { continue }
            for rawLine in block.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: " -\"'"))
                guard line.hasPrefix("VLLM_BASE_URL=") || line.hasPrefix("VLLM_BACKEND_URLS=") else { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                for url in line[line.index(after: eq)...].split(separator: ",") {
                    var host = url.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
                    if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
                    if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
                    if !host.isEmpty { names.insert(host) }
                }
            }
        }
        return names
    }

    /// Whether this service block IS one of those backends — matched on the
    /// compose service key (the block's first line) or an explicit
    /// `container_name:`, since a terminator's URL may name either.
    static func isNamedAsProxyBackend(_ rawBlock: String, backends: Set<String>) -> Bool {
        guard !backends.isEmpty else { return false }
        let lines = rawBlock.components(separatedBy: "\n")
        if let header = lines.first?.trimmingCharacters(in: .whitespaces),
           header.hasSuffix(":"), backends.contains(String(header.dropLast())) {
            return true
        }
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("container_name:") else { continue }
            let v = String(line.dropFirst("container_name:".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if backends.contains(v) { return true }
        }
        return false
    }

    /// Signal drift (verified live): SGLang engine blocks use `launch_server` or
    /// `sglang serve … --model-path …`; **vLLM** engine blocks (gemma-4, gpt-oss,
    /// Qwen3-VL) use `vllm serve <repo>` OR a bare positional under the
    /// `vllm/vllm-openai` entrypoint — no `--model-path`. Recognize the engine
    /// IMAGES too so a vLLM server on a combined node is tagged (and scoped)
    /// like an SGLang one, instead of the co-located SGLang server standing in.
    static func hasModelServerSignal(_ block: String) -> Bool {
        let l = block.lowercased()
        return l.contains("launch_server") || l.contains("--model-path")
            || l.contains("vllm serve")
            || l.contains("vllm/vllm-openai") || l.contains("lmsysorg/sglang")
    }

    /// The model id a model-server block serves — for scoping a COMBINED node's
    /// compose. Priority: `--served-model-name`, then `--model-path` (weights
    /// repo; its vendor matches the served id), then the `nearai.otel.model`
    /// label (present on servers whose model is a bare positional, e.g. gpt-oss).
    /// nil for shared infra (proxy, telemetry, mesh) that serves no model.
    static func servedModel(inBlock block: String) -> String? {
        if let v = flagValue("--served-model-name", in: block) { return v }
        if let v = flagValue("--model-path", in: block) { return v }
        if let v = labelValue("nearai.otel.model", in: block) { return v }
        return nil
    }

    /// A COMBINED multi-model node's compose scoped to the REQUESTED model:
    /// removes the service blocks of OTHER models' inference servers (and the
    /// `&anchor` blocks only they reference — where their engine `image:` lives,
    /// which `ProvenanceService` would otherwise regex-grep). Left standing: the
    /// requested model's server plus ALL shared infrastructure (E2EE proxy,
    /// compose-manager, telemetry, mesh). So the plaintext tiers and the image
    /// list reflect only the model you're talking to — the co-located servers
    /// never receive your plaintext (the proxy routes by `model`). A single-model
    /// compose, a nil request, or no other-model server → returned unchanged.
    static func scoped(_ rawYAML: String, toModel requested: String?) -> String {
        guard let requested, !requested.isEmpty else { return rawYAML }
        let yaml = dockerComposeYAML(from: rawYAML)
        let anchors = anchorBlocks(in: yaml)
        var droppedBlocks: [String] = []
        var droppedAnchors = Set<String>()
        var keptAnchors = Set<String>()
        for rawBlock in serviceBlocks(in: yaml) {
            let expanded = expand(rawBlock, anchors: anchors)
            let refs = anchorRefs(in: rawBlock)
            if hasModelServerSignal(expanded),
               let served = servedModel(inBlock: expanded),
               NearAIModelCatalog.differentVendor(served, requested) {
                droppedBlocks.append(rawBlock)
                droppedAnchors.formUnion(refs)
            } else {
                keptAnchors.formUnion(refs)   // requested server + shared infra
            }
        }
        guard !droppedBlocks.isEmpty else { return yaml }
        var out = yaml
        for b in droppedBlocks { out = out.replacingOccurrences(of: b, with: "") }
        for name in droppedAnchors.subtracting(keptAnchors) {
            if let text = anchors[name] { out = out.replacingOccurrences(of: text, with: "") }
        }
        return out
    }

    /// The `&name` anchors a block references (`<<: *name`, `command: *name`, …).
    private static func anchorRefs(in block: String) -> Set<String> {
        var refs = Set<String>()
        for rawLine in block.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let star = line.firstIndex(of: "*") else { continue }
            let name = String(line[line.index(after: star)...]
                .prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
            if !name.isEmpty { refs.insert(name) }
        }
        return refs
    }

    /// Value after a `--flag` (or `--flag=value`) in a block's whitespace/newline
    /// token stream — the flags live in folded-scalar commands.
    private static func flagValue(_ flag: String, in block: String) -> String? {
        let strip = CharacterSet(charactersIn: "\"',[]")
        let tokens = block.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .map { $0.trimmingCharacters(in: strip) }
        for (i, t) in tokens.enumerated() {
            if t == flag, i + 1 < tokens.count, !tokens[i + 1].isEmpty { return tokens[i + 1] }
            if t.hasPrefix("\(flag)=") { return String(t.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    /// Value of a `key: "value"` label line within a block.
    private static func labelValue(_ key: String, in block: String) -> String? {
        for rawLine in block.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\(key):") else { continue }
            return String(line.dropFirst(key.count + 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return nil
    }
}
