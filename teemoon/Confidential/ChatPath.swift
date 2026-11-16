//
//  ChatPath.swift
//  teemoon
//
//  Which running services a chat's request passes through on a CVM, per the HOST the app connected to
//  (audit 2026-11-06, conformance/nearai-trust expected.json chat_path): nginx's server_name → its
//  `location /` proxy_pass → the proxy's VLLM_BACKEND_URLS / VLLM_BASE_URL, through routers. Never per model id: two proxies
//  on one node can declare the same MODEL_NAME. Anything it can't pin down is `.ambiguous`, and the
//  caller then counts every LEAKS page on the CVM.
//

import Foundation

enum ChatPath {
    struct Hop: Equatable, Sendable {
        let service: String
        let source: ActionLogReading.Source
        /// The image the service runs: its own `image:`, or a build's last FROM.
        let image: ProvenanceService.ImageRef?
    }

    enum Result: Equatable, Sendable {
        case path([Hop])
        case ambiguous(String)

        var services: Set<String>? {
            if case .path(let hops) = self { return Set(hops.map(\.service)) }
            return nil
        }
    }

    static func resolve(host: String, running: [ActionLogReading.RunningService],
                        body: (ActionLogReading.Source) -> String?) -> Result {
        var bySource: [String: ActionLogReading.Source] = [:]
        for r in running where !r.service.isEmpty { bySource[r.service] = r.source }
        let host = host.lowercased()

        // (1) Ingress: a running service with published ports whose mounted nginx config serves HOST.
        var matches: [(ingress: String, target: String)] = []
        for source in Set(bySource.values) {
            guard let text = body(source) else { return .ambiguous("a running revision's file is unread") }
            let compose = Compose(text)
            for (name, block) in compose.services where bySource[name] == source && block.hasPorts {
                for config in block.configSources {
                    guard let conf = compose.configs[config] else { continue }
                    if let target = Nginx.proxyTarget(in: conf, host: host) { matches.append((name, target)) }
                }
            }
        }
        guard let first = matches.first else { return .ambiguous("no server_name matches \(host)") }
        guard matches.allSatisfy({ $0.target == first.target && $0.ingress == first.ingress }) else {
            return .ambiguous("several server blocks match \(host)")
        }
        guard let proxy = serviceName(fromURL: first.target) else { return .ambiguous("unresolvable proxy_pass") }

        // (2) Engines: each hop's backend list (a literal or a ${VAR:-literal} default), followed through routers
        // (3) to an engine; every hop wears its OWN attributing revision and the image it runs.
        guard case let (ingress, _)? = hop(first.ingress, bySource: bySource, body: body) else {
            return .ambiguous("\(first.ingress) has no attributed revision")
        }
        var hops = [ingress]
        var seen: Set<String> = [first.ingress, proxy]
        var frontier = [proxy]
        var depth = 1
        while !frontier.isEmpty {
            var next: [String] = []
            for name in frontier {
                guard case let (h, backends)? = hop(name, bySource: bySource, body: body) else {
                    return .ambiguous("\(name) has no attributed revision")
                }
                hops.append(h)
                switch backends {
                case .none where name == proxy: return .ambiguous("the proxy has no backend list")
                case .none: continue
                case .unreadable: return .ambiguous("\(name)'s backend list isn't a literal")
                case .urls(let urls):
                    let upstream = urls.compactMap(serviceName(fromURL:))
                    guard !upstream.isEmpty, upstream.count == urls.count else { return .ambiguous("unreadable backend URL") }
                    next += upstream.filter { seen.insert($0).inserted }
                }
            }
            if !next.isEmpty { depth += 1 }
            guard depth <= maxDepth else { return .ambiguous("more than \(maxDepth) hops") }
            frontier = next
        }
        return .path(hops)
    }

    /// Edges from the ingress to the deepest engine; a longer chain is ambiguous.
    static let maxDepth = 4

