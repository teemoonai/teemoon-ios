//
//  WhereGetSection.swift
//  teemoon
//
//  The Where sheet's `get` section — what you could add, per tier. Decisions
//  arrive as `WhereGetPolicy`; taps leave through the closures. Layout only:
//  do not grow a state machine here.
//

import SwiftUI

struct WhereGetSection<Header: View>: View {
    @Environment(ProviderStore.self) var providerStore

    /// Who appears in the lists, and every caption / footer string.
    let policy: WhereGetPolicy
    /// Whether the sheet was opened straight to `get` — decides the footer copy.
    let openToGet: Bool
    /// Downloads are started and cancelled from the `get` list, so their
    /// progress has to be observed here.
    let downloader: LocalModelDownloader
    /// `WhereSheetView.hasKey` — the policy's answer, preview-overridable.
    let hasKey: (Provider) -> Bool
    /// The sheet's own header treatment, so `get` matches `ready now`.
    let sectionHeader: (String) -> Header

    @Binding var idsBeforeAdd: Set<UUID>
    @Binding var addTarget: WhereSheetView.AddTarget?
    @Binding var addingPreset: Provider?
    @Binding var pullingOnProvider: Provider?
    @Binding var detailTarget: ModelDetailTarget?

    let openBrowse: (Provider) -> Void
    let startAndSelect: (LocalModel) -> Void

    var body: some View {
        if policy.filter == nil {
            allGetBody
        } else if !policy.getSectionIsEmpty {
            getSectionBody
        }
    }

    /// `all` is not a fourth tier — it's the other three read end to end, so its
    /// `get` is ordered by what it costs the user rather than by internal type:
    /// a download that needs nothing, then a machine you own, then a key you pay
    /// for, then the catalogs behind those keys.
    ///
    /// Per-tier `get` keeps its own order, because there the user has already
    /// narrowed to one kind of answer.
    @ViewBuilder
    private var allGetBody: some View {
        Section {
            // 1. ONE model you could have on the phone, by name — the
            //    recommended one, or none. The generic "download on this phone"
            //    link used to sit here; naming the actual model is strictly more
            //    useful and no shorter. Naming BOTH was the overcorrection: see
            //    `recommendedDownload`.
            if let model = policy.recommendedDownload {
                downloadRow(model)
            }

            // 2. A MODEL FOR A MACHINE YOU ALREADY HAVE — the same row the
            //    `home` filter offers, which `all` was missing entirely, so the
            //    filter most people leave selected could not reach the feature.
            //
            //    ABOVE "connect a computer", because it is the more specific
            //    offer: it names a machine that already exists and answers, and
            //    the row below it is the generic invitation to go find one. This
            //    section reads by what an option costs, and both are free — so
            //    within that tier the concrete row goes first, the same way
            //    "browse near.ai" precedes the generic "add a cloud key" at the
            //    bottom.
            pullRows

            // 3. A computer you don't have set up yet.
            addProviderRow(label: "connect a computer",
                           glyph: WhereLocality.home.systemImage,
                           caption: "ollama, lm studio, or any openai-compatible server",
                           selfHosted: true)

            // 4. The catalogs, one row per known provider, in `Provider.presets`
            //    order. Unkeyed ones are listed too — the point of this list is
            //    what's POSSIBLE, and "add key" is a smaller ask than hiding the
            //    provider until the user discovers it elsewhere.
            ForEach(Provider.presets) { preset in
                presetRow(preset)
            }

            // 5. The generic key, LAST — per the design. It is the fallback for
            //    a provider the four rows above don't cover, so putting it before
            //    them offered a blank form ahead of the four named answers.
            addProviderRow(label: "add a cloud key",
                           glyph: "key",
                           caption: "configures an api key for any provider")
        } header: {
            sectionHeader("get")
        }
        // The same row box as `ready now`. Nothing in `get` was setting insets,
        // so these rows inherited List's defaults while the sections above them
        // used the design's — two row metrics inside one list, which is why the
        // glyph column stepped sideways and the rows got taller halfway down the
        // sheet. Applied to the Section so it can't be forgotten on a new row.
        .listRowInsets(WhereSheetView.rowInsets)
    }

