//
//  LauncherIndexWiringTests.swift
//  teemoonTests
//
//  Trust scope (d) through ProvenanceService: GLM 5.3 Flash's compose names the launcher's linux/amd64 CHILD
//  (079a14b4…), which GitHub has no attestation for; near.ai attests the OCI INDEX (91fdff3c…). Both the real
//  index attestation and the rule vectors live in conformance/nearai-trust (launcher-index-rules.json) so Android
//  can vendor the same files; the index bytes are audit's pin, launcher-index-91fdff3c.json.
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

@Suite("Trust scope — the launcher verifies through its index", .serialized)
struct LauncherIndexWiringTests {
    static let child = LauncherIndexTests.child
    static let index = LauncherIndexTests.index
    static let launcher = "docker.io/nearaidev/compose-manager-launcher"

    private func service(tags: [String: String], indexes: [String: Data], list: [String]? = ["prod"],
                         registryDown: Bool = false) throws -> (ProvenanceService, UserDefaults) {
        Hosts.reset(tags: tags, indexes: indexes, list: list, registryDown: registryDown)
        Hosts.bundle = try LauncherIndexRules.file("launcher-index-attestation-91fdff3c.json")
        _ = ProvenanceService.recentlyMissed(Self.child, now: .distantFuture)   // drops only this digest's miss
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Hosts.self]
        let name = "launcher-wiring-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (ProvenanceService(session: URLSession(configuration: config), defaults: defaults), defaults)
    }

    private func askedGitHub(about digest: String) -> Bool {
        Hosts.github.contains { $0.hasSuffix("/attestations/sha256:\(digest)") }
    }

    @Test func theMeasuredChildVerifiesThroughTheIndexNearAIAttested() async throws {
        guard let bytes = try LauncherIndexTests.indexBytes() else { return }
        let (svc, defaults) = try service(tags: ["prod": Self.index], indexes: [Self.index: bytes])

        let outcome = await svc.verify(.init(image: Self.launcher, digest: Self.child))
        guard case .verified(let repo, _, let ref, let commit, _) = outcome else {
            Issue.record("expected the child to verify through its index, got \(outcome)"); return
        }
        #expect(repo == "https://github.com/nearai/compose-manager")
        #expect(ref == "refs/heads/master")
        #expect(commit?.hasPrefix("8e07c3583909") == true)
        #expect(Hosts.registry.contains("/v2/nearaidev/compose-manager-launcher/manifests/sha256:\(Self.index)"),
                "the index is fetched by digest, not trusted by tag: \(Hosts.registry)")
        #expect(askedGitHub(about: Self.child), "the child's own attestation is asked for first")
        #expect(Hosts.github.contains("/repos/nearai/compose-manager/attestations/sha256:\(Self.index)"))
        #expect(ProvenanceService.cachedVerification(digest: Self.child, defaults: defaults) == outcome,
                "cached under the child's digest")

        let before = Hosts.github.count + Hosts.registry.count
        #expect(await svc.verify(.init(image: Self.launcher, digest: Self.child)) == outcome)
        #expect(Hosts.github.count + Hosts.registry.count == before, "a later pass is free")
    }

    @Test func anIndexWhoseBytesDoNotHashVerifiesNothing() async throws {
        guard let bytes = try LauncherIndexTests.indexBytes() else { return }
        let (svc, _) = try service(tags: ["prod": Self.index], indexes: [Self.index: bytes + Data(" ".utf8)])

        let outcome = await svc.verify(.init(image: Self.launcher, digest: Self.child))
        guard case .unverified(.fetchFailed(let why)) = outcome else {
            Issue.record("expected today's unpublished 404, got \(outcome)"); return
        }
        #expect(why.contains("404"))
        #expect(Hosts.registry.contains { $0.hasSuffix("sha256:\(Self.index)") }, "precondition: the index was read")
        #expect(!askedGitHub(about: Self.index), "an index that isn't what its digest names is never looked up")
    }

    @Test func anIndexListingTheChildOnlyForArm64VerifiesNothing() async throws {
        guard let bytes = try LauncherIndexTests.indexBytes() else { return }
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json["manifests"] = (json["manifests"] as? [[String: Any]])?.map { m in
            guard m["digest"] as? String == "sha256:" + Self.child else { return m }
            var m = m
            m["platform"] = ["os": "linux", "architecture": "arm64"]
            return m
        }
        let forged = try JSONSerialization.data(withJSONObject: json)
        let forgedDigest = Data(SHA256.hash(data: forged)).hexString
        let (svc, _) = try service(tags: ["prod": forgedDigest], indexes: [forgedDigest: forged])

        let outcome = await svc.verify(.init(image: Self.launcher, digest: Self.child))
        guard case .unverified(.fetchFailed) = outcome else {
            Issue.record("expected today's unpublished 404, got \(outcome)"); return
        }
        #expect(Hosts.registry.contains { $0.hasSuffix("sha256:\(forgedDigest)") }, "precondition: the index was read")
        #expect(!askedGitHub(about: forgedDigest), "an index without a linux/amd64 child is never looked up")
    }

    @Test func aRegistryOutageIsTransientNeverUnpublished() async throws {
        guard try LauncherIndexTests.indexBytes() != nil else { return }
        #expect(try LauncherIndexRules.cases("rule_d_registry_no_answer").map { $0["expect"] } == ["inconclusive"])
        let (svc, _) = try service(tags: [:], indexes: [:], registryDown: true)

        let outcome = await svc.verify(.init(image: Self.launcher, digest: Self.child))
        guard case .unverified(.fetchTransient) = outcome else {
            Issue.record("expected transient, got \(outcome)"); return
        }
        #expect(!ProvenanceService.recentlyMissed(Self.child), "no evidence either way: not remembered as a miss")
    }

    /// Review item provenance-dockerhub-unreachable: the outage is worded as Docker Hub's, and stays inconclusive (T2b).
    @Test func aRegistryOutageSaysDockerHubAndStaysInconclusive() async throws {
        guard try LauncherIndexTests.indexBytes() != nil else { return }
        let reasons = try #require(LauncherIndexRules.rules()["failure_reasons"] as? [String: String])
        let rule = try LauncherIndexRules.cases("rule_d_registry_no_answer")
        #expect(rule.first?["reason"] == "fetchTransient_dockerHub")
        #expect(reasons["fetchTransient_dockerHub"] == "couldn\u{2019}t reach Docker Hub (rate-limited or offline)")
        let (svc, _) = try service(tags: [:], indexes: [:], registryDown: true)
        let ref = ProvenanceService.ImageRef(image: Self.launcher, digest: Self.child)

        let outcome = await svc.verify(ref)
        #expect(outcome.failureReason == reasons["fetchTransient_dockerHub"], "\(outcome)")
        let manifest = ProvenanceService.ManifestProvenance.incomplete(
            verified: [], failures: [.init(ref: ref, reason: outcome)], thirdParty: [])
        #expect(manifest.isInconclusive && !manifest.isUnpublishedOnly, "still no evidence either way")
    }

    /// GitHub not answering for the index's own attestation keeps GitHub's words.
    @Test func gitHubDownForTheIndexAttestationStillSaysGitHub() async throws {
        guard let bytes = try LauncherIndexTests.indexBytes() else { return }
        let reasons = try #require(LauncherIndexRules.rules()["failure_reasons"] as? [String: String])
        #expect(reasons["fetchTransient_gitHub"] == "couldn\u{2019}t reach GitHub (rate-limited or offline)")
        let (svc, _) = try service(tags: ["prod": Self.index], indexes: [Self.index: bytes])
        Hosts.indexAttestationStatus = 503
        defer { Hosts.indexAttestationStatus = nil }

        let outcome = await svc.verify(.init(image: Self.launcher, digest: Self.child))
        guard case .unverified(.fetchTransient) = outcome else { Issue.record("expected transient, got \(outcome)"); return }
        #expect(outcome.failureReason == reasons["fetchTransient_gitHub"])
    }

    @Test func otherImagesNeverAskTheRegistry() async throws {
        guard let bytes = try LauncherIndexTests.indexBytes() else { return }
        let (svc, _) = try service(tags: ["prod": Self.index], indexes: [Self.index: bytes])
        let digest = String(repeating: "4", count: 64)
        let outcome = await svc.verify(.init(image: "nearaidev/compose-manager", digest: digest))
        guard case .unverified(.fetchFailed) = outcome else {
            Issue.record("expected the plain 404, got \(outcome)"); return
        }
        #expect(Hosts.registry.isEmpty, "only the launcher's repository gets the index lookup: \(Hosts.registry)")
        _ = ProvenanceService.recentlyMissed(digest, now: .distantFuture)
    }

    private func record(gpuManifest: String) -> AttestationRecord {
        var r = AttestationRecord(
            composeHash: "", mrtd: "", osImageHash: "", intelQuote: "",
            composeManifest: nil, gpuArch: nil, gpuNodeComposeHash: nil, modelFileHash: nil,
            signingAddress: nil, gpuSigningAddress: nil, modelEd25519PubKey: nil,
            quoteVerification: nil, gpuQuoteVerification: nil, modelQuoteVerification: nil,
            fetchedAt: Date(), providerID: UUID())
        r.gpuNodeComposeManifest = gpuManifest
        return r
    }

    /// The lookup runs inside one record's provenance pass: while it runs nothing is published (NeverVerifiedWhilePending),
    /// and a refresh to another record leaves its late answer inert (OldAnswerInert).
    @MainActor
    @Test func aRefreshMidLookupLeavesTheLateAnswerInertAndNothingShowsWhileItRuns() async throws {
        guard let bytes = try LauncherIndexTests.indexBytes() else { return }
        let other = String(repeating: "c", count: 64)
        Hosts.reset(tags: ["prod": LauncherIndexTests.index], indexes: [LauncherIndexTests.index: bytes],
                    list: ["prod"], registryDown: false)
        Hosts.bundle = try LauncherIndexRules.file("launcher-index-attestation-91fdff3c.json")
        Hosts.holdToken = true
        defer { Hosts.holdToken = false }
        _ = ProvenanceService.recentlyMissed(LauncherIndexTests.child, now: .distantFuture)
        _ = ProvenanceService.recentlyMissed(other, now: .distantFuture)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Hosts.self]
        let defaults = UserDefaults(suiteName: "launcher-late-\(UUID().uuidString)")!
        let s = ConfidentialSession(providers: ProviderStore(inMemory: true),
                                    provenanceService: ProvenanceService(session: URLSession(configuration: config),
                                                                         defaults: defaults))
        s.attestationTask?.cancel()
        let a = record(gpuManifest: "services:\n  launcher:\n    image: \(LauncherIndexWiringTests.launcher)@sha256:\(LauncherIndexTests.child)\n")
        let b = record(gpuManifest: "services:\n  other:\n    image: nearaidev/other@sha256:\(other)\n")

        s.verifyImageProvenance(for: a)
        for _ in 0..<400 where !Hosts.tokenHeld { try? await Task.sleep(for: .milliseconds(25)) }
        #expect(Hosts.tokenHeld, "precondition: record A's pass is inside the index lookup")
        #expect(s.imageProvenance == nil && !s.provenanceSettled, "nothing is published while the lookup runs")

        s.verifyImageProvenance(for: b)
        Hosts.holdToken = false
        for _ in 0..<400 where !s.provenanceSettled { try? await Task.sleep(for: .milliseconds(25)) }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(s.provenanceKey == ConfidentialSession.provenanceKey(for: b))
        guard case .incomplete(let verified, let failures, _) = s.imageProvenance else {
            Issue.record("expected record B's own unpublished verdict, got \(String(describing: s.imageProvenance))"); return
        }
        #expect(verified.isEmpty, "record A's launcher answer must not show on record B")
        #expect(failures.map(\.ref.digest) == [other])
        _ = ProvenanceService.recentlyMissed(other, now: .distantFuture)
    }
}

