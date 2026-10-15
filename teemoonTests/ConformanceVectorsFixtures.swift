//
//  ConformanceVectorsFixtures.swift
//  teemoonTests
//
//  Kit 0.4.0 — §7 items 5–8, the classes the Android port was still owed:
//  recorded SSE streams (the tool-call dialects) with what the parser makes of
//  them, the cloud catalogue responses with the picker rows the adapters
//  build, and Brave's answer/context bodies with what teemoon shows the
//  model and the user. Every expectation here is COMPUTED from the production
//  code path over a frozen fixture, so the bytes are stable and a Kotlin
//  port that disagrees is wrong by definition (§7.2).
//
import Foundation
import Testing
@testable import teemoon

// MARK: - §7 item 5/6 — recorded streams and the dialects

struct StreamVectors: Encodable {
    struct ToolSpec: Encodable { let name: String; let params: [String]; let required: [String] }
    struct Case: Encodable {
        let name: String
        let hasTools: Bool
        let availableTools: [ToolSpec]
        /// Raw `data:` payloads, one per event, exactly as recorded.
        let events: [String]
        let expectToolCalls: [String]
        let contentMustNotContain: [String]
        /// What the production parser recovered — names in call order — and the text left visible.
        let recoveredToolNames: [String]
        let finalContent: String
    }
    let cases: [Case]
}

// MARK: - §7 item 7 — catalogue responses and the rows the adapters build

struct CatalogVectors: Encodable {
    struct Row: Encodable {
        let id: String, displayName: String, vendor: String, price: String, contextWindow: String
        let isNew: Bool
        let capabilities: [String]
        let summary: String?, modelPageURL: String?, huggingFaceURL: String?, githubURL: String?, deprecationDate: String?
    }
    struct XAI: Encodable { let languageModels: String; let models: String; let rows: [Row] }
    struct Fireworks: Encodable { let models: String; let rows: [Row] }
    struct LMStudio: Encodable { let models: String; let rows: [Row] }
    /// `isNew` and the retirement label are relative to this instant, never to the clock.
    let pinnedNow: String
    let xai: XAI
    let fireworks: Fireworks
    let lmstudio: LMStudio
}

// MARK: - §7 item 8 — Brave bodies

struct BraveVectors: Encodable {
    struct Source: Encodable { let url: String, domain: String, title: String, snippet: String }
    let answersContent: String
    let visible: String
    let sources: [Source]
    let llmContext: String
    let llmContextXML: String
    let llmContextNews: String
    let llmContextNewsXML: String
    let llmContextNewsXMLWithoutPublished: String
}

struct FixtureKitError: Error, CustomStringConvertible { let description: String; init(_ m: String) { description = m } }

