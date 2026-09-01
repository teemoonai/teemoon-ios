//
//  ProvenanceService.swift
//  teemoon
//
//  Fetches GitHub Artifact Attestations for the image digests named in an
//  attested compose manifest and verifies each with ProvenanceVerifier.
//  This is the network half of the "running code traces to near.ai's source"
//  check; the crypto is in ImageProvenance.swift.
//
//  Fail-closed: any image whose attestation can't be fetched or verified
//  leaves the overall result unverified.
//

import CryptoKit
import Foundation
import os

/// Outcome of fetching + hash-checking the model-layer (inner) compose against
/// the action log's pinned `file_sha256`. The three cases are deliberately
/// distinct: a tamper (`hashMismatch`) must fail loud, a transient network
/// failure (`fetchFailed`) must not — see `fetchModelLayerManifest`.
enum ModelLayerFetch: Equatable {
    /// Hash matched — carries the verified YAML text.
    case verified(String)
    /// The fetched file's hash does NOT match the pinned value: an adversarial
    /// integrity break. The launched recipe is not what the action log pinned.
    case hashMismatch(expected: String, got: String)
    /// Could not fetch (network/HTTP error) — transient, not evidence of tamper.
    case fetchFailed
}

/// The display-level verdict of the model-layer hash check, stored on the
/// session and read by the attestation summary (without the YAML payload).
enum ModelLayerVerification: Equatable, Sendable {
    /// Recipe hash matched the action-log pin, verified on this device.
    case verified
    /// Recipe hash did NOT match — the running config is unverified. Fail-closed.
    case hashMismatch
    /// Could not reach the source to check — transient, advisory only.
    case fetchFailed
}

private let logger = Logger(subsystem: "ai.teemoon", category: "provenance")

struct ProvenanceService {
    let verifier: ProvenanceVerifier
    let session: URLSession
    let defaults: UserDefaults

    init(verifier: ProvenanceVerifier = ProvenanceVerifier(), session: URLSession = .shared,
         defaults: UserDefaults = .standard) {
        self.verifier = verifier
        self.session = session
        self.defaults = defaults
    }

    /// One image reference and its digest, parsed from a compose manifest.
    struct ImageRef: Equatable, Sendable {
        let image: String   // e.g. "nearaidev/cloud-api"
        let digest: String  // hex sha256, no prefix
        /// The GitHub repository the image's Sigstore certificate names as its
        /// build source (e.g. "https://github.com/nearai/private-ml-sdk").
        /// Populated by verification; nil before/without it.
        var sourceRepo: String? = nil
        /// The git ref the attested build ran on (e.g. "refs/tags/v0.5.1").
        var sourceRef: String? = nil
        /// The exact source commit the attested build resolved.
        var sourceCommit: String? = nil
        /// Which attested machines run this image ("gateway" / "model"),
        /// merged when the same digest appears in several manifests.
        var hosts: [String] = []
    }

    /// One image that failed provenance, with why.
    struct Failure: Equatable, Sendable {
        let ref: ImageRef
        let reason: ImageProvenance
    }

    /// The provenance outcome for a whole manifest.
    ///
    /// Only near.ai-built images (`nearaidev/*` / `nearai/*`) are held to the
    /// provenance requirement — that is the check's claim. Third-party
    /// sidecars in the compose (e.g. `datadog/agent`, `alpine`) have no
    /// near.ai attestation to verify; they are digest-pinned by the attested
    /// manifest itself (which code identity binds to MRCONFIGID), so they are
    /// reported distinctly rather than counted as failures. near.ai's own
    /// verifier makes the same distinction.
    enum ManifestProvenance: Equatable, Sendable {
        /// Every near.ai image digest verified against a pinned workflow.
        case allVerified(verified: [ImageRef], thirdParty: [ImageRef])
        /// At least one near.ai image is unverified (fail-closed).
        case incomplete(verified: [ImageRef], failures: [Failure], thirdParty: [ImageRef])

        var isFullyVerified: Bool { if case .allVerified = self { return true }; return false }

