//
//  WhereFilterPolicy.swift
//  teemoon
//
//  The where sheet's "show only" row: what a filter hides and what the row says (docs/IMAGES.md §4e,
//  conformance/wherefilter.json, which Android runs too). The sheet draws what this returns.
//

import Foundation

struct WhereFilterPolicy: Equatable {
    typealias Filter = ModelBrowserQuery.Filter

    var filters: Filter = []
    var imagesOnDevice = LocalModelCatalog.imagesOnDevice

    /// The menu, in this order. No "uses tools": nearly every model takes them.
    static let offered: [Filter] = [.vision, .encrypted]
    static let heading = "show only"
    static let phoneCantYet = "no model on this phone reads images yet."
    static let nothingMatches = "nothing here matches."

    var isFiltering: Bool { !filters.isEmpty }

    /// Unknown image ability fails, as `modelSeesImages` does; end-to-end is the row's own caption claim.
    func passes(readsImages: Bool, endToEnd: Bool) -> Bool {
        (!filters.contains(.vision) || readsImages) && (!filters.contains(.encrypted) || endToEnd)
    }

    /// A phone model whose image turn can never fit this phone: listed under "reads images" alone, with the permanent
    /// caption, not counted (§4b). It still fails passes(), so it is never a model images go to.
    func listsRefused(imagesRefused: Bool) -> Bool { imagesRefused && filters == .vision }

    /// The model browser's words, for the tab's ready-now rows.
    func countLabel(shown: Int, total: Int) -> String {
        if total == 0 { return "" }
        if shown == total { return total == 1 ? "1 model" : "\(total) models" }
        return "\(shown) of \(total)"
    }

    /// "show only", one filter's full label, or the browser's short names joined.
    var controlLabel: String {
        let on = Self.offered.filter { filters.contains($0) }
        switch on.count {
        case 0: return Self.heading
        case 1: return on[0].label
        default: return on.map(\.summary).joined(separator: " · ")
        }
    }

    /// The one line under the row when a filter leaves nothing to show and nothing to get.
    func emptyLine(tab: WhereLocality?, nothingShown: Bool, getOffers: Bool) -> String? {
        guard isFiltering, nothingShown, !getOffers else { return nil }
        return tab == .phone && filters == .vision && !imagesOnDevice ? Self.phoneCantYet : Self.nothingMatches
    }

    /// "connect a computer" and "add a model to …": no home model is end-to-end encrypted.
    var showsHomeGetRows: Bool { !filters.contains(.encrypted) }

    /// A phone download: never end-to-end encrypted, reads images only when images work on the phone.
    var showsDownload: Bool { showsDownload(readsImages: imagesOnDevice) }

    /// Per model: image ability is the model's on this phone (E2B only in 1.1.0).
    func showsDownload(readsImages: Bool) -> Bool { passes(readsImages: readsImages, endToEnd: false) }

    enum ServerRow: Equatable {
        case hidden
        /// The trailing text: a count, "k of n", "add key", or none.
        case shown(String?)
    }

    /// A preset or browse row. `matching` counts the saved list under these filters; nil with no saved list.
    func serverRow(keyed: Bool, claimsEndToEnd: Bool, total: Int?, matching: Int?) -> ServerRow {
        guard isFiltering else { return .shown(keyed ? total.map(String.init) : "add key") }
        if keyed, let total, let matching {
            return matching == 0 ? .hidden : .shown("\(matching) of \(total)")
        }
        // No key or no saved list: the count is unknown, so only a claim the preset makes can hide it.
        if filters.contains(.encrypted), !claimsEndToEnd { return .hidden }
        return .shown(keyed ? nil : "add key")
    }

    /// The browser's own predicate, so the row's number is the number the browser shows with these filters.
    static func matching(_ models: [KnownModel], filters: Filter, tiered: Bool) -> Int {
        models.filter {
            ModelBrowserListing.satisfies($0, filters: filters,
                                          tier: { tiered ? NearAIModelCatalog.confidentiality(forID: $0.id) : nil })
        }.count
    }
}
