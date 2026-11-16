//
//  ChatPathTests.swift
//  teemoonTests
//
//  expected.json chat_path (audit 2026-11-06): the small-models CVM's signed log and running revisions,
//  per host. A Qwen3.8 chat is off FLUX's path, so FLUX's recipe LEAKS pages don't judge it; a FLUX request
//  is on it. Anything unresolvable counts every LEAKS page.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Chat path — per host, from the signed log")
@MainActor
struct ChatPathTests {
    nonisolated static let kit = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("conformance/nearai-trust")

    static func fixture() throws -> (cases: [[String: Any]], actions: [[String: Any]])? {
        guard TestFixture.sourceTreeAvailable() else { return nil }
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: kit.appendingPathComponent("expected.json"))) as? [String: Any]
        let chatPath = try #require(expected?["chat_path"] as? [String: Any])
        let log = try #require((chatPath["log"] as? [String: Any])?["file"] as? String)
        let actions = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: kit.appendingPathComponent(log))) as? [[String: Any]])
        return (try #require(chatPath["cases"] as? [[String: Any]]), actions)
    }

    nonisolated static func body(_ s: ActionLogReading.Source) -> String? {
        try? String(contentsOf: kit.appendingPathComponent("compose-files/\(s.commit)/\(s.file)"), encoding: .utf8)
    }

    static func running(_ actions: [[String: Any]]) -> [ActionLogReading.RunningService] {
        ActionLogReading.runningServices(actions: actions, servicesIn: ActionLogReadingTests.vendoredServices())
    }

    @Test func eachHostGetsAuditsPath() throws {
        guard let f = try Self.fixture() else { return }
        let running = Self.running(f.actions)
        #expect(f.cases.count == 2)
        for c in f.cases {
            let host = try #require(c["host"] as? String)
            let want = try #require(c["path"] as? [String])
            guard case .path(let hops) = ChatPath.resolve(host: host, running: running, body: Self.body) else {
                Issue.record("\(host): \(ChatPath.resolve(host: host, running: running, body: Self.body))"); continue
            }
            #expect(hops.map(\.service) == want, "\(host)")
            for (hop, key) in zip(hops, ["ingress", "proxy"]) {
                let rev = try #require((c[key] as? [String: Any])?["revision"] as? String)
                #expect(hop.source.fileSHA256.hasPrefix(rev), "\(host) \(key) revision")
            }
            let engines = try #require(c["engines"] as? [[String: Any]])
            for (hop, e) in zip(hops.dropFirst(2), engines) {
                #expect(hop.source.fileSHA256.hasPrefix(try #require(e["revision"] as? String)), "\(host) engine revision")
            }
        }
    }

    @Test func theEngineImageIsItsOwnOrItsBuildsBase() throws {
        guard let f = try Self.fixture() else { return }
        let running = Self.running(f.actions)
        guard case .path(let flux) = ChatPath.resolve(host: "flux2-klein.completions.near.ai", running: running, body: Self.body),
              case .path(let qwen) = ChatPath.resolve(host: "qwen3-8-27b.completions.near.ai", running: running, body: Self.body) else {
            Issue.record("paths didn't resolve"); return
        }
        #expect(flux.last?.image?.digest == "8ece90ad52faa8b56149f0117227d9009db34513213e35990da468aeb6fe0b75", "FLUX's FROM base")
        #expect(qwen.last?.image?.digest.hasPrefix("febfb971") == true)
        #expect(qwen[1].image?.digest.hasPrefix("0be4ee8f") == true, "the proxy image")
    }

    /// The rollup judges a chat by its own path: FLUX's recipe pages count for a FLUX request, not a Qwen chat.
    @Test func aSiblingsLeakDoesNotJudgeThisChat() throws {
        guard let f = try Self.fixture() else { return }
        let running = Self.running(f.actions)
        let flux = ChatPath.resolve(host: "flux2-klein.completions.near.ai", running: running, body: Self.body)
        let qwen = ChatPath.resolve(host: "qwen3-8-27b.completions.near.ai", running: running, body: Self.body)
        let pages = ["320afade84f1606bda2c473ec0d09d3b6cd745038133bf353252f2683cc24eba",
                     "dfac289866183c8fdd21606a0c431f7a5e8b240f2aeeb939461b823aec9541ac",
                     "68b80451c141f21eab9f80302e60f48857ddf2d6304b485327c23abe8c9423b2"]
        let file = "prod/small-models.yaml"
        let key = "\(ProvenanceService.modelComposeRepo)/\(file)"
        let page = { (sha: String) in "manifests/nearai/cvm-compose-files/prod/small-models/sha256-\(sha).md" }
        var classes: [String: String] = [:]
        var exposure: [String: AuditIndex.Exposure] = [:]
        for sha in pages.prefix(2) {
            classes[page(sha)] = "leaks"
            exposure[page(sha)] = .init(summary: "the FLUX service logs every prompt.", scope_kind: "recipe",
                                        services: ["model-sg-flux2-klein-4b-tp1"])
        }
        classes[page(pages[2])] = "private"
        let index = AuditIndex.Index(schema: 1, images: [:], sources: nil, projects: nil, tagAudits: nil,
                                     manifests: [key: pages], measured: [], os: [], verdicts: nil,
                                     verdictClass: classes, exposure: exposure)
        let audit = AuditIndex(fixedIndex: index)
        let newest = try #require(audit.manifestAuditURL(path: file, fileSHA256: pages[0]))
        let classesFor = { (path: ChatPath.Result) in
            ModelNodeAudit.onPath([newest], chatPath: path, runningSources: [], audit: audit).map { audit.verdictClass(for: $0) }
        }
        #expect(!classesFor(qwen).contains(.leaks), "a Qwen3.8 chat isn't judged by FLUX's leak")
        #expect(classesFor(qwen).contains(.privateReview), "its own engine's revision still judges it")
        #expect(classesFor(flux).filter { $0 == .leaks }.count == 2, "320afade and dfac2898 both count for FLUX")
        let unsure = ModelNodeAudit.onPath([], chatPath: .ambiguous("no server_name"),
                                           runningSources: running.map(\.source), audit: audit)
        #expect(unsure.filter { audit.verdictClass(for: $0) == .leaks }.count == 2, "ambiguous: every LEAKS page counts")
    }

    @Test func anUnknownHostOrAnOverriddenBackendIsAmbiguous() throws {
        guard let f = try Self.fixture() else { return }
        let running = Self.running(f.actions)
        guard case .ambiguous = ChatPath.resolve(host: "nobody.completions.near.ai", running: running, body: Self.body) else {
            Issue.record("an unknown host resolved"); return
        }
        guard case .ambiguous = ChatPath.resolve(host: "qwen3-8-27b.completions.near.ai", running: running, body: { _ in nil }) else {
            Issue.record("unread files resolved"); return
        }
        let override = """
        services:
          proxy:
            environment:
              - VLLM_BACKEND_URLS=${VLLM_BACKEND_URLS}
        """
        #expect(ChatPath.Compose(override).services["proxy"]?.backendURLs == nil, "an override the log can't show")
        let defaulted = override.replacingOccurrences(of: "${VLLM_BACKEND_URLS}", with: "${VLLM_BACKEND_URLS:-http://e1:8000,http://e2:8000}")
        #expect(ChatPath.Compose(defaulted).services["proxy"]?.backendURLs == ["http://e1:8000", "http://e2:8000"])
    }

    /// The same pins as android (26858d9a): underscores and case are kept; only http(s) names a service.
    @Test func aBackendURLNamesItsServiceExactly() {
        #expect(ChatPath.serviceName(fromURL: "http://model_sg_x:8000") == "model_sg_x")
        #expect(ChatPath.serviceName(fromURL: "http://Model.Engine_2:9000") == "Model.Engine_2")
        #expect(ChatPath.serviceName(fromURL: "unix:///run/engine.sock") == nil)
    }

    @Test func serverNamesMatchExactlyOrByRegex() {
        let conf = """
        server {
            listen 443 ssl http2;
            server_name a.completions.near.ai
                        ~^a-i\\d+\\.completions(-stg)?\\.near\\.ai$;
            location ^~ /metrics { return 404; }
            location / { set $up http://proxy-a:8000; proxy_pass $up; }
        }
        """
        #expect(ChatPath.Nginx.proxyTarget(in: conf, host: "a.completions.near.ai") == "http://proxy-a:8000")
        #expect(ChatPath.Nginx.proxyTarget(in: conf, host: "a-i3.completions-stg.near.ai") == "http://proxy-a:8000")
        #expect(ChatPath.Nginx.proxyTarget(in: conf, host: "b.completions.near.ai") == nil)
    }
}
