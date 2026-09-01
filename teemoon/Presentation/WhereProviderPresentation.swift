//
//  WhereProviderPresentation.swift
//  teemoon
//
//  How a configured Provider maps onto a list row: model label, place caption,
//  canonical name. Pure functions over Provider + catalogs. Views render the
//  strings; Models persist a snapshot of them. This file must not import SwiftUI.
//
//  Related: WhereLocality, Provider, ModelCatalog.
//

import Foundation

enum WhereProviderPresentation {
    /// Short model label for the chip and list (not the raw API id).
    static func modelLabel(for provider: Provider) -> String {
        // On-device models carry a HuggingFace repo id, and the generic path
        // renders it whole: "gemma-4-e2b-it-litert-lm". Two of those three
        // suffixes name a file format and a runtime, which is not what the user
        // downloaded — the download screen called it "Gemma 4 E2B" and so does
        // the catalog. `compactName` can't rescue this on its own; it peels
        // build words from cloud ids and has no idea "litert-lm" is one.
        if let localID = provider.localModelID,
           let model = LocalModelCatalog.model(id: localID) {
            return model.displayName.lowercased()
        }
        // `canonicalName`, NOT `provider.name` — the same auto-label bug
        // `placeCaption` documents below, showing up in the TITLE this time.
        //
        // `titleLabel` prefers the provider's name when it already begins with
        // the model's, which is right for a preset: model `brave` + name
        // "Brave Answers" → "brave answers", better than a bare "brave". But
        // teemoon auto-labels a saved provider from BOTH, so the stored name is
        // "brave answers brave" — it still begins with "brave", so the rule
        // fired and the row's title was that, the word printed twice. Matching
        // the endpoint to a preset gets the service's real name and the rule
        // does what it was written for.
        if let label = ModelCatalog.titleLabel(
            model: provider.model, providerName: canonicalName(for: provider)
        ) {
            return label
        }
        let tail = provider.model.split(separator: "/").last.map(String.init) ?? provider.model
        return tail.isEmpty ? provider.name.lowercased() : tail.lowercased()
    }

