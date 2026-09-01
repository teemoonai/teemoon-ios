//
//  ModelBrowserView.swift
//  teemoon
//
//  Model picker sheet. Lived inside AddEditProviderView.swift; the form and
//  the browser are different products.
//

import SwiftUI

// MARK: - Model browser sheet

/// How the browser groups rows. Sorting reorders rows *within* these groups; it
/// never dissolves them — so a flat price list can't bury the trust structure.
enum ModelGrouping: CaseIterable { case confidentiality, vendor }
/// Sort applied within each group.
enum ModelSortWithin: CaseIterable { case `default`, priceAsc, priceDesc }

struct ModelBrowserView: View {
    @Binding var selectedModel: String
    /// Curated / offline model list, shown immediately.
    let models: [KnownModel]
    var onSelect: ((KnownModel) -> Void)? = nil
    /// Optional live catalogue loader (near.ai). When it returns a non-empty
    /// list, it replaces `models`; on failure the curated list stays.
    var liveLoader: (() async -> [KnownModel]?)? = nil
    /// near.ai only: tag each row with its confidentiality tier.
    var showsConfidentialityTags = false
    @State private var liveModels: [KnownModel]? = nil
    @State private var isLoadingLive = false
    @State private var sortWithin: ModelSortWithin = .default
    /// nil = use the default for this catalog (confidentiality when tiered, else vendor).
    @State private var groupingOverride: ModelGrouping? = nil
    /// The model whose detail is pushed, if any.
    @State private var detailModel: KnownModel? = nil
    @Environment(\.dismiss) var dismiss

    /// Live list once loaded, else the curated fallback.
    private var effectiveModels: [KnownModel] { liveModels ?? models }

    /// Default grouping: confidentiality is the *resting structure* for a tiered
    /// (near.ai) catalog so trust never scatters; vendor otherwise.
    private var grouping: ModelGrouping {
        groupingOverride ?? (showsConfidentialityTags ? .confidentiality : .vendor)
    }
    private var groupingBinding: Binding<ModelGrouping> {
        Binding(get: { grouping }, set: { groupingOverride = $0 })
    }

    /// Sort applied within each group (never across groups).
    private var sortedModels: [KnownModel] {
        switch sortWithin {
        case .default:   return effectiveModels
        case .priceAsc:  return effectiveModels.sorted { priceScore($0) < priceScore($1) }
        case .priceDesc: return effectiveModels.sorted { priceScore($0) > priceScore($1) }
        }
    }

    /// Combined price for sorting: input + output per-1M rates. Output usually
    /// dominates real spend, so summing both reflects cost far better than the input
    /// rate alone (e.g. a cheap-input / dear-output model shouldn't read as "cheap").
    private func priceScore(_ model: KnownModel) -> Double {
        // "$1.40/$4.40" → 1.40 + 4.40
        model.price.split(separator: "/").reduce(0.0) { acc, part in
            let digits = part.drop(while: { !$0.isNumber && $0 != "." })
            return acc + (Double(digits.prefix(while: { $0.isNumber || $0 == "." })) ?? 0)
        }
    }

    /// Forwards to the tier's own label — see `Confidentiality.label`. Kept as a
    /// name because the call sites read better with it.
    private func tierHeader(_ t: NearAIModelCatalog.Confidentiality) -> String { t.label }

    /// Rows bucketed by the active grouping, each bucket sorted by `sortWithin`.
    /// Confidentiality groups run in trust order (e2ee → attested → proxied); vendor
    /// groups run in first-appearance order.
    private var groups: [(id: String, header: String, models: [KnownModel])] {
        let rows = sortedModels
        switch grouping {
        case .confidentiality:
            let order: [NearAIModelCatalog.Confidentiality] = [.teeOwn, .teeThirdParty, .proxied]
            return order.compactMap { tier in
                let ms = rows.filter { NearAIModelCatalog.confidentiality(forID: $0.id) == tier }
                return ms.isEmpty ? nil : (String(describing: tier), tierHeader(tier), ms)
            }
        case .vendor:
            var seen: [String] = []
            for m in rows where !seen.contains(m.vendor) { seen.append(m.vendor) }
            return seen.map { v in (v, v.lowercased(), rows.filter { $0.vendor == v }) }
        }
    }

