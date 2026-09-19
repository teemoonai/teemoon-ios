//
//  ModelDetailView.swift
//  teemoon
//
//  What a model IS, next to what it costs.
//
//  The browser could say a model's price and context and nothing else, while
//  both catalogues were already handing teemoon more on every fetch and it was
//  being dropped: near.ai's /v1/models carries a prose description, the
//  features the model supports and the sampling parameters it accepts; the
//  fireworks control plane carries a description, a Hugging Face link, a GitHub
//  link and a deprecation date.
//
//  ONE RULE, the same as the price table's: render only what the provider
//  actually returned. A missing field is absent, never invented and never
//  borrowed from a neighbour — a browser that guesses is worse than one that
//  says less.
//
//  Reached by LONG PRESS on a model row. Tap still selects, because the sheet
//  this lives in exists to switch models quickly and an extra tap on that path
//  costs more than the detail is worth.
//

import SwiftUI

struct ModelDetailView: View {
    let model: KnownModel
    /// near.ai only — its confidentiality tier is teemoon's central claim, so it
    /// sits above the vendor's own prose rather than under it.
    var confidentiality: String? = nil
    /// Fetches the LIVE catalogue entry for this model, when one can be had.
    ///
    /// The page must show the same facts the model browser shows, and the
    /// browser's richness comes from the live catalogue — not from the shipped
    /// snapshot, which is always behind (it knew `deepseek-v4-flash` while
    /// `-0731` was the model actually answering). Opening from a Where row
    /// therefore has to make the same fetch the browser makes, or the two
    /// surfaces describe the same model differently.
    ///
    /// Optimistic: the page opens immediately with whatever is already known
    /// and fills in when the answer arrives. A spinner over an empty page would
    /// be slower and say less.
    var liveLoader: (() async -> KnownModel?)? = nil
    /// Who can serve this model, when the catalogue publishes such a list.
    /// Fetched when the page opens, beside `liveLoader`. nil otherwise — an
    /// empty section would imply the list exists.
    var offersLoader: (() async -> [ModelOffer])? = nil

    @State private var copiedID = false
    @State private var live: KnownModel? = nil
    @State private var offers: [ModelOffer] = []

