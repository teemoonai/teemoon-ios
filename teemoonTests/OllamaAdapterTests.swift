//
//  OllamaAdapterTests.swift
//  teemoonTests
//
//  Covers the model-capability model and the Ollama adapter:
//   • ModelCapabilities mapping (Ollama /api/show strings) + Codable-safety.
//   • Provider.modelSupportsTools gating logic (unknown → optimistic).
//   • Provider Codable back-compat: old JSON (no modelCapabilities key) decodes
//     to nil, never wiping saved providers.
//   • normalizePullRef: HF URL / hf.co snippet / bare name → what /api/pull wants.
//   • LIVE (skips if Ollama isn't on :11434): /api/show capabilities are read so a
//     non-tool model (gemma3n) is gated and a tool model (qwen3.5) is not.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Model capabilities & Ollama adapter")
struct OllamaAdapterTests {

    /// A DERIVED LINK MUST BE A FACT, not a guess.
    ///
    /// Ollama names are registry names, not repo paths — `gemma4:e2b` is not
    /// `google/gemma4`, and the quantised GGUF a home box runs is usually
    /// somebody's conversion rather than the vendor's own repo. So the library
    /// page is derivable and the Hugging Face repo is not, unless the name
    /// already says so.
    ///
    /// The URL shape is checked against the live site, including that a name it
    /// does not know 404s — a derived URL nobody verified is how a set of grok
    /// doc links nearly shipped pointing at a not-found page.
    @Test func ollamaLinksAreDerivedOnlyWhereTheNameSaysSo() {
        #expect(OllamaAdapter.libraryURL(forOllamaName: "gemma4:e2b")
                == "https://ollama.com/library/gemma4")
        #expect(OllamaAdapter.libraryURL(forOllamaName: "qwen3") == "https://ollama.com/library/qwen3")
        // Namespaced pulls are not in the library.
        #expect(OllamaAdapter.libraryURL(forOllamaName: "user/custom:latest") == nil)
        #expect(OllamaAdapter.libraryURL(forOllamaName: "hf.co/org/repo:Q4_K_M") == nil)

