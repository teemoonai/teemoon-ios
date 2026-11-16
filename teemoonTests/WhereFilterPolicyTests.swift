//
//  WhereFilterPolicyTests.swift
//  teemoonTests
//
//  The where sheet's "show only" row (docs/IMAGES.md §4e, the maintainer 2026-11-11), run from conformance/wherefilter.json
//  so Android holds the same cells. Each cell is composed here in the sheet's own order from WhereFilterPolicy's
//  answers; the get order itself is today's, pinned by WhereGetPolicyTests.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Where — show only")
struct WhereFilterPolicyTests {

    struct Fixture: Decodable {
        let menu: Menu
        let scenarios: [Scenario]
        struct Menu: Decodable { let heading: String; let items: [String] }
    }

    struct Scenario: Decodable {
        let name: String
        var online: Bool?
        let imagesOnDevice: Bool
        let models: [Model]
        let recents: [String]
        let downloads: [Download]
        let homes: [Home]
        var customs: [Custom]?
        let presets: [String: Preset]
        let expect: Expect

        struct Model: Decodable {
            let id: String
            let tab: String
            var localModel: String?
            let readsImages: Bool?
            var imagesRefused: Bool?
            let e2ee: Bool
        }
        struct Download: Decodable { let id: String; var readsImages: Bool? }
        struct Home: Decodable { let name: String; let kind: String }
        struct Custom: Decodable { let name: String; let claimsE2ee: Bool; var counts: [String: Int]? }
        struct Preset: Decodable {
            let keyed: Bool
            let claimsE2ee: Bool
            var counts: [String: Int]?
            var fixedAnswer: Bool?
            var configured: Bool?
        }
        struct Expect: Decodable {
            let filterRow: Bool
            var cells: [String: Cell]?
        }
    }

    struct Cell: Decodable, Equatable, CustomStringConvertible {
        let count: String
        let control: String
        let ready: [String]
        let refused: [String]
        let recents: [String]
        let get: [GetRow]?
        let line: String?
        var description: String {
            "\(count) | \(control) | \(ready) | refused \(refused) | \(recents) | \(get.map { $0.map(\.description) } ?? []) | \(line ?? "-")"
        }
    }

    struct GetRow: Decodable, Equatable, CustomStringConvertible {
        let id: String
        var trailing: String?
        var description: String { trailing.map { "\(id)[\($0)]" } ?? id }
    }

    static let presetOrder = ["near.ai", "grok", "fireworks", "openrouter", "nvidia", "brave"]
    static let filterNames: [String: WhereFilterPolicy.Filter] = ["none": [], "images": [.vision], "e2ee": [.encrypted],
                                                                  "images+e2ee": [.vision, .encrypted]]

