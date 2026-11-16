//
//  HomeCapabilityRefresh.swift
//  teemoon
//
//  What each model on the user's own Ollama machine can do ("reads images"), kept on its equipped row.
//  The where sheet calls this right after it probes the machine; nothing else does.
//

import Foundation

@MainActor
final class HomeCapabilityRefresh {
    static let shared = HomeCapabilityRefresh()

    /// One read per server per hour: each read is a `/api/show` per model on the user's machine.
    static let maxAge: TimeInterval = 3600

    typealias Lister = (URL) async -> [KnownModel]?

    /// Keyed by the machine, not the setup: a setup pointed at another machine is asked again.
    private var fetchedAt: [URL: Date] = [:]
    private let list: Lister
    private let now: () -> Date

    init(list: @escaping Lister = { base in
            guard case .connected(let models) = await OllamaAdapter.listModels(baseURL: base) else { return nil }
            return models
        },
         now: @escaping () -> Date = Date.init) {
        self.list = list
        self.now = now
    }

    /// Ollama servers only: the other home kinds report no capabilities.
    func refresh(_ providers: [Provider], kind: (Provider) -> LocalServerKind?,
                 adopt: ([KnownModel], UUID) -> Void) async {
        for provider in providers where WhereLocality.of(provider) == .home && kind(provider) == .ollama {
            guard let base = provider.openAIBaseURL else { continue }
            if let last = fetchedAt[base], now().timeIntervalSince(last) < Self.maxAge { continue }
            guard let models = await list(base), !models.isEmpty else { continue }
            fetchedAt[base] = now()
            adopt(models, provider.id)
        }
    }

    /// Before a photo to a home Ollama model is refused: unless the machine was read this hour, ask it about that one
    /// model (one /api/show, short timeout) and keep the answer. True when it reads images. Unreachable: false, and
    /// the refusal stands. Never at launch, never a cloud server (the maintainer 2026-11-12).
    func recheckBeforeRefusing(
        _ provider: Provider, kind: LocalServerKind?,
        show: (String, URL) async -> ModelCapabilities? = { await OllamaAdapter.capabilities(of: $0, baseURL: $1) },
        adopt: ([KnownModel], UUID) -> Void
    ) async -> Bool {
        // Unknown kind is asked too (a fresh setup never probed); only a machine known not to be Ollama is skipped.
        guard WhereLocality.of(provider) == .home, kind == .ollama || kind == nil,
              let base = provider.openAIBaseURL else { return false }
        if let last = fetchedAt[base], now().timeIntervalSince(last) < Self.maxAge { return false }
        guard let caps = await show(provider.model, base) else { return false }
        adopt([KnownModel(id: provider.model, displayName: provider.model, vendor: "", price: "", capabilities: caps)],
              provider.id)
        return caps.contains(.vision)
    }
}