        // Hugging Face only when the name carries the path.
        #expect(OllamaAdapter.huggingFaceURL(forOllamaName: "hf.co/unsloth/gemma-4-GGUF:Q4_K_M")
                == "https://huggingface.co/unsloth/gemma-4-GGUF")
        #expect(OllamaAdapter.huggingFaceURL(forOllamaName: "huggingface.co/org/repo")
                == "https://huggingface.co/org/repo")
        // NEVER invented for a plain registry name.
        #expect(OllamaAdapter.huggingFaceURL(forOllamaName: "gemma4:e2b") == nil)
        #expect(OllamaAdapter.huggingFaceURL(forOllamaName: "llama3.2") == nil)
    }

    // MARK: ModelCapabilities

    /// Was `fromOllamaMapsToolsAndVisionIgnoresRest`, and it pinned a contract
    /// that turned out to be a silent data loss: everything but tools and vision
    /// was dropped, so `audio` never reached teemoon at all. The vocabulary is
    /// now the one the server actually sends.
    @Test func fromOllamaMapsTheWholeVocabulary() {
        #expect(ModelCapabilities.fromOllama(["completion", "tools", "vision", "thinking"])
                == [.completion, .tools, .vision, .thinking])
        #expect(ModelCapabilities.fromOllama(["completion"]) == [.completion])
        #expect(ModelCapabilities.fromOllama(["TOOLS"]) == [.tools])           // case-insensitive
        #expect(ModelCapabilities.fromOllama([]) == [])                        // known-none
    }

    @Test func capabilitiesCodableRoundTrips() throws {
        let caps: ModelCapabilities = [.tools, .vision]
        let data = try JSONEncoder().encode(caps)
        #expect(try JSONDecoder().decode(ModelCapabilities.self, from: data) == caps)
    }

    // MARK: Provider tool-gating

    @Test func modelSupportsToolsUnknownIsOptimistic() {
        func provider(_ caps: ModelCapabilities?) -> Provider {
            Provider(name: "p", endpoint: "http://x/v1", model: "m", modelCapabilities: caps)
        }
        #expect(provider(nil).modelSupportsTools == true)        // unknown → optimistic
        #expect(provider([]).modelSupportsTools == false)        // known-none → withhold
        #expect(provider([.vision]).modelSupportsTools == false) // known, no tools → withhold
        #expect(provider([.tools]).modelSupportsTools == true)
        #expect(provider([.tools, .vision]).modelSupportsTools == true)
    }

    // MARK: Codable back-compat (data safety)

    @Test func oldProviderJSONWithoutCapabilitiesDecodesToNil() throws {
        // A Provider blob as persisted before modelCapabilities existed.
        let json = """
        {"id":"\(UUID().uuidString)","name":"legacy","endpoint":"http://127.0.0.1:8080/v1",
         "model":"qwen2.5-7b","requiresAPIKey":false,"supportsModelBrowsing":false,
         "extraParams":{},"hasBuiltInGrounding":false,"omitSystemPrompt":false}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(Provider.self, from: json)
        #expect(p.modelCapabilities == nil)          // absent key → nil, no throw
        #expect(p.modelSupportsTools == true)        // and therefore optimistic
        #expect(p.model == "qwen2.5-7b")
    }

    @Test func providerCapabilitiesSurviveEncodeDecode() throws {
        let p = Provider(name: "o", endpoint: "http://127.0.0.1:11434/v1",
                         model: "gemma3n:e4b", modelCapabilities: [])
        let round = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(p))
        #expect(round.modelCapabilities == [])       // known-none preserved (not nil)
    }

    // MARK: normalizePullRef

    @Test func normalizePullRefHandlesAllInputShapes() {
        let cases: [(String, String)] = [
            ("https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF",
             "hf.co/bartowski/Qwen2.5-3B-Instruct-GGUF"),
            ("huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/tree/main",
             "hf.co/bartowski/Qwen2.5-3B-Instruct-GGUF"),
            ("hf.co/bartowski/Qwen2.5-3B-Instruct-GGUF:Q4_K_M",
             "hf.co/bartowski/Qwen2.5-3B-Instruct-GGUF:Q4_K_M"),
            ("ollama run hf.co/mlabonne/repo:Q8_0", "hf.co/mlabonne/repo:Q8_0"),
            ("  ollama pull qwen3.5  ", "qwen3.5"),
            ("qwen3.5", "qwen3.5"),
            ("gemma4:e4b", "gemma4:e4b"),

            // OLLAMA.COM URLS. Copying the page's link is what a phone user can
            // do; finding "the model's name" means reading a code block on it.
            ("https://ollama.com/library/qwen3.5", "qwen3.5"),
            ("https://ollama.com/library/gemma4:26b", "gemma4:26b"),
            ("ollama.com/library/gemma4", "gemma4"),
            // Pages ABOUT a model are not part of its name.
            ("https://ollama.com/library/gemma4/tags", "gemma4"),
            ("https://www.ollama.com/library/qwen3.5?variant=4b", "qwen3.5"),
            // A community model on ollama.com keeps its namespace.
            ("https://ollama.com/some-user/their-model", "some-user/their-model"),
            // Query and fragment come off an HF url too.
            ("https://huggingface.co/bartowski/repo-GGUF?library=true#files",
             "hf.co/bartowski/repo-GGUF"),
        ]
        for (input, expected) in cases {
            #expect(OllamaAdapter.normalizePullRef(input) == expected,
                    "normalize(\(input)) → \(OllamaAdapter.normalizePullRef(input)), expected \(expected)")
        }
    }

    // MARK: Live (Ollama on :11434)

    /// The whole capability model in one live check: gemma3n:e4b (no tools) must be
    /// gated, qwen3.5:4b (tools) must not. Skips if Ollama isn't running — or if it
    /// is running with NOTHING INSTALLED, which is a normal developer state and used
    /// to fail the build.
    ///
    /// `listModels` reports an empty server as `.failed(.badResponse)`, which is right
    /// for the app (a server with no models cannot answer, and the add screen must say
    /// so) and wrong as a test verdict: an emptied server says nothing about the
    /// capability gate this test exists to check. Observed 2026-07-30, when the machine
    /// happened to have every model deleted between two runs.
    @Test func liveOllamaCapabilitiesGateGemmaNotQwen() async throws {
        let base = URL(string: "http://127.0.0.1:11434/v1")!
        guard await OllamaAdapter.isOllama(baseURL: base) else {
            print("[ollama-live] not running on :11434 — skipping"); return
        }
        guard case .connected(let models) = await OllamaAdapter.listModels(baseURL: base) else {
            print("[ollama-live] running but has no models installed — skipping"); return
        }
        // If these models are installed, assert their capability verdicts.
        if let gemma = models.first(where: { $0.id.hasPrefix("gemma3n") }) {
            #expect(gemma.capabilities != nil, "gemma caps should be KNOWN (from /api/show)")
            #expect(gemma.capabilities?.contains(.tools) == false, "gemma3n must not report tools")
        }
        if let qwen = models.first(where: { $0.id.hasPrefix("qwen3.5") }) {
            #expect(qwen.capabilities?.contains(.tools) == true, "qwen3.5 must report tools")
        }
        // Every listed model with known caps drives the gate deterministically.
        for m in models where m.capabilities != nil {
            let p = Provider(name: "o", endpoint: base.absoluteString, model: m.id,
                             modelCapabilities: m.capabilities)
            #expect(p.modelSupportsTools == (m.capabilities?.contains(.tools) ?? true))
        }
    }
}

/// The capability vocabulary the live servers actually send.
///
/// teemoon dropped `audio` silently for as long as `fromOllama` mapped only
/// tools and vision — found by dumping a real `/api/show` rather than by
/// anything failing. These pin the whole vocabulary so the next word Ollama
/// adds is a visible gap, not another silent drop.
@Suite("ModelCapabilities vocabulary")
struct ModelCapabilityVocabularyTests {

    /// The verbatim response for `gemma4:latest` from the real home server.
    @Test func gemma4sRealCapabilityListMapsCompletely() {
        let caps = ModelCapabilities.fromOllama(["completion", "vision", "audio", "tools", "thinking"])
        #expect(caps.contains(.completion))
        #expect(caps.contains(.vision))
        #expect(caps.contains(.audio))
        #expect(caps.contains(.tools))
        #expect(caps.contains(.thinking))
        #expect(!caps.contains(.embedding))
    }

    @Test func qwen35RealCapabilityList() {
        // Same server, no audio — so the flag tracks the model, not the server.
        let caps = ModelCapabilities.fromOllama(["completion", "vision", "tools", "thinking"])
        #expect(!caps.contains(.audio))
        #expect(caps.contains(.thinking))
    }

    @Test func anEmbeddingModelIsNotAChatModel() {
        let caps = ModelCapabilities.fromOllama(["embedding"])
        #expect(caps.contains(.embedding))
        #expect(!caps.contains(.completion))
    }

    @Test func aWordOllamaAddsLaterIsIgnoredRatherThanFatal() {
        let caps = ModelCapabilities.fromOllama(["tools", "teleportation"])
        #expect(caps == [.tools])
    }

    /// Bit values are PERSISTED (`EquippedModel.capabilities`), so they are a
    /// wire format: renumbering them would silently reinterpret stored data.
    @Test func rawValuesAreStableBecauseTheyArePersisted() {
        #expect(ModelCapabilities.tools.rawValue == 1 << 0)
        #expect(ModelCapabilities.vision.rawValue == 1 << 1)
        #expect(ModelCapabilities.uploads.rawValue == 1 << 2)
        #expect(ModelCapabilities.audio.rawValue == 1 << 3)
        #expect(ModelCapabilities.thinking.rawValue == 1 << 4)
        #expect(ModelCapabilities.completion.rawValue == 1 << 5)
        #expect(ModelCapabilities.embedding.rawValue == 1 << 6)
        #expect(ModelCapabilities.insert.rawValue == 1 << 7)
    }

    /// Old stored capabilities must keep meaning what they meant. A value
    /// written before the new bits existed decodes with only the old ones set.
    @Test func capabilitiesStoredBeforeTheNewBitsStillDecode() throws {
        // RawRepresentable synthesises a SINGLE-VALUE container, so a stored
        // capability is the bare integer `3` — not `{"rawValue":3}`. Worth
        // pinning: the on-disk shape is what old data is written in.
        let legacy = try JSONDecoder().decode(ModelCapabilities.self, from: Data("3".utf8))
        #expect(legacy == [.tools, .vision])
        #expect(!legacy.contains(.audio))
        #expect(try JSONEncoder().encode(ModelCapabilities([.tools, .vision])) == Data("3".utf8))
    }
}
