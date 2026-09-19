//
//  EndpointDirectoryTests.swift
//  teemoonTests
//
//  Parses near.ai's authoritative endpoints directory (a real captured
//  snapshot, Fixtures/nearai_endpoints_directory.json) into the model → direct
//  host map used by the E2EE key fetch.
//

import Foundation
import Testing
@testable import teemoon

@Suite("EndpointDirectory")
struct EndpointDirectoryTests {

    static func loadFixture(file: String = #filePath) throws -> Data {
        return try TestFixture.data("nearai_endpoints_directory.json", file: file)
    }

    @Test func parsesRealDirectory() throws {
        let map = try #require(EndpointDirectory.parseDirectory(try Self.loadFixture()))
        // Authoritative mappings — including slugs no heuristic would derive.
        #expect(map["zai-org/glm-5.1-fp8"] == "https://glm-5-1.completions.near.ai/v1")
        #expect(map["deepseek-ai/deepseek-v4-flash"] == "https://dsv4-flash.completions.near.ai/v1")
        // A domain serving multiple models maps each of them.
        #expect(map["z-ai/glm-5.2"] == "https://glm-5-2.completions.near.ai/v1")
        #expect(map["zai-org/glm-5.2-fp8"] == "https://glm-5-2.completions.near.ai/v1")
    }

    @Test func lookupIsCaseInsensitiveOnModelId() throws {
        let map = try #require(EndpointDirectory.parseDirectory(try Self.loadFixture()))
        // Keys are lowercased; callers lowercase the requested id before lookup.
        #expect(map["ZAI-ORG/GLM-5.1-FP8".lowercased()] == "https://glm-5-1.completions.near.ai/v1")
    }

    @Test func malformedJSONReturnsNil() {
        #expect(EndpointDirectory.parseDirectory(Data("{}".utf8)) == nil
                || EndpointDirectory.parseDirectory(Data("{}".utf8))?.isEmpty == true)
        #expect(EndpointDirectory.parseDirectory(Data("not json".utf8)) == nil)
    }

    @Test func absoluteDomainIsNotDoublePrefixed() {
        // Defensive: a domain already carrying a scheme is used as-is.
        let data = Data(#"{"endpoints":[{"domain":"https://x.completions.near.ai","models":["a/b"]}]}"#.utf8)
        #expect(EndpointDirectory.parseDirectory(data)?["a/b"] == "https://x.completions.near.ai/v1")
    }
}

/// The directory chooses where sealed prompts go, so it is also a filter.
@Suite("EndpointDirectory host rule")
struct EndpointDirectoryHostRuleTests {

    @Test func nearAIHostsOverHTTPSAreAccepted() {
        #expect(EndpointDirectory.confidentialHost("glm-5-3-flash.completions.near.ai")
                == "https://glm-5-3-flash.completions.near.ai")
        #expect(EndpointDirectory.confidentialHost("https://dsv4-flash.completions.near.ai")
                == "https://dsv4-flash.completions.near.ai")
    }

    @Test func everythingElseIsRejected() {
        #expect(EndpointDirectory.confidentialHost("http://glm.completions.near.ai") == nil)
        #expect(EndpointDirectory.confidentialHost("glm.completions.near.ai.evil.com") == nil)
        #expect(EndpointDirectory.confidentialHost("evil.example") == nil)
        #expect(EndpointDirectory.confidentialHost("glm.completions.near.ai:8443") == nil)
        #expect(EndpointDirectory.confidentialHost("glm.completions.near.ai/redirect") == nil)
    }

    /// A rejected row drops out of the map rather than poisoning it.
    @Test func aRejectedRowIsDroppedNotKept() throws {
        let json = """
        {"endpoints":[{"domain":"evil.example","models":["z-ai/glm-5.3-flash"]},
                      {"domain":"glm-5-3-flash.completions.near.ai","models":["z-ai/glm-5.3-flash"]}]}
        """
        let map = try #require(EndpointDirectory.parseDirectory(Data(json.utf8)))
        #expect(map["z-ai/glm-5.3-flash"] == "https://glm-5-3-flash.completions.near.ai/v1")
        #expect(!map.values.contains { $0.contains("evil.example") })
    }

private final class FailingDirectoryStub: URLProtocol {
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("EndpointDirectory — a failure is remembered")
struct EndpointDirectoryFailureTests {
    /// `buildModels` asks once per own-fleet row. A host that is down must
    /// cost one round trip per minute, not one timeout per row.
    @Test func aFailedFetchIsNotRepeatedForEveryRow() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingDirectoryStub.self]
        FailingDirectoryStub.requests = 0
        let directory = EndpointDirectory(session: URLSession(configuration: config))
        for id in ["own/one", "own/two", "own/three"] {
            _ = await directory.directBase(forModel: id)
        }
        #expect(FailingDirectoryStub.requests == 1)
    }
}
}