    static func fixture(file: String = #filePath) throws -> Fixture? {
        guard TestFixture.sourceTreeAvailable() else { return nil }
        let url = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conformance/wherefilter.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// The fixture's counts are keyed by the filters' short names joined, in the menu's order.
    static func countKey(_ filters: WhereFilterPolicy.Filter) -> String {
        filters.isEmpty ? "none"
            : [(WhereFilterPolicy.Filter.vision, "images"), (.encrypted, "e2ee")]
                .filter { filters.contains($0.0) }.map(\.1).joined(separator: "+")
    }

    static func serverRow(_ policy: WhereFilterPolicy, id: String, keyed: Bool, claims: Bool,
                          counts: [String: Int]?) -> GetRow? {
        let total = keyed ? counts?["none"] : nil
        let matching = keyed ? counts?[countKey(policy.filters)] : nil
        switch policy.serverRow(keyed: keyed, claimsEndToEnd: claims, total: total, matching: matching) {
        case .hidden: return nil
        case .shown(let trailing): return GetRow(id: id, trailing: trailing)
        }
    }

    static func cell(_ s: Scenario, tab: WhereLocality?, filters: WhereFilterPolicy.Filter) -> Cell {
        let policy = WhereFilterPolicy(filters: filters, imagesOnDevice: s.imagesOnDevice)
        let online = s.online ?? true
        let mine = s.models.filter { m in
            (tab == nil || m.tab == tab?.rawValue) && (online || m.tab == "phone")
        }
        let passes = { (m: Scenario.Model) in policy.passes(readsImages: m.readsImages == true, endToEnd: m.e2ee) }
        let ready = mine.filter(passes)
        let byID = Dictionary(uniqueKeysWithValues: s.models.map { ($0.id, $0) })
        let recents = tab == nil && online ? s.recents.filter { byID[$0].map(passes) ?? false } : []

        var get: [GetRow] = []
        var offers = false
        func offer(_ row: GetRow?) { if let row { get.append(row); offers = true } }
        let owned = Set(s.models.compactMap(\.localModel))
        let downloads = s.downloads.filter { !owned.contains($0.id) }
        let pulls = policy.showsHomeGetRows
            ? s.homes.filter { $0.kind == "ollama" }.map { GetRow(id: "pull:\($0.name)") } : []
        let connect = policy.showsHomeGetRows ? [GetRow(id: "connect a computer")] : []
        func presets() {
            for name in presetOrder {
                guard let p = s.presets[name] else { continue }
                if p.fixedAnswer == true {
                    if !policy.isFiltering, p.configured != true { offer(GetRow(id: "preset:\(name)", trailing: "add key")) }
                    continue
                }
                offer(serverRow(policy, id: "preset:\(name)", keyed: p.keyed, claims: p.claimsE2ee, counts: p.counts))
            }
        }
        switch tab {
        case nil:
            if let first = downloads.first, first.id == s.downloads.first?.id,
               policy.showsDownload(readsImages: first.readsImages ?? s.imagesOnDevice) {
                offer(GetRow(id: "download:\(first.id)"))
            }
            get += pulls + connect
            presets()
            get.append(GetRow(id: "add a cloud key"))
        case .phone:
            for d in downloads where policy.showsDownload(readsImages: d.readsImages ?? s.imagesOnDevice) {
                offer(GetRow(id: "download:\(d.id)"))
            }
        case .home:
            get += pulls + connect
        case .cloud:
            for c in s.customs ?? [] {
                offer(serverRow(policy, id: "browse:\(c.name)", keyed: true, claims: c.claimsE2ee, counts: c.counts))
            }
            presets()
            get.append(GetRow(id: "add a cloud key"))
        }
        if !online { offers = false }

        return Cell(count: policy.countLabel(shown: ready.count, total: mine.count),
                    control: policy.controlLabel,
                    ready: ready.map(\.id),
                    refused: mine.filter { policy.listsRefused(imagesRefused: $0.imagesRefused == true) }.map(\.id),
                    recents: recents,
                    get: online ? get : nil,
                    line: policy.emptyLine(tab: tab, nothingShown: ready.isEmpty && recents.isEmpty, getOffers: offers))
    }

    @Test func theMenuOffersReadsImagesThenEndToEnd() throws {
        guard let fixture = try Self.fixture() else { return }
        #expect(fixture.menu.heading == WhereFilterPolicy.heading)
        #expect(fixture.menu.items == WhereFilterPolicy.offered.map(\.label))
    }

    @Test func everyCellMatchesTheFixture() throws {
        guard let fixture = try Self.fixture() else { return }
        var checked = 0
        for s in fixture.scenarios {
            for (key, want) in s.expect.cells ?? [:] {
                let parts = key.split(separator: "/").map(String.init)
                let tab = parts[0] == "all" ? nil : WhereLocality(rawValue: parts[0])
                let filters = try #require(Self.filterNames[parts[1]], "\(key)")
                let got = Self.cell(s, tab: tab, filters: filters)
                #expect(got == want, "\(s.name) \(key)\n  got:  \(got)\n  want: \(want)")
                checked += 1
            }
        }
        #expect(checked == 68, "every cell in the fixture was checked")
    }

    /// The row's number is the browser's: unknown vision and a third-party near.ai model don't count.
    @Test func aServersNumberIsTheBrowsersPredicate() {
        func model(_ id: String, _ caps: ModelCapabilities?) -> KnownModel {
            KnownModel(id: id, displayName: id, vendor: "v", price: "", contextWindow: "", capabilities: caps)
        }
        let list = [model("a", [.vision]), model("b", []), model("c", nil), model("d", [.vision, .tools])]
        #expect(WhereFilterPolicy.matching(list, filters: [], tiered: false) == 4)
        #expect(WhereFilterPolicy.matching(list, filters: [.vision], tiered: false) == 2)
        // Not a near.ai list: nothing in it is end-to-end encrypted.
        #expect(WhereFilterPolicy.matching(list, filters: [.encrypted], tiered: false) == 0)
    }
}