    /// Place / trust caption beside the model name.
    static func placeCaption(for provider: Provider) -> String {
        switch WhereLocality.of(provider) {
        case .phone:
            // Verbatim the download screen's title and the title block's
            // caption. The promise made before installing a model is the
            // promise repeated while using it — three surfaces, one sentence.
            return "on this device"
        case .home:
            // THE MACHINE'S NAME, not its fully-qualified address. This returned
            // the raw host — "ringzero.tailnet-name.ts.net" in the composer chip —
            // while `canonicalName` a few lines down already reduced the same
            // host to "ringzero", for reasons it documents. Two functions
            // describing one machine, disagreeing.
            //
            // A tailnet FQDN is mostly suffix: three of its four labels identify
            // the network, not the computer, and none of them is what the user
            // calls it. The Where sheet made this call already — its rows say
            // "ollama · warm" rather than a hostname, because "a machine's
            // hostname is the least useful true thing about it — the user typed
            // it". The chip should not be the last place still shouting the
            // address.
            return provider.openAIBaseURL?.host.map {
                HostLabel.friendly($0).lowercased()
            } ?? provider.name.lowercased()
        case .cloud:
            // A grounded-answer endpoint is not a chat model, and the caption
            // has to say so BEFORE it's picked. Brave Answers has one fixed id,
            // takes no system prompt, and `maxMessages: 1` means it never sees
            // the conversation — ChatView warns about that, but only after the
            // first reply has already come back contextless.
            //
            // Tested by capability (`answersSingleTurnOnly`), never by endpoint
            // string, so anything else with the same shape reads the same way.
            // Citations are the compensation and belong in the same breath.
            if provider.answersSingleTurnOnly, provider.hasBuiltInGrounding {
                // ONE LINE, which is what this list is for — a picker is a
                // density instrument and a row that takes two costs a row you
                // could have seen.
                //
                // "built-in" is the real distinction, and it is a distinction
                // from teemoon's OWN grounding: every other provider gets web
                // search as a tool round (`ChatGeneration` attaches
                // `BraveWebSearchTool` only when the provider lacks
                // `.builtInGrounding`), costing a decision generation, the
                // search, a re-prefill and then the answer. This endpoint does
                // all of it server-side in one round and needs no grounding key.
                //
                // "fast" is that structural difference, NOT a measured figure —
                // one round against four phases.
                //
                // "single turn q&a" carries the warning in three words:
                // `maxMessages: 1` means this endpoint is sent your latest
                // message and nothing else, so "and the second one?" arrives
                // with no idea what the first was. Shorter than spelling it out,
                // and `ChatView` says it again at send time.
                //
                // NOT "private": this is a plaintext POST to Brave, with no
                // `.endToEndEncryption` capability. The cloud segment's own
                // header promises "each row says whether it's end-to-end
                // encrypted", so a privacy word on the one row that isn't would
                // read as parity with the near.ai row above it, which really is.
                //
                // Citations are dropped: they arrive on the same
                // `onSourcesFound` path as the tool's and render in the same
                // view, so they are not a difference anyone chooses between.
                // CONSTRAINT FIRST, and the order is the whole point. The Where
                // row has width for both, but the chip above the composer draws
                // this same caption at `.lineLimit(1)` — and with the benefit
                // leading it truncated to "brave answers · fast built-in se…",
                // keeping the sales pitch and cutting the caveat on the one
                // surface that is always on screen. Leading with the limit means
                // truncation eats "fast built-in search" instead, which is the
                // half a user can afford to lose.
                return "single turn q&a, fast built-in search"
            }
            // Provider first, then the guarantee, spelled out. "e2ee" is jargon
            // that has to be learned before it means anything, and this line is
            // the whole reason a user would pick one cloud row over another.
            //
            // "end-to-end encrypted" verbatim from `AttestationState.caption`,
            // hyphens included — the title block says exactly this about the
            // same connection, and two surfaces describing one guarantee in two
            // spellings reads as two different guarantees.
            // The PROVIDER's canonical name, not the row's editable label.
            //
            // teemoon auto-labels a saved provider from its model, so the label
            // becomes "near.ai glm 5.2" — and printing that beside a model name
            // produced "glm-5.1 · near.ai glm 5.2 · end-to-end encrypted": two
            // model names in one row, one of them wrong for the row it's in.
            // Matching the endpoint to a preset gets the service's actual name.
            let name = canonicalName(for: provider)
            if provider.capabilities.contains(.endToEndEncryption) {
                return "\(name) · end-to-end encrypted"
            }
            // Only stated where it's a real distinction the user can act on:
            // near.ai runs some models in enclaves and PROXIES others, so the
            // negative is news. Elsewhere it's the unremarkable default.
            if provider.endpoint.contains("near.ai") {
                return "\(name) · not end-to-end encrypted"
            }
            return name
        }
    }

    /// The service's name. Owned by `Provider`; this is the presentation
    /// spelling so Where rows keep calling one type.
    static func canonicalName(for provider: Provider) -> String {
        provider.canonicalName
    }

    static func systemImage(for provider: Provider) -> String {
        WhereLocality.of(provider).systemImage
    }

    /// The catalog's one-liner for a downloaded model, lowercased.
    ///
    /// Used instead of the place caption when the user is already filtered to
    /// the phone: "on this device" is the answer to a question the segment has
    /// already answered, and it was the same string on every row.
    static func modelDescription(for provider: Provider) -> String? {
        guard let localID = provider.localModelID,
              let model = LocalModelCatalog.model(id: localID) else { return nil }
        return model.blurb.lowercased()
    }