    private static func hop(_ name: String, bySource: [String: ActionLogReading.Source],
                            body: (ActionLogReading.Source) -> String?) -> (Hop, Compose.Service.Backends)? {
        guard let source = bySource[name], let text = body(source), let block = Compose(text).services[name] else { return nil }
        return (Hop(service: name, source: source, image: block.image), block.backends)
    }

    /// "http://proxy-qwen38-27b:8000/v1" → "proxy-qwen38-27b".
    static func serviceName(fromURL url: String) -> String? {
        guard let comps = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
              comps.scheme == "http" || comps.scheme == "https", let host = comps.host, !host.isEmpty else { return nil }
        return host
    }

    // MARK: Compose, as far as the path needs it

    struct Compose {
        struct Service {
            let text: String
            var hasPorts: Bool { text.range(of: "(?m)^\\s+ports:", options: .regularExpression) != nil }
            var configSources: [String] {
                matches(of: "(?m)^\\s*-\\s*source:\\s*([A-Za-z0-9_.-]+)", in: text)
            }
            enum Backends: Equatable { case none, unreadable, urls([String]) }
            /// VLLM_BACKEND_URLS, else VLLM_BASE_URL. `.unreadable` when only an unrecorded override.
            var backends: Backends {
                for key in ["VLLM_BACKEND_URLS", "VLLM_BASE_URL"] {
                    guard let raw = envValue(key) else { continue }
                    guard let value = literal(raw) else { return .unreadable }
                    return .urls(value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
                }
                return .none
            }
            var backendURLs: [String]? { if case .urls(let u) = backends { u } else { nil } }
            var image: ProvenanceService.ImageRef? {
                if let line = text.components(separatedBy: "\n").first(where: {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("image:")
                }), let ref = ProvenanceService.imageRefs(inManifest: line).first { return ref }
                let froms = text.components(separatedBy: "\n").filter {
                    $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("FROM ")
                }
                return froms.last.flatMap { ProvenanceService.imageRefs(inManifest: $0).first }
            }
            /// The MODEL_NAME a proxy declares, when it's a literal.
            var modelName: String? { envValue("MODEL_NAME").flatMap(literal) }
            private func envValue(_ key: String) -> String? {
                let pattern = "(?m)^\\s*(?:-\\s*)?\(key)\\s*[=:]\\s*(.+?)\\s*$"
                return matches(of: pattern, in: text).first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            }
            /// "x" → x; "${VAR:-x}" → x; "${VAR}" → nil (an override the log doesn't record).
            private func literal(_ value: String) -> String? {
                guard value.contains("${") else { return value }
                guard let r = value.range(of: "^\\$\\{[A-Za-z0-9_]+:-(.*)\\}$", options: .regularExpression) else { return nil }
                let inner = String(value[r])
                guard let dash = inner.range(of: ":-") else { return nil }
                let v = String(inner[dash.upperBound...].dropLast())
                return v.contains("${") ? nil : v
            }
        }

        let services: [String: Service]
        let configs: [String: String]

        init(_ input: String) {
            let yaml = PlaintextExposure.dockerComposeYAML(from: input)
            let anchors = PlaintextExposure.anchorBlocks(in: yaml)
            var services: [String: Service] = [:]
            for block in PlaintextExposure.serviceBlocks(in: yaml) {
                let header = block.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
                guard header.hasSuffix(":") else { continue }
                services[String(header.dropLast())] = Service(text: Self.expandFully(block, anchors: anchors))
            }
            self.services = services
            configs = Self.configContents(in: yaml)
        }

        /// Anchors can merge anchors: expand until nothing new appears.
        static func expandFully(_ block: String, anchors: [String: String]) -> String {
            var text = block
            for _ in 0..<8 {
                let next = PlaintextExposure.expand(text, anchors: anchors)
                if next == text { break }
                text = next
            }
            return text
        }