    private var groupSummary: String {
        switch grouping { case .confidentiality: return "confidentiality"; case .vendor: return "vendor" }
    }
    private var sortSummary: String {
        switch sortWithin {
        case .default:   return "default"
        case .priceAsc:  return "price ↑"
        case .priceDesc: return "price ↓"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section { sortGroupControl }
                ForEach(groups, id: \.id) { group in
                    Section {
                        ForEach(group.models) { model in
                            modelRow(model)
                        }
                    } header: {
                        Text(group.header).textCase(.lowercase)
                    }
                }
            }
            .navigationTitle("browse models")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // A PUSH, not another sheet. The browser is already presented
            // modally — from Where, on top of a second sheet — and stacking a
            // third would leave the user two dismissals from the transcript.
            .navigationDestination(item: $detailModel) { model in
                ModelDetailView(
                    model: model,
                    // near.ai is the only catalogue that tiers its models, and
                    // that tier is the app's central claim — so it is passed in
                    // only where it is real.
                    confidentiality: showsConfidentialityTags
                        ? tierHeader(NearAIModelCatalog.confidentiality(forID: model.id))
                        : nil
                )
            }
            .task {
                guard let liveLoader, liveModels == nil else { return }
                isLoadingLive = true
                if let live = await liveLoader(), !live.isEmpty { liveModels = live }
                isLoadingLive = false
            }
            .toolbar {
                #if os(iOS) || os(visionOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isLoadingLive { ProgressView() }
                }
                #elseif os(macOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                #endif
            }
        }
    }

    /// The list-header control that states both dimensions at rest — "confidentiality ·
    /// price ↑" — and opens one menu holding group + sort, so they're never two separate
    /// hunts. Replaces the old nav-bar 3-way cycle icon that never said what it sorted by.
    private var sortGroupControl: some View {
        Menu {
            if showsConfidentialityTags {
                Picker("group by", selection: groupingBinding) {
                    Text("confidentiality").tag(ModelGrouping.confidentiality)
                    Text("vendor").tag(ModelGrouping.vendor)
                }
            }
            Picker("sort", selection: $sortWithin) {
                Text("default").tag(ModelSortWithin.default)
                Text("price · low to high").tag(ModelSortWithin.priceAsc)
                Text("price · high to low").tag(ModelSortWithin.priceDesc)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.caption)
                Text(showsConfidentialityTags ? "\(groupSummary) · \(sortSummary)" : sortSummary)
                    .textCase(.lowercase)
                Image(systemName: "chevron.down").font(.caption2)
                Spacer()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func modelRow(_ model: KnownModel) -> some View {
        Button {
            selectedModel = model.id
            onSelect?(model)
            dismiss()
        } label: {
            // One flowing line: name (truncates, never wraps) → tags right after it →
            // price/context right-aligned. Flattened so a long name shrinks itself
            // instead of wrapping under the tag.
            HStack(spacing: 6) {
                Text(model.displayName)
                    .tint(.primary)
                    .textCase(.lowercase)
                    .lineLimit(1)
                // RETIRING, next to `new` and in its place when both would show:
                // a model on its way out is the more decision-relevant fact, and
                // two badges on one row is where the name starts truncating.
                if model.isRetiring {
                    Text("retiring")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.14)))
                        .fixedSize()
                } else if model.isNew {
                    Text("new")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .fixedSize()
                }
                // Not when the list is GROUPED by confidentiality: the section
                // header directly above already says "attested on third-party
                // hardware", so the tag repeats it once per row and spends the
                // width doing it. It's `.fixedSize()` and the name isn't, so the
                // name is what paid — `deepseek v3.2` rendered as "deeps…" beside
                // a 17-character tag restating its own heading. The tag earns its
                // place under any OTHER grouping, where trust would otherwise
                // scatter across vendor sections.
                if showsConfidentialityTags, grouping != .confidentiality {
                    confidentialityTag(NearAIModelCatalog.confidentiality(forID: model.id))
                        .fixedSize()
                }
                Spacer(minLength: 6)
                Text(model.metaLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)          // reference data — quiet gray
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()                          // price stays intact; the name yields first
            }
        }
        // .plain so price/context + tier tags render in true label colors instead of
        // inheriting the row Button's accent (the "everything went blue" bug).
        #if os(macOS)
        .buttonStyle(.borderless)
        #else
        .buttonStyle(.plain)
        #endif
        // LONG PRESS, not a second tap target in the row.
        //
        // Tapping a row selects the model, and this sheet exists to switch
        // models quickly — an extra tap on that path costs more than the detail
        // is worth. Nesting a button inside the row Button was tried elsewhere
        // in this app and rejected: two tap targets in one row make which one
        // fired ambiguous.
        .contextMenu {
            Button {
                detailModel = model
            } label: {
                Label("model info", systemImage: "info.circle")
            }
        }
    }

    // Trust-tier badge is now the file-level `confidentialityTag(_:)` so the inline
    // add-provider rows can render it identically to the browser.

    /// Extracts the input price from "$2.00/$6.00" → 2.00
    private func inputPrice(_ model: KnownModel) -> Double {
        let s = model.price.drop(while: { $0 == "$" })
        return Double(s.prefix(while: { $0.isNumber || $0 == "." })) ?? 0
    }
}