    /// Per-tier `get`. Three separate bodies rather than one with three sets of
    /// conditionals: the old form had `filter == .phone` and `filter != .phone`
    /// and `filter == nil` interleaved down a single Section, which is how the
    /// cloud tier ended up with no provider rows and the `all` tier with a
    /// signpost instead of models.
    @ViewBuilder
    private var getSectionBody: some View {
        Section {
            switch policy.filter {
            case .phone:
                // Name the models you could actually have, with sizes. Each row
                // downloads in place, and owns progress, the
                // memory gate and delete, and none of that gets a second copy.
                ForEach(policy.downloadableModels) { model in
                    downloadRow(model)
                }

            case .home:
                // The only thing missing from `ready now` is a model the server
                // doesn't have, so the row says ADD, not browse.
                pullRows
                addProviderRow(label: policy.addProviderLabel,
                               glyph: policy.addProviderGlyph,
                               caption: policy.addProviderCaption,
                               selfHosted: true)

            case .cloud:
                // Custom endpoints the user typed themselves — not presets, so
                // they need their own browse row.
                ForEach(policy.browseableProviders.filter(policy.isCustom)) { provider in
                    Button {
                        openBrowse(provider)
                    } label: {
                        WhereRow(
                            glyph: "magnifyingglass",
                            glyphTint: Color.accentColor,
                            title: "browse \(policy.browseName(for: provider))",
                            trailingGlyph: "chevron.right",
                            caption: policy.browseCaption(for: provider)
                        )
                    }
                    .buttonStyle(.plain)
                }
                // Every known provider, keyed or not — the same rows `all` shows,
                // because "which clouds could I use" has one answer regardless of
                // which segment asked it.
                ForEach(Provider.presets) { preset in
                    presetRow(preset)
                }
                addProviderRow(label: policy.addProviderLabel,
                               glyph: policy.addProviderGlyph,
                               caption: policy.addProviderCaption)

            case .none:
                EmptyView()   // `all` has its own body
            }
        } header: {
            sectionHeader("get")
        } footer: {
            Text(getFooter)
                .textCase(.lowercase)
        }
        .listRowInsets(WhereSheetView.rowInsets)
    }

