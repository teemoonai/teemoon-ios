//
//  ImageProvenanceTests.swift
//  teemoonTests
//
//  Exercises the provenance verifier against a REAL GitHub Artifact
//  Attestation captured from nearai/cloud-api (Fixtures/), so the DSSE
//  signature, Sigstore cert chain, SAN identity, and subject-digest checks
//  all run against genuine production data.
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

@Suite("ImageProvenance")
struct ImageProvenanceTests {

    /// Digest the fixture attestation was issued for.
    static let fixtureDigest = "ac8a539ce1ac9ae3ebd0dfcffdba18effaaedfa69685fce220e3b3a35357e326"

    private func loadFixture(_ name: String, file: String = #filePath) throws -> Data {
        return try TestFixture.data(name, file: file)
    }

    @Test func realAttestation_verifies() throws {
        let json = try loadFixture("nearai_cloudapi_attestation.json")
        let result = ProvenanceVerifier().verify(attestationJSON: json, expectedDigest: Self.fixtureDigest)
        guard case .verified(let repo, let identity, let ref, let commit, let tlog) = result else {
            Issue.record("expected .verified, got \(result)")
            return
        }
        #expect(repo == "https://github.com/nearai/cloud-api")
        #expect(identity == "https://github.com/nearai/cloud-api/.github/workflows/build.yml@refs/heads/main")
        // Source version + commit come from the signed SLSA payload.
        #expect(ref == "refs/heads/main")
        #expect(commit == "84367f0253fa94aa6816d64210e5812215ee2622")
        // Rekor SET verified against the pinned Rekor key + payloadHash binding.
        #expect(tlog == true)
    }

    @Test func wrongDigest_isDigestMismatch() throws {
        let json = try loadFixture("nearai_cloudapi_attestation.json")
        let result = ProvenanceVerifier().verify(
            attestationJSON: json,
            expectedDigest: String(repeating: "00", count: 32))
        guard case .unverified(.digestMismatch) = result else {
            Issue.record("expected .digestMismatch, got \(result)")
            return
        }
    }

    @Test func orgPolicy_extractsRepoOnlyForDirectWorkflowIdentities() {
        let policy = BuildIdentityPolicy(organizationURL: "https://github.com/nearai")
        // Any repo directly under the org, any workflow file, any ref.
        #expect(policy.repository(forIdentity: "https://github.com/nearai/dstack-vpc-client/.github/workflows/build.yml@refs/heads/main")
                == "https://github.com/nearai/dstack-vpc-client")
        // Other orgs — including prefix-crafted names — are rejected.
        #expect(policy.repository(forIdentity: "https://github.com/nearai-evil/x/.github/workflows/build.yml@main") == nil)
        #expect(policy.repository(forIdentity: "https://github.com/someone/else/.github/workflows/build.yml@main") == nil)
        // Non-workflow identities under the org are rejected.
        #expect(policy.repository(forIdentity: "https://github.com/nearai/x") == nil)
        #expect(policy.repository(forIdentity: "https://github.com/nearai//.github/workflows/build.yml@main") == nil)
    }

    @Test func untrustedRepo_isIdentityNotTrusted() throws {
        let json = try loadFixture("nearai_cloudapi_attestation.json")
        let verifier = ProvenanceVerifier(policies: [
            BuildIdentityPolicy(organizationURL: "https://github.com/someone")
        ])
        let result = verifier.verify(attestationJSON: json, expectedDigest: Self.fixtureDigest)
        guard case .unverified(.identityNotTrusted(let got)) = result else {
            Issue.record("expected .identityNotTrusted, got \(result)")
            return
        }
        #expect(got.hasPrefix("https://github.com/nearai/cloud-api"))
    }

    @Test func tamperedSignature_isSignatureInvalid() throws {
        let json = try loadFixture("nearai_cloudapi_attestation.json")
        // Flip a base64 char inside the DSSE signature so it decodes but fails verify.
        var obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        var attestations = obj["attestations"] as! [[String: Any]]
        var bundle = attestations[0]["bundle"] as! [String: Any]
        var env = bundle["dsseEnvelope"] as! [String: Any]
        var sigs = env["signatures"] as! [[String: Any]]
        let sig = sigs[0]["sig"] as! String
        let flipped = String(sig.dropLast(4)) + (sig.hasSuffix("AAAA") ? "BBBB" : "AAAA")
        sigs[0]["sig"] = flipped
        env["signatures"] = sigs; bundle["dsseEnvelope"] = env
        attestations[0]["bundle"] = bundle; obj["attestations"] = attestations
        let tampered = try JSONSerialization.data(withJSONObject: obj)

        let result = ProvenanceVerifier().verify(attestationJSON: tampered, expectedDigest: Self.fixtureDigest)
        guard case .unverified = result else {
            Issue.record("tampered signature must not verify, got \(result)")
            return
        }
    }

    @Test func emptyBundle_isMalformed() {
        let result = ProvenanceVerifier().verify(
            attestationJSON: Data(#"{"attestations":[]}"#.utf8),
            expectedDigest: Self.fixtureDigest)
        guard case .unverified(.malformedBundle) = result else {
            Issue.record("expected .malformedBundle, got \(result)")
            return
        }
    }

    @Test func sanExtraction_returnsWorkflowURI() throws {
        // Pull the leaf cert DER out of the fixture and check the SAN walk.
        let json = try loadFixture("nearai_cloudapi_attestation.json")
        let obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        let att = (obj["attestations"] as! [[String: Any]])[0]
        let bundle = att["bundle"] as! [String: Any]
        let vm = bundle["verificationMaterial"] as! [String: Any]
        let cert = vm["certificate"] as! [String: Any]
        let der = Data(base64Encoded: cert["rawBytes"] as! String)!
        let uri = ProvenanceVerifier.subjectAltNameURI(certDER: der)
        #expect(uri == "https://github.com/nearai/cloud-api/.github/workflows/build.yml@refs/heads/main")
    }
}

