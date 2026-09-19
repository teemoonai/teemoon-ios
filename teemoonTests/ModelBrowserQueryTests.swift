//
//  ModelBrowserQueryTests.swift
//  teemoonTests
//
//  What the browser shows. The load-bearing rule is that "cheapest" is a
//  question about the whole catalogue, not about one vendor's section — so a
//  price sort dissolves the sections rather than ordering inside them.
//

import Foundation
import Testing
@testable import teemoon

@Suite("ModelBrowserQuery")
struct ModelBrowserQueryTests {

    private func model(_ id: String, vendor: String, price: String = "",
                       context: String = "", free: Bool = false,
                       caps: ModelCapabilities? = nil, open: Bool? = nil,
                       created: TimeInterval? = nil, new: Bool = false) -> KnownModel {
        var m = KnownModel(id: id, displayName: id, vendor: vendor, price: price,
                           contextWindow: context, capabilities: caps)
        m.isFree = free
        m.openWeights = open
        m.created = created.map { Date(timeIntervalSince1970: $0) }
        m.isNew = new
        return m
    }

    /// Two vendors, interleaved prices. Grouped they never meet; ranked they do.
    private var mixed: [KnownModel] {
        [
            model("alpha/dear", vendor: "Alpha", price: "$10.00/$30.00", context: "200k"),
            model("beta/cheap", vendor: "Beta", price: "$0.10/$0.20", context: "1M"),
            model("alpha/mid", vendor: "Alpha", price: "$1.00/$2.00", context: "128k"),
            model("beta/free", vendor: "Beta", price: "", context: "32k", free: true),
            model("beta/unpriced", vendor: "Beta", price: "", context: "8k"),
        ]
    }

    private func listing(_ models: [KnownModel], _ query: ModelBrowserQuery,
                         tiered: Bool = false, selected: String = "",
                         customID: Bool = false) -> ModelBrowserListing {
        ModelBrowserListing(models: models, query: query, tiered: tiered,
                            selectedID: selected, allowsCustomID: customID,
                            tier: { id in
                                if id.hasPrefix("own/") { return .teeOwn }
                                if id.hasPrefix("third/") { return .teeThirdParty }
                                return .proxied
                            })
    }

    // MARK: sorting

    /// THE point of the screen: the cheapest model in the catalogue is the
    /// first row, whoever makes it. Free counts as nothing; a model with no
    /// published price is not "cheapest", so it sorts last in both directions.
    @Test func priceSortRanksAcrossVendors() {
        let low = listing(mixed, ModelBrowserQuery(sort: .priceLowToHigh))
        let lowSection = low.sections.first
        #expect(low.sections.count == 1, "a ranked list has no vendor sections")
        #expect(lowSection?.header == nil)
        #expect(lowSection?.rows.map(\.id)
                == ["beta/free", "beta/cheap", "alpha/mid", "alpha/dear", "beta/unpriced"])