#Preview("Add Provider") {
    AddEditProviderView(mode: .add)
        .environment(ProviderStore())
}

// MARK: Where → get → "browse X · add key"
//
// The place is already chosen, so: no preset grid, title "add {vendor} key",
// endpoint filled, and the key field is the whole job. Previews per provider
// because each one's identity tile, signup link and model section differ — and
// brave answers has no model browser at all.

#Preview("Where → add near.ai key") {
    AddEditProviderView(mode: .add, initialPreset: .nearAI)
        .environment(ProviderStore(inMemory: true))
}

#Preview("Where → add grok key") {
    AddEditProviderView(mode: .add, initialPreset: .grok)
        .environment(ProviderStore(inMemory: true))
}

#Preview("Where → add fireworks key") {
    AddEditProviderView(mode: .add, initialPreset: .fireworks)
        .environment(ProviderStore(inMemory: true))
}

#Preview("Where → add brave answers key") {
    // Fixed model, single-turn: connection check, no model browser.
    AddEditProviderView(mode: .add, initialPreset: .braveAnswers)
        .environment(ProviderStore(inMemory: true))
}

#Preview("Edit Provider") {
    // Cloud preset detail: identity tile + quiet "open console" (not "get api key").
    AddEditProviderView(mode: .edit(Provider.nearAI))
        .environment(ProviderStore(inMemory: true))
}

// Brave publishes no model list, so this screen shows a connection check instead
// of a model picker — there is nothing to fetch, pick, or refresh.
/// A KEYED cloud setup — the state this screen is opened in most of the time, and the
/// one a canvas could not show: the key comes from the Keychain, which is empty here.
///
/// Both destructive actions are visible, which is the point of having two. Revoking a
/// key at the vendor means clearing it here, and that used to require emptying the
/// field and saving — an edit gesture for a removal — so the only obvious button
/// deleted the whole setup and took the equipped models with it.
///
/// The key field looks EMPTY in this render and isn't: a `SecureField`'s dots don't
/// draw in a preview snapshot. The copy button beside it and the `remove key` section
/// below both appear only when a key is present, so they are the proof.
#Preview("Edit Provider — keyed") {
    let store = ProviderStore(inMemory: true)
    var near = Provider.nearAI
    near.equippedModels = ["z-ai/glm-5.2", "z-ai/glm-5.1"]
    store.providers = [near]
    return AddEditProviderView(mode: .edit(near),
                               keyOverride: "near-sk-preview-000000000000000000")
        .environment(store)
}

/// What `places & keys` opens now: a SERVER-and-key page. No model field, no fetch, no
/// "use this provider" — those belong to the Where chip, and having them here is what
/// made a key look like a property of a model.
///
/// The model is not lost, only absent: `save()` writes back what was loaded, so the
/// equipped set and the active id survive.
/// Every failure this screen can show, which none of them had a preview for — nine
/// strings that are the only explanation a user gets for a setup that won't connect.
///
/// Also the on-device state that exposed the duplicate: the message
/// no longer carries its own "try again", because the button directly above it —
/// "refresh models" here, "test connection" in the connection section — already runs
/// the same probe.
#Preview("Add key — connection failed") {
    AddEditProviderView(mode: .add,
                        connOverride: .failed(.unauthorized),
                        initialPreset: .grok)
        .environment(ProviderStore(inMemory: true))
}

/// A SAVED provider whose key was removed — reachable via "remove key" above.
/// Edit mode with an empty field, so it is exactly the state the old
/// `!isEditing` gate stranded: the screen asks for a key and, before the gate
/// moved to "field is empty", offered no way to get one.
#Preview("Server & key — cloud, key removed") {
    let store = ProviderStore(inMemory: true)
    var near = Provider.nearAI
    near.equippedModels = ["z-ai/glm-5.2"]
    store.providers = [near]
    return AddEditProviderView(scope: .serverAndKey, mode: .edit(near),
                               keyOverride: "")
        .environment(store)
}

