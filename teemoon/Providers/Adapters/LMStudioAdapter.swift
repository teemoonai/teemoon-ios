//
//  LMStudioAdapter.swift
//  teemoon
//
//  LM Studio-specific behavior, contained in one file.
//  LM Studio speaks OpenAI-compat at `{host}/v1/*` (default port 1234), but like
//  Ollama it carries the metadata teemoon needs on a NATIVE surface at the host
//  ROOT: `/api/v0/*`, a sibling of `/v1`.
//
//  Why native, not the generic /v1/models probe — `/api/v0/models` is the richest
//  catalogue any local server exposes, and all four fields change what the picker
//  can honestly show:
//   • `type` — "llm" | "vlm" | "embeddings". The embedding model sits in the same
//     `/v1/models` list as the chat models; picking one 400s on first message.
//     `vlm` is also how vision is MODELED here rather than guessed.
//   • `capabilities` — e.g. ["tool_use"], so a non-tool model is gated before the
//     request instead of discovering it as a 400 in the hot path.
//   • `max_context_length` + `quantization` — the "128k · Q4_K_M" a local row
//     otherwise renders blank.
//   • `state` — "loaded" | "not-loaded", the same warm/cold signal Ollama's
//     `/api/ps` gives (LM Studio JIT-loads on first request, so a cold model
//     costs a load delay).
//
//  Not knowable from here: whether a listed model will actually LOAD. LM Studio's
//  bundled llama.cpp engine can be older than a GGUF in its own library and dies
//  loading it ("exited before becoming healthy … SIGABRT") — observed with a
//  gemma-4 QAT build that a standalone llama-server serves fine. It surfaces as a
//  provider error on send; nothing in the catalogue predicts it.
//
//  Wire contract — https://lmstudio.ai/docs/app/api/endpoints/rest
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "lmstudio-adapter")

enum LMStudioAdapter {

    // MARK: Detection

    /// Cheap probe: is this endpoint LM Studio? `GET {root}/api/v0/models` is its
    /// own REST surface — Ollama and llama.cpp 404 it. Swallows all errors → false.
    static func isLMStudio(baseURL: URL, session: URLSession = .shared) async -> Bool {
        guard let list = await fetchModels(baseURL: baseURL, timeout: 5, session: session) else {
            return false
        }
        logger.info("[detect] lm studio (\(list.data.count) model(s)) at \(EndpointModelCatalog.rootURL(from: baseURL).absoluteString)")
        return true
    }

    // MARK: List models (+ capabilities)

    /// Native model list that doubles as the connection test — same `ProbeResult`
    /// as every other adapter. Falls back to the generic `/v1/models` probe if the
    /// native surface stops answering mid-session.
    static func listModels(
        baseURL: URL,
        session: URLSession = .shared
    ) async -> EndpointModelCatalog.ProbeResult {
        guard let list = await fetchModels(baseURL: baseURL, timeout: 12, session: session) else {
            return await EndpointModelCatalog.probe(baseURL: baseURL, session: session)
        }
        let models = buildModels(from: list.data)
        guard !models.isEmpty else { return .failed(.badResponse) }
        logger.info("[list] \(models.count) lm studio chat model(s)")
        return .connected(models)
    }

    /// Ids currently loaded in memory (warm). Same shape as `OllamaAdapter.loadedModels`.
    static func loadedModels(baseURL: URL, session: URLSession = .shared) async -> Set<String> {
        guard let list = await fetchModels(baseURL: baseURL, timeout: 6, session: session) else {
            return []
        }
        return Set(list.data.filter(\.isLoaded).map(\.id))
    }

