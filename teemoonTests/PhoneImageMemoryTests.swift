//
//  PhoneImageMemoryTests.swift
//  teemoonTests
//
//  Images on the phone models, decided at run time from memory (docs/IMAGES.md §4b; the maintainer 2026-11-12: "check how
//  much memory is needed and how much is available at run time"). Run from conformance/wherefilter.json phoneImages,
//  which Android runs too.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Phone images — run-time memory")
struct PhoneImageMemoryTests {

    struct Fixture: Decodable {
        struct Need: Decodable { let ios: Int? }
        struct TurnCase: Decodable {
            let name: String, needMB: Int, ceilingMB: Int, availableMB: Int, expect: String
            var killedBefore: Bool?
        }
        struct GB: Decodable { struct Case: Decodable { let mb: Int, gb: String }; let cases: [Case] }
        struct History: Decodable {
            struct Case: Decodable {
                struct Turn: Decodable { let images: Int }
                let name: String, turns: [Turn], maxImages: Int
                let expectSentOnLastTurn: Int, expectLines: Int, expectReuse: Bool
            }
            let cases: [Case]
        }
        let imageNeedMB: [String: Need]
        let turnCases: [TurnCase]
        let gb: GB
        let history: History
    }

    static func fixture(file: String = #filePath) throws -> Fixture? {
        guard TestFixture.sourceTreeAvailable() else { return nil }
        struct Root: Decodable { let phoneImages: Fixture }
        let url = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conformance/wherefilter.json")
        return try JSONDecoder().decode(Root.self, from: Data(contentsOf: url)).phoneImages
    }

    @Test func everyTurnCaseMatchesTheFixture() throws {
        guard let f = try Self.fixture() else { return }
        for c in f.turnCases {
            let turn = PhoneImageMemory.turn(needMB: c.needMB, ceilingMB: c.ceilingMB, availableMB: c.availableMB,
                                             killedBefore: c.killedBefore ?? false)
            #expect(turn.kind == c.expect, "\(c.name)")
        }
    }

    @Test func theFiguresAreTheFixturesForIOS() throws {
        guard let f = try Self.fixture() else { return }
        #expect(PhoneImageMemory.needMB(modelID: "litert-community/gemma-4-E2B-it-litert-lm") == f.imageNeedMB["gemma-4-e2b"]?.ios)
        #expect(PhoneImageMemory.needMB(modelID: "litert-community/gemma-4-E4B-it-litert-lm") == f.imageNeedMB["gemma-4-e4b"]?.ios)
    }

    @Test func gigabytesReadToOneDecimal() throws {
        guard let f = try Self.fixture() else { return }
        for c in f.gb.cases { #expect(PhoneImageMemory.gb(c.mb) == c.gb, "\(c.mb) MB") }
    }

    @Test func theNowLineNamesBothNumbers() {
        #expect(PhoneImageMemory.turn(needMB: 2980, ceilingMB: 6000, availableMB: 2000, killedBefore: false)
                .text(model: "gemma 4 e2b")
                == "gemma 4 e2b needs about 2.9 GB free for images; this phone has 2.0 GB free right now. close some apps and try again.")
        #expect(PhoneImageMemory.turn(needMB: 4900, ceilingMB: 3500, availableMB: 1200, killedBefore: false)
                .text(model: "gemma 4 e4b") == "this phone doesn't have enough memory for images with gemma 4 e4b.")
    }

    /// The where sheet: a model reads images when its figure fits the ceiling and the OS never killed it here.
    @Test func aModelReadsImagesOnlyWhenItFitsAndWasNeverKilled() {
        let e4b = "litert-community/gemma-4-E4B-it-litert-lm"
        #expect(PhoneImageMemory.reads(modelID: e4b, ceilingMB: 6000, killed: []))
        #expect(!PhoneImageMemory.reads(modelID: e4b, ceilingMB: 3000, killed: []))
        #expect(!PhoneImageMemory.reads(modelID: e4b, ceilingMB: 6000, killed: [e4b]))
        #expect(!PhoneImageMemory.reads(modelID: "unknown/model", ceilingMB: 99_000, killed: []))
    }

    /// The refusal's "use <smaller model>": a phone model ahead of it in the catalog that does fit.
    @Test func theSmallerModelIsOfferedOnlyWhenItFits() {
        let e2b = "litert-community/gemma-4-E2B-it-litert-lm", e4b = "litert-community/gemma-4-E4B-it-litert-lm"
        #expect(PhoneImageMemory.smallerModel(than: e4b, ceilingMB: 3200, killed: []) == e2b)
        #expect(PhoneImageMemory.smallerModel(than: e4b, ceilingMB: 2000, killed: []) == nil)
        #expect(PhoneImageMemory.smallerModel(than: e4b, ceilingMB: 6000, killed: [e2b]) == nil)
        #expect(PhoneImageMemory.smallerModel(than: e2b, ceilingMB: 6000, killed: []) == nil)
    }

    /// The get section offers a phone download under "reads images" only when that model fits.
    @Test func aDownloadThatCanNeverReadImagesIsNotOfferedUnderReadsImages() {
        var policy = WhereGetPolicy(filter: .phone, providers: [], networkSatisfied: true, home: [:],
                                    credentialFor: { _ in "" }, credentialForEndpoint: { _ in "" })
        policy.show = WhereFilterPolicy(filters: [.vision], imagesOnDevice: true)
        policy.phoneReadsImages = { $0 == "litert-community/gemma-4-E2B-it-litert-lm" }
        #expect(policy.downloadableModels.map(\.id) == ["litert-community/gemma-4-E2B-it-litert-lm"])
        policy.show = WhereFilterPolicy(filters: [], imagesOnDevice: true)
        #expect(policy.downloadableModels.count == LocalModelCatalog.all.count)
    }

    /// A turn the OS killed (the in-flight mark survives the relaunch) is remembered for that model.
    @Test func aTurnThatNeverEndedIsRememberedAsKilled() {
        let defaults = UserDefaults(suiteName: "PhoneImageMemoryTests.\(UUID())")!
        let store = PhoneImageMemory.KillStore(defaults: defaults)
        store.began("m")
        #expect(store.killed.isEmpty)
        PhoneImageMemory.KillStore(defaults: defaults).settleAfterLaunch()
        #expect(PhoneImageMemory.KillStore(defaults: defaults).killed == ["m"])
        let clean = PhoneImageMemory.KillStore(defaults: UserDefaults(suiteName: "PhoneImageMemoryTests.\(UUID())")!)
        clean.began("n"); clean.ended()
        clean.settleAfterLaunch()
        #expect(clean.killed.isEmpty)
    }
}