    /// The live entry once it lands, else what we opened with.
    private var shown: KnownModel { live ?? model }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shown.displayName)
                        .font(.title3.weight(.semibold))
                        .textCase(.lowercase)
                    Text(shown.vendor.lowercased())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)

                // THE ID IS COPYABLE because it is what goes on the wire — the
                // debug card learned the same lesson: when something disagrees,
                // the exact string is the evidence.
                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = shown.id
                    #endif
                    copiedID = true
                    Haptics.play()
                } label: {
                    HStack {
                        Text(shown.id)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Image(systemName: copiedID ? "checkmark" : "square.on.square")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            if let deprecation = shown.deprecationLabel {
                Section {
                    Label(deprecation, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textCase(.lowercase)
                } footer: {
                    Text("the provider has announced a retirement date for this model.")
                        .textCase(.lowercase)
                }
            }

            if let confidentiality {
                Section("confidentiality") {
                    Text(confidentiality).textCase(.lowercase)
                }
            }

            Section("what it costs") {
                if !shown.price.isEmpty {
                    row("price", shown.priceLabel)
                } else if shown.isFree {
                    row("price", "free")
                } else {
                    // Absent, not guessed — see the header.
                    Text("no published price")
                        .foregroundStyle(.secondary)
                        .textCase(.lowercase)
                }
                if !shown.contextWindow.isEmpty {
                    row("context", shown.contextWindow.lowercased())
                }
                if let out = shown.maxOutputTokens {
                    row("max output", ModelCatalog.contextLabel(out).lowercased())
                }
                // Cache reads, image tokens, a per-search fee, a long-context
                // tier: what the two headline rates leave out.
                ForEach(shown.extraCosts, id: \.label) { cost in
                    row(cost.label, cost.amount)
                }
            }

            if shown.parameterSize != nil || shown.quantization != nil
                || shown.downloadSize != nil || shown.pinnedRevision != nil {
                Section {
                    if let params = shown.parameterSize { row("parameters", params) }
                    // The weights' real precision — what a local model trades
                    // quality for size on, and the one number that explains why
                    // two copies of "the same" model answer differently.
                    if let quant = shown.quantization { row("quantization", quant) }
                    if let size = shown.downloadSize { row("size", size) }
                    // Shortened: a full sha is 40 characters of noise on a phone,
                    // and the point is that a pin EXISTS and which one.
                    if let rev = shown.pinnedRevision {
                        row("pinned revision", String(rev.prefix(12)))
                    }
                } header: {
                    Text("weights").textCase(.lowercase)
                }
            }

            if !shown.features.isEmpty || !shown.inputModalities.isEmpty {
                Section("what it can do") {
                    if !shown.features.isEmpty {
                        chips(shown.features)
                    }
                    if !shown.inputModalities.isEmpty {
                        row("accepts", shown.inputModalities.joined(separator: ", "))
                    }
                    if !shown.reasoningEfforts.isEmpty {
                        row("reasoning", shown.reasoningEfforts.joined(separator: ", "))
                    }
                    if let cutoff = shown.knowledgeCutoff {
                        row("knows up to", cutoff)
                    }
                }
            }

            if !offers.isEmpty {
                Section {
                    ForEach(offers) { offer in providerOffer(offer) }
                } header: {
                    Text("providers").textCase(.lowercase)
                } footer: {
                    Text("who openrouter can route this model to. speed is "
                         + "measured over the last half hour.")
                        .textCase(.lowercase)
                }
            }

            if let summary = shown.summary {
                Section("about") {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !shown.samplingParameters.isEmpty {
                Section {
                    chips(shown.samplingParameters)
                } header: {
                    Text("request parameters").textCase(.lowercase)
                } footer: {
                    Text("what this model accepts. published by the provider, not guessed.")
                        .textCase(.lowercase)
                }
            }

            if shown.modelPageURL != nil || shown.huggingFaceURL != nil || shown.githubURL != nil {
                Section("elsewhere") {
                    link("model page", shown.modelPageURL)
                    link("hugging face", shown.huggingFaceURL)
                    link("source", shown.githubURL)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Both at once: the card is worth less with either half missing,
            // and the providers table is a second request.
            async let fresh: KnownModel? = liveLoader?() ?? nil
            async let routes: [ModelOffer] = offersLoader?() ?? []
            if live == nil, let fresh = await fresh { live = fresh }
            let loaded = await routes
            if !loaded.isEmpty { offers = loaded }
        }
        .navigationTitle("model")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).textCase(.lowercase)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textCase(.lowercase)
        }
    }

    @ViewBuilder
    private func link(_ label: String, _ raw: String?) -> some View {
        if let raw, let url = URL(string: raw) {
            Link(destination: url) {
                Label(label, systemImage: "arrow.up.right.square")
                    .textCase(.lowercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.tint)
        }
    }

    /// Wrapping chips. The provider's own spelling is kept — `json_mode`, not
    /// "JSON mode" — because this view reports what was said rather than
    /// teemoon's reading of it, and the raw name is what you would put in a
    /// request.
    /// One routing target. Only what the catalogue actually reported: latency
    /// and throughput are null without a key, and a row of blanks says nothing.
    @ViewBuilder
    private func providerOffer(_ offer: ModelOffer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(offer.title)
                    .font(.body.weight(.medium))
                    .textCase(.lowercase)
                if offer.isZeroDataRetention {
                    Text("zero data retention")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.13)))
                        .fixedSize()
                }
            }
            if offer.isFree {
                row("price", "free")
            } else if !offer.price.isEmpty {
                row("price", offer.price + " / 1M tokens")
            }
            if let context = offer.contextTokens {
                row("context", ModelCatalog.contextLabel(context).lowercased())
            }
            if let out = offer.maxOutputTokens {
                row("max output", ModelCatalog.contextLabel(out).lowercased())
            }
            if let quant = offer.quantization { row("quantization", quant) }
            if let uptime = offer.uptimeLabel { row("uptime · 1d", uptime) }
            if let latency = offer.latencyLabel { row("first token", latency) }
            if let throughput = offer.throughputLabel { row("speed", throughput) }
            if offer.supportsImplicitCaching { row("caching", "automatic") }
        }
        .padding(.vertical, 4)
    }

    private func chips(_ items: [String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.fill))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Minimal wrapping stack — chips run on as many lines as they need.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

