//
//  NVIDIAAdapter.swift
//  teemoon
//
//  NVIDIA's hosted API catalogue (build.nvidia.com), contained in one file.
//  Inference is OpenAI-compat at `https://integrate.api.nvidia.com/v1/*`, and
//  `/v1/models` is the plain OpenAI list — ids and an `owned_by`, nothing to
//  render. It is public: no key is needed to read it.
//
//  Why native, not the generic probe:
//   • The list mixes embedders, rerankers, guard/safety classifiers, a reward
//     model, translators, parsers and vision encoders in with the chat models,
//     and none of them carry a marker the generic keyword filter catches.
//     Picking one breaks the chat.
//   • There is no per-token price to show, and that is a fact about the tier,
//     not a gap in a table: the hosted catalogue is free for development under
//     the NVIDIA Developer Program, rate-limited per model. Rows say "free"
//     rather than sitting blank.
//
//  Wire contract — the OpenAI "list models" shape (`OpenAIModelsResponse`).
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "nvidia-adapter")

enum NVIDIAAdapter {

    /// Hosts this adapter serves. `integrate.api.nvidia.com` today; matched on
    /// the api subtree so a regional host still resolves here.
    static func handles(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "integrate.api.nvidia.com" || host.hasSuffix(".api.nvidia.com")
    }

    /// The shared non-chat filter plus `parse`, which stays NVIDIA-only:
    /// nemotron-parse is a document parser, and the word is too common for
    /// the shared list.
    static func isChatModel(_ id: String) -> Bool {
        !ModelCatalog.isNonChat(id) && !ModelCatalog.slug(id).lowercased().contains("parse")
    }

    // MARK: - List models

    static func listModels(
        baseURL: URL,
        apiKey: String,
        session: URLSession = .shared
    ) async -> EndpointModelCatalog.ProbeResult {
        let list: OpenAIModelsResponse
        switch await EndpointModelCatalog.fetchList(OpenAIModelsResponse.self, from: baseURL.appendingPathComponent("models"),
                                                    apiKey: apiKey, session: session) {
        case .failure(let kind): return .failed(kind)
        case .success(let decoded): list = decoded
        }
        let models = buildModels(from: list.data)
        guard !models.isEmpty else { return .failed(.badResponse) }
        logger.info("[list] \(models.count) nvidia chat model(s) from \(list.data.count) record(s)")
        return .connected(models)
    }

    /// Pure (no network) so it is unit-testable against a captured payload.
    /// NVIDIA's `created` is one constant for the whole list, so recency
    /// cannot be read from it: rows sort by vendor then id, NVIDIA's own first.
    static func buildModels(from records: [OpenAIModelsResponse.Model]) -> [KnownModel] {
        var seen = Set<String>()
        let models: [KnownModel] = records.compactMap { m in
            guard isChatModel(m.id), seen.insert(m.id.lowercased()).inserted else { return nil }
            let vendor = ModelCatalog.vendorLabel(forID: m.id)
            return KnownModel(
                id: m.id,
                displayName: ModelCatalog.displayName(forID: m.id),
                vendor: vendor,
                // No context window: the list does not report one, and a
                // number from elsewhere would be a guess. Blank, honestly.
                price: "",
                // The model page is `build.nvidia.com/<namespace>/<slug>`,
                // verified for nemotron-3-super-120b-a12b and kimi-k3.
                modelPageURL: "https://build.nvidia.com/" + m.id,
                isFree: true,
                openWeights: true)
        }
        return models.sorted { a, b in
            if a.vendor != b.vendor { return rank(a.vendor) < rank(b.vendor) }
            return a.id < b.id
        }
    }

    private static func rank(_ vendor: String) -> String {
        vendor == "NVIDIA" ? "" : vendor.lowercased()
    }
}