        /// Top-level `configs:` → name → its `content: |` text, compose's `$$` unescaped.
        static func configContents(in yaml: String) -> [String: String] {
            let lines = yaml.components(separatedBy: "\n")
            guard let start = lines.firstIndex(where: { $0.hasPrefix("configs:") }) else { return [:] }
            var out: [String: String] = [:]
            var name: String?
            var body: [String] = []
            var contentIndent: Int?
            func flush() {
                if let name, !body.isEmpty { out[name] = body.joined(separator: "\n").replacingOccurrences(of: "$$", with: "$") }
                body = []; contentIndent = nil
            }
            for line in lines[(start + 1)...] {
                let indent = line.prefix { $0 == " " }.count
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, indent == 0 { break }
                if indent == 2, trimmed.hasSuffix(":"), !trimmed.hasPrefix("#") {
                    flush(); name = String(trimmed.dropLast()); continue
                }
                if contentIndent == nil {
                    if trimmed.hasPrefix("content:") { contentIndent = indent + 2 }
                    continue
                }
                if let ci = contentIndent, trimmed.isEmpty || indent >= ci { body.append(String(line.dropFirst(min(ci, indent)))) }
            }
            flush()
            return out
        }
    }

    // MARK: nginx, as far as the path needs it

    enum Nginx {
        /// The `location /` target of the server block whose server_name matches `host`, if one does.
        static func proxyTarget(in conf: String, host: String) -> String? {
            for server in blocks(named: "server", in: conf) where serverNames(server).contains(where: { matches($0, host) }) {
                for location in blocks(named: "location /", in: server) {
                    guard let pass = directive("proxy_pass", in: location) else { continue }
                    if pass.hasPrefix("$") {
                        let variable = NSRegularExpression.escapedPattern(for: pass)
                        let set = ChatPath.matches(of: "set\\s+\(variable)\\s+([^;\\s]+)\\s*;", in: location + "\n" + server)
                        return set.first
                    }
                    return pass
                }
            }
            return nil
        }

        /// The `{…}` bodies of every `name {` at any depth, braces balanced. "location /" matches only the
        /// bare prefix location, never `location ^~ /x` or `location = /x`.
        static func blocks(named name: String, in text: String) -> [String] {
            let pattern = "(?m)(^|[;{\\s])" + NSRegularExpression.escapedPattern(for: name).replacingOccurrences(of: " ", with: "\\s+") + "\\s*\\{"
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            let ns = text as NSString
            var out: [String] = []
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var depth = 0
                var i = m.range.location + m.range.length - 1
                let open = i
                while i < ns.length {
                    let c = ns.character(at: i)
                    if c == 123 { depth += 1 } else if c == 125 { depth -= 1; if depth == 0 { break } }
                    i += 1
                }
                guard i < ns.length else { continue }
                out.append(ns.substring(with: NSRange(location: open + 1, length: i - open - 1)))
            }
            return out
        }

        static func serverNames(_ server: String) -> [String] {
            guard let value = directive("server_name", in: server, topLevelOnly: true) else { return [] }
            return value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }

        static func matches(_ name: String, _ host: String) -> Bool {
            if name.hasPrefix("~") {
                let pattern = String(name.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
                return re.firstMatch(in: host, range: NSRange(location: 0, length: (host as NSString).length)) != nil
            }
            return name.lowercased() == host
        }

        /// A directive's value up to its `;`, comments dropped, across lines.
        static func directive(_ name: String, in block: String, topLevelOnly: Bool = false) -> String? {
            var text = block.components(separatedBy: "\n").map { line in
                line.range(of: "#").map { String(line[..<$0.lowerBound]) } ?? line
            }.joined(separator: "\n")
            if topLevelOnly { text = stripNestedBlocks(text) }
            let found = ChatPath.matches(of: "(?:^|[;{\\s])\(name)\\s+([^;]+);", in: text)
            return found.first?.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }

        private static func stripNestedBlocks(_ text: String) -> String {
            var out = ""; var depth = 0
            for c in text {
                if c == "{" { depth += 1; continue }
                if c == "}" { depth -= 1; continue }
                if depth == 0 { out.append(c) }
            }
            return out
        }
    }

    static func matches(of pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }
}