#Preview("Model detail — near.ai") {
    NavigationStack {
        ModelDetailView(
            model: KnownModel(
                id: "deepseek-ai/DeepSeek-V4-Flash",
                displayName: "DeepSeek V4 Flash",
                vendor: "DeepSeek",
                price: "$0.17/$0.35",
                contextWindow: "1M",
                capabilities: [.tools],
                summary: "DeepSeek V4 Flash — large mixture-of-experts language model from "
                    + "DeepSeek, FP8-quantized. Served on H200 with TP=4 and EAGLE speculative "
                    + "decoding in a TDX-confidential inference CVM.",
                features: ["tools", "reasoning", "json_mode", "structured_outputs"],
                samplingParameters: ["temperature", "top_p", "top_k", "min_p",
                                     "frequency_penalty", "presence_penalty",
                                     "repetition_penalty", "max_tokens", "stop",
                                     "seed", "logit_bias"],
                maxOutputTokens: 32768,
                inputModalities: ["text"]),
            confidentiality: "end-to-end encrypted"
        )
    }
}

#Preview("Model detail — fireworks, retiring") {
    NavigationStack {
        ModelDetailView(
            model: KnownModel(
                id: "accounts/fireworks/models/deepseek-v4-flash-0731",
                displayName: "DeepSeek V4 Flash 0731",
                vendor: "DeepSeek",
                price: "$0.14/$0.28",
                contextWindow: "1M",
                capabilities: [.tools],
                summary: "The official release of DeepSeek-V4-Flash-0731, with substantially "
                    + "enhanced agentic capabilities over the preview it supersedes.",
                huggingFaceURL: "https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash",
                modelPageURL: "https://app.fireworks.ai/models/fireworks/deepseek-v4-flash-0731",
                // Through the same parser the adapter uses, so the preview can't
                // show a date shape the wire path would reject.
                deprecationDate: KnownModel.deprecationDate(fromProvider: "2026-12-01"))
    )
    }
}

#Preview("Model detail — nvidia, free tier") {
    NavigationStack {
        ModelDetailView(
            model: KnownModel(
                id: "nvidia/nemotron-3-super-120b-a12b",
                displayName: "nemotron-3-super-120b-a12b",
                vendor: "NVIDIA",
                // No price and no context: the hosted tier is free for
                // development, and the list reports no window.
                price: "",
                modelPageURL: "https://build.nvidia.com/nvidia/nemotron-3-super-120b-a12b",
                isFree: true)
        )
    }
}

/// An OpenRouter card with everything that catalogue publishes: the cost lines
/// under the headline rate, what the model can be asked to do, and who it can
/// be routed to. Values are from a real 2026-09-15 capture.
#Preview("Model detail — openrouter") {
    NavigationStack {
        ModelDetailView(
            model: {
                var model = KnownModel(
                    id: "openai/gpt-5.4",
                    displayName: "GPT 5.4",
                    vendor: "OpenAI",
                    price: "$2.50/$15.00",
                    contextWindow: "1.1M",
                    capabilities: [.tools, .vision],
                    summary: "GPT-5.4 unifies the Codex and GPT lines into one model.",
                    features: ["tools", "reasoning", "structured outputs", "moderated"],
                    samplingParameters: ["reasoning_effort", "response_format", "seed", "tools"],
                    maxOutputTokens: 128_000,
                    inputModalities: ["text", "image", "file"],
                    modelPageURL: "https://openrouter.ai/openai/gpt-5.4")
                model.extraCosts = [
                    .init(label: "cache read", perMillion: 0.25),
                    .init(label: "web search", perCall: 0.01),
                    .init(label: "past 272k", perMillion: 5, perMillionOutput: 22.5),
                ]
                model.reasoningEfforts = ["xhigh", "high", "medium", "low", "none"]
                model.knowledgeCutoff = "2025-09-30"
                return model
            }(),
            offersLoader: {
                [
                    ModelOffer(
                        providerName: "OpenAI", tag: "openai/flex", price: "$1.25/$7.50",
                        contextTokens: 1_050_000, maxOutputTokens: 128_000,
                        uptimePercent: 91.6, latencyMilliseconds: 2085.5,
                        throughputTokensPerSecond: 37),
                    ModelOffer(
                        providerName: "Azure", tag: "azure/us", price: "$2.50/$15.00",
                        contextTokens: 1_050_000, uptimePercent: 99.97,
                        latencyMilliseconds: 600, throughputTokensPerSecond: 38,
                        isZeroDataRetention: true),
                ]
            })
    }
}
