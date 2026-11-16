//
//  ActiveInfrastructureTests.swift
//  teemoonTests
//
//  The sheet's "running now, per the action log" list shows active infrastructure only (decided 2026-11-08):
//  the rows the log vouches for, plus this chat's path. Vectors: conformance/nearai-trust expected.json
//  sheet_rows. Before this, the 2026-11-08 glm-5-3-flash sheet listed all 20 never-closed services, among them
//  GLM 5.2's 2 Oct proxy and engines, the 21 Oct canary set and a 23 Sep TP4 pair, each "can't tell whether
//  this is still running", beside the four live engines. When the path can't be derived the whole list stays:
//  "can't tell" is then the state. Compose revisions the kit lacks are in
//  Fixtures/nearai_actionlog_revisions_20261108.json, hash-checked against the log.
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

@Suite("Active infrastructure — the sheet's running list")
@MainActor
struct ActiveInfrastructureTests {
    struct Revisions: Decodable { let services: [String: [String]]; let bodies: [String: String] }

    static func revisions() throws -> Revisions {
        try JSONDecoder().decode(Revisions.self, from: TestFixture.data("nearai_actionlog_revisions_20261108.json"))
    }

    static func body(_ s: ActionLogReading.Source, _ extra: Revisions) -> String? {
        let text = ChatPathTests.body(s) ?? extra.bodies["\(s.commit)/\(s.file)"]
        guard let text else { return nil }
        return s.fileSHA256.isEmpty || Data(SHA256.hash(data: Data(text.utf8))).hexString == s.fileSHA256 ? text : nil
    }

    struct Case {
        let name: String
        let actions: [[String: Any]]
        let model: String
        let host: String
        let rows: [[String: Any]]
        let path: [String]?
    }

