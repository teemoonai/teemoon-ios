//
//  KnownModelDumpTests.swift
//  teemoonTests
//
//  EXTRACTION, not verification. Runs each provider's real adapter against the
//  live catalog and dumps the resulting `[KnownModel]` to
//  where-knownmodels-<provider>.json in a design-baseline folder, so the design side
//  can see how often `price` and `contextWindow` are actually populated instead
//  of inferring it from the hardcoded presets.
//
//  Skipped unless keys are present, so the normal suite is unaffected. Keys are
//  read from a file rather than the environment because xcodebuild does not pass
//  the shell environment through to a hosted test process. Write it with:
//
//      source ~/.zshrc && printf '{"near":"%s","fireworks":"%s","xai":"%s"}' \
//        "$NEAR_AI_API_KEY" "$FIREWORKS_API_KEY" "$XAI_API_KEY" > /tmp/teemoon-keys.json
//
//  Every field is emitted, and EMPTY STRINGS ARE PRESERVED AS EMPTY STRINGS —
//  the whole question is which fields come back blank, so normalising them away
//  would destroy the answer.
//

import Foundation
import Testing
@testable import teemoon

@Suite("KnownModel live dump", .serialized)
struct KnownModelDumpTests {

    private static var keys: [String: String]? {
        let url = URL(fileURLWithPath: "/tmp/teemoon-keys.json")
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return parsed
    }

    private static var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // teemoonTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("docs/design-baseline")
    }

    /// One `KnownModel`, every field, nothing omitted or normalised.
    private static func encode(_ models: [KnownModel], provider: String, source: String) -> String {
        let objects: [[String: Any]] = models.map { m in
            [
                "id": m.id,
                "displayName": m.displayName,
                "vendor": m.vendor,
                "price": m.price,
                "contextWindow": m.contextWindow,
                "isNew": m.isNew,
                "directBaseURL": m.directBaseURL as Any,
                // EVERY bit. Hand-enumerating a subset is how the dump ended up
                // reporting only tools/vision while the type had already grown
                // audio and thinking — an artifact quietly contradicting the code.
                "capabilities": m.capabilities.map(Self.names(of:)) as Any,
                "metaLabel": m.metaLabel,
            ]
        }
        let blank = { (key: String) in
            models.filter { m in
                switch key {
                case "price": return m.price.isEmpty
                case "contextWindow": return m.contextWindow.isEmpty
                default: return false
                }
            }.count
        }
        let doc: [String: Any] = [
            "_comment": [
                "Live [KnownModel] for \(provider), via \(source).",
                "Empty strings are PRESERVED — they are the finding, not noise.",
                "KnownModel has no `description` field (Provider.swift:280), so a wire",
                "`description` cannot reach a row today however rich it is.",
            ],
            "provider": provider,
            "source": source,
            "modelCount": models.count,
            "blankPrice": blank("price"),
            "blankContextWindow": blank("contextWindow"),
            "models": objects,
        ]
        let data = try! JSONSerialization.data(withJSONObject: doc,
                                               options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static let allCapabilities: [(ModelCapabilities, String)] = [
        (.tools, "tools"), (.vision, "vision"), (.uploads, "uploads"),
        (.audio, "audio"), (.thinking, "thinking"), (.completion, "completion"),
        (.embedding, "embedding"), (.insert, "insert"),
    ]

    private static func names(of caps: ModelCapabilities) -> [String] {
        allCapabilities.filter { caps.contains($0.0) }.map(\.1)
    }

    private static func write(_ body: String, provider: String) {
        let url = outputDirectory.appendingPathComponent("where-knownmodels-\(provider).json")
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try? (body + "\n").write(to: url, atomically: true, encoding: .utf8)
        print("DUMP wrote \(url.lastPathComponent)")
    }

    @Test(.enabled(if: KnownModelDumpTests.keys != nil))
    func dumpNearAI() async throws {
        let key = try #require(Self.keys?["near"])
        let models = try #require(await NearAIModelCatalog.fetchLive(apiKey: key),
                                  "near.ai /v1/models did not return 200")
        Self.write(Self.encode(models, provider: "nearai",
                               source: "NearAIModelCatalog.fetchLive → /v1/models"),
                   provider: "nearai")
        #expect(!models.isEmpty)
    }

    @Test(.enabled(if: KnownModelDumpTests.keys != nil))
    func dumpFireworks() async throws {
        let key = try #require(Self.keys?["fireworks"])
        let base = try #require(URL(string: "https://api.fireworks.ai/inference/v1"))
        let result = await FireworksAdapter.listModels(baseURL: base, apiKey: key)
        guard case .connected(let models) = result else {
            Issue.record("fireworks probe failed: \(result)")
            return
        }
        Self.write(Self.encode(models, provider: "fireworks",
                               source: "FireworksAdapter.listModels"),
                   provider: "fireworks")
    }

    /// The home tier. Its `contextWindow` is BUILT, not returned — `showMeta`
    /// joins a context label and a quantization level with " · " — so the design
    /// needs the real string shape, which no fixture can supply.
    @Test(.enabled(if: KnownModelDumpTests.keys?["ollama"] != nil))
    func dumpOllama() async throws {
        let endpoint = try #require(Self.keys?["ollama"])
        let base = try #require(URL(string: endpoint))
        let result = await OllamaAdapter.listModels(baseURL: base)
        guard case .connected(let models) = result else {
            Issue.record("ollama probe failed: \(result)")
            return
        }
        for m in models {
            print("OLLAMA \(m.id) | contextWindow=\(m.contextWindow) | metaLabel=\(m.metaLabel)")
        }
        Self.write(Self.encode(models, provider: "ollama",
                               source: "OllamaAdapter.listModels → /api/tags + /api/show"),
                   provider: "ollama")
    }

    @Test(.enabled(if: KnownModelDumpTests.keys != nil))
    func dumpXAI() async throws {
        let key = try #require(Self.keys?["xai"])
        let base = try #require(URL(string: "https://api.x.ai/v1"))
        let result = await XAIAdapter.listModels(baseURL: base, apiKey: key)
        guard case .connected(let models) = result else {
            Issue.record("xai probe failed: \(result)")
            return
        }
        Self.write(Self.encode(models, provider: "xai", source: "XAIAdapter.listModels"),
                   provider: "xai")
    }
}
