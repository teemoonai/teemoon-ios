//
//  LauncherIndexTests.swift
//  teemoonTests
//
//  Trust scope (d) against audit's pinned launcher index (conformance/nearai-trust/launcher-index-91fdff3c.json)
//  and a scripted registry. The maintainer's conditions (2026-10-31): prod, then latest, then a newest-first tag scan —
//  a match under prod makes no tags/list request; every request names one repository; anonymous token only.
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

@Suite("Trust scope — the launcher's index", .serialized)
struct LauncherIndexTests {
    static let child = "079a14b41deb11e0e27f9b69648e8b3d89bd6fb9ccf6071643b8f447fa415085"
    static let index = "91fdff3cfa3543d72656b2368c7d8a0a83d95a0f1087378c897aa1537acdba56"

    static func indexBytes(file: String = #filePath) throws -> Data? {
        guard TestFixture.sourceTreeAvailable() else { return nil }
        let url = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conformance/nearai-trust/launcher-index-91fdff3c.json")
        return try Data(contentsOf: url)
    }

    private func resolver(tags: [String: String], list: [String]? = nil) -> (LauncherIndex, UserDefaults) {
        Registry.reset(tags: tags, list: list)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Registry.self]
        let defaults = UserDefaults(suiteName: "launcher-\(UUID().uuidString)")!
        return (LauncherIndex(session: URLSession(configuration: config), defaults: defaults), defaults)
    }

    @Test func thePinnedIndexListsTheMeasuredChild() throws {
        guard let bytes = try Self.indexBytes() else { return }
        #expect(LauncherIndex.indexLists(child: Self.child, bytes: bytes, digest: Self.index))
        var other = Self.child; other.removeLast(); other += "0"
        #expect(!LauncherIndex.indexLists(child: other, bytes: bytes, digest: Self.index), "a replaced child digest fails")
        #expect(!LauncherIndex.indexLists(child: Self.child, bytes: bytes + Data(" ".utf8), digest: Self.index),
                "bytes that don't hash to the digest can't pass")
        // Dropping the attestation-manifest entry changes the bytes, so test the rule on a re-hashed copy.
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json["manifests"] = (json["manifests"] as? [[String: Any]])?.filter {
            ($0["annotations"] as? [String: String])?["vnd.docker.reference.type"] != "attestation-manifest" }
        let trimmed = try JSONSerialization.data(withJSONObject: json)
        #expect(LauncherIndex.indexLists(child: Self.child, bytes: trimmed, digest: Data(SHA256.hash(data: trimmed)).hexString),
                "dropping a tag-only child still passes")
    }

    @Test func aMatchUnderProdAsksNothingElse() async throws {
        guard let bytes = try Self.indexBytes() else { return }
        Registry.indexes = [Self.index: bytes]
        let (r, _) = resolver(tags: ["prod": Self.index])
        Registry.indexes = [Self.index: bytes]
        #expect(await r.resolve(child: Self.child) == .found(indexDigest: Self.index))
        #expect(!Registry.paths.contains { $0.hasSuffix("/tags/list") }, "no tags/list when prod resolves")
        #expect(!Registry.paths.contains { $0.contains("/manifests/latest") })
        #expect(Registry.paths.allSatisfy { $0.contains("nearaidev/compose-manager-launcher") || $0.hasPrefix("/token") })
        #expect(Registry.tokenScopes == ["repository:nearaidev/compose-manager-launcher:pull"])
        #expect(Registry.authorizations.allSatisfy { $0 == nil || $0 == "Bearer t0k" }, "no other credential is ever sent")
    }

    @Test func neitherProdNorLatestScansNewestFirstAndCachesTheAnswer() async throws {
        guard let bytes = try Self.indexBytes() else { return }
        let (r, _) = resolver(tags: ["prod": String(repeating: "e", count: 64), "staging-20261030": Self.index],
                              list: ["staging-20260901", "staging-20261030", "prod"])
        Registry.indexes = [Self.index: bytes]
        #expect(await r.resolve(child: Self.child) == .found(indexDigest: Self.index))
        let heads = Registry.paths.filter { $0.contains("/manifests/") && !$0.contains("sha256:") }
        #expect(heads.first?.hasSuffix("/prod") == true && heads.dropFirst().first?.hasSuffix("/latest") == true)
        #expect(heads.contains { $0.hasSuffix("staging-20261030") } && !heads.contains { $0.hasSuffix("staging-20260901") },
                "stops at the first match, newest first")
        let before = Registry.paths.count
        #expect(await r.resolve(child: Self.child) == .found(indexDigest: Self.index))
        #expect(Registry.paths.count == before, "cached by digest: no second lookup")
    }

    @Test func noIndexIsRememberedForADay() async throws {
        guard try Self.indexBytes() != nil else { return }
        let (r, _) = resolver(tags: [:], list: ["a", "b"])
        #expect(await r.resolve(child: Self.child) == .notFound)
        let before = Registry.paths.count
        #expect(await r.resolve(child: Self.child) == .notFound)
        #expect(Registry.paths.count == before)
    }
}

/// A scripted Docker Hub: token, HEAD per tag, GET per index digest, tags/list.
private final class Registry: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var tags: [String: String] = [:]
    nonisolated(unsafe) static var indexes: [String: Data] = [:]
    nonisolated(unsafe) static var list: [String]? = nil
    nonisolated(unsafe) static var paths: [String] = []
    nonisolated(unsafe) static var tokenScopes: [String] = []
    nonisolated(unsafe) static var authorizations: [String?] = []

    static func reset(tags: [String: String], list: [String]?) {
        self.tags = tags; self.list = list; indexes = [:]; paths = []; tokenScopes = []; authorizations = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        Self.paths.append(url.path)
        Self.authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
        func reply(_ status: Int, _ body: Data = Data(), headers: [String: String] = [:]) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if url.host == "auth.docker.io" {
            Self.tokenScopes.append(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value ?? "")
            return reply(200, Data(#"{"token":"t0k"}"#.utf8))
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
