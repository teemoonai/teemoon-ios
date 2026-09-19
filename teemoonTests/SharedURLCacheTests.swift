//
//  SharedURLCacheTests.swift
//  teemoonTests
//
//  Pins the fix for the teemoonai/audits runtime-pass MEDIUM on 1.0.2
//  (client/teemoon-ios/v1.0.2-21d534e.md): the near.ai key was readable nine
//  times from Library/Caches/ai.teemoon.app/Cache.db after one session, because
//  every authenticated fetch outside the chat request ran on the shared session
//  with its default disk cache. The app itself must disable that cache — these
//  tests never call `SharedURLCache.disable()`; the hosted `TeemoonApp.init`
//  already did, or the tripwire below stores a bearer token and fails.
//

import Foundation
import Testing
@testable import teemoon

/// Answers any request with a cacheable 200 and asks CFNetwork to store it.
private final class CacheableStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cache-tripwire.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Cache-Control": "public, max-age=86400", "Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Shared URL cache holds no authenticated request")
struct SharedURLCacheTests {

    @Test("the app launched with a zero-capacity shared cache")
    func sharedCacheIsDisabledByTheApp() {
        #expect(URLCache.shared.diskCapacity == 0)
        #expect(URLCache.shared.memoryCapacity == 0)
        let inUse = URLSession.shared.configuration.urlCache
        #expect(inUse?.diskCapacity == 0)
    }

    @Test("a cacheable authenticated response is not stored")
    func authenticatedResponseIsNotCached() async throws {
        URLProtocol.registerClass(CacheableStubProtocol.self)
        defer { URLProtocol.unregisterClass(CacheableStubProtocol.self) }

        var request = URLRequest(url: URL(string: "https://cache-tripwire.invalid/v1/attestation/report?nonce=1")!)
        request.setValue("Bearer tripwire-secret-do-not-persist", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSessionHTTP().data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(!data.isEmpty)

        #expect(URLCache.shared.cachedResponse(for: request) == nil)
        #expect(URLSession.shared.configuration.urlCache?.cachedResponse(for: request) == nil)
    }

    @Test("the default cache store is not on disk after launch")
    func defaultStoreIsGone() {
        // `disable()` removes the files earlier builds wrote and must not
        // create them again by opening the default cache to empty it.
        for url in SharedURLCache.defaultStoreFiles {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) exists")
        }
    }
}