/// conformance/nearai-trust, read from the source tree (the tests that use it skip where there is none).
enum LauncherIndexRules {
    static func file(_ name: String, file: String = #filePath) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conformance/nearai-trust/\(name)"))
    }

    static func rules() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: file("launcher-index-rules.json")) as? [String: Any])
    }

    static func cases(_ rule: String) throws -> [[String: String]] {
        try #require((rules()[rule] as? [String: Any])?["cases"] as? [[String: String]])
    }

    /// `transform` from launcher-index-rules.json applied to the pinned index; returns the bytes and the digest offered.
    static func index(_ transform: String) throws -> (bytes: Data, digest: String) {
        let pinned = try file("launcher-index-91fdff3c.json")
        let child = LauncherIndexTests.child
        if transform == "none" { return (pinned, LauncherIndexTests.index) }
        if transform == "append_space" { return (pinned + Data(" ".utf8), LauncherIndexTests.index) }
        var json = try #require(JSONSerialization.jsonObject(with: pinned) as? [String: Any])
        json["manifests"] = (json["manifests"] as? [[String: Any]])?.map { m -> [String: Any] in
            guard m["digest"] as? String == "sha256:" + child else { return m }
            var m = m
            switch transform {
            case "child_platform_arm64": m["platform"] = ["os": "linux", "architecture": "arm64"]
            case "child_as_attestation_manifest": m["annotations"] = ["vnd.docker.reference.type": "attestation-manifest"]
            case "child_digest_last_hex_to_0": m["digest"] = "sha256:" + String(child.dropLast()) + "0"
            default: Issue.record("unknown transform \(transform)")
            }
            return m
        }
        let bytes = try JSONSerialization.data(withJSONObject: json)
        return (bytes, Data(SHA256.hash(data: bytes)).hexString)
    }
}