        /// True when the only thing standing between this result and
        /// `.allVerified` is transient fetch trouble (rate limits, network) —
        /// no image produced actual negative evidence. Callers should treat
        /// such a result as still-pending rather than degraded: fail-closed
        /// on evidence, in-flight on no evidence.
        var isInconclusive: Bool {
            guard case .incomplete(_, let failures, _) = self, !failures.isEmpty else { return false }
            return failures.allSatisfy {
                if case .unverified(.fetchTransient) = $0.reason { return true }
                return false
            }
        }

        /// True when every failure is a definitive unpublished attestation
        /// (clean GitHub 404). Not a bad signature, wrong identity, or digest
        /// mismatch — and not an empty failure list. The send gate must not
        /// treat this as an encryption failure; the chip must not say verified.
        var isUnpublishedOnly: Bool {
            guard case .incomplete(_, let failures, _) = self, !failures.isEmpty else { return false }
            return failures.allSatisfy {
                if case .unverified(.fetchFailed) = $0.reason { return true }
                return false
            }
        }
    }

    /// Whether an image reference names a near.ai-published image (and must
    /// therefore carry verifiable provenance). Strips a registry host prefix
    /// (a first path component containing "." or ":") before checking the
    /// publisher namespace.
    static func isNearAIImage(_ image: String) -> Bool {
        var components = image.split(separator: "/")
        if let first = components.first, first.contains(".") || first.contains(":") {
            components.removeFirst()
        }
        guard components.count >= 2 else { return false }  // bare images like "alpine"
        return ["nearai", "nearaidev"].contains(components[0].lowercased())
    }

    /// Extracts `@sha256:<digest>` image references from a compose manifest.
    /// Compiled ONCE, and memoized by document.
    ///
    /// A manifest is IMMUTABLE — it is the text an enclave attested to — so
    /// its parse is a pure function of its content and can be cached for the
    /// life of the process. It was neither: `NSRegularExpression(pattern:)` is
    /// an ICU compile and ran on every call, and every call rescanned the whole
    /// 16 KB document. `TrustLadderView.enclaveGroup` calls this ONCE PER IMAGE
    /// (via `isRecipeImage`), `enclaveGroups` is reached from `hero`, and the
    /// sheet re-derives its body on every `@Observable` session mutation — so
    /// the cost was (images × manifest size × mutations).
    ///
    /// Measured 2026-08-22: the attestation sheet took ~5s to open on device,
    /// with 3 of 5 main-thread hang samples inside `icu::RegexMatcher::find`
    /// under this function. One `@Observable` mutation cost 73.5 ms.
    private static let imageRefRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"([A-Za-z0-9._/\-]+)(?::[A-Za-z0-9._\-]+)?@sha256:([0-9a-f]{64})"#)

    private static let imageRefsCache: NSCache<NSString, CacheEntry<[ImageRef]>> = {
        let cache = NSCache<NSString, CacheEntry<[ImageRef]>>()
        // A session sees a handful of documents: gateway outer, model outer,
        // model inner. The limit is a leak stop, not a working-set estimate.
        cache.countLimit = 32
        return cache
    }()

    private static let tagPinnedCache: NSCache<NSString, CacheEntry<[String]>> = {
        let cache = NSCache<NSString, CacheEntry<[String]>>()
        cache.countLimit = 32
        return cache
    }()

    static func imageRefs(inManifest manifest: String) -> [ImageRef] {
        let key = manifest as NSString
        if let hit = imageRefsCache.object(forKey: key) { return hit.value }
        let parsed = parseImageRefs(inManifest: manifest)
        imageRefsCache.setObject(CacheEntry(parsed), forKey: key)
        return parsed
    }