@Suite("ProvenanceService parsing")
struct ProvenanceServiceTests {

    @Test func imageRefs_extractsAllDigests() {
        let manifest = """
        services:
          cloud-api:
            image: nearaidev/cloud-api@sha256:ac8a539ce1ac9ae3ebd0dfcffdba18effaaedfa69685fce220e3b3a35357e326
          mesh:
            image: nearaidev/dstack-vpc@sha256:03bd4b222d07059af91fc3d2aa851026cecbecf719ba7423616058272db57b2c
        """
        let refs = ProvenanceService.imageRefs(inManifest: manifest)
        #expect(refs.count == 2)
        #expect(refs[0].image == "nearaidev/cloud-api")
        #expect(refs[0].digest == "ac8a539ce1ac9ae3ebd0dfcffdba18effaaedfa69685fce220e3b3a35357e326")
        #expect(refs[1].image == "nearaidev/dstack-vpc")
    }

    /// A fully-pinned `repo:tag@sha256:…` ref (Qwen 3.6's sglang engine uses
    /// this form) must resolve to `repo`, NOT the tag. The `:` truncation bug
    /// surfaced it as `v0.5.12-cu129`, so it couldn't be tagged the model server
    /// and the panel fell back to the "built in-enclave" descriptor.
    @Test func imageRefs_stripsTagFromPinnedRef() {
        let d = "9e02c8e1fe2790a1c445bd5f6814305fe43639a4adb01c8ad1e8e21e750bf581"
        let manifest = "image: lmsysorg/sglang:v0.5.12-cu129@sha256:\(d)"
        let refs = ProvenanceService.imageRefs(inManifest: manifest)
        #expect(refs.count == 1)
        #expect(refs[0].image == "lmsysorg/sglang")
        #expect(refs[0].digest == d)
        // Untagged form still resolves identically.
        let untagged = ProvenanceService.imageRefs(inManifest: "image: lmsysorg/sglang@sha256:\(d)")
        #expect(untagged.first?.image == "lmsysorg/sglang")
    }