#Preview("Server & key — cloud") {
    let store = ProviderStore(inMemory: true)
    var near = Provider.nearAI
    near.equippedModels = ["z-ai/glm-5.2", "z-ai/glm-5.1"]
    store.providers = [near]
    return AddEditProviderView(scope: .serverAndKey, mode: .edit(near),
                               keyOverride: "near-sk-preview-000000000000000000")
        .environment(store)
}

/// The same page for a machine — which CAN need a key (llama.cpp and vLLM both take
/// `--api-key`, and a proxied Ollama can want a bearer token), so the field is here
/// too. This one is keyless, which is the common case.
/// What "add cloud key" opens now — the ADD half of the same scope.
///
/// The preset grid stays: it names the PLACE, which is the question this screen asks.
/// What went is the model half — no fetch, no picker — because "add a key" was
/// otherwise a model chooser with a key field in it, and the model it chose was
/// immediately overridden by whatever the Where chip picked next.
#Preview("Add cloud key — server & key") {
    AddEditProviderView(scope: .serverAndKey, mode: .add)
        .environment(ProviderStore(inMemory: true))
}

#Preview("Server & key — machine") {
    let store = ProviderStore(inMemory: true)
    var box = Provider(name: "ringzero", endpoint: "https://ringzero.tailnet-name.ts.net:11434/v1",
                       model: "gemma4:e4b", requiresAPIKey: false)
    box.equippedModels = ["gemma4:e4b", "qwen3.5:4b"]
    store.providers = [box]
    return AddEditProviderView(scope: .serverAndKey, mode: .edit(box))
        .environment(store)
}

#Preview("Edit Provider — Brave (no models)") {
    AddEditProviderView(mode: .edit(Provider.braveAnswers))
        .environment(ProviderStore(inMemory: true))
}

// The cloud previews below build their rows through the ADAPTER, from a sample of
// the real wire payload — not from the curated block. The curated lists always
// looked right in a preview, which is exactly how the live pickers came to render
// bare ids with no price or vendor without anyone noticing.

/// Grok rows as the app builds them, from a sample of the real
/// `/v1/language-models` + `/v1/models` pair. Shared with the parity preview at
/// the bottom of this file so the two can't drift into two fixtures.
private func previewGrokRows() -> [KnownModel] {
    let sample = """
    {"models":[
     {"id":"grok-4.5","created":1782691200,"input_modalities":["text","image"],
      "prompt_text_token_price":20000,"completion_text_token_price":60000},
     {"id":"grok-4.3","created":1776384000,"input_modalities":["text","image"],
      "prompt_text_token_price":12500,"completion_text_token_price":25000},
     {"id":"grok-build-0.1","created":1776297600,"input_modalities":["text","image"],
      "prompt_text_token_price":10000,"completion_text_token_price":20000},
     {"id":"grok-4.20-0309-reasoning","created":1773014400,"input_modalities":["text","image"],
      "prompt_text_token_price":12500,"completion_text_token_price":25000}]}
    """
    let list = try! JSONDecoder().decode(XAIAdapter.LanguageModelsResponse.self, from: Data(sample.utf8))
    return XAIAdapter.buildModels(
        from: list.models.map(XAIAdapter.Entry.init(language:)),
        contexts: ["grok-4.5": 500_000, "grok-4.3": 1_000_000,
                   "grok-build-0.1": 256_000, "grok-4.20-0309-reasoning": 1_000_000],
        // Pinned, like the near.ai live preview below: the badge is part of what
        // makes these rows match, so it must not depend on the clock.
        now: previewNow)
}

/// 2026-07-29, so `isNew` is asserted by the fixture rather than by the calendar.
private let previewNow: Date = {
    var when = DateComponents()
    when.year = 2026; when.month = 7; when.day = 29
    when.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: when)!
}()

#Preview("Model Browser — Grok") {
    ModelBrowserView(selectedModel: .constant("grok-4.5"), models: previewGrokRows())
}

