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
