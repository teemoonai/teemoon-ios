//
//  ModelBrowserQuery.swift
//  teemoon
//
//  What the model browser shows: search, sort, filters, sections. The view
//  renders the answer; it does not compute it.
//
//  The question a person opens this screen with is "what is the cheapest model
//  that can do the job", and the answer spans vendors — so any sort but the
//  recommended one DISSOLVES the sections. Cheapest-within-one-vendor is the
//  same screen with that vendor typed into the search field.
//

import Foundation

struct ModelBrowserQuery: Equatable {

    enum Sort: String, CaseIterable, Equatable {
        case recommended, priceLowToHigh, priceHighToLow, newest, largestContext

        var label: String {
            switch self {
            case .recommended:     return "recommended"
            case .priceLowToHigh:  return "price · low to high"
            case .priceHighToLow:  return "price · high to low"
            case .newest:          return "newest"
            case .largestContext:  return "largest context"
            }
        }

        /// Short form for the header, where the width is a row, not a menu.
        var summary: String {
            switch self {
            case .recommended:    return "recommended"
            case .priceLowToHigh: return "price ↑"
            case .priceHighToLow: return "price ↓"
            case .newest:         return "newest"
            case .largestContext: return "context"
            }
        }
    }

    struct Filter: OptionSet, Hashable {
        let rawValue: Int
        static let tools      = Filter(rawValue: 1 << 0)
        static let vision     = Filter(rawValue: 1 << 1)
        static let free       = Filter(rawValue: 1 << 2)
        static let openWeights = Filter(rawValue: 1 << 3)
        static let encrypted  = Filter(rawValue: 1 << 4)

        static let all: [Filter] = [.tools, .vision, .free, .openWeights, .encrypted]

        var label: String {
            switch self {
            case .tools:       return "uses tools"
            case .vision:      return "reads images"
            case .free:        return "free"
            case .openWeights: return "open weights"
            case .encrypted:   return "end-to-end encrypted"
            default:           return ""
            }
        }

        /// The one-line "what is on" caption.
        var summary: String {
            switch self {
            case .tools:       return "tools"
            case .vision:      return "images"
            case .free:        return "free"
            case .openWeights: return "open weights"
            case .encrypted:   return "e2ee"
            default:           return ""
            }
        }
    }

    var text = ""
    var sort: Sort = .recommended
    var filters: Filter = []
}

/// The rendered answer: sections, what each row should say about itself, and
/// which controls are worth offering for this catalogue.
struct ModelBrowserListing: Equatable {

    struct Row: Identifiable, Equatable {
        let model: KnownModel
        let tier: NearAIModelCatalog.Confidentiality?
        /// Set when the list is flat: without a section header, the row has to
        /// name its own vendor.
        let showsVendor: Bool
        let showsTier: Bool
        let isSelected: Bool
        var id: String { model.id }
    }

    struct Section: Identifiable, Equatable {
        let id: String
        let header: String?
        let rows: [Row]
    }

    let sections: [Section]
    let shown: Int
    let total: Int
    /// Sorts and filters worth showing for THIS list: a price sort with no
    /// prices, or a filter every row satisfies, is a control that does nothing.
    let sorts: [ModelBrowserQuery.Sort]
    let filters: [ModelBrowserQuery.Filter]
    let effectiveSort: ModelBrowserQuery.Sort
    let activeSummary: String?
    /// The typed text, when it matches nothing and the caller allows an id to
    /// be used as-is.
    let customID: String?

    var isEmpty: Bool { sections.allSatisfy { $0.rows.isEmpty } }

    var countLabel: String {
        if total == 0 { return "" }
        if shown == total { return total == 1 ? "1 model" : "\(total) models" }
        return "\(shown) of \(total)"
    }
}

extension ModelBrowserListing {

    /// `tiered` marks a catalogue whose models carry a trust tier (near.ai).
    /// `allowsCustomID` offers the typed text as a model id when nothing
    /// matches — never for near.ai, where an unknown id is treated as own-fleet
    /// and would claim an encryption teemoon cannot check.
    init(models: [KnownModel],
         query: ModelBrowserQuery,
         tiered: Bool,
         selectedID: String = "",
         allowsCustomID: Bool = false,
         tier: @escaping (String) -> NearAIModelCatalog.Confidentiality? = {
             NearAIModelCatalog.confidentiality(forID: $0)
         }) {
        let tierOf: (KnownModel) -> NearAIModelCatalog.Confidentiality? = { tiered ? tier($0.id) : nil }

        let offeredSorts = Self.sorts(for: models)
        let offeredFilters = Self.filters(for: models, tiered: tiered, tier: tierOf)
        let sort = offeredSorts.contains(query.sort) ? query.sort : .recommended
        let filters = query.filters.intersection(offeredFilters.reduce(into: ModelBrowserQuery.Filter()) {
            $0.insert($1)
        })

        let matching = models.filter {
            Self.matches($0, text: query.text) && Self.satisfies($0, filters: filters, tier: tierOf)
        }
        let ordered = Self.ordered(matching, by: sort)
        let flat = sort != .recommended

        func row(_ model: KnownModel, showsTier: Bool) -> Row {
            Row(model: model, tier: tierOf(model), showsVendor: flat, showsTier: showsTier,
                isSelected: !selectedID.isEmpty && model.id == selectedID)
        }

        if flat {
            sections = [Section(id: "all", header: nil, rows: ordered.map { row($0, showsTier: tiered) })]
        } else if tiered {
            // Trust is the resting structure for near.ai: what teemoon can seal,
            // then what near.ai attests elsewhere, then plain proxies. The tag
            // is left off the rows because the header above them says it.
            sections = [NearAIModelCatalog.Confidentiality.teeOwn, .teeThirdParty, .proxied]
                .compactMap { want in
                    let rows = ordered.filter { tierOf($0) == want }
                    guard !rows.isEmpty else { return nil }
                    return Section(id: want.rawValue, header: want.label,
                                   rows: rows.map { row($0, showsTier: false) })
                }
        } else {
            var vendors: [String] = []
            for model in ordered where !vendors.contains(model.vendor) { vendors.append(model.vendor) }
            sections = vendors.map { vendor in
                Section(id: vendor, header: vendor.lowercased(),
                        rows: ordered.filter { $0.vendor == vendor }.map { row($0, showsTier: false) })
            }
        }

        shown = ordered.count
        total = models.count
        sorts = offeredSorts
        self.filters = offeredFilters
        effectiveSort = sort
        activeSummary = filters.isEmpty ? nil
            : ModelBrowserQuery.Filter.all.filter { filters.contains($0) }
                .map(\.summary).joined(separator: " · ")
        let typed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        customID = (allowsCustomID && !typed.isEmpty && ordered.isEmpty) ? typed : nil
    }