    private static func parseImageRefs(inManifest manifest: String) -> [ImageRef] {
        // Match "<image>[:<tag>]@sha256:<64 hex>" where <image> is the token
        // before '@' (or before an OPTIONAL `:tag`). The tag is discarded: a
        // fully-pinned ref like `lmsysorg/sglang:v0.5.12-cu129@sha256:…` names
        // the image `lmsysorg/sglang`, not the tag — without skipping the tag the
        // `:` (absent from the image class) would truncate the capture to just
        // `v0.5.12-cu129`, mislabeling the image (Qwen 3.6's tagged sglang did
        // exactly this — shown as `v0.5.12-cu129`, untaggable as the model server).
        guard let re = imageRefRegex else { return [] }
        let ns = manifest as NSString
        var seen = Set<String>()
        var refs: [ImageRef] = []
        for m in re.matches(in: manifest, range: NSRange(location: 0, length: ns.length)) {
            // Strip the "-" that compose shell-default syntax leaks into the
            // match: `${VAR:-nearaidev/img@sha256:…}` — image names can't
            // legitimately start with a dash. Without this, near.ai images
            // behind a default would be misclassified as third-party.
            var image = ns.substring(with: m.range(at: 1))
            while image.hasPrefix("-") { image.removeFirst() }
            let digest = ns.substring(with: m.range(at: 2))
            if seen.insert(digest).inserted {
                refs.append(ImageRef(image: image, digest: digest))
            }
        }
        return refs
    }

    /// Image refs across several host-labeled manifests, deduplicated by
    /// digest — an image in both the gateway's and the model node's manifest
    /// yields one ref carrying both hosts.
    static func imageRefs(inManifests manifests: [(host: String, manifest: String)]) -> [ImageRef] {
        var order: [String] = []
        var byDigest: [String: ImageRef] = [:]
        for (host, manifest) in manifests {
            for ref in imageRefs(inManifest: manifest) {
                if var existing = byDigest[ref.digest] {
                    if !host.isEmpty, !existing.hosts.contains(host) {
                        existing.hosts.append(host)
                        byDigest[ref.digest] = existing
                    }
                } else {
                    var new = ref
                    if !host.isEmpty { new.hosts = [host] }
                    byDigest[ref.digest] = new
                    order.append(ref.digest)
                }
            }
        }
        return order.compactMap { byDigest[$0] }
    }

    /// TAG-pinned (digestless) image references declared by a compose
    /// manifest's services — e.g. `nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-…`
    /// with no `@sha256`. These are REAL action-log-declared containers that
    /// `imageRefs` (digest-only by design) can never surface; without this,
    /// a near-root sidecar renders nowhere at all.
    ///
    /// Parsed per-service via the same anchor-aware block parsing the
    /// plaintext analysis uses — never a doc-wide regex, which would match
    /// image-shaped strings inside label VALUES (`com.datadoghq.*`) and
    /// comments. `${VAR:-default}` unwraps to the default, like
    /// `shortImageName`. Flood guards: `:local` in-enclave builds are excluded
    /// (already represented by the local-engine row — a "can drift" marker on
    /// a digest-pinned-base build would be flatly wrong), and replicas dedupe
    /// by full image ref (one dcgm row, not one per model service).
    ///
    /// Call ONLY with the hash-verified inner compose — a tag-pinned row's
    /// facts must come from the document the action log actually pinned.
    static func tagPinnedImageRefs(inManifest manifest: String) -> [String] {
        let key = manifest as NSString
        if let hit = tagPinnedCache.object(forKey: key) { return hit.value }
        let parsed = parseTagPinnedImageRefs(inManifest: manifest)
        tagPinnedCache.setObject(CacheEntry(parsed), forKey: key)
        return parsed
    }

    /// Same immutability argument as `imageRefs(inManifest:)`, and the same
    /// call shape: once per image, inside a re-derived computed property. This
    /// one is heavier still — it rebuilds the YAML, its anchors and every
    /// service block per call.
    private static func parseTagPinnedImageRefs(inManifest manifest: String) -> [String] {
        let yaml = PlaintextExposure.dockerComposeYAML(from: manifest)
        let anchors = PlaintextExposure.anchorBlocks(in: yaml)
        var refs: [String] = []
        var seen = Set<String>()
        for rawBlock in PlaintextExposure.serviceBlocks(in: yaml) {
            let block = PlaintextExposure.expand(rawBlock, anchors: anchors)
            guard let ref = fullImageRef(inBlock: block) else { continue }
            guard !ref.contains("@sha256:") else { continue }   // digest-pinned → imageRefs
            guard !ref.hasSuffix(":local") else { continue }    // in-enclave build → local-engine row
            if seen.insert(ref).inserted { refs.append(ref) }
        }
        return refs
    }