    /// GLM-5.1's engine is `:local`, built `FROM lmsysorg/sglang@sha256:…` in a
    /// compose `dockerfile_inline`. The base image + digest (where its audit is
    /// keyed) must be recoverable from that FROM line.
    @Test func dockerfileBaseImage_extractsFromInlineDockerfile() {
        let d = "aac6b242680daeb74d2ab1d85f70575357552d7d165d2e5d30eb362797db54a1"
        let compose = """
        x-awq-build: &awq-build
          dockerfile_inline: |
            FROM lmsysorg/sglang:dev-cu12@sha256:\(d)
            RUN python3 - <<'PYEOF'
            print("patch")
            PYEOF
        services:
          model:
            image: glm51-sgl-awq-tp4-patched:local
            build: *awq-build
        """
        let base = ProvenanceService.dockerfileBaseImage(inManifest: compose)
        #expect(base?.image == "lmsysorg/sglang")
        #expect(base?.digest == d)
        // No FROM → nil.
        #expect(ProvenanceService.dockerfileBaseImage(inManifest: "services:\n  m:\n    image: x@sha256:\(d)") == nil)
        #expect(ProvenanceService.hasInEnclaveEngineBuild(inManifest: compose))
    }

    /// REGRESSION: a flat scan for the last `FROM` in the whole document handed
    /// one model's base to another. Production `small-models.yaml` carries three
    /// in-enclave builds — FLUX (`FROM lmsysorg/sglang@8ece90ad…`), whisper
    /// (`FROM vllm/vllm-openai@ccd6a6db…`) and the privacy filter — so every
    /// model on that node was told its engine was built from whisper's base, and
    /// the local-engine row adopted whisper's audit. With several candidates we
    /// cannot tell which build is "the" engine, so fail closed.
    @Test func dockerfileBaseImage_failsClosedWhenSeveralEnginesAreBuiltInEnclave() {
        let flux = "8ece90ad52faa8b56149f0117227d9009db34513213e35990da468aeb6fe0b75"
        let whisper = "ccd6a6dbf4aba4e94c6f7052d1835d6e742082b6a5095276552e9b7a5a47c2e5"
        let compose = """
        services:
          model-sg-flux2-klein-4b-tp1:
            image: sglang-diffusion
            build:
              dockerfile_inline: |
                FROM lmsysorg/sglang@sha256:\(flux)
                RUN pip install diffusers
          model-vllm-whisper-large-v3-tp1:
            image: vllm-with-audio
            build:
              dockerfile_inline: |
                FROM vllm/vllm-openai@sha256:\(whisper)
                RUN pip install openai-whisper
        """
        // Two in-enclave engine builds → ambiguous → no base, rather than
        // confidently naming whisper's for a request served by FLUX.
        #expect(ProvenanceService.dockerfileBaseImage(inManifest: compose) == nil)
        // …but the compose demonstrably DOES build an engine in-enclave.
        #expect(ProvenanceService.hasInEnclaveEngineBuild(inManifest: compose))
    }

    /// REGRESSION: a compose whose engine is a plain digest-pinned registry
    /// image builds nothing in-enclave, so the ladder must not render a
    /// "built in-enclave" row at all (it used to, labelled with the YAML
    /// filename, for gpt-oss / Qwen3-VL / Qwen3.6 and others).
    @Test func hasInEnclaveEngineBuild_falseForPlainRegistryEngine() {
        let d = "6766ce0c459e24b76f3e9ba14ffc0442131ef4248c904efdcbf0d89e38be01fe"
        let compose = """
        services:
          model-vllm-gptoss-120b-mxfp4-tp1-r1:
            image: vllm/vllm-openai@sha256:\(d)
            command: openai/gpt-oss-120b --tensor-parallel-size 1
        """
        #expect(!ProvenanceService.hasInEnclaveEngineBuild(inManifest: compose))
        #expect(ProvenanceService.dockerfileBaseImage(inManifest: compose) == nil)
    }

    @Test func imageRefs_deduplicatesByDigest() {
        let d = "ac8a539ce1ac9ae3ebd0dfcffdba18effaaedfa69685fce220e3b3a35357e326"
        let manifest = "a@sha256:\(d)\nb@sha256:\(d)"
        #expect(ProvenanceService.imageRefs(inManifest: manifest).count == 1)
    }

    @Test func imageRefs_noneWhenNoDigests() {
        #expect(ProvenanceService.imageRefs(inManifest: "image: nearaidev/cloud-api:latest").isEmpty)
    }

    @Test func githubRepo_mapsDockerNamespaceToNearai() {
        #expect(ProvenanceService.githubRepo(forImage: "nearaidev/cloud-api") == "nearai/cloud-api")
        #expect(ProvenanceService.githubRepo(forImage: "cloud-api") == "nearai/cloud-api")
    }

