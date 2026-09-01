//
//  HomeServerProbe.swift
//  teemoon
//
//  What a home endpoint actually IS, so the Where sheet can say "ollama · 3
//  models" instead of "100.100.0.12".
//
//  An IP address is the least useful true thing about a machine. The user
//  already knows which computer it is — they typed the address — and what they
//  can't see is which server is answering, how many models it has, and which of
//  those are warm. `LocalServerKind.detect` and the adapters' `loadedModels`
//  already answered all three; nothing surfaced it in the picker.
//
//  Not persisted, deliberately. A server's kind can change (Ollama replaced by
//  LM Studio on the same port), its model list changes constantly, and warmth
//  changes by the minute — a cached answer would be wrong more often than
//  absent. This lives for as long as the sheet is open.
//
//  Related: LocalServerKind, OllamaAdapter, LMStudioAdapter, WhereSheetView.
//

import Foundation
import Observation

@Observable
@MainActor
final class HomeServerProbe {

    /// One cache for the app. The results are per-endpoint and short-lived, so
    /// sharing them across presentations of the sheet just avoids re-probing a
    /// server the user opened a minute ago.
    static let shared = HomeServerProbe()

    struct Info: Equatable {
        var kind: LocalServerKind = .unknown
        /// Every model id the server reports. nil = not probed / unreachable,
        /// which is different from "none" and must read differently.
        ///
        /// This is the equipped set for a home provider, not a menu to pick
        /// from: everything on the machine is already available to run, so
        /// making the user "add" one from a list of things they already have is
        /// a step that exists only because the data model used to need it.
        var models: [String]?
        var modelCount: Int? { models?.count }
        /// Model ids currently loaded in the server's memory. A cold model pays
        /// a load delay on first token; a warm one answers immediately.
        var warm: Set<String> = []
    }

    private(set) var infoByProvider: [UUID: Info] = [:]

    private var inFlight: Set<UUID> = []

    /// True when the results were seeded for a preview.
    ///
    /// `refresh` is a no-op then. Without this the sheet's `.task` fired a real
    /// probe at the fixture's invented address, failed, and OVERWROTE the seeded
    /// answer — so a preview built to show a named server with warm models
    /// rendered "couldn't reach this server" instead, and which one you saw
    /// depended on whether the render beat the network timeout.
    private var isSeeded = false

    func info(for provider: Provider) -> Info? { infoByProvider[provider.id] }

    /// Drops a model from the CACHED answer for a machine, after teemoon deleted
    /// it there.
    ///
    /// Needed because this cache is what `syncHomeEquipped` reconciles against,
    /// and it outlives the delete. Re-probing instead is not enough and was the
    /// bug: `refresh` skips any provider already `inFlight`, so a probe overlapping
    /// the delete made the refresh a no-op, `syncHomeEquipped` then read the
    /// pre-delete list, and the row the user had just deleted was written straight
    /// back into `equippedModels`. Deleting the model is something we KNOW
    /// happened; the cache should say so without a round trip to find out.
    func forget(modelID: String, on provider: Provider) {
        guard var info = infoByProvider[provider.id] else { return }
        info.models = info.models?.filter { $0 != modelID }
        info.warm.remove(modelID)
        infoByProvider[provider.id] = info
    }

    /// Probes every home provider concurrently. Cheap enough to run on each
    /// appearance: detection is one round trip, and the model list is a request
    /// the picker would otherwise make when browsing anyway.
    /// Seeds the cache from what was persisted about each machine, so a machine
    /// that answered before is described from the first frame rather than after the
    /// network agrees.
    ///
    /// §2.4: this cache used to be memory-only, so a failed probe meant the row
    /// fell back to a bare IP, warmth vanished, and — worst — `pullableProviders`
    /// (which needs `kind == .ollama`) went empty, taking away the machine's only
    /// path to adding a model. A dead end caused by one dropped request.
    ///
    /// `warm` is deliberately NOT seeded: residency is a live fact with a 5-minute
    /// keep-alive, and a remembered "warm" would be a claim about right now made
    /// from something observed an hour ago.
    func seed(from store: ProviderStore) {
        guard !isSeeded else { return }
        for provider in store.providers where WhereLocality.of(provider) == .home {
            guard infoByProvider[provider.id] == nil else { continue }
            guard let served = store.servedModels(of: provider), !served.isEmpty
            else { continue }
            infoByProvider[provider.id] = Info(
                kind: store.storedKind(of: provider) ?? .unknown,
                models: served,
                warm: []
            )
        }
    }

    func refresh(_ providers: [Provider], credential: (Provider) -> String) async {
        guard !isSeeded else { return }
        await withTaskGroup(of: Void.self) { group in
            for provider in providers where WhereLocality.of(provider) == .home {
                guard let base = provider.openAIBaseURL, !inFlight.contains(provider.id) else { continue }
                inFlight.insert(provider.id)
                let key = credential(provider)
                let header = provider.authHeaderName
                let id = provider.id
                group.addTask { @MainActor in
                    let info = await Self.probe(base: base, authHeaderName: header, apiKey: key)
                    self.infoByProvider[id] = info
                    self.inFlight.remove(id)
                }
            }
        }
    }

    private static func probe(base: URL, authHeaderName: String?, apiKey: String) async -> Info {
        let kind = await LocalServerKind.detect(baseURL: base)

        // The generic `/models` probe works for every kind, including the ones
        // detection can't name — a count is the one fact even an unidentified
        // OpenAI-compatible server will give up.
        // `/models` AND `/v1/models`, because the endpoint the user typed may or
        // may not already carry the `/v1`.
        //
        // `probe` appends "models" to the base, so an endpoint entered as
        // `host:11434` asks for `…:11434/models` — a path Ollama does not serve.
        // The OpenAI-compatible list lives at `/v1/models`, and there is no way
        // for the user to know teemoon wanted the longer form: the add screen
        // accepts the short one and connects fine for chat, because THAT url is
        // built separately. So the list came back empty for a server that was
        // working, and every home capability that depends on the list — the
        // model count, warmth, auto-equipping the rest of the machine's models —
        // silently did nothing.
        var ids: [String]?
        for candidate in Self.modelListCandidates(base) {
            if case let .connected(models) = await EndpointModelCatalog.probe(
                baseURL: candidate, authHeaderName: authHeaderName, apiKey: apiKey
            ), !models.isEmpty {
                ids = models.map(\.id)
                break
            }
        }

        // Warmth is native-surface only. llama.cpp has no equivalent, so an
        // unidentified server reports nothing rather than guessing.
        var warm: Set<String> = []
        switch kind {
        case .ollama:   warm = await OllamaAdapter.loadedModels(baseURL: base)
        case .lmStudio: warm = await LMStudioAdapter.loadedModels(baseURL: base)
        case .unknown:  break
        }

        return Info(kind: kind, models: ids, warm: warm)
    }

    /// Bases to try for the OpenAI-compatible model list, in order: the endpoint
    /// as given, then the same with `/v1` appended when it isn't already there.
    static func modelListCandidates(_ base: URL) -> [URL] {
        let path = base.path
        if path.hasSuffix("/v1") || path.hasSuffix("/v1/") { return [base] }
        return [base, base.appendingPathComponent("v1")]
    }

    /// Seeded, no requests. Previews otherwise show every home row as an
    /// unprobed IP address, which is the state this type exists to replace.
    static func previewing(_ entries: [(UUID, Info)]) -> HomeServerProbe {
        let probe = HomeServerProbe()
        probe.isSeeded = true
        for (id, info) in entries { probe.infoByProvider[id] = info }
        return probe
    }
}
