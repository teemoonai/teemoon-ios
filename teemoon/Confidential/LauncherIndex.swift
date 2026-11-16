//
//  LauncherIndex.swift
//  teemoon
//
//  Trust scope (d), 1.1.0: the measured compose names the launcher by its linux/amd64 CHILD digest, but
//  near.ai attests the multi-platform INDEX. OCI has no child → parent lookup, so this finds the index on
//  Docker Hub and proves it lists the child. Spec and fixture: conformance/nearai-trust (audit 2026-10-30,
//  The maintainer's conditions 2026-10-31).
//
//  Don't widen it: anonymous pull token only; every request names the one repository below; it runs only
//  during verification; no credentials or identifiers in any header; no cert pinning on these hosts.
//

import CryptoKit
import Foundation

actor LauncherIndex {
    static let repository = "nearaidev/compose-manager-launcher"
    static let indexMediaType = "application/vnd.oci.image.index.v1+json"
    /// Tags tried before any listing, in this order (the maintainer 2026-10-31: "prod/latest first").
    static let firstTags = ["prod", "latest"]
    static let scanCap = 200
    /// The one signer the index's attestation may carry (org-level trust is not enough here).
    static let builderRepository = "https://github.com/nearai/compose-manager"
    static let builderRef = "refs/heads/master"
    static let builder = builderRepository + "/.github/workflows/build.yml@" + builderRef
    static let negativeTTL: TimeInterval = 24 * 3600

    enum Result: Equatable, Sendable {
        /// The index that lists the child for linux/amd64, verified by content hash.
        case found(indexDigest: String)
        /// No index near.ai published lists it (within the cap); remembered for a day.
        case notFound
        /// Network trouble: no evidence either way.
        case inconclusive(String)
    }

    private let session: URLSession
    private let defaults: UserDefaults
    private let now: () -> Date
    private static let cacheKey = "launcherIndex.childToIndex"
    private static let negativeKey = "launcherIndex.notFoundAt"

    init(session: URLSession = .shared, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.session = session
        self.defaults = defaults
        self.now = now
    }

    /// `child`: 64 hex, the digest the measured compose names.
    func resolve(child: String) async -> Result {
        let child = child.lowercased()
        if let index = (defaults.dictionary(forKey: Self.cacheKey) as? [String: String])?[child] {
            return .found(indexDigest: index)
        }
        if let at = (defaults.dictionary(forKey: Self.negativeKey) as? [String: Double])?[child],
           now().timeIntervalSince1970 - at < Self.negativeTTL {
            return .notFound
        }
        guard let token = await token() else { return .inconclusive("couldn't get a registry token") }
        var tried = Set<String>()
        var sawNetworkTrouble = false
        func check(tag: String) async -> String? {
            switch await head(tag: tag, token: token) {
            case .digest(let d):
                guard !tried.contains(d) else { return nil }
                tried.insert(d)
                switch await verify(index: d, lists: child, token: token) {
                case .some(true): return d
                case .some(false): return nil
                case nil: sawNetworkTrouble = true; return nil
                }
            case .missing: return nil
            case .trouble: sawNetworkTrouble = true; return nil
            }
        }
        for tag in Self.firstTags {
            if let d = await check(tag: tag) { return remember(child: child, index: d) }
        }
        // Neither prod nor latest resolved to an index listing the child: newest tags first, capped.
        guard let tags = await listTags(token: token) else {
            return .inconclusive("couldn't list the launcher's tags")
        }
        for tag in Self.newestFirst(tags).filter({ !Self.firstTags.contains($0) }).prefix(Self.scanCap) {
            if let d = await check(tag: tag) { return remember(child: child, index: d) }
        }
        if sawNetworkTrouble { return .inconclusive("some tags couldn't be read") }
        var negative = defaults.dictionary(forKey: Self.negativeKey) as? [String: Double] ?? [:]
        negative[child] = now().timeIntervalSince1970
        defaults.set(negative, forKey: Self.negativeKey)
        return .notFound
    }

    private func remember(child: String, index: String) -> Result {
        var cache = defaults.dictionary(forKey: Self.cacheKey) as? [String: String] ?? [:]
        cache[child] = index
        defaults.set(cache, forKey: Self.cacheKey)
        return .found(indexDigest: index)
    }

    /// Dated staging tags sort by date; everything else after them, reverse lexical.
    nonisolated static func newestFirst(_ tags: [String]) -> [String] {
        tags.sorted { $0 > $1 }
    }

    /// Pure: the bytes are the index named by `digest`, and it lists `child` for linux/amd64.
    nonisolated static func indexLists(child: String, bytes: Data, digest: String) -> Bool {
        guard Data(SHA256.hash(data: bytes)).hexString == digest.lowercased(),
              let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              json["mediaType"] as? String == indexMediaType,
              let manifests = json["manifests"] as? [[String: Any]] else { return false }
        return manifests.contains { m in
            let annotations = m["annotations"] as? [String: String]
            guard annotations?["vnd.docker.reference.type"] != "attestation-manifest",
                  let platform = m["platform"] as? [String: String] else { return false }
            return m["digest"] as? String == "sha256:" + child.lowercased()
                && platform["os"] == "linux" && platform["architecture"] == "amd64"
        }
    }

    /// `outcome` is the index attestation's verdict; anything not signed by `builder` is refused.
    nonisolated static func signedByItsBuilder(_ outcome: ImageProvenance) -> ImageProvenance {
        guard case .verified(let repo, let identity, let ref, _, _) = outcome else { return outcome }
        if repo == builderRepository && identity == builder && ref == builderRef { return outcome }
        let inOrg = BuildIdentityPolicy.nearAI.contains { $0.repository(forIdentity: identity) != nil }
        return .unverified(inOrg ? .identityNotThisBuild(got: identity) : .identityNotTrusted(got: identity))
    }

    // MARK: - Registry calls (every one names `repository`)

    private enum Head { case digest(String), missing, trouble }

    private func request(_ url: URL, token: String?, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue(Self.indexMediaType, forHTTPHeaderField: "Accept")
        return r
    }

    private func token() async -> String? {
        var c = URLComponents(string: "https://auth.docker.io/token")!
        c.queryItems = [.init(name: "service", value: "registry.docker.io"),
                        .init(name: "scope", value: "repository:\(Self.repository):pull")]
        guard let url = c.url, let (data, response) = try? await session.data(for: URLRequest(url: url)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["token"] as? String
    }

    private func head(tag: String, token: String) async -> Head {
        guard let url = URL(string: "https://registry-1.docker.io/v2/\(Self.repository)/manifests/\(tag)"),
              let (_, response) = try? await session.data(for: request(url, token: token, method: "HEAD")),
              let http = response as? HTTPURLResponse else { return .trouble }
        if http.statusCode == 404 { return .missing }
        guard http.statusCode == 200,
              let digest = http.value(forHTTPHeaderField: "Docker-Content-Digest"), digest.hasPrefix("sha256:") else {
            return .trouble
        }
        return .digest(String(digest.dropFirst("sha256:".count)).lowercased())
    }

    /// nil: the index couldn't be fetched.
    private func verify(index digest: String, lists child: String, token: String) async -> Bool? {
        guard let url = URL(string: "https://registry-1.docker.io/v2/\(Self.repository)/manifests/sha256:\(digest)"),
              let (data, response) = try? await session.data(for: request(url, token: token)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.indexLists(child: child, bytes: data, digest: digest)
    }

    private func listTags(token: String) async -> [String]? {
        guard let url = URL(string: "https://registry-1.docker.io/v2/\(Self.repository)/tags/list"),
              let (data, response) = try? await session.data(for: request(url, token: token)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["tags"] as? [String]
    }
}