    /// The full `image:` value of a service block — registry host, path, and
    /// tag intact (unlike `PlaintextExposure.shortImageName`, which reduces to
    /// the short name). `${VAR:-default}` unwraps to the default.
    static func fullImageRef(inBlock block: String) -> String? {
        for rawLine in block.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("image:") else { continue }
            var v = String(line.dropFirst("image:".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if v.hasPrefix("${"), let dash = v.range(of: ":-"), let end = v.lastIndex(of: "}") {
                v = String(v[dash.upperBound..<end])
            }
            return v.isEmpty ? nil : v
        }
        return nil
    }

    /// The base image of an in-enclave build: the `FROM <ref>[:tag]@sha256:…`
    /// of a compose `dockerfile_inline`. The engine that runs is `<name>:local`
    /// (no registry digest), so its provenance and its audit live on this base
    /// — e.g. GLM-5.1's `glm51-sgl-awq-tp4-patched:local` builds `FROM
    /// lmsysorg/sglang@sha256:aac6b242…`, and the sglang audit is keyed there.
    ///
    /// SCOPED TO THE SERVICE BLOCK, and fail-closed on ambiguity. A flat scan of
    /// the whole document returns whichever `FROM` happens to come last, which
    /// on a multi-build compose is another model's base entirely: production
    /// `small-models.yaml` carries three in-enclave builds — `sglang-diffusion`
    /// (FLUX, `FROM lmsysorg/sglang@8ece90ad…`), `vllm-with-audio` (whisper,
    /// `FROM vllm/vllm-openai@ccd6a6db…`) and `privacy-filter-hf` — so the flat
    /// scan handed the whisper base to every model on that node and the
    /// local-engine row named the wrong image (and adopted the wrong audit).
    /// Now: consider only service blocks that are BOTH an in-enclave `build:`
    /// AND a model server, take that block's own last `FROM` (its final build
    /// stage), and return a base only when exactly one such service exists.
    /// Several → we cannot tell which one is "the" engine, so return nil and
    /// let the caller show no base rather than confidently show the wrong one.
    static func dockerfileBaseImage(inManifest manifest: String) -> ImageRef? {
        let yaml = PlaintextExposure.dockerComposeYAML(from: manifest)
        let anchors = PlaintextExposure.anchorBlocks(in: yaml)
        var candidates: [ImageRef] = []
        for rawBlock in PlaintextExposure.serviceBlocks(in: yaml) {
            let block = PlaintextExposure.expand(rawBlock, anchors: anchors)
            guard block.range(of: "(?m)^\\s*build:", options: .regularExpression) != nil,
                  PlaintextExposure.hasModelServerSignal(block) else { continue }
            var base: ImageRef?
            for rawLine in block.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.uppercased().hasPrefix("FROM ") else { continue }
                if let ref = imageRefs(inManifest: line).first { base = ref }
            }
            if let base { candidates.append(base) }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Whether this compose builds its inference engine in-enclave at all.
    /// `dockerfileBaseImage` returns nil both when there is no such build and
    /// when there are several; callers that decide whether to render a
    /// local-engine row need to tell those apart — a compose whose engine is a
    /// plain digest-pinned registry image (most of the fleet) must not get a
    /// row claiming something was "built in-enclave".
    static func hasInEnclaveEngineBuild(inManifest manifest: String) -> Bool {
        let yaml = PlaintextExposure.dockerComposeYAML(from: manifest)
        let anchors = PlaintextExposure.anchorBlocks(in: yaml)
        return PlaintextExposure.serviceBlocks(in: yaml).contains { rawBlock in
            let block = PlaintextExposure.expand(rawBlock, anchors: anchors)
            return block.range(of: "(?m)^\\s*build:", options: .regularExpression) != nil
                && PlaintextExposure.hasModelServerSignal(block)
        }
    }

    /// Maps a Docker image name to the GitHub repo that publishes its
    /// attestations. near.ai builds under `nearai/<name>` and publishes to
    /// Docker Hub as `nearaidev/<name>`, so the trailing path component maps
    /// across. The verifier's SAN identity check is the real gate — this only
    /// picks which repo to query.
    /// Images whose attestations are published by a different repo than the
    /// image name suggests (verified empirically against GitHub's attestation
    /// API). Only affects where we LOOK for the attestation — the certificate's
    /// SAN identity still determines the trusted source.
    private static let repoAliases = [
        "compose-manager-launcher": "compose-manager",
        "vllm-proxy-rs": "inference-proxy",
    ]

    /// The public repo compose-manager pulls model-layer YAMLs from
    /// (verified empirically: attested action-log paths + commits resolve
    /// here with matching file hashes).
    static let modelComposeRepo = "nearai/cvm-compose-files"

    static func githubRepo(forImage image: String) -> String? {
        guard let name = image.split(separator: "/").last.map(String.init) else { return nil }
        return "nearai/\(repoAliases[name] ?? name)"
    }

    /// Fetches the model-layer compose YAML at the attested commit and path and
    /// hash-checks it against the action log's pinned `file_sha256`. The three
    /// outcomes are DISTINCT and must stay so: a `.hashMismatch` is an
    /// adversarial integrity break (the recipe on disk is not what the signed
    /// action log pinned — fail loud), while a `.fetchFailed` is transient
    /// (GitHub unreachable / throttled — never accuse near.ai of tampering over
    /// a network blip). Collapsing the two — as an earlier `String?` return did —
    /// makes the loud tamper state unreachable and the seam check fail open.
    func fetchModelLayerManifest(path: String, commit: String, expectedSHA256: String) async -> ModelLayerFetch {
        guard let url = URL(string: "https://raw.githubusercontent.com/\(Self.modelComposeRepo)/\(commit)/\(path)") else { return .fetchFailed }
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .fetchFailed }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expectedSHA256.lowercased() else {
                logger.error("model-layer compose hash mismatch: attested \(expectedSHA256, privacy: .public) got \(digest, privacy: .public)")
                return .hashMismatch(expected: expectedSHA256.lowercased(), got: digest)
            }
            return .verified(String(decoding: data, as: UTF8.self))
        } catch {
            return .fetchFailed
        }
    }

