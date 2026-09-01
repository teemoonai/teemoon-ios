//
//  ParsingValidationTests.swift
//  teemoonTests
//
//  Replay-based parsing validator. Feeds captured (decrypted) SSE delta streams
//  from Fixtures/parsing/<provider>/<model>/<scenario>.jsonl back through
//  SSEStreamParser + the tool-call recovery/strip logic, and asserts the two
//  invariants that define correct behavior:
//
//    1. Every tool call the model emitted is RECOVERED (name shows up in the
//       parsed tool calls) — recover, don't strip.
//    2. NO tool-call/reasoning markup leaks into the final user-visible content.
//
//  Each .jsonl has a sibling .expected.json describing what to assert. Drop in a
//  new capture + expected pair and it's validated automatically — this is the
//  reusable rig for every NEAR model and any other provider.
//
//  Fixture classes (see each .expected.json `class`):
//    · well-formed          — canonical format teemoon already handles (should PASS today)
//    · recoverable-malformed — model malformed below its grammar; recovery target (RED until fixed)
//    · low-confidence        — unrecoverable; asserts skip + no-leak (added later)
//

import Foundation
import Testing
@testable import teemoon

@Suite("Parsing validation — replay captured streams")
struct ParsingValidationTests {

    // MARK: expected-spec schema

    // Tolerant of missing keys so a fixture only declares the fields it asserts.
    private struct ExpectedSpec: Decodable {
        struct Call: Decodable { let name: String }
        struct ToolSpec: Decodable {
            let name: String
            var params: [String] = []
            var required: [String] = []
            enum K: String, CodingKey { case name, params, required }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: K.self)
                name = try c.decode(String.self, forKey: .name)
                params = try c.decodeIfPresent([String].self, forKey: .params) ?? []
                required = try c.decodeIfPresent([String].self, forKey: .required) ?? []
            }
        }
        var hasTools = true
        var availableTools: [ToolSpec] = []
        var expectToolCalls: [Call] = []
        var contentMustNotContain: [String] = []

        enum K: String, CodingKey { case hasTools, availableTools, expectToolCalls, contentMustNotContain }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            hasTools = try c.decodeIfPresent(Bool.self, forKey: .hasTools) ?? true
            availableTools = try c.decodeIfPresent([ToolSpec].self, forKey: .availableTools) ?? []
            expectToolCalls = try c.decodeIfPresent([Call].self, forKey: .expectToolCalls) ?? []
            contentMustNotContain = try c.decodeIfPresent([String].self, forKey: .contentMustNotContain) ?? []
        }

        var recoverySpecs: [RecoveryToolSpec] {
            availableTools.map { .init(name: $0.name, paramNames: $0.params, requiredParams: $0.required) }
        }
    }

    // MARK: fixture discovery

    private static func fixturesDir(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parsing")
    }

    /// Every `<scenario>.jsonl` fixture.
    ///
    /// Asks the BUNDLE first, because on a device there is no source tree to
    /// walk — and the Resources phase flattens `Fixtures/parsing/<provider>/
    /// <model>/` into the bundle root, so the hierarchy that made a recursive
    /// enumeration necessary does not survive the copy. Scenario filenames are
    /// already unique, which is what makes flattening safe here.
    ///
    /// Falls back to walking the source tree so a host run still works if the
    /// fixtures ever stop being bundled.
    private static func allFixtures() -> [URL] {
        let bundled = TestFixture.all(withExtension: "jsonl")
        if !bundled.isEmpty {
            return bundled.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let root = fixturesDir()
        guard let en = FileManager.default.enumerator(at: root,
                                                      includingPropertiesForKeys: nil) else { return [] }
        return en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
    }

    // MARK: replay harness

    /// Mirrors the finish-path decision in GenerationEngine: recover structured
    /// tool calls, else text-based tool calls; strip text tool-call markup from
    /// the visible content only when a text tool call was recovered.
    private struct ReplayResult {
        let recovered: [ToolCallState]
        let finalContent: String
    }

    private func replay(events: [String], hasTools: Bool,
                        tools: [RecoveryToolSpec]) -> ReplayResult {
        let parser = SSEStreamParser(hasTools: hasTools, tools: tools)
        for line in events where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            _ = parser.consume(Data("data: \(line)\n\n".utf8))
        }
        _ = parser.consume(Data("data: [DONE]\n\n".utf8))

        var recovered = Array(parser.toolCallStates.values)
        let textCalls = SSEStreamParser.parseTextToolCalls(from: parser.accumulatedContent, tools: tools)
        if recovered.isEmpty { recovered = Array(textCalls.values) }

        let isText = parser.isTextBasedToolCall || !textCalls.isEmpty
        let stripped = isText
            ? SSEStreamParser.stripTextToolCalls(from: parser.accumulatedContent)
            : parser.accumulatedContent
        // Mirror GenerationEngine's final containment net.
        let finalContent = SSEStreamParser.sanitizeToolMarkup(from: stripped).clean
        return ReplayResult(recovered: recovered, finalContent: finalContent)
    }

    /// Multiset containment: every expected name appears at least as many times
    /// as expected among the recovered calls.
    private func recovers(_ expected: [String], in recovered: [ToolCallState]) -> Bool {
        var have: [String: Int] = [:]
        for c in recovered { have[c.name, default: 0] += 1 }
        var want: [String: Int] = [:]
        for n in expected { want[n, default: 0] += 1 }
        return want.allSatisfy { have[$0.key, default: 0] >= $0.value }
    }

    // MARK: the validator

    @Test func replayedStreamsParseWithoutLeaks() throws {
        let fixtures = Self.allFixtures()
        #expect(!fixtures.isEmpty, "no parsing fixtures found under Fixtures/parsing")

        for jsonl in fixtures {
            let name = jsonl.deletingPathExtension().lastPathComponent
            let expectedURL = jsonl.deletingPathExtension().appendingPathExtension("expected.json")
            guard let expData = try? Data(contentsOf: expectedURL) else {
                Issue.record("[\(name)] missing sibling expected.json")
                continue
            }
            let spec = try JSONDecoder().decode(ExpectedSpec.self, from: expData)
            let events = (try String(contentsOf: jsonl, encoding: .utf8))
                .split(separator: "\n").map(String.init)

            let result = replay(events: events, hasTools: spec.hasTools, tools: spec.recoverySpecs)

            // Invariant 1 — every emitted tool call is recovered.
            let expectedNames = spec.expectToolCalls.map(\.name)
            #expect(recovers(expectedNames, in: result.recovered),
                    "[\(name)] tool calls not recovered — expected \(expectedNames), got \(result.recovered.map(\.name))")

            // Invariant 2 — no markup leaks into visible content.
            for marker in spec.contentMustNotContain {
                #expect(!result.finalContent.contains(marker),
                        "[\(name)] leaked `\(marker)` into visible content: \(result.finalContent.prefix(200))")
            }
        }
    }
}