#Preview("Model Browser — LM Studio (local)") {
    let sample = """
    {"data":[
     {"id":"qwen2.5-7b-instruct","type":"llm","publisher":"bartowski","arch":"qwen2",
      "quantization":"Q4_K_M","state":"loaded","max_context_length":32768,
      "capabilities":["tool_use"]},
     {"id":"gemma-4-e4b-it-qat@q4_k_xl","type":"vlm","publisher":"unsloth","arch":"gemma4",
      "quantization":"Q4_K_XL","state":"not-loaded","max_context_length":131072,
      "capabilities":["tool_use"]},
     {"id":"gemma-4-e4b-it-qat@q2_k_xl","type":"vlm","publisher":"unsloth","arch":"gemma4",
      "quantization":"Q2_K_XL","state":"not-loaded","max_context_length":131072,
      "capabilities":["tool_use"]},
     {"id":"text-embedding-nomic-embed-text-v1.5","type":"embeddings","publisher":"nomic-ai",
      "arch":"nomic-bert","quantization":"Q4_K_M","state":"not-loaded","max_context_length":2048}]}
    """
    let list = try! JSONDecoder().decode(LMStudioAdapter.ModelsResponse.self, from: Data(sample.utf8))
    return ModelBrowserView(selectedModel: .constant("qwen2.5-7b-instruct"),
                            models: LMStudioAdapter.buildModels(from: list.data))
}

#Preview("Model Browser — near.ai") {
    ModelBrowserView(selectedModel: .constant("zai-org/GLM-5.1-FP8"),
                     models: KnownModel.nearAIModels,
                     showsConfidentialityTags: true)
}

/// The LIVE near.ai catalog, which is what both browsers now render — the
/// preview above shows the offline fallback, and the two used to be the same
/// thing.
///
/// Real `created` values from a captured `/v1/models`, and `now` pinned to
/// 2026-07-29, so the badge is asserted rather than left to the clock: glm-5.2
/// (2026-06-17, 42 days) wears it and Qwen3.6-27B / DeepSeek-V4-Flash
/// (2026-06-04, 55 days) do not. Those last two were the rows the frozen
/// snapshot was still badging.
///
/// `models: []` on purpose — nothing curated to fall back to, so anything on
/// screen came from the live path.
#Preview("Model Browser — near.ai · live") {
    let sample = """
    {"object":"list","data":[
     {"id":"z-ai/glm-5.2","created":1781700379,"owned_by":"nearai","name":"GLM 5.2",
      "pricing":{"input":1.4,"output":4.4},"context_length":1000000,
      "supported_features":["tools"],"input_modalities":["text"]},
     {"id":"deepseek/deepseek-v3.2","created":1781515743,"owned_by":"nearai","name":"DeepSeek V3.2",
      "pricing":{"input":0.27,"output":0.41},"context_length":163840,
      "supported_features":["tools"],"input_modalities":["text"]},
     {"id":"Qwen/Qwen3.6-27B-FP8","created":1780589812,"owned_by":"nearai","name":"Qwen3.6 27B",
      "pricing":{"input":0.33,"output":3.25},"context_length":262144,
      "supported_features":["tools"],"input_modalities":["text"]},
     {"id":"deepseek-ai/DeepSeek-V4-Flash","created":1780561470,"owned_by":"nearai","name":"DeepSeek V4 Flash",
      "pricing":{"input":0.17,"output":0.35},"context_length":1000000,
      "supported_features":["tools"],"input_modalities":["text"]},
     {"id":"google/gemini-3.5-flash","created":1779214705,"owned_by":"openrouter","name":"Gemini 3.5 Flash",
      "pricing":{"input":0.3,"output":2.5},"context_length":1048576,
      "supported_features":["tools"],"input_modalities":["text","image"]}
    ]}
    """
    var when = DateComponents()
    when.year = 2026; when.month = 7; when.day = 29
    when.timeZone = TimeZone(identifier: "UTC")
    let pinned = Calendar(identifier: .gregorian).date(from: when)!
    return ModelBrowserView(
        selectedModel: .constant("z-ai/glm-5.2"),
        models: [],
        liveLoader: {
            guard let list = try? JSONDecoder().decode(
                NearAIModelCatalog.ModelsResponse.self, from: Data(sample.utf8)
            ) else { return nil }
            return await NearAIModelCatalog.buildModels(from: list.data, now: pinned)
        },
        showsConfidentialityTags: true)
}