@Suite("Trust scope — launcher index rule vectors (conformance/nearai-trust)", .serialized)
struct LauncherIndexRuleVectorTests {
    @Test func ruleASignerIsTheComposeManagerBuildOnMasterNotJustTheOrg() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let signer = try #require(LauncherIndexRules.rules()["rule_a_signer"] as? [String: Any])
        #expect(signer["repository"] as? String == LauncherIndex.builderRepository)
        #expect(signer["workflow_identity"] as? String == LauncherIndex.builder)
        #expect(signer["source_ref"] as? String == LauncherIndex.builderRef)
        let reasons = try #require(LauncherIndexRules.rules()["failure_reasons"] as? [String: String])
        for c in try LauncherIndexRules.cases("rule_a_signer") {
            let given = ImageProvenance.verified(repositoryURL: c["repository"]!, workflowIdentity: c["workflow_identity"]!,
                                                 sourceRef: c["source_ref"], sourceCommit: "8e07c3583909",
                                                 transparencyLogChecked: true)
            let out = LauncherIndex.signedByItsBuilder(given)
            switch c["expect"] {
            case "verified": #expect(out == given, "\(c["name"]!)")
            case "refused":
                #expect(ConformanceAttestationVectors.reasonKind(out) == c["reason"], "\(c["name"]!): \(out)")
                #expect(out.failureReason == reasons[c["reason"] ?? ""], "\(c["name"]!)")
            default: Issue.record("unknown expectation in \(c)")
            }
        }
        // The attestation file itself verifies against the index digest and passes the pin.
        let rules = try LauncherIndexRules.rules()
        let bundle = try LauncherIndexRules.file(try #require(rules["attestation_file"] as? String))
        let real = ProvenanceVerifier().verify(attestationJSON: bundle, expectedDigest: LauncherIndexTests.index)
        guard case .verified(_, _, _, let commit, _) = real else { Issue.record("the attestation file: \(real)"); return }
        #expect(LauncherIndex.signedByItsBuilder(real) == real)
        #expect(commit == signer["source_commit_of_attestation_file"] as? String)
    }

