//
//  WhereSheetView+Ready.swift
//  teemoon
//

import SwiftUI

extension WhereSheetView {
    // MARK: - Ready

    /// One equipped model, on one provider. The unit `ready now` lists.
    ///
    /// The sheet used to list PROVIDERS, which made an Ollama host with three
    /// models pulled render as a single row — a place, not a thing you can run.
    /// The prototype listed eight rows for the same fixtures for this reason.
    struct Equipped: Identifiable {
        let provider: Provider
        let modelID: String
        /// Composite: the same provider appears once per equipped model.
        var id: String { "\(provider.id.uuidString)#\(modelID)" }

        /// The provider as it would be with this model active — what the row
        /// must render, since `provider.model` still points at whichever one is
        /// current and every label helper reads that.
        var asActive: Provider {
            var p = provider
            p.model = modelID
            return p
        }
    }

    /// Phone, then home, then cloud — the picker's own order, read downward.
    ///
    /// This was briefly sorted by recency instead, which was a regression for a
    /// reason worth writing down: the list is grouped by WHERE, and recency
    /// interleaves the groups. A cloud model you used an hour ago jumped above
    /// the model on your phone, so the sheet whose entire job is to show you the
    /// three places you can run stopped showing them as three places. The order
    /// also changed between openings, which costs you the muscle memory a picker
    /// lives on.
    ///
    /// Recency didn't need a home in this list — it has its own section.
    var equippedRows: [Equipped] {
        let rows = filteredProviders.flatMap { provider in
            provider.equipped.map { Equipped(provider: provider, modelID: $0) }
        }
        return Self.ordered(rows, isWarm: isWarm)
    }

    /// Tier, then place, then warm before cold.
    ///
    /// Warmth breaks the tie only between rows in the SAME PLACE. Sorted across
    /// the whole home tier it would interleave two servers — second mac's warm
    /// model, the linux box's warm model, then second mac's cold ones — and the
    /// list stops reading as a set of places, which is the same failure
    /// recency-sorting caused above.
    static func ordered(_ rows: [Equipped], isWarm: (Equipped) -> Bool?) -> [Equipped] {
        rows.enumerated().sorted { a, b in
            let lhs = WhereLocality.of(a.element.provider).rank
            let rhs = WhereLocality.of(b.element.provider).rank
            if lhs != rhs { return lhs < rhs }
            if placeKey(a.element) == placeKey(b.element) {
                // The recommendation outranks warmth.
                let lhsRec = recommendationRank(a.element)
                let rhsRec = recommendationRank(b.element)
                if lhsRec != rhsRec { return lhsRec < rhsRec }

                if let lhsWarm = isWarm(a.element),
                   let rhsWarm = isWarm(b.element),
                   lhsWarm != rhsWarm {
                    return lhsWarm
                }
            }
            // Configured order within a tier, and STABLE: `sorted` isn't, and
            // rows reshuffling on every redraw for no reason is its own bug.
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The unit warmth is comparable within: one machine for home, the DEVICE
    /// for phone.
    ///
    /// Not the provider id, which is the bug this replaced. A machine is one
    /// `Provider` holding several equipped models, but `Provider.local` makes one
    /// provider PER downloaded model — so keying on the provider put every phone
    /// row in a group of one and warmth could never break a tie there. Two local
    /// models installed with one resident is exactly the case that matters, since
    /// only one CAN be resident.
    static func placeKey(_ row: Equipped) -> String {
        WhereLocality.of(row.provider) == .phone
            ? "phone"
            : row.provider.id.uuidString
    }

    /// 0 for the on-device model teemoon recommends, 1 for everything else.
    ///
    /// Phone only — nothing recommends one of a server's models over another, so
    /// home rows all rank the same and warmth decides.
    ///
    /// `LocalModelCatalog.all` is ordered on purpose and says so: E2B leads
    /// because it is the better model on the axis that was actually measured, and
    /// E4B's own catalog note says it "does NOT lead the catalog … not better,
    /// only bigger". Warmth is worth 2.3–4.0 s once; a recommendation is a
    /// standing judgement about which model to use, and the transient saving must
    /// not push the recommended row below the one we advise against. Warmth still
    /// orders everything BELOW it.
    static func recommendationRank(_ row: Equipped) -> Int {
        guard WhereLocality.of(row.provider) == .phone,
              let recommended = LocalModelCatalog.all.first?.id else { return 1 }
        return row.provider.localModelID == recommended ? 0 : 1
    }

    var filteredProviders: [Provider] { getPolicy.filteredProviders }


}