/// Fireworks rows as the app builds them, from a sample of the real control-plane
/// list. Shared with the parity preview below.
///
/// `createTime` values are the REAL ones from that capture (2026-07-25), because
/// two things a Fireworks row does are derived from them and both were invisible
/// while the field was missing from this sample: the `new` badge, and the vendor
/// ordering (each section ranked by its newest model). Against `previewNow`,
/// glm 5.2 (2026-06-16, 43 days) earns the badge and kimi k2.7 code (47 days)
/// just misses it — which is the badge working, not the badge broken.
private func previewFireworksRows() -> [KnownModel] {
    let sample = """
    {"models":[
     {"name":"accounts/fireworks/models/kimi-k2p7-code","displayName":"Kimi K2.7 Code",
      "kind":"HF_BASE_MODEL","state":"READY","contextLength":262144,"createTime":"2026-06-12T17:00:00.491288Z",
      "supportsServerless":true,"supportsTools":true,"supportsImageInput":true},
     {"name":"accounts/fireworks/models/deepseek-v4-flash","displayName":"DeepSeek-V4-Flash",
      "kind":"HF_BASE_MODEL","state":"READY","contextLength":1048576,"createTime":"2026-04-24T04:09:07.488210Z",
      "supportsServerless":true,"supportsTools":true,"supportsImageInput":false},
     {"name":"accounts/fireworks/models/glm-5p2","displayName":"GLM 5.2",
      "kind":"HF_BASE_MODEL","state":"READY","contextLength":1048576,"createTime":"2026-06-16T17:18:13.939706Z",
      "supportsServerless":true,"supportsTools":true,"supportsImageInput":false},
     {"name":"accounts/fireworks/models/minimax-m3","displayName":"Minimax M3",
      "kind":"HF_BASE_MODEL","state":"READY","contextLength":512000,"createTime":"2026-06-11T21:52:28.589913Z",
      "supportsServerless":true,"supportsTools":true,"supportsImageInput":false},
     {"name":"accounts/fireworks/models/nemotron-3-ultra-nvfp4","displayName":"NVIDIA Nemotron 3 Ultra NVFP4",
      "kind":"HF_BASE_MODEL","state":"READY","contextLength":262144,"createTime":"2026-06-02T15:48:46.182132Z",
      "supportsServerless":true,"supportsTools":true,"supportsImageInput":false},
     {"name":"accounts/fireworks/models/gpt-oss-20b","displayName":"OpenAI gpt-oss-20b",
      "kind":"HF_BASE_MODEL","state":"READY","contextLength":131072,"createTime":"2025-08-04T22:11:06.445132Z",
      "supportsServerless":true,"supportsTools":false,"supportsImageInput":false},
     {"name":"accounts/fireworks/models/qwen3-embedding-8b","displayName":"Qwen3 Embedding 8B",
      "kind":"EMBEDDING_MODEL","state":"READY","contextLength":40960,"createTime":"2025-08-20T16:24:50.233084Z",
      "supportsServerless":true,"supportsTools":false,"supportsImageInput":false}]}
    """
    let list = try! JSONDecoder().decode(FireworksAdapter.ModelsResponse.self, from: Data(sample.utf8))
    return FireworksAdapter.buildModels(from: list.models, now: previewNow)
}

#Preview("Model Browser — Fireworks") {
    ModelBrowserView(selectedModel: .constant("accounts/fireworks/models/kimi-k2p7-code"),
                     models: previewFireworksRows())
}

/// The comparison being made on the device: the three cloud catalogues side
/// by side, each rendered by the browser the Where sheet opens.
///
/// They did not look alike, and the difference was never the design — it was what
/// reached the rows. near.ai fetched live from this sheet and grok and fireworks
/// did not, so they fell back to a curated snapshot: `grokDisplayNames` is a NAME
/// table (`price: ""`, no context, no badge) and `fireworksPrices` is a PRICE
/// table (no context, no badge). One column had a full right-hand rail, one had
/// half of it, one had nothing.
///
/// All three columns now come through `ModelCatalog.liveCatalog` in the app, so
/// all three carry the same run: name · badge · price · context. near.ai keeps
/// its confidentiality grouping — that is a near.ai FACT, not a fourth row shape,
/// and it is the one difference that should survive.
#Preview("Model Browser — cloud parity", traits: .fixedLayout(width: 1240, height: 880)) {
    HStack(spacing: 0) {
        ModelBrowserView(selectedModel: .constant("grok-4.5"), models: previewGrokRows())
        Divider()
        ModelBrowserView(selectedModel: .constant("accounts/fireworks/models/kimi-k2p7-code"),
                         models: previewFireworksRows())
        Divider()
        ModelBrowserView(selectedModel: .constant("zai-org/GLM-5.1-FP8"),
                         models: KnownModel.nearAIModels,
                         showsConfidentialityTags: true)
    }
}