    /// Offline catalog rows for browse, when the place supports browsing.
    ///
    /// A FALLBACK, never the answer on its own — see `liveCatalogSource`. What
    /// these rows carry varies by provider and has nothing to do with the
    /// provider: near.ai's snapshot is a full catalogue (price, context, tiers),
    /// Grok's is built from `grokDisplayNames` — a name table, so every row has
    /// `price: ""` and no context — and Fireworks' from `fireworksPrices`, which
    /// has prices and no context. Rendering these *instead of* live is what made
    /// the three providers' rows look like three different designs.
    static func browseModels(for provider: Provider) -> [KnownModel] {
        if let preset = Provider.presets.first(where: { $0.sameEndpoint(as: provider) }) {
            return KnownModel.models(for: preset.id)
        }
        if provider.endpoint.contains("near.ai") {
            return KnownModel.nearAIModels
        }
        return []
    }

    /// Which live catalogue a browse row should fetch, or nil when there is
    /// nothing live to fetch.
    ///
    /// EVERY cloud provider has one. This returned near.ai alone until
    /// 2026-07-29, which is the whole of the "cloud browsers aren't consistent"
    /// bug: with no source, `ModelBrowserView` renders `browseModels` and nothing
    /// else, so a Grok row was a name and a vendor while a near.ai row a tap away
    /// was a name, a badge, a price and a context window.
    ///
    /// nil for the other two tiers, and for different reasons. The phone has no
    /// browse affordance at all — a downloaded model is already in `ready now`.
    /// Home does have one, but `syncHomeEquipped` puts every model the machine
    /// serves in that same list, so there is nothing on the other side of the tap;
    /// its catalogue arrives through `HomeServerProbe`, not through here.
    static func liveCatalogSource(for provider: Provider) -> EndpointModelCatalog.Source? {
        guard WhereLocality.of(provider) == .cloud, let host = provider.openAIBaseURL?.host
        else { return nil }
        return EndpointModelCatalog.Source.resolve(host: host)
    }

    /// The live catalogue for ANY provider, cloud or home — the one place that
    /// answers "what does this server say about its models".
    ///
    /// `liveCatalogSource` is cloud-only by design: it picks between the vendor
    /// adapters, and a home box is none of them. But that made a HOME model's
    /// detail page permanently empty — Ollama's `/api/show` already returns
    /// quantisation, parameter size and real context, and none of it could
    /// reach the page because the page had no way to ask for it.
    ///
    /// nil when there is genuinely nothing to fetch: on-device (no server), or
    /// a home server with no metadata endpoint teemoon speaks — LM Studio and
    /// llama.cpp answer `/v1/models` with ids and nothing else, so their pages
    /// stay thin and honestly so.
    static func liveModelsLoader(
        for provider: Provider,
        apiKey: String,
        homeKind: LocalServerKind?
    ) -> (() async -> [KnownModel]?)? {
        guard let base = provider.openAIBaseURL else { return nil }
        if let source = liveCatalogSource(for: provider) {
            let header = provider.authHeaderName
            return {
                guard case .connected(let models) = await ModelCatalog.liveCatalog(
                    for: source, baseURL: base, apiKey: apiKey, authHeaderName: header
                ) else { return nil }
                return models
            }
        }
        // A home box teemoon has a real adapter for.
        if WhereLocality.of(provider) == .home, homeKind == .ollama {
            return {
                guard case .connected(let models) =
                    await OllamaAdapter.listModels(baseURL: base) else { return nil }
                return models
            }
        }
        return nil
    }

    static func showsConfidentialityTags(for provider: Provider) -> Bool {
        provider.endpoint.contains("near.ai")
    }

    /// Joins a caption with one more piece of metadata using this file's `·`
    /// convention — `ollama` + `warm` → `ollama · warm`.
    ///
    /// Either side can be absent, and BOTH cases are real. A home model's
    /// warmth is nil for a server that doesn't report it (llama.cpp), and the
    /// caption is nil when the sheet is filtered to a single machine and the
    /// server's name would just be the tier's own label repeated downward — so
    /// naive interpolation produces a row captioned `ollama · ` or ` · warm`,
    /// an orphaned separator pointing at nothing.
    static func metadataRun(_ caption: String?, _ trailing: String?) -> String? {
        switch (caption, trailing) {
        case let (caption?, trailing?): return "\(caption) · \(trailing)"
        case let (caption?, nil): return caption
        case let (nil, trailing?): return trailing
        case (nil, nil): return nil
        }
    }
}