enum ConformanceFixtureVectors {
    static let pinnedNow: Date = {
        var when = DateComponents(); when.year = 2026; when.month = 7; when.day = 29
        when.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: when)!
    }()

    static func capabilityNames(_ caps: ModelCapabilities?) -> [String] {
        guard let caps else { return [] }
        let table: [(ModelCapabilities, String)] = [(.tools, "tools"), (.vision, "vision"), (.uploads, "uploads"), (.audio, "audio"),
                                                    (.thinking, "thinking"), (.completion, "completion"), (.embedding, "embedding"), (.insert, "insert")]
        return table.filter { caps.contains($0.0) }.map(\.1)
    }

    static func row(_ m: KnownModel) -> CatalogVectors.Row {
        let iso = ISO8601DateFormatter()
        return .init(id: m.id, displayName: m.displayName, vendor: m.vendor, price: m.price, contextWindow: m.contextWindow,
                     isNew: m.isNew, capabilities: capabilityNames(m.capabilities), summary: m.summary, modelPageURL: m.modelPageURL,
                     huggingFaceURL: m.huggingFaceURL, githubURL: m.githubURL, deprecationDate: m.deprecationDate.map { iso.string(from: $0) })
    }

    // MARK: streams

    private struct ExpectedSpec: Decodable {
        struct Call: Decodable { let name: String }
        struct ToolSpec: Decodable {
            let name: String; var params: [String] = []; var required: [String] = []
            enum K: String, CodingKey { case name, params, required }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: K.self)
                name = try c.decode(String.self, forKey: .name)
                params = try c.decodeIfPresent([String].self, forKey: .params) ?? []
                required = try c.decodeIfPresent([String].self, forKey: .required) ?? []
            }
        }
        var hasTools = true; var availableTools: [ToolSpec] = []; var expectToolCalls: [Call] = []; var contentMustNotContain: [String] = []
        enum K: String, CodingKey { case hasTools, availableTools, expectToolCalls, contentMustNotContain }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            hasTools = try c.decodeIfPresent(Bool.self, forKey: .hasTools) ?? true
            availableTools = try c.decodeIfPresent([ToolSpec].self, forKey: .availableTools) ?? []
            expectToolCalls = try c.decodeIfPresent([Call].self, forKey: .expectToolCalls) ?? []
            contentMustNotContain = try c.decodeIfPresent([String].self, forKey: .contentMustNotContain) ?? []
        }
    }

    /// The same replay ParsingValidationTests performs — the production parser, then the text-recovery fallback and the sanitize pass.
    static func replay(events: [String], hasTools: Bool, tools: [RecoveryToolSpec]) -> (names: [String], finalContent: String) {
        let parser = SSEStreamParser(hasTools: hasTools, tools: tools)
        for line in events where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            _ = parser.consume(Data("data: \(line)\n\n".utf8))
        }
        _ = parser.consume(Data("data: [DONE]\n\n".utf8))
        var recovered = parser.toolCallStates.sorted { $0.key < $1.key }.map(\.value)
        let textCalls = SSEStreamParser.parseTextToolCalls(from: parser.accumulatedContent, tools: tools)
        if recovered.isEmpty { recovered = textCalls.sorted { $0.key < $1.key }.map(\.value) }
        let isText = parser.isTextBasedToolCall || !textCalls.isEmpty
        let stripped = isText ? SSEStreamParser.stripTextToolCalls(from: parser.accumulatedContent) : parser.accumulatedContent
        return (recovered.map(\.name), SSEStreamParser.sanitizeToolMarkup(from: stripped).clean)
    }

    static func streams(file: String = #filePath) throws -> StreamVectors {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("Fixtures/parsing")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { throw FixtureKitError("no parsing fixtures") }
        let files = en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
        var cases: [StreamVectors.Case] = []
        for jsonl in files {
            let spec = try JSONDecoder().decode(ExpectedSpec.self, from: Data(contentsOf: jsonl.deletingPathExtension().appendingPathExtension("expected.json")))
            let events = try String(contentsOf: jsonl, encoding: .utf8).split(separator: "\n").map(String.init)
            let tools = spec.availableTools.map { RecoveryToolSpec(name: $0.name, paramNames: $0.params, requiredParams: $0.required) }
            let out = replay(events: events, hasTools: spec.hasTools, tools: tools)
            // From the components after Fixtures/parsing, not a path-prefix strip: under /tmp the enumerator hands back
            // /private/tmp/… and the strip left "/private" glued to every case name.
            let comps = jsonl.deletingPathExtension().pathComponents
            let name = comps.lastIndex(of: "parsing").map { comps[($0 + 1)...].joined(separator: "/") } ?? jsonl.deletingPathExtension().lastPathComponent
            cases.append(.init(name: name, hasTools: spec.hasTools,
                               availableTools: spec.availableTools.map { .init(name: $0.name, params: $0.params, required: $0.required) },
                               events: events, expectToolCalls: spec.expectToolCalls.map(\.name), contentMustNotContain: spec.contentMustNotContain,
                               recoveredToolNames: out.names, finalContent: out.finalContent))
        }
        return StreamVectors(cases: cases)
    }

    // MARK: catalogs

    static func catalogs(file: String = #filePath) throws -> CatalogVectors {
        let xaiLanguage = try TestFixture.string("xai_language_models.json", file: file)
        let xaiModels = try TestFixture.string("xai_models.json", file: file)
        let language = try JSONDecoder().decode(XAIAdapter.LanguageModelsResponse.self, from: Data(xaiLanguage.utf8))
        let models = try JSONDecoder().decode(XAIAdapter.ModelsResponse.self, from: Data(xaiModels.utf8))
        // The context join listModels performs: /v1/models carries context_length, /v1/language-models the prices.
        let contexts = Dictionary(models.data.compactMap { m in m.context_length.map { (m.id.lowercased(), $0) } }, uniquingKeysWith: { a, _ in a })
        let xaiRows = XAIAdapter.buildModels(from: language.models.filter(\.isTextModel).map(XAIAdapter.Entry.init(language:)), contexts: contexts, now: pinnedNow)
        let fw = try TestFixture.string("fireworks_serverless_models.json", file: file)
        let fwRows = FireworksAdapter.buildModels(from: try JSONDecoder().decode(FireworksAdapter.ModelsResponse.self, from: Data(fw.utf8)).models, now: pinnedNow)
        let lm = try TestFixture.string("lmstudio_api_v0_models.json", file: file)
        let lmRows = LMStudioAdapter.buildModels(from: try JSONDecoder().decode(LMStudioAdapter.ModelsResponse.self, from: Data(lm.utf8)).data)
        return CatalogVectors(pinnedNow: ISO8601DateFormatter().string(from: pinnedNow),
                              xai: .init(languageModels: xaiLanguage, models: xaiModels, rows: xaiRows.map(row)),
                              fireworks: .init(models: fw, rows: fwRows.map(row)),
                              lmstudio: .init(models: lm, rows: lmRows.map(row)))
    }

    // MARK: brave

    static func brave(file: String = #filePath) throws -> BraveVectors {
        let answers = try TestFixture.string("brave_answers_content.txt", file: file)
        let (visible, sources) = BraveAnswersFormat.split(answers)
        let ctx = try TestFixture.string("brave_llm_context.json", file: file)
        let news = try TestFixture.string("brave_llm_context_news.json", file: file)
        let ctxResponse = try JSONDecoder().decode(BraveGroundingResponse.self, from: Data(ctx.utf8))
        let newsResponse = try JSONDecoder().decode(BraveGroundingResponse.self, from: Data(news.utf8))
        return BraveVectors(answersContent: answers, visible: visible,
                            sources: sources.map { .init(url: $0.url, domain: $0.domain, title: $0.title, snippet: $0.snippet) },
                            llmContext: ctx, llmContextXML: BraveWebSearchTool.contextXML(from: ctxResponse),
                            llmContextNews: news, llmContextNewsXML: BraveWebSearchTool.contextXML(from: newsResponse),
                            llmContextNewsXMLWithoutPublished: BraveWebSearchTool.contextXML(from: newsResponse, includePublished: false))
    }
}