    /// Ollama-only — `pullableProviders` already excludes LM Studio / llama.cpp.
    @ViewBuilder
    private var pullRows: some View {
        ForEach(policy.pullableProviders) { provider in
            Button {
                pullingOnProvider = provider
            } label: {
                WhereRow(
                    glyph: "arrow.down.circle",
                    glyphTint: Color.accentColor,
                    title: "add a model to \(policy.browseName(for: provider))",
                    trailingGlyph: "chevron.right",
                    caption: "pulls it onto the machine — it appears above when it lands"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func addProviderRow(
        label: String,
        glyph: String,
        caption: String?,
        selfHosted: Bool = false
    ) -> some View {
        Button {
            idsBeforeAdd = Set(providerStore.providers.map(\.id))
            addTarget = selfHosted ? .selfHosted : .cloudKey
        } label: {
            WhereRow(
                glyph: glyph,
                glyphTint: Color.accentColor,
                title: label,
                caption: caption
            )
        }
        .buttonStyle(.plain)
    }

    /// A known cloud provider, keyed or not.
    ///
    /// Keyed: its model count, sized down and sitting left of the chevron, then
    /// browse. Unkeyed: "add key" in the same slot, opening the add sheet already
    /// on this provider — a row that names brave answers has to land on brave
    /// answers, or it asks the user to choose the thing they just tapped.
    ///
    /// The count comes from the curated offline catalog, so the list costs
    /// nothing to draw: probing four providers to populate a `get` list would
    /// spend four round trips on a number.
    @ViewBuilder
    private func presetRow(_ preset: Provider) -> some View {
        // The user's own provider for this endpoint, if they have one — that is
        // where the key lives, and its equipped models are what browse edits.
        // `sameEndpoint(as:)`, not `==`. A raw comparison called a keyed grok
        // setup unkeyed — the row rendered "add key" while the key and its
        // equipped models were right there — because the record spelled the
        // endpoint differently from the preset. See `Provider.endpointKey`.
        let configured = providerStore.providers.first { $0.sameEndpoint(as: preset) }
        let provider = configured ?? preset
        // A KEY IS THE CONFIGURATION. The record is teemoon's bookkeeping.
        //
        // This required `configured != nil`, so a preset whose key was written
        // by onboarding — under the endpoint account, with no `servers` row —
        // rendered "add key" while the sheet one tap away prefilled that very
        // key. Pulled from the device: `servers` held near.ai, fireworks and the
        // on-device model, no grok, and grok's row was the only one asking for a
        // key the user already had.
        //
        // `hasKey` looks the key up by provider AND by endpoint, so it answers
        // for a preset with no record — which is exactly the state this missed.
        let keyed = hasKey(provider)

        if preset.isFixedAnswerService {
            // Not a catalog, so not a browse row. One fixed id that will never
            // grow: once it is SET UP, its single model is already up in `ready
            // now` and there is nothing left to get — so the row disappears
            // rather than offering a tap that leads to a list of one.
            //
            // GATED ON THE RECORD, not the key. A record is what puts the model
            // in `ready now`, so hiding on `keyed` alone made the row vanish for
            // a key with no record — and the service then appeared NOWHERE:
            // not in `ready now`, because nothing is equipped, and not in `get`,
            // because the key made it look done. The same key-without-record
            // state grok was in, with the opposite symptom.
            if configured == nil {
                Button {
                    idsBeforeAdd = Set(providerStore.providers.map(\.id))
                    addingPreset = preset
                } label: {
                    WhereRow(
                        glyph: "sparkle.magnifyingglass",
                        glyphTint: Color.accentColor,
                        title: preset.name.lowercased(),
                        // "add key" is wrong when there IS one — the tap
                        // opens a sheet that prefills it, and asking for
                        // something the user already gave is how grok's row
                        // read before this was fixed.
                        trailingText: keyed ? "set up" : "add key",
                        // Its own preset description says it needs "a different
                        // key than brave llm grounding api", and using the wrong
                        // one fails with OPTION_NOT_IN_PLAN — a message that
                        // sends you hunting for a plan problem you don't have.
                        // The add row is the last cheap moment to say so.
                        caption: "live web search · needs its own key, not the grounding one",
                        // Two lines. At one it truncated to "…not the groundin…",
                        // cutting the clause the sentence exists for.
                        captionLineLimit: 2
                    )
                }
                .buttonStyle(.plain)
                // A row in `get` names a service you might pay for — its page is
                // where "what am I buying" gets answered, before the key.
                .contextMenu {
                    if let known = KnownModel.models(for: preset.id).first {
                        Button {
                            detailTarget = ModelDetailTarget(provider: preset, model: known)
                        } label: {
                            Label("model info", systemImage: "info.circle")
                        }
                    }
                }
            }
        } else {
            let count = WhereProviderPresentation.browseModels(for: provider).count
            Button {
                if keyed {
                    openBrowse(provider)
                } else {
                    idsBeforeAdd = Set(providerStore.providers.map(\.id))
                    addingPreset = preset
                }
            } label: {
                WhereRow(
                    glyph: "magnifyingglass",
                    glyphTint: Color.accentColor,
                    title: "browse \(preset.name.lowercased())",
                    showsE2EETag: preset.capabilities.contains(.endToEndEncryption),
                    trailingText: keyed ? (count > 0 ? "\(count)" : nil) : "add key",
                    trailingGlyph: "chevron.right"
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// A catalog model you don't have yet. Tapping downloads it HERE — no
    /// chevron, because nothing is being navigated to: the row turns into its
    /// own progress bar and a cancel, and when the bytes land the model appears
    /// under `ready now` (`LocalModelDownloader.onInstalled` registers it).
    ///
    /// Sending the user to a separate catalogue to press a second "download" was a
    /// signpost pointing at the thing they had already asked for.
    @ViewBuilder
    private func downloadRow(_ model: LocalModel) -> some View {
        let fraction = downloader.progress(model.id)
        let failure = downloader.failure(model.id)
        // A model you have not downloaded yet is exactly when its details matter
        // MOST — size, what it is for, whether it calls tools — because the tap
        // costs gigabytes. `.onDevice` builds the entry from the catalogue
        // teemoon ships, so nothing needs fetching to answer.
        let known = KnownModel.onDevice(model)

        // Icon vertically centred against the whole text block, not pinned to
        // the first baseline: the rows are two lines, so a baseline-aligned
        // glyph sat high and disagreed with the ready-now rows above it.
        WhereRow(
            // The locality glyph, the same one the downloaded rows above use —
            // this row is a model that runs on the phone, it just isn't here
            // yet. Varying the leading glyph by state is what made the column
            // look ragged; the download affordance moves to the trailing side.
            glyph: WhereLocality.phone.systemImage,
            title: model.displayName,
            // PRIMARY, like every other row. The accent tint here was meant to read
            // as "tappable", but every row in this sheet is tappable and none of the
            // others is tinted — so this was the only shouting title in the list,
            // and it was on the model the catalog deliberately doesn't lead with.
            // The trailing `arrow.down.circle` already carries the affordance, in
            // the accent, where one glyph per action is the sheet's own convention.
            titleWeight: .medium,
            // Size only matters before you commit to it; after that the only
            // number worth the space is how much is left.
            trailingText: fraction == nil
                ? model.sizeLabel.lowercased()
                : "downloading \(Int(fraction! * 100))%",
            trailingMonospaced: fraction != nil,
            trailingGlyph: fraction == nil ? "arrow.down.circle" : nil,
            caption: model.blurb,
            progress: fraction,
            onCancel: { downloader.cancel(model.id) },
            // Worth saying BEFORE a multi-gigabyte download, not after it fails
            // to load. Same warning as the download screen.
            note: failure ?? (fraction == nil && tooLargeForMemory(model)
                              ? "may not fit in memory on this device" : nil)
        )
        .onTapGesture {
            guard downloader.progress(model.id) == nil else { return }
            startAndSelect(model)
        }
        .accessibilityLabel(
            fraction == nil
            ? "download \(model.displayName), \(model.sizeLabel)"
            : "\(model.displayName), downloading \(Int((fraction ?? 0) * 100)) percent"
        )
        .contextMenu {
            Button {
                detailTarget = ModelDetailTarget(provider: Provider.local(model), model: known)
            } label: {
                Label("model info", systemImage: "info.circle")
            }
        }
    }

    private func tooLargeForMemory(_ model: LocalModel) -> Bool {
        LocalMemory.exceedsAvailable(sizeMB: model.sizeMB)
    }

    private var getFooter: String {
        policy.getFooter(
            openToGet: openToGet,
            memoryFigure: LocalMemory.weightsHeadroomFigure()
        )
    }
}