    static func cases() throws -> [Case]? {
        guard TestFixture.sourceTreeAvailable() else { return nil }
        let expected = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: ChatPathTests.kit.appendingPathComponent("expected.json"))) as? [String: Any])
        let sheet = try #require((expected["sheet_rows"] as? [String: Any])?["cases"] as? [[String: Any]])
        return try sheet.map { c in
            let file = try #require((c["log"] as? [String: Any])?["file"] as? String)
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: ChatPathTests.kit.appendingPathComponent(file)))
            let report = json as? [String: Any]
            let log = report.map { ($0["compose_manager_attestation"] as? [String: Any])?["actions"] } ?? json
            let actions = try #require(log as? [[String: Any]])
            let host = try #require(c["host"] as? String)
            // The small-models log is a bare log: the model is the one its Qwen3.8 host serves.
            let model = report?["model_name"] as? String ?? (file.contains("5e513dbd72e1") ? "Qwen/Qwen3.8-27B" : "z-ai/glm-5.3-flash")
            return Case(name: try #require(c["name"] as? String), actions: actions, model: model, host: host,
                        rows: (c["rows"] as? [[String: Any]] ?? []) + (c["dropped"] as? [[String: Any]] ?? []),
                        path: c["path"] as? [String])
        }
    }

    static func scope(_ c: Case, _ extra: Revisions, host: String? = nil,
                      outcome: (ActionLogReading.Source) -> RunningPairCheck.Outcome = { _ in .verified }) -> TrustScope {
        let kitNames = ActionLogReadingTests.vendoredServices()
        let sources = Set(ActionLogReading.wholeFileSources(actions: c.actions) + ActionLogReading.upRevisionSources(actions: c.actions))
        var names: [ActionLogReading.Source: [String]] = [:]
        for s in sources { names[s] = extra.services["\(s.commit)/\(s.file)"] ?? kitNames(s) }
        let services = ActionLogReading.runningServices(actions: c.actions) { names[$0] }
        var texts: [ActionLogReading.Source: String] = [:]
        for s in services { texts[s.source] = body(s.source, extra) }
        let pairs = ActionLogReading.pairsToCheck(services)
        let outcomes = pairs.check.map { ($0, outcome($0)) } + pairs.notFetched.map { ($0, RunningPairCheck.Outcome.notFetched) }
        var scope = TrustScope(binding: .bound, boot: .matches)
        (scope.running, scope.chatPath) = TrustScope.runningSection(
            actions: c.actions, services: services, names: names, texts: texts,
            outcomes: outcomes, model: c.model, host: host ?? c.host)
        return scope
    }

    struct Row: Hashable { let service, commit, file, sha: String }

    static func row(_ r: TrustScope.RunningRow) -> Row {
        Row(service: r.service.service, commit: r.service.source.commit, file: r.service.source.file, sha: r.service.source.fileSHA256)
    }

    /// sheet_rows.cases: shown rows by (service, commit, file, file_sha256); "none" rows are dropped.
    @Test func everySheetCaseShowsItsRows() throws {
        guard let cases = try Self.cases() else { return }
        let extra = try Self.revisions()
        #expect(cases.count == 5)
        for c in cases {
            let scope = Self.scope(c, extra)
            let want = c.rows.map { Row(service: $0["service"] as? String ?? "", commit: $0["commit"] as? String ?? "",
                                        file: $0["file"] as? String ?? "", sha: $0["file_sha256"] as? String ?? "") }
            let shownBy = c.rows.map { $0["shown_by"] as? String ?? "" }
            let shown = Set(zip(want, shownBy).filter { $0.1 != "none" }.map(\.0))
            #expect(Set(scope.running.map(Self.row)) == Set(want), "\(c.name): the log's running table")
            #expect(Set(scope.activeRunning.map(Self.row)) == shown, "\(c.name): the sheet")
            if let path = c.path {
                guard case .path(let hops) = scope.chatPath else { Issue.record("\(c.name): \(String(describing: scope.chatPath))"); continue }
                #expect(hops.map(\.service) == path, "\(c.name)")
                // Each hop wears its own attributing revision, never the proxy's.
                for hop in hops {
                    #expect(scope.running.contains { $0.service.service == hop.service && $0.service.source == hop.source }, "\(c.name) \(hop.service)")
                }
            } else {
                guard case .ambiguous = scope.chatPath else { Issue.record("\(c.name) resolved"); continue }
                #expect(scope.activeRunning == scope.running, "\(c.name): ambiguous keeps the full list")
            }
        }
    }

    static func glm1108() throws -> Case? {
        try cases()?.first { $0.name.hasPrefix("the other glm-5-3-flash CVM") }
    }

    @Test func todaysGLMDropsTheDeadSets() throws {
        guard let c = try Self.glm1108() else { return }
        let scope = Self.scope(c, try Self.revisions())
        #expect(scope.running.count == 20)
        #expect(scope.activeRunning.count == 8)
        let shown = Set(scope.activeRunning.map(\.service.service))
        for dead in ["proxy-glm52", "model-sg-glm52-w4a-tp4-r1", "dcgm-glm52", "model-sg-glm53-w4afp8-tp4-r1",
                     "glm53-ghost-aggregator", "glm53-soak-relay", "otelcol-contrib"] {
            #expect(!shown.contains(dead), "\(dead)")
        }
        let engine = try #require(scope.activeRunning.first { $0.service.service == "model-sg-glm53-w4afp8-tp2-r1" })
        #expect(engine.service.source.commit.hasPrefix("7ee4a4c7"), "the engine's own revision, not the proxy's 5a5119f7")
        #expect(engine.undecidable, "liveness semantics unchanged: the path shows it, the log still can't vouch")
    }

    @Test func anUnreadRunningRevisionKeepsTheWholeList() throws {
        guard let c = try Self.glm1108() else { return }
        var extra = try Self.revisions()
        extra = Revisions(services: extra.services, bodies: extra.bodies.filter { !$0.key.contains("GLM-5.2") })
        let scope = Self.scope(c, extra)
        guard case .ambiguous = scope.chatPath else { Issue.record("an unread revision resolved"); return }
        #expect(scope.activeRunning == scope.running)

        var unbound = Self.scope(c, try Self.revisions())
        unbound.chatPath = nil
        #expect(unbound.activeRunning == unbound.running, "an unbound log has no path")
    }

    /// Display only: every attributed pair is still hash-checked, and a stale one that fails still breaks.
    @Test func aStalePairsMismatchStillBreaksWhenItsRowIsHidden() throws {
        guard let c = try Self.glm1108() else { return }
        let scope = Self.scope(c, try Self.revisions()) { $0.file.hasPrefix("prod/GLM-5.2") ? .mismatch : .verified }
        #expect(scope.running.contains { $0.outcome == .mismatch }, "precondition: GLM 5.2's pair is within the cap")
        #expect(!scope.activeRunning.contains { $0.outcome == .mismatch })
        #expect(scope.runningMismatch)
        #expect(scope.hardBreak)
    }

    // MARK: routers (rule iii)

    static func compose(proxyBackends: String, extra: String = "") -> String {
        """
        services:
          nginx:
            image: nginx@sha256:\(String(repeating: "a", count: 64))
            ports:
              - "443:443"
            configs:
              - source: nginx_conf
          proxy:
            image: nearaidev/vllm-proxy-rs@sha256:\(String(repeating: "b", count: 64))
            environment:
              - MODEL_NAME=m
              - VLLM_BACKEND_URLS=\(proxyBackends)
        \(extra)
        configs:
          nginx_conf:
            content: |
              server {
                  listen 443 ssl;
                  server_name m.completions.near.ai;
                  location / { proxy_pass http://proxy:8000; }
              }
        """
    }

    static func router(_ name: String, to next: String) -> String {
        """
          \(name):
            image: nearaidev/vllm-proxy-rs@sha256:\(String(repeating: "c", count: 64))
            environment:
              VLLM_BASE_URL: \(next)
        """
    }

    static let engineBlock = """
      engine:
        image: lmsysorg/sglang@sha256:\(String(repeating: "d", count: 64))
    """

    static func resolve(_ text: String) -> ChatPath.Result {
        let source = ActionLogReading.Source(commit: "c1", file: "prod/m.yaml", fileSHA256: "")
        let running = ChatPath.Compose(text).services.keys.sorted().map {
            ActionLogReading.RunningService(service: $0, source: source, tag: nil, since: nil)
        }
        return ChatPath.resolve(host: "m.completions.near.ai", running: running) { _ in text }
    }

    @Test func routersAreFollowedToTheEngine() {
        let one = Self.compose(proxyBackends: "http://filter:8000",
                               extra: Self.router("filter", to: "http://engine:8000") + "\n" + Self.engineBlock)
        #expect(Self.resolve(one).services == ["nginx", "proxy", "filter", "engine"])

        let deepest = Self.compose(proxyBackends: "http://r1:8000", extra: [
            Self.router("r1", to: "http://r2:8000"), Self.router("r2", to: "http://engine:8000"), Self.engineBlock,
        ].joined(separator: "\n"))
        #expect(Self.resolve(deepest).services == ["nginx", "proxy", "r1", "r2", "engine"], "four hops")

        let tooDeep = Self.compose(proxyBackends: "http://r1:8000", extra: [
            Self.router("r1", to: "http://r2:8000"), Self.router("r2", to: "http://r3:8000"),
            Self.router("r3", to: "http://engine:8000"), Self.engineBlock,
        ].joined(separator: "\n"))
        guard case .ambiguous = Self.resolve(tooDeep) else { Issue.record("five hops resolved"); return }

        let overridden = Self.compose(proxyBackends: "http://filter:8000",
                                      extra: Self.router("filter", to: "${UPSTREAM}") + "\n" + Self.engineBlock)
        guard case .ambiguous = Self.resolve(overridden) else { Issue.record("an unrecorded router override resolved"); return }

        let undefined = Self.compose(proxyBackends: "http://filter:8000", extra: Self.router("filter", to: "http://ghost:8000"))
        guard case .ambiguous = Self.resolve(undefined) else { Issue.record("an undefined upstream resolved"); return }
    }
}