    // MARK: - near.ai vs third-party classification

    @Test func isNearAIImage_classifiesPublisherNamespace() {
        #expect(ProvenanceService.isNearAIImage("nearaidev/cloud-api"))
        #expect(ProvenanceService.isNearAIImage("nearai/cloud-api"))
        #expect(ProvenanceService.isNearAIImage("docker.io/nearaidev/dstack-vpc"))
        #expect(ProvenanceService.isNearAIImage("ghcr.io/nearai/cvm-ingress"))
        // Third-party sidecars from the live compose — no near.ai attestation exists.
        #expect(!ProvenanceService.isNearAIImage("datadog/agent"))
        #expect(!ProvenanceService.isNearAIImage("otel/opentelemetry-collector-contrib"))
        #expect(!ProvenanceService.isNearAIImage("alpine"))
        #expect(!ProvenanceService.isNearAIImage("registry.example.com:5000/alpine"))
    }

    @Test func verifyManifest_thirdPartyOnly_failsClosed() async {
        // A manifest with no near.ai images is nothing this check can vouch for.
        let manifest = "image: alpine@sha256:\(String(repeating: "1", count: 64))"
        let result = await ProvenanceService().verifyManifest(manifest)
        guard case .incomplete(let verified, let failures, let thirdParty) = result else {
            Issue.record("expected .incomplete, got \(result)")
            return
        }
        #expect(verified.isEmpty && failures.isEmpty)
        #expect(thirdParty.count == 1)
    }

    // MARK: - Verified-digest cache

    @Test func legacyThreeFieldCacheEntry_decodesWithNilSourceInfo() throws {
        let defaults = try #require(UserDefaults(suiteName: "provenance-cache-legacy-test"))
        defaults.removePersistentDomain(forName: "provenance-cache-legacy-test")
        let digest = String(repeating: "b", count: 64)
        defaults.set([digest: ["https://github.com/nearai/cloud-api", "identity", "true"]],
                     forKey: "ai.teemoon.provenance.verified")
        let cached = ProvenanceService.cachedVerification(digest: digest, defaults: defaults)
        guard case .verified(let repo, _, let ref, let commit, let tlog) = cached else {
            Issue.record("expected legacy entry to decode, got \(String(describing: cached))")
            return
        }
        #expect(repo == "https://github.com/nearai/cloud-api")
        #expect(ref == nil)
        #expect(commit == nil)
        #expect(tlog == true)
    }

    @Test func verifiedDigestCache_roundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "provenance-cache-test"))
        defaults.removePersistentDomain(forName: "provenance-cache-test")
        let digest = String(repeating: "a", count: 64)
        #expect(ProvenanceService.cachedVerification(digest: digest, defaults: defaults) == nil)

        let outcome = ImageProvenance.verified(
            repositoryURL: "https://github.com/nearai/cloud-api",
            workflowIdentity: "https://github.com/nearai/cloud-api/.github/workflows/build.yml@refs/heads/main",
            sourceRef: "refs/heads/main",
            sourceCommit: "84367f0253fa94aa6816d64210e5812215ee2622",
            transparencyLogChecked: true)
        ProvenanceService.cacheVerification(digest: digest, outcome: outcome, defaults: defaults)
        #expect(ProvenanceService.cachedVerification(digest: digest, defaults: defaults) == outcome)
        // Unverified outcomes are never cached.
        ProvenanceService.cacheVerification(
            digest: "ff", outcome: .unverified(.fetchFailed("x")), defaults: defaults)
        #expect(ProvenanceService.cachedVerification(digest: "ff", defaults: defaults) == nil)
        defaults.removePersistentDomain(forName: "provenance-cache-test")
    }
}

// MARK: - Manifest parsing

@Suite("ProvenanceService manifest parsing")
struct ProvenanceManifestParsingTests {