    /// Verifies provenance for every near.ai image in `manifest`. Fail-closed
    /// for near.ai images; third-party sidecars are classified, not verified.
    func verifyManifest(_ manifest: String) async -> ManifestProvenance {
        await verifyManifests([(host: "", manifest: manifest)])
    }

    /// Verifies provenance across several host-labeled attested manifests as
    /// one set — e.g. the gateway CVM's and the model node's, deduplicated by
    /// digest with host membership merged.
    func verifyManifests(_ manifests: [(host: String, manifest: String)]) async -> ManifestProvenance {
        let refs = Self.imageRefs(inManifests: manifests)
        let nearAI = refs.filter { Self.isNearAIImage($0.image) }
        let thirdParty = refs.filter { !Self.isNearAIImage($0.image) }
        guard !nearAI.isEmpty else {
            // A manifest with no near.ai images at all is not something this
            // check can vouch for — fail-closed.
            return .incomplete(verified: [], failures: [], thirdParty: thirdParty)
        }
        var verified: [ImageRef] = []
        var failures: [Failure] = []
        for ref in nearAI {
            let outcome = await verify(ref)
            if case .verified(let repositoryURL, _, let sourceRef, let sourceCommit, _) = outcome {
                var v = ref
                v.sourceRepo = repositoryURL
                v.sourceRef = sourceRef
                v.sourceCommit = sourceCommit
                verified.append(v)
            } else {
                failures.append(Failure(ref: ref, reason: outcome))
            }
        }
        return failures.isEmpty ? .allVerified(verified: verified, thirdParty: thirdParty)
                                : .incomplete(verified: verified, failures: failures, thirdParty: thirdParty)
    }

    /// Fetches and verifies one image's GitHub Artifact Attestation.
    ///
    /// A digest's provenance is immutable, so verified results are cached
    /// persistently — GitHub's unauthenticated rate limit (60/hr) can then
    /// never flip a previously-verified image back to failed, and routine
    /// attestation refreshes cost no API calls for unchanged images.
    /// Digests whose legacy cache entry we already tried to upgrade this
    /// launch — one attempt each, so a rate-limited hour can't be burned by
    /// re-fetching the same digests on every verification run.
    private static let upgradeAttempted = OSAllocatedUnfairLock(initialState: Set<String>())

