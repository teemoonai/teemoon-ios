//
//  SharedURLCacheTests.swift
//  teemoonTests
//
//  Pins the fix for the audits runtime-pass MEDIUM on 1.0.2: an authenticated
//  request made through the production HTTP seam must never be archived into
//  the shared URL cache, even when the server says it may be cached.
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

    @Test("the shared cache is zero-capacity once the app has launched")
    func sharedCacheIsDisabled() {
        SharedURLCache.disable()
        #expect(URLCache.shared.diskCapacity == 0)
        #expect(URLCache.shared.memoryCapacity == 0)
        // The session every authenticated fetch defaults to must be using it.
        let inUse = URLSession.shared.configuration.urlCache
        #expect(inUse == nil || inUse!.diskCapacity == 0)
    }

    @Test("a cacheable authenticated response is not stored")
    func authenticatedResponseIsNotCached() async throws {
        SharedURLCache.disable()
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
}