    /// Review item provenance-wrong-build-signer: an out-of-org signer keeps its own words; an in-org signer that is not
    /// the image's build gets different ones, and both stay definitive (neither unpublished nor inconclusive).
    @Test func anInOrgSignerThatIsNotTheBuildIsWordedApartFromAnOutOfOrgOne() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let reasons = try #require(LauncherIndexRules.rules()["failure_reasons"] as? [String: String])
        #expect(reasons["identityNotThisBuild"] == "signed inside near.ai, but not by this image\u{2019}s build")
        #expect(reasons["identityNotTrusted"] == "signed by an identity outside near.ai\u{2019}s org")
        let outOfOrg = ImageProvenance.unverified(.identityNotTrusted(got: "https://github.com/someone/x/.github/workflows/b.yml@main"))
        #expect(outOfOrg.failureReason == reasons["identityNotTrusted"])

        let wrongBranch = LauncherIndex.signedByItsBuilder(.verified(
            repositoryURL: LauncherIndex.builderRepository,
            workflowIdentity: LauncherIndex.builderRepository + "/.github/workflows/build.yml@refs/heads/dev",
            sourceRef: "refs/heads/dev", sourceCommit: nil, transparencyLogChecked: true))
        #expect(wrongBranch.failureReason == reasons["identityNotThisBuild"])
        let ref = ProvenanceService.ImageRef(image: LauncherIndexWiringTests.launcher, digest: LauncherIndexTests.child)
        let manifest = ProvenanceService.ManifestProvenance.incomplete(
            verified: [], failures: [.init(ref: ref, reason: wrongBranch)], thirdParty: [])
        #expect(!manifest.isInconclusive && !manifest.isUnpublishedOnly, "a wrong-build signer is negative evidence")
    }

    @Test func rulesBAndCChildForLinuxAmd64InBytesThatHashToTheDigest() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        for rule in ["rule_b_child_linux_amd64", "rule_c_bytes_hash"] {
            for c in try LauncherIndexRules.cases(rule) {
                let (bytes, digest) = try LauncherIndexRules.index(c["transform"]!)
                let lists = LauncherIndex.indexLists(child: LauncherIndexTests.child, bytes: bytes, digest: digest)
                #expect(lists == (c["expect"] == "verified"), "\(rule): \(c["name"]!)")
            }
        }
    }
}