@Suite("Conformance fixture vectors — round-trip against production")
struct ConformanceFixtureVectorTests {
    @Test func everyRecordedStreamRecoversItsCallsAndLeaksNothing() throws {
        let v = try ConformanceFixtureVectors.streams()
        #expect(v.cases.count == 3)
        for c in v.cases {
            for name in c.expectToolCalls { #expect(c.recoveredToolNames.contains(name), "[\(c.name)] \(name) not recovered") }
            for marker in c.contentMustNotContain { #expect(!c.finalContent.contains(marker), "[\(c.name)] leaked \(marker)") }
        }
    }
    @Test func catalogRowsMatchWhatTheAdapterTestsAssert() throws {
        let v = try ConformanceFixtureVectors.catalogs()
        #expect(v.xai.rows.count == 6)
        #expect(v.xai.rows.first?.id == "grok-4.5"); #expect(v.xai.rows.first?.price == "$2.00/$6.00"); #expect(v.xai.rows.first?.contextWindow == "500k")
        #expect(v.xai.rows.allSatisfy { $0.capabilities == ["tools", "vision"] })
        let kimi = try #require(v.fireworks.rows.first { $0.id == "accounts/fireworks/models/kimi-k2p6" })
        #expect(kimi.displayName == "Kimi K2.6"); #expect(kimi.vendor == "Moonshot"); #expect(kimi.contextWindow == "262k"); #expect(kimi.price == "")   // off serverless 2026-10-15
        let qwen = try #require(v.lmstudio.rows.first { $0.id == "qwen2.5-7b-instruct" })
        #expect(qwen.contextWindow == "32k · Q4_K_M"); #expect(qwen.vendor == "Qwen"); #expect(qwen.price == "")
    }
    @Test func braveVectorsMatchTheFormatTests() throws {
        let v = try ConformanceFixtureVectors.brave()
        #expect(v.visible.hasPrefix("**Paris** is the capital")); #expect(v.sources.count >= 5)
        #expect(v.sources.contains { $0.url == "https://en.wikipedia.org/wiki/Paris" })
        #expect(v.llmContextXML.contains("<source index=\"1\">")); #expect(!v.llmContextNewsXMLWithoutPublished.contains("<published>"))
    }
    @Test func generationIsByteStable() throws {
        let a = try ConformanceEncoder.encode(ConformanceDocument(kitVersion: "x", fixtureClass: "catalogs", sourceOfTruth: "t", vectors: try ConformanceFixtureVectors.catalogs()))
        let b = try ConformanceEncoder.encode(ConformanceDocument(kitVersion: "x", fixtureClass: "catalogs", sourceOfTruth: "t", vectors: try ConformanceFixtureVectors.catalogs()))
        #expect(a == b)
    }
}