    /// Compose shell-default syntax leaks a "-" into the image match:
    /// `${VAR:-nearaidev/img@sha256:…}`. It must still classify as near.ai.
    @Test func shellDefaultSyntax_stripsLeadingDash() {
        let digest = String(repeating: "b", count: 64)
        let manifest = "services:\n  cm:\n    image: ${COMPOSE_MANAGER_IMAGE:-nearaidev/compose-manager@sha256:\(digest)}"
        let refs = ProvenanceService.imageRefs(inManifest: manifest)
        #expect(refs.count == 1)
        #expect(refs.first?.image == "nearaidev/compose-manager")
        #expect(ProvenanceService.isNearAIImage(refs.first?.image ?? "") == true)
    }

    /// The gateway and model-node manifests share mesh images — the combined
    /// ref set counts each digest once, with host membership merged.
    @Test func multipleManifests_dedupeByDigestAndMergeHosts() {
        let shared = String(repeating: "c", count: 64)
        let gwOnly = String(repeating: "d", count: 64)
        let nodeOnly = String(repeating: "e", count: 64)
        let gateway = "image: nearaidev/dstack-vpc@sha256:\(shared)\nimage: nearaidev/cloud-api@sha256:\(gwOnly)"
        let node = "image: nearaidev/dstack-vpc@sha256:\(shared)\nimage: nearaidev/compose-manager@sha256:\(nodeOnly)"
        let refs = ProvenanceService.imageRefs(inManifests: [
            (host: "gateway", manifest: gateway), (host: "model", manifest: node)])
        #expect(refs.count == 3)
        let sharedRef = refs.first { $0.digest == shared }
        #expect(sharedRef?.hosts == ["gateway", "model"])
        #expect(refs.first { $0.digest == gwOnly }?.hosts == ["gateway"])
        #expect(refs.first { $0.digest == nodeOnly }?.hosts == ["model"])
    }

    /// The launcher image's attestations are published by the compose-manager
    /// repo (verified against GitHub's API).
    @Test func launcherImage_queriesComposeManagerRepo() {
        #expect(ProvenanceService.githubRepo(forImage: "nearaidev/compose-manager-launcher") == "nearai/compose-manager")
        #expect(ProvenanceService.githubRepo(forImage: "nearaidev/cloud-api") == "nearai/cloud-api")
    }
}

// MARK: - Legacy cache upgrade

/// Serves a canned response for the GitHub attestations endpoint.
private final class StubGitHub: URLProtocol {
    nonisolated(unsafe) static var responseData: Data?
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requestCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = Self.responseData { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Legacy 3-field cache entries (no source ref/commit) must upgrade via one
/// re-fetch — and must never downgrade to failed when that re-fetch fails.
/// Serialized: the stub's canned response is shared mutable state.
@Suite("ProvenanceService legacy cache upgrade", .serialized)
struct ProvenanceCacheUpgradeTests {

    private func makeService(defaults: UserDefaults) -> ProvenanceService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubGitHub.self]
        return ProvenanceService(session: URLSession(configuration: config), defaults: defaults)
    }

    private func seedLegacyEntry(digest: String, defaults: UserDefaults) {
        defaults.set([digest: ["https://github.com/nearai/cloud-api",
                               "https://github.com/nearai/cloud-api/.github/workflows/build.yml@refs/heads/main",
                               "true"]],
                     forKey: "ai.teemoon.provenance.verified")
    }

    private func loadFixture(_ name: String, file: String = #filePath) throws -> Data {
        return try TestFixture.data(name, file: file)
    }

    @Test func legacyEntry_upgradesToSourceInfoOnRefetch() async throws {
        let defaults = try #require(UserDefaults(suiteName: "provenance-upgrade-test"))
        defaults.removePersistentDomain(forName: "provenance-upgrade-test")
        let digest = ImageProvenanceTests.fixtureDigest
        seedLegacyEntry(digest: digest, defaults: defaults)
        StubGitHub.responseData = try loadFixture("nearai_cloudapi_attestation.json")
        StubGitHub.statusCode = 200

        let result = await makeService(defaults: defaults)
            .verify(.init(image: "nearaidev/cloud-api", digest: digest))
        guard case .verified(_, _, let ref, let commit, _) = result else {
            Issue.record("expected .verified, got \(result)")
            return
        }
        #expect(ref == "refs/heads/main")
        #expect(commit == "84367f0253fa94aa6816d64210e5812215ee2622")
        // and the upgraded entry is persisted in the 5-field format
        guard case .verified(_, _, .some, .some, _) =
            ProvenanceService.cachedVerification(digest: digest, defaults: defaults) else {
            Issue.record("expected upgraded 5-field cache entry")
            return
        }
        defaults.removePersistentDomain(forName: "provenance-upgrade-test")
    }