    // MARK: - Matching

    /// Every typed word must match something: "qwen 27" finds Qwen3.8-27B.
    static func matches(_ model: KnownModel, text: String) -> Bool {
        let tokens = text.lowercased().split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        let haystack = [model.displayName, model.id, model.vendor].joined(separator: " ").lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }

    static func satisfies(_ model: KnownModel,
                          filters: ModelBrowserQuery.Filter,
                          tier: (KnownModel) -> NearAIModelCatalog.Confidentiality?) -> Bool {
        // Unknown capabilities do NOT match: a filter is a promise about what
        // the row can do, and nil means the catalogue never said.
        if filters.contains(.tools), model.capabilities?.contains(.tools) != true { return false }
        if filters.contains(.vision), model.capabilities?.contains(.vision) != true { return false }
        if filters.contains(.free), !model.isFree { return false }
        if filters.contains(.openWeights), model.openWeights != true { return false }
        if filters.contains(.encrypted), tier(model) != .teeOwn { return false }
        return true
    }

    // MARK: - Ordering

    /// Price for sorting: input + output per 1M. nil when the catalogue quotes
    /// no price — which is NOT zero, and must not read as "cheapest".
    static func priceScore(_ model: KnownModel) -> Double? {
        if model.price.isEmpty { return model.isFree ? 0 : nil }
        return ModelDefaultRule.priceScore(model)
    }

    static func ordered(_ models: [KnownModel], by sort: ModelBrowserQuery.Sort) -> [KnownModel] {
        // Ties break by name then id, so the same list never shuffles between
        // two renders of the same screen.
        func byName(_ a: KnownModel, _ b: KnownModel) -> Bool {
            let compared = a.displayName.localizedStandardCompare(b.displayName)
            return compared == .orderedSame ? a.id < b.id : compared == .orderedAscending
        }
        switch sort {
        case .recommended:
            return models
        case .priceLowToHigh, .priceHighToLow:
            let ascending = sort == .priceLowToHigh
            return models.sorted { a, b in
                switch (priceScore(a), priceScore(b)) {
                case let (x?, y?):
                    return x == y ? byName(a, b) : (ascending ? x < y : x > y)
                case (_?, nil): return true          // unpriced sorts last, both ways
                case (nil, _?): return false
                default:        return byName(a, b)
                }
            }
        case .newest:
            return models.sorted { a, b in
                switch (a.created, b.created) {
                case let (x?, y?): return x == y ? byName(a, b) : x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return byName(a, b)
                }
            }
        case .largestContext:
            return models.sorted { a, b in
                let (x, y) = (ModelDefaultRule.contextValue(a.contextWindow),
                              ModelDefaultRule.contextValue(b.contextWindow))
                return x == y ? byName(a, b) : x > y
            }
        }
    }

    // MARK: - What is worth offering

    /// A sort is offered only when it would reorder the list. NVIDIA gives
    /// every model away, so "price" there is a control that does nothing.
    static func sorts(for models: [KnownModel]) -> [ModelBrowserQuery.Sort] {
        var out: [ModelBrowserQuery.Sort] = [.recommended]
        if Set(models.compactMap { priceScore($0) }).count > 1 {
            out += [.priceLowToHigh, .priceHighToLow]
        }
        if Set(models.compactMap(\.created)).count > 1 { out.append(.newest) }
        if Set(models.map { ModelDefaultRule.contextValue($0.contextWindow) }.filter { $0 > 0 }).count > 1 {
            out.append(.largestContext)
        }
        return out
    }

    /// A filter earns its place only when it divides the list: on NVIDIA every
    /// model is free, so "free" would be a switch that does nothing.
    static func filters(for models: [KnownModel],
                        tiered: Bool,
                        tier: (KnownModel) -> NearAIModelCatalog.Confidentiality?) -> [ModelBrowserQuery.Filter] {
        ModelBrowserQuery.Filter.all.filter { filter in
            if filter == .encrypted && !tiered { return false }
            let matching = models.filter { satisfies($0, filters: filter, tier: tier) }.count
            return matching > 0 && matching < models.count
        }
    }
}