    func verify(_ ref: ImageRef) async -> ImageProvenance {
        if let cached = Self.cachedVerification(digest: ref.digest, defaults: defaults) {
            // Legacy cache entries predate source ref/commit capture. Try one
            // re-fetch (per launch) to upgrade them so provenance can link the
            // exact code — but a failed re-fetch (rate limit, offline) must
            // never downgrade an already-verified digest.
            if case .verified(_, _, nil, nil, _) = cached,
               Self.upgradeAttempted.withLock({ $0.insert(ref.digest).inserted }) {
                let fresh = await fetchAndVerify(ref)
                if case .verified = fresh { return fresh }
            }
            return cached
        }
        return await fetchAndVerify(ref)
    }

    private func fetchAndVerify(_ ref: ImageRef) async -> ImageProvenance {
        guard let repo = Self.githubRepo(forImage: ref.image),
              let url = URL(string: "https://api.github.com/repos/\(repo)/attestations/sha256:\(ref.digest)") else {
            return .unverified(.fetchFailed("no GitHub repo for image \(ref.image)"))
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        do {
            var data = Data()
            attempts: for attempt in 0..<2 {
                let (d, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                switch http?.statusCode ?? 0 {
                case 200:
                    data = d
                    break attempts
                case 404:
                    // A 404 is only definitive when GitHub actually answered
                    // the question. Under rate pressure the unauthenticated
                    // API returns 404s that are NOT evidence of absence
                    // (observed live 2026-07-19: a digest 404'd on-device
                    // while the same URL served 200 elsewhere — the
                    // attestation existed; the device had exhausted the
                    // 60/hr anonymous quota re-verifying). A 404 carrying
                    // `X-RateLimit-Remaining: 0` is a throttling artifact →
                    // transient, non-blocking. A clean 404 gets one retry;
                    // only a repeatable, un-throttled 404 fails closed.
                    if http?.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                        return .unverified(.fetchTransient("GitHub attestations HTTP 404 under rate limit"))
                    }
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        continue
                    }
                    return .unverified(.fetchFailed("GitHub attestations HTTP 404"))
                default:
                    // Rate limits (403/429), server errors: no evidence either way.
                    return .unverified(.fetchTransient("GitHub attestations HTTP \(http?.statusCode ?? 0)"))
                }
            }
            let outcome = verifier.verify(attestationJSON: data, expectedDigest: ref.digest)
            if case .verified = outcome {
                Self.cacheVerification(digest: ref.digest, outcome: outcome, defaults: defaults)
            }
            return outcome
        } catch {
            return .unverified(.fetchTransient(error.localizedDescription))
        }
    }

    // MARK: - Verified-digest cache

    private static let cacheKey = "ai.teemoon.provenance.verified"

    static func cachedVerification(digest: String, defaults: UserDefaults = .standard) -> ImageProvenance? {
        guard let cache = defaults.dictionary(forKey: cacheKey) as? [String: [String]],
              let entry = cache[digest] else { return nil }
        switch entry.count {
        case 5:  // [repo, identity, ref, commit, tlog] — empty string means nil
            return .verified(repositoryURL: entry[0], workflowIdentity: entry[1],
                             sourceRef: entry[2].isEmpty ? nil : entry[2],
                             sourceCommit: entry[3].isEmpty ? nil : entry[3],
                             transparencyLogChecked: entry[4] == "true")
        case 3:  // legacy pre-ref/commit entry
            return .verified(repositoryURL: entry[0], workflowIdentity: entry[1],
                             sourceRef: nil, sourceCommit: nil,
                             transparencyLogChecked: entry[2] == "true")
        default:
            return nil
        }
    }

    static func cacheVerification(digest: String, outcome: ImageProvenance, defaults: UserDefaults = .standard) {
        guard case .verified(let repo, let identity, let ref, let commit, let tlog) = outcome else { return }
        var cache = (defaults.dictionary(forKey: cacheKey) as? [String: [String]]) ?? [:]
        cache[digest] = [repo, identity, ref ?? "", commit ?? "", tlog ? "true" : "false"]
        // Old digests rotate out of manifests; keep the cache bounded.
        if cache.count > 64 { cache = cache.filter { $0.key == digest } }
        defaults.set(cache, forKey: cacheKey)
    }
}