    /// Rate limits (403) are transient — the manifest result must read as
    /// inconclusive, never as evidence of compromise. A 404 (no attestation
    /// exists) stays a definitive, fail-closed failure.
    @Test func rateLimit_isInconclusive_missingAttestation_isNot() async throws {
        let defaults = try #require(UserDefaults(suiteName: "provenance-transient-test"))
        defaults.removePersistentDomain(forName: "provenance-transient-test")
        let manifest = "image: nearaidev/cloud-api@sha256:\(String(repeating: "d", count: 64))"

        StubGitHub.responseData = nil
        StubGitHub.statusCode = 403
        let rateLimited = await makeService(defaults: defaults).verifyManifest(manifest)
        #expect(rateLimited.isInconclusive)
        #expect(!rateLimited.isFullyVerified)

        StubGitHub.statusCode = 404
        let missing = await makeService(defaults: defaults).verifyManifest(manifest)
        #expect(!missing.isInconclusive)
        #expect(missing.isUnpublishedOnly)
        defaults.removePersistentDomain(forName: "provenance-transient-test")
    }

    /// A legacy entry's upgrade re-fetch happens once per launch — repeated
    /// verifications while rate-limited must not burn quota on it again.
    @Test func legacyUpgrade_attemptedOncePerLaunch() async throws {
        let defaults = try #require(UserDefaults(suiteName: "provenance-throttle-test"))
        defaults.removePersistentDomain(forName: "provenance-throttle-test")
        let digest = String(repeating: "f", count: 64)
        seedLegacyEntry(digest: digest, defaults: defaults)
        StubGitHub.responseData = nil
        StubGitHub.statusCode = 403
        let service = makeService(defaults: defaults)

        _ = await service.verify(.init(image: "nearaidev/cloud-api", digest: digest))
        let after1 = StubGitHub.requestCount
        let second = await service.verify(.init(image: "nearaidev/cloud-api", digest: digest))
        #expect(StubGitHub.requestCount == after1)   // no second fetch
        guard case .verified = second else {
            Issue.record("legacy verification must be preserved, got \(second)")
            return
        }
        defaults.removePersistentDomain(forName: "provenance-throttle-test")
    }

    @Test func modelLayerManifest_triStateDistinguishesMatchMismatchAndFetchFailure() async throws {
        let defaults = try #require(UserDefaults(suiteName: "provenance-model-layer-test"))
        defaults.removePersistentDomain(forName: "provenance-model-layer-test")
        let yaml = "services:\n  proxy:\n    image: nearaidev/vllm-proxy-rs@sha256:\(String(repeating: "a", count: 64))\n"
        StubGitHub.responseData = Data(yaml.utf8)
        StubGitHub.statusCode = 200
        let sha = SHA256.hash(data: Data(yaml.utf8)).map { String(format: "%02x", $0) }.joined()

        let service = makeService(defaults: defaults)
        // hash match → .verified carrying the exact YAML
        let ok = await service.fetchModelLayerManifest(
            path: "prod/x.yaml", commit: "c545c95", expectedSHA256: sha)
        #expect(ok == .verified(yaml))

        // hash mismatch → .hashMismatch (adversarial), NEVER unverified content.
        // Must be distinct from a fetch failure so the UI can fail LOUD on tamper
        // while staying quiet on a transient network error.
        let mismatch = await service.fetchModelLayerManifest(
            path: "prod/x.yaml", commit: "c545c95", expectedSHA256: String(repeating: "0", count: 64))
        guard case .hashMismatch = mismatch else {
            Issue.record("expected .hashMismatch, got \(mismatch)"); return
        }

        // non-200 (throttled/unreachable) → .fetchFailed — transient, NOT tamper.
        StubGitHub.responseData = nil
        StubGitHub.statusCode = 403
        let transient = await service.fetchModelLayerManifest(
            path: "prod/x.yaml", commit: "c545c95", expectedSHA256: sha)
        #expect(transient == .fetchFailed)
        defaults.removePersistentDomain(forName: "provenance-model-layer-test")
    }

