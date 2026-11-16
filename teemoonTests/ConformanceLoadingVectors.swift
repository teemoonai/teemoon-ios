//
//  ConformanceLoadingVectors.swift
//  teemoonTests
//
//  The on-device load line (strings approved by the maintainer 2026-10-25/26 via pm; first-load rule agreed with Android
//  2026-10-26). Expected lines are worked by hand from the rule, not computed by EngineLoadLine.
//

import Foundation
import Testing
@testable import teemoon

struct LoadingVectors: Encodable {
    struct Probe: Encodable { let atMs: Double; let line: String }
    struct Case: Encodable {
        let name: String
        let note: String
        let loadStartMs: Double?
        let loadEndsAtMs: Double?
        let imageCapable: Bool
        let cachePresent: Bool
        let rebuildSeenAtMs: Double?
        let probes: [Probe]
    }
    let rule: String
    let harness: String
    let quietMs: Double
    let cases: [Case]
}

enum ConformanceLoadingVectors {
    static let rule = """
        Times are ms from the send. Outside a load (before loadStartMs, from loadEndsAtMs on, or no load at all) \
        the line is the thinking clock counted from the send: "thinking…" under 1 s, else "thinking… Ns" with \
        N = floor(atMs / 1000). During a load, a load is a rebuild when no cache for the current bundle existed at \
        its start, or from the moment a cache file is created or rewritten during it (rebuildSeenAtMs). An \
        image-capable rebuild shows "preparing the model for images… this happens once" from that moment to the \
        load's end. Any other load shows the thinking clock until quietMs after loadStartMs, then \
        "loading the model…". "Cache present for this bundle" is each platform's own test; only the bool is shared.
        """
    static let harness = "For each probe, line(atMs, case) must equal the probe's line exactly."

    static let images = EngineLoadLine.preparingForImages
    static let loadingLine = EngineLoadLine.loading
    static func p(_ t: Double, _ line: String) -> LoadingVectors.Probe { .init(atMs: t, line: line) }

    static let cases: [LoadingVectors.Case] = [
        .init(name: "resident-engine-no-load", note: "the engine was already loaded: only the thinking clock",
              loadStartMs: nil, loadEndsAtMs: nil, imageCapable: true, cachePresent: true, rebuildSeenAtMs: nil,
              probes: [p(0, "thinking…"), p(999, "thinking…"), p(1000, "thinking… 1s"), p(5400, "thinking… 5s")]),
        .init(name: "image-first-load", note: "no cache: the images line from the load's start to its end, then the clock from the send",
              loadStartMs: 200, loadEndsAtMs: 61_000, imageCapable: true, cachePresent: false, rebuildSeenAtMs: nil,
              probes: [p(100, "thinking…"), p(200, images), p(3200, images), p(60_999, images), p(61_000, "thinking… 61s")]),
        .init(name: "image-cached-quick", note: "cached, done under 3 s: no loading line at all",
              loadStartMs: 0, loadEndsAtMs: 2800, imageCapable: true, cachePresent: true, rebuildSeenAtMs: nil,
              probes: [p(0, "thinking…"), p(2799, "thinking… 2s"), p(2800, "thinking… 2s"), p(4000, "thinking… 4s")]),
        .init(name: "image-cached-slow", note: "cached but slow: the plain loading line from 3 s after the load's start",
              loadStartMs: 500, loadEndsAtMs: 8000, imageCapable: true, cachePresent: true, rebuildSeenAtMs: nil,
              probes: [p(3499, "thinking… 3s"), p(3500, loadingLine), p(7999, loadingLine), p(8000, "thinking… 8s")]),
        .init(name: "image-rebuild-before-3s", note: "a cache rewritten 1.2 s in: straight to the images line, never the loading line",
              loadStartMs: 0, loadEndsAtMs: 40_000, imageCapable: true, cachePresent: true, rebuildSeenAtMs: 1200,
              probes: [p(1199, "thinking… 1s"), p(1200, images), p(3000, images), p(40_000, "thinking… 40s")]),
        .init(name: "image-rebuild-after-3s", note: "rebuild seen 5 s in: the loading line first, then the images line to the end",
              loadStartMs: 0, loadEndsAtMs: 30_000, imageCapable: true, cachePresent: true, rebuildSeenAtMs: 5000,
              probes: [p(3000, loadingLine), p(4999, loadingLine), p(5000, images), p(29_999, images)]),
        .init(name: "text-only-first-load", note: "not image-capable: a first load never shows the images line",
              loadStartMs: 0, loadEndsAtMs: 23_000, imageCapable: false, cachePresent: false, rebuildSeenAtMs: nil,
              probes: [p(2999, "thinking… 2s"), p(3000, loadingLine), p(22_999, loadingLine), p(23_000, "thinking… 23s")]),
        .init(name: "text-only-rebuild", note: "not image-capable, cache rewritten: still only the loading line after 3 s",
              loadStartMs: 0, loadEndsAtMs: 20_000, imageCapable: false, cachePresent: true, rebuildSeenAtMs: 1000,
              probes: [p(1000, "thinking… 1s"), p(3000, loadingLine), p(20_000, "thinking… 20s")]),
        .init(name: "queued-behind-a-load", note: "the load started before the send (pre-warm): 3 s counts from the load's start, so negative",
              loadStartMs: -2500, loadEndsAtMs: 4000, imageCapable: true, cachePresent: true, rebuildSeenAtMs: nil,
              probes: [p(0, "thinking…"), p(499, "thinking…"), p(500, loadingLine), p(4000, "thinking… 4s")]),
    ]

    static func loading() -> LoadingVectors {
        LoadingVectors(rule: rule, harness: harness, quietMs: EngineLoadLine.quietMs, cases: cases)
    }

    static func load(_ c: LoadingVectors.Case) -> EngineLoadLine.Load {
        .init(loadStartMs: c.loadStartMs, loadEndsAtMs: c.loadEndsAtMs, imageCapable: c.imageCapable,
              cachePresent: c.cachePresent, rebuildSeenAtMs: c.rebuildSeenAtMs)
    }
}

struct ConformanceLoadingTests {

    @Test(arguments: ConformanceLoadingVectors.cases.indices)
    func everyProbeShowsWhatTheRuleSays(_ index: Int) {
        let c = ConformanceLoadingVectors.cases[index]
        for probe in c.probes {
            #expect(EngineLoadLine.line(atMs: probe.atMs, load: ConformanceLoadingVectors.load(c)) == probe.line,
                    "\(c.name) at \(probe.atMs) ms")
        }
    }

    @Test func theApprovedWordsAreExact() {
        #expect(EngineLoadLine.preparingForImages == "preparing the model for images… this happens once")
        #expect(EngineLoadLine.loading == "loading the model…")
    }

    @Test func itsKitVersionMovedWithItsBytes() {
        #expect(ConformanceVectors.kitVersion(for: "loading") == "0.5.6")
    }

    @Test func theCommittedFixtureMatchesTheTable() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let url = ConformanceEmitTests.outputDirectory().appendingPathComponent("loading.json")
        let committed = try Data(contentsOf: url)
        let fresh = try ConformanceEncoder.encode(ConformanceDocument(
            kitVersion: ConformanceVectors.kitVersion(for: "loading"), fixtureClass: "loading",
            sourceOfTruth: "teemoon-ios", vectors: ConformanceLoadingVectors.loading()))
        #expect(committed == fresh, "conformance/loading.json is stale: run make conformance")
    }
}