        let high = listing(mixed, ModelBrowserQuery(sort: .priceHighToLow))
        #expect(high.sections.first?.rows.map(\.id)
                == ["alpha/dear", "alpha/mid", "beta/cheap", "beta/free", "beta/unpriced"])
    }

    /// A flat row has no header above it, so it names its own vendor.
    @Test func aRankedRowNamesItsVendor() {
        let low = listing(mixed, ModelBrowserQuery(sort: .priceLowToHigh))
        #expect(low.sections.first?.rows.allSatisfy(\.showsVendor) == true)
        let grouped = listing(mixed, ModelBrowserQuery())
        #expect(grouped.sections.allSatisfy { $0.rows.allSatisfy { !$0.showsVendor } })
    }

    /// The default keeps the server's own order, in vendor sections.
    @Test func recommendedGroupsByVendorInTheServersOrder() {
        let grouped = listing(mixed, ModelBrowserQuery())
        #expect(grouped.sections.map(\.header) == ["alpha", "beta"])
        #expect(grouped.sections.first?.rows.map(\.id) == ["alpha/dear", "alpha/mid"])
    }

    /// near.ai's resting structure is trust, strongest first.
    @Test func aTieredCatalogueGroupsByTrust() {
        let models = [model("proxy/one", vendor: "V", price: "$3.00/$9.00"),
                      model("own/one", vendor: "V", price: "$1.00/$2.00"),
                      model("third/one", vendor: "V", price: "$2.00/$4.00")]
        let grouped = listing(models, ModelBrowserQuery(), tiered: true)
        #expect(grouped.sections.map(\.id) == ["teeOwn", "teeThirdParty", "proxied"])
        // The header says the tier, so the rows do not repeat it.
        #expect(grouped.sections.allSatisfy { $0.rows.allSatisfy { !$0.showsTier } })
        // Ranked, the headers are gone and each row carries its own tag.
        let ranked = listing(models, ModelBrowserQuery(sort: .priceLowToHigh), tiered: true)
        #expect(ranked.sections.first?.rows.allSatisfy(\.showsTier) == true)
    }

    @Test func newestAndContextSortsPutTheUnknownLast() {
        let models = [
            model("a/old", vendor: "A", context: "8k", created: 1_700_000_000),
            model("a/new", vendor: "A", context: "1M", created: 1_800_000_000),
            model("a/undated", vendor: "A"),
        ]
        #expect(listing(models, ModelBrowserQuery(sort: .newest)).sections.first?.rows.map(\.id)
                == ["a/new", "a/old", "a/undated"])
        #expect(listing(models, ModelBrowserQuery(sort: .largestContext)).sections.first?.rows.map(\.id)
                == ["a/new", "a/old", "a/undated"])
    }

    /// Equal prices must not shuffle between renders.
    @Test func tiesBreakByName() {
        let models = [model("z/one", vendor: "Z", price: "$1.00/$1.00"),
                      model("a/two", vendor: "A", price: "$1.00/$1.00"),
                      model("a/dear", vendor: "A", price: "$9.00/$9.00")]
        let rows = listing(models, ModelBrowserQuery(sort: .priceLowToHigh)).sections.first?.rows
        #expect(rows?.map(\.id) == ["a/two", "z/one", "a/dear"])
    }

    // MARK: search

    @Test func everyTypedWordMustMatch() {
        let models = [model("qwen/qwen3.8-27b", vendor: "Qwen"),
                      model("qwen/qwen3.6-35b", vendor: "Qwen"),
                      model("openai/gpt-5.4", vendor: "OpenAI")]
        let hit = listing(models, ModelBrowserQuery(text: "qwen 27"))
        #expect(hit.sections.flatMap(\.rows).map(\.id) == ["qwen/qwen3.8-27b"])
        // Vendor is searchable too, and the count says what is hidden.
        let byVendor = listing(models, ModelBrowserQuery(text: "openai"))
        #expect(byVendor.shown == 1)
        #expect(byVendor.total == 3)
        #expect(byVendor.countLabel == "1 of 3")
    }

    /// Searching a vendor's name is how "cheapest from this vendor" is asked.
    @Test func searchNarrowsAndTheSortStillApplies() {
        let rows = listing(mixed, ModelBrowserQuery(text: "beta", sort: .priceLowToHigh))
            .sections.first?.rows
        #expect(rows?.map(\.id) == ["beta/free", "beta/cheap", "beta/unpriced"])
    }

    @Test func aTypedIdIsOfferedOnlyWhenNothingMatchesAndItIsAllowed() {
        let models = [model("a/one", vendor: "A")]
        #expect(listing(models, ModelBrowserQuery(text: "zzz"), customID: true).customID == "zzz")
        #expect(listing(models, ModelBrowserQuery(text: "zzz"), customID: false).customID == nil)
        #expect(listing(models, ModelBrowserQuery(text: "a/one"), customID: true).customID == nil)
    }

    // MARK: filters and what is offered

    @Test func filtersHideRowsThatDoNotPromiseTheCapability() {
        let models = [
            model("a/tools", vendor: "A", caps: [.tools]),
            model("a/vision", vendor: "A", caps: [.vision]),
            model("a/unknown", vendor: "A", caps: nil),
        ]
        let tools = listing(models, ModelBrowserQuery(filters: .tools))
        // Unknown capabilities do not match: a filter is a promise.
        #expect(tools.sections.flatMap(\.rows).map(\.id) == ["a/tools"])
        #expect(tools.activeSummary == "tools")
    }

    /// A control that changes nothing is not shown: NVIDIA prices nothing and
    /// gives everything away, so it offers no price sort and no "free" switch.
    @Test func onlyControlsThatDivideTheListAreOffered() {
        let nvidia = (1...3).map { model("nv/\($0)", vendor: "NVIDIA", free: true, open: true) }
        let listed = listing(nvidia, ModelBrowserQuery())
        #expect(listed.sorts == [.recommended])
        #expect(listed.filters.isEmpty)

        let mixedRows = mixed + [model("a/tooled", vendor: "Alpha", caps: [.tools])]
        let offered = listing(mixedRows, ModelBrowserQuery())
        #expect(offered.sorts.contains(.priceLowToHigh))
        #expect(offered.filters.contains(.tools))
        // "end-to-end encrypted" only where models carry a tier at all.
        #expect(!offered.filters.contains(.encrypted))
    }

    @Test func anUnavailableSortFallsBackToRecommended() {
        let nvidia = (1...3).map { model("nv/\($0)", vendor: "NVIDIA", free: true) }
        let listed = listing(nvidia, ModelBrowserQuery(sort: .priceLowToHigh))
        #expect(listed.effectiveSort == .recommended)
        #expect(listed.sections.count > 0)
    }

    @Test func theSelectedModelIsMarkedOnce() {
        let listed = listing(mixed, ModelBrowserQuery(), selected: "alpha/mid")
        let selected = listed.sections.flatMap(\.rows).filter(\.isSelected)
        #expect(selected.map(\.id) == ["alpha/mid"])
        // Nothing selected is nothing marked: the trust ladder's picker opens
        // with no pick.
        #expect(listing(mixed, ModelBrowserQuery()).sections.flatMap(\.rows).allSatisfy { !$0.isSelected })
    }

    @Test func theCountLabelReadsAsAWholeOrAPart() {
        #expect(listing(mixed, ModelBrowserQuery()).countLabel == "5 models")
        #expect(listing([mixed[0]], ModelBrowserQuery()).countLabel == "1 model")
        #expect(listing(mixed, ModelBrowserQuery(text: "beta")).countLabel == "3 of 5")
    }
}