    @Test func legacyEntry_failedRefetch_staysVerified() async throws {
        let defaults = try #require(UserDefaults(suiteName: "provenance-upgrade-fail-test"))
        defaults.removePersistentDomain(forName: "provenance-upgrade-fail-test")
        let digest = String(repeating: "c", count: 64)
        seedLegacyEntry(digest: digest, defaults: defaults)
        StubGitHub.responseData = nil
        StubGitHub.statusCode = 403  // rate-limited

        let result = await makeService(defaults: defaults)
            .verify(.init(image: "nearaidev/cloud-api", digest: digest))
        guard case .verified(let repo, _, let ref, let commit, _) = result else {
            Issue.record("expected legacy verification preserved, got \(result)")
            return
        }
        #expect(repo == "https://github.com/nearai/cloud-api")
        #expect(ref == nil)
        #expect(commit == nil)
        defaults.removePersistentDomain(forName: "provenance-upgrade-fail-test")
    }
}

// MARK: - 404 classification under rate pressure (live regression 2026-07-19)

/// Serves a scripted sequence of (status, headers) responses.
private final class ScriptedGitHub: URLProtocol {
    nonisolated(unsafe) static var script: [(status: Int, headers: [String: String])] = []
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let idx = Self.requestCount
        Self.requestCount += 1
        let step = idx < Self.script.count ? Self.script[idx] : Self.script.last ?? (404, [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: step.status,
                                       httpVersion: nil, headerFields: step.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Observed live: a digest 404'd on-device while the same URL served 200
/// elsewhere — the attestation existed; the device had exhausted GitHub's
/// anonymous quota re-verifying. A 404 must only fail closed when GitHub
/// actually answered: throttled 404s are transient, and a clean 404 gets one
/// retry before it is believed.
@Suite("ProvenanceService — 404 classification", .serialized)
struct Provenance404ClassificationTests {

    private func makeService() -> ProvenanceService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedGitHub.self]
        let suite = "prov404-\(UUID().uuidString)"
        return ProvenanceService(session: URLSession(configuration: config),
                                 defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func rateLimited404IsTransientNotDefinitive() async {
        ScriptedGitHub.script = [(404, ["X-RateLimit-Remaining": "0"])]
        ScriptedGitHub.requestCount = 0
        let outcome = await makeService().verify(.init(image: "nearaidev/compose-manager-launcher",
                                                       digest: String(repeating: "1", count: 64)))
        guard case .unverified(.fetchTransient(let why)) = outcome else {
            Issue.record("expected transient, got \(outcome)"); return
        }
        #expect(why.contains("rate limit"))
        #expect(ScriptedGitHub.requestCount == 1)   // no pointless retry against a dry quota
    }

    @Test func clean404RetriesOnceThenFailsClosed() async {
        ScriptedGitHub.script = [(404, ["X-RateLimit-Remaining": "37"]),
                                 (404, ["X-RateLimit-Remaining": "36"])]
        ScriptedGitHub.requestCount = 0
        let outcome = await makeService().verify(.init(image: "nearaidev/compose-manager-launcher",
                                                       digest: String(repeating: "2", count: 64)))
        guard case .unverified(.fetchFailed(let why)) = outcome else {
            Issue.record("expected definitive fetchFailed, got \(outcome)"); return
        }
        #expect(why.contains("404"))
        #expect(ScriptedGitHub.requestCount == 2)   // the retry happened
    }

    @Test func transient404ThenSuccessIsRescuedByTheRetry() async {
        ScriptedGitHub.script = [(404, ["X-RateLimit-Remaining": "37"]),
                                 (200, ["X-RateLimit-Remaining": "36"])]
        ScriptedGitHub.requestCount = 0
        let outcome = await makeService().verify(.init(image: "nearaidev/compose-manager-launcher",
                                                       digest: String(repeating: "3", count: 64)))
        // The `{}` body won't pass Sigstore verification, but the point is the
        // 404 must NOT be believed: the retry reached the 200 and the outcome
        // is a verification verdict, not a fetch-404 failure.
        if case .unverified(.fetchFailed(let why)) = outcome {
            #expect(!why.contains("404"), "retry should have rescued the fetch, got \(why)")
        }
        #expect(ScriptedGitHub.requestCount == 2)
    }
}