/// GitHub (the index bundle under nearai/compose-manager, 404 otherwise) and a scripted Docker Hub.
private final class Hosts: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bundle = Data()
    nonisolated(unsafe) static var tags: [String: String] = [:]
    nonisolated(unsafe) static var indexes: [String: Data] = [:]
    nonisolated(unsafe) static var list: [String]? = nil
    nonisolated(unsafe) static var registryDown = false
    /// When set, GitHub answers this status for the index's attestation.
    nonisolated(unsafe) static var indexAttestationStatus: Int? = nil
    /// While set, the Docker Hub token is answered only once it is cleared.
    nonisolated(unsafe) static var holdToken = false
    nonisolated(unsafe) static var tokenHeld = false
    nonisolated(unsafe) static var github: [String] = []
    nonisolated(unsafe) static var registry: [String] = []

    static func reset(tags: [String: String], indexes: [String: Data], list: [String]?, registryDown: Bool) {
        self.tags = tags; self.indexes = indexes; self.list = list; self.registryDown = registryDown
        github = []; registry = []; holdToken = false; tokenHeld = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        func reply(_ status: Int, _ body: Data = Data(), headers: [String: String] = [:]) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                                  headerFields: headers)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if url.host == "api.github.com" {
            Self.github.append(url.path)
            let hit = url.path == "/repos/nearai/compose-manager/attestations/sha256:\(LauncherIndexWiringTests.index)"
            if hit, let status = Self.indexAttestationStatus { return reply(status, headers: ["X-RateLimit-Remaining": "40"]) }
            return reply(hit ? 200 : 404, hit ? Self.bundle : Data(#"{"message":"Not Found"}"#.utf8),
                         headers: ["X-RateLimit-Remaining": "40"])
        }
        Self.registry.append(url.path)
        if Self.registryDown { return reply(503) }
        if url.host == "auth.docker.io" {
            guard Self.holdToken else { return reply(200, Data(#"{"token":"t0k"}"#.utf8)) }
            Self.tokenHeld = true
            func later() {
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) {
                    Self.holdToken ? later() : reply(200, Data(#"{"token":"t0k"}"#.utf8))
                }
            }
            return later()
        }
        if url.path.hasSuffix("/tags/list") {
            guard let list = Self.list else { return reply(500) }
            return reply(200, try! JSONSerialization.data(withJSONObject: ["tags": list]))
        }
        let ref = url.lastPathComponent
        if ref.hasPrefix("sha256:") {
            guard let data = Self.indexes[String(ref.dropFirst(7))] else { return reply(404) }
            return reply(200, data)
        }
        guard let digest = Self.tags[ref] else { return reply(404) }
        reply(200, headers: ["Docker-Content-Digest": "sha256:" + digest])
    }
}