    /// Pure (no network) so it is unit-testable against a captured payload.
    static func buildModels(from records: [ModelsResponse.Model]) -> [KnownModel] {
        records.compactMap { m in
            guard m.isChatModel else { return nil }
            return KnownModel(
                id: m.id,                       // full id incl. "@quant" — what /v1 expects
                displayName: m.displayName,
                // `publisher` is whoever uploaded the GGUF (unsloth, bartowski),
                // not the model's vendor, so the family wins; publisher is the
                // fallback for a name nothing recognizes.
                vendor: ModelCatalog.familyVendor(forID: m.id)
                        ?? m.publisher?.capitalized
                        ?? ModelCatalog.vendorLabel(forID: m.id),
                price: "",                      // local inference is free
                contextWindow: m.contextLabel,  // "128k · Q4_K_M"
                capabilities: m.modelCapabilities)
        }
    }

    // MARK: Fetch

    private static func fetchModels(
        baseURL: URL, timeout: TimeInterval, session: URLSession
    ) async -> ModelsResponse? {
        var request = URLRequest(
            url: EndpointModelCatalog.rootURL(from: baseURL).appendingPathComponent("api/v0/models"))
        request.timeoutInterval = timeout
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            return nil
        }
        return list
    }
}

// MARK: - Wire contract — https://lmstudio.ai/docs/app/api/endpoints/rest

extension LMStudioAdapter {

    /// `GET /api/v0/models` — every model in the library, loaded or not.
    /// (`GET /api/v0/models/{id}` returns one entry with the same shape.)
    struct ModelsResponse: Decodable {
        let object: String?      // "list"
        let data: [Model]

        struct Model: Decodable {
            /// The id `/v1/chat/completions` expects, e.g.
            /// "gemma-4-e4b-it-qat@q4_k_xl" — the "@quant" suffix is part of it
            /// when a repo ships several quantizations.
            let id: String
            let object: String?
            /// "llm" | "vlm" (vision) | "embeddings"
            let type: String?
            /// The GGUF's uploader ("unsloth", "bartowski"), NOT the model vendor.
            let publisher: String?
            /// GGUF architecture ("gemma4", "qwen2").
            let arch: String?
            /// "gguf" | "mlx" — MLX models are Apple-silicon native.
            let compatibility_type: String?
            let quantization: String?          // "Q4_K_M", "Q2_K_XL", "4bit"
            /// "loaded" | "not-loaded" — LM Studio JIT-loads on first request.
            let state: String?
            let max_context_length: Int?
            /// Feature strings, e.g. ["tool_use"]. Absent on models with none.
            let capabilities: [String]?
            /// Present only while loaded: the context the instance was given.
            let loaded_context_length: Int?

            var isLoaded: Bool { state == "loaded" }

            /// Chat models only. `embeddings` ships in the same list and would
            /// 400 on the first message; an unknown/absent type is kept (a new
            /// LM Studio type shouldn't silently empty the picker).
            var isChatModel: Bool {
                guard let type = type?.lowercased() else { return !ModelCatalog.isNonChat(id) }
                return type != "embeddings" && !ModelCatalog.isNonChat(id)
            }

            /// "gemma-4-e4b-it-qat@q4_k_xl" → "gemma-4-e4b-it-qat". The quant is
            /// shown beside the context window instead of inside the name; the id
            /// keeps its suffix because that is what inference expects.
            var displayName: String {
                id.split(separator: "@").first.map(String.init) ?? id
            }

            /// "128k · Q4_K_M" — GGUF context sizes are powers of two, so the
            /// label is 1024-based (131072 → "128k", not "131k").
            var contextLabel: String {
                [ModelCatalog.localContextLabel(max_context_length), quantization]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            }

            /// Tools from `capabilities`, vision from `type == "vlm"`. Always
            /// **known** (non-nil): LM Studio reports these explicitly, so an
            /// empty set means "supports neither", not "unknown".
            var modelCapabilities: ModelCapabilities {
                var caps: ModelCapabilities = []
                if capabilities?.contains(where: { $0.lowercased() == "tool_use" }) == true {
                    caps.insert(.tools)
                }
                if type?.lowercased() == "vlm" { caps.insert(.vision) }
                return caps
            }
        }
    }
}
