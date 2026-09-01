//
//  WhereSheetView+Recents.swift
//  teemoon
//

import SwiftUI

extension WhereSheetView {
    // MARK: - Recents

    /// From the config file's own `lastUsedAt` now, not a second UserDefaults blob
    /// (§2.6). `ProviderStore.recentlyUsed` keeps the store's rules — used not
    /// picked, newest first, live servers only — and drops the stale label copies.
    ///
    /// `all` ONLY, which was `WhereRecentsStore.visible`'s rule and is a view
    /// concern rather than a storage one, so it lives here: inside one tier this
    /// section can't beat the list above it. Phone and home are already complete —
    /// every downloaded model, every model the server has — so a recent there is a
    /// row printed twice, and cloud is longer than the history. In `all` the rows
    /// are grouped by PLACE, and the cross-tier question grouping can't answer is
    /// exactly this one: what have I been running lately, wherever it ran.
    var visibleRecents: [WhereRecentEntry] {
        guard pathObserver.isSatisfied, filter == nil else { return [] }
        return providerStore.recentlyUsed()
    }

    @ViewBuilder
    var recentsSection: some View {
        let rows = visibleRecents
        if !rows.isEmpty {
            Section {
                ForEach(rows) { entry in
                    recentRow(entry)
                        .listRowInsets(Self.rowInsets)
                }
            } header: {
                // No footer. "what you've been running lately, wherever it ran"
                // explained a header that needs no explaining — the rows carry
                // their own place captions, so "wherever it ran" is visible in
                // the list rather than something to be told.
                sectionHeader("recently used")
            }
        }
    }

    /// The place caption for a recent, from the provider as it is NOW. Falls
    /// back to the entry's own provider only if the live record is gone.
    func recentCaption(_ entry: WhereRecentEntry) -> String {
        guard var provider = providerStore.providers.first(where: { $0.id == entry.providerID })
        else { return WhereProviderPresentation.placeCaption(for: entry.provider) }
        provider.model = entry.modelID
        return WhereProviderPresentation.placeCaption(for: provider)
    }

    func recentRow(_ entry: WhereRecentEntry) -> some View {
        Button {
            selectRecent(entry)
        } label: {
            // `WhereRow`, not a hand-built copy of it.
            //
            // This row was assembled separately and drifted: a 14pt glyph in a
            // 22pt column against the shared row's 20pt in 28pt, and a `.caption`
            // second line against its 13pt. Two sections of one list, forty
            // points apart, drawing the same shape at two sizes — which is
            // exactly the failure `WhereRow` was extracted to end, reintroduced
            // by the one row that didn't adopt it.
            //
            // No "recent" tag: the section is called "recently used", so the
            // badge restated the heading on every row under it.
            WhereRow(
                glyph: entry.locality.systemImage,
                glyphTint: Color.accentColor,
                title: WhereProviderPresentation.modelLabel(for: entry.provider),
                // Recomputed from the live provider, not a string stored when
                // the entry was recorded. A cached caption is a snapshot of how
                // the app described a place at some point in the past — which is
                // why this row still read "near.ai glm 5.2" after the caption
                // logic stopped printing labels that contain model names.
                // The SAME caption the row above would carry, warmth included.
                //
                // These are two sections of one list showing the same models, and
                // they described them differently: `ready now` said "ollama · warm",
                // this said "ringzero.tailnet-name.ts.net". A machine's hostname is the
                // least useful true thing about it — the user typed it — and warmth
                // is the difference between an answer now and a model load first,
                // which doesn't stop mattering because the row moved down a section.
                caption: recentEquipped(entry).map { readyCaption(for: $0.asActive) }
                    ?? WhereProviderPresentation.placeCaption(for: entry.provider),
                warmth: recentEquipped(entry).flatMap(warmthLabel)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(WhereProviderPresentation.modelLabel(for: entry.provider)), \(recentCaption(entry)), recent")
        // EVERY ROW THAT NAMES A MODEL REACHES ITS PAGE. `ready now` had this and
        // `recently used` did not, so the same model answered a long press in one
        // section and ignored it in the other — two sections of one list behaving
        // differently, which is the failure `WhereRow` was extracted to end.
        //
        // `recentEquipped` already rebuilds the row as an `Equipped`, so this
        // shares the resolution, the live fetch and the page with `ready now`
        // rather than growing a parallel one. When the provider is gone the
        // entry is a tombstone with nothing to open, and no menu is offered.
        .contextMenu {
            if let equipped = recentEquipped(entry) {
                Button {
                    detailTarget = ModelDetailTarget(provider: equipped.provider,
                                                     model: knownModel(for: equipped))
                } label: {
                    Label("model info", systemImage: "info.circle")
                }
            }
            // THE SAME PAIR `ready now` OFFERS. A recent row is the same model
            // in a different section, and a menu that only reads rather than
            // acts made the long press worth less here than one row up — while
            // the tap on both rows does the identical thing. `activate` puts it
            // back in `ready now` and makes it answer the next message, which is
            // what "use" has meant on every other row in this sheet.
            Button {
                selectRecent(entry)
            } label: {
                Label("use for chat", systemImage: "checkmark.circle")
            }
        }
    }

    /// The recent as a `ready now` row, so the two sections can share every
    /// presentation helper instead of maintaining parallel ones.
    func recentEquipped(_ entry: WhereRecentEntry) -> Equipped? {
        providerStore.providers.first { $0.id == entry.providerID }
            .map { Equipped(provider: $0, modelID: entry.modelID) }
    }


}
