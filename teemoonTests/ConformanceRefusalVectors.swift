//
//  ConformanceRefusalVectors.swift
//  teemoonTests
//
//  Which error bodies mean "this model does not take the effort setting": a refusal
//  is retried once without the field, anything else fails the send as usual. Build 58
//  matched snake case only, so xAI's camel-case 400 failed every send to
//  grok-build-0.1. Each verdict here is declared, not computed, so a matcher change
//  that drops a row fails this suite, and Android runs the same rows.
//

import Foundation
import Testing
@testable import teemoon

struct RefusalVectors: Encodable {
    struct Row: Encodable {
        let note: String
        /// "live <date>" for a body a provider actually sent; "shape" for one written to the rule.
        let source: String
        let status: Int
        let body: String
        /// true: retry once without the effort field. false: not a refusal.
        let refusal: Bool
    }
    let rule: String
    let rows: [Row]
}

enum ConformanceRefusalVectors {
    static let rule = """
        A response is a refusal of the effort setting only when its status is 400 and its \
        body names one of the fields the app sends for it (reasoning_effort, \
        chat_template_kwargs, enable_thinking). Names are matched case-insensitively with \
        '_', '.' and spaces removed, so reasoningEffort and reasoning.effort count. A refusal \
        is retried once without the field; the model is not sent it again this launch.
        """

    static let rows: [RefusalVectors.Row] = [
        .init(note: "xAI grok-build-0.1, camel case; build 58 missed it and every send failed",
              source: "live 2026-10-22", status: 400,
              body: #"{"code":"invalid-argument","error":"Model grok-build-0.1 does not support parameter reasoningEffort."}"#,
              refusal: true),
        .init(note: "snake case in a nested OpenAI-style error", source: "shape", status: 400,
              body: #"{"error":{"message":"Unknown field reasoning_effort"}}"#, refusal: true),
        .init(note: "words with spaces", source: "shape", status: 400,
              body: #"{"error":"Invalid reasoning effort."}"#, refusal: true),
        .init(note: "dotted path", source: "shape", status: 400,
              body: #"{"error":"Unsupported parameter: reasoning.effort"}"#, refusal: true),
        .init(note: "the thinking switch's outer field", source: "shape", status: 400,
              body: #"{"error":"unexpected field chat_template_kwargs"}"#, refusal: true),
        .init(note: "the thinking switch's inner field, camel case", source: "shape", status: 400,
              body: #"{"error":"unknown field enableThinking"}"#, refusal: true),
        .init(note: "a 400 about something else", source: "shape", status: 400,
              body: #"{"error":"context length exceeded"}"#, refusal: false),
        .init(note: "names the field but is not a 400", source: "shape", status: 401,
              body: "reasoning_effort", refusal: false),
        .init(note: "says effort without naming the field", source: "shape", status: 400,
              body: #"{"error":"invalid effort"}"#, refusal: false),
        .init(note: "about reasoning tokens, not the setting", source: "shape", status: 400,
              body: #"{"error":"reasoning tokens exceed max_tokens"}"#, refusal: false),
    ]

    static func refusals() -> RefusalVectors { RefusalVectors(rule: rule, rows: rows) }
}

@Suite("Conformance vectors — effort refusals")
struct ConformanceRefusalTests {

    @Test(arguments: ConformanceRefusalVectors.rows.indices)
    func everyRowGetsItsVerdict(_ index: Int) {
        let row = ConformanceRefusalVectors.rows[index]
        #expect(ReasoningEffort.isRefusal(status: row.status, body: Data(row.body.utf8)) == row.refusal,
                "\(row.note): \(row.body)")
    }

    @Test func theCommittedFixtureMatchesTheTable() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let url = ConformanceEmitTests.outputDirectory().appendingPathComponent("refusals.json")
        let committed = try Data(contentsOf: url)
        let fresh = try ConformanceEncoder.encode(ConformanceDocument(
            kitVersion: ConformanceVectors.kitVersion, fixtureClass: "refusals",
            sourceOfTruth: "teemoon-ios", vectors: ConformanceRefusalVectors.refusals()))
        #expect(committed == fresh, "conformance/refusals.json is stale: run make conformance")
    }
}
