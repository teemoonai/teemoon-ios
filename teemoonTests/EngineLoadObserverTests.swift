//
//  EngineLoadObserverTests.swift
//  teemoonTests
//
//  The load line reads facts the engine and its cache folder produce (conformance/loading.json holds the rule):
//  the cache key LiteRT puts in each file name, a file written during the load, and the load's own start and end,
//  placed on the turn's clock.
//

import Foundation
import Testing
@testable import teemoon

@MainActor
@Suite(.serialized) struct EngineLoadObserverTests {

    private func scratchBundle() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(component: "load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bundle = folder.appending(component: "m.litertlm")
        try Data(count: 1234).write(to: bundle)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_792_699_638)],
                                              ofItemAtPath: bundle.path)
        return bundle
    }

    @Test func theCacheKeyIsTheBundlesNameMtimeAndSize() throws {
        let bundle = try scratchBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        #expect(LocalModelStorage.engineCacheKey(forBundle: bundle) == "m.litertlm_1792699638_1234")
    }

    @Test func onlyACacheForThisBundleCounts() throws {
        let bundle = try scratchBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let cache = LocalModelStorage.engineCacheDirectory(forBundle: bundle)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        #expect(!LocalModelStorage.engineCachePresent(forBundle: bundle, vision: false))
        try Data(count: 1).write(to: cache.appending(component: "m.litertlm_1700000000_1234_mldrift_weight_cache.bin"))
        #expect(!LocalModelStorage.engineCachePresent(forBundle: bundle, vision: false), "an older copy's cache counted")
        try Data(count: 1).write(to: cache.appending(component: "m.litertlm_1792699638_1234_mldrift_weight_cache.bin"))
        #expect(LocalModelStorage.engineCachePresent(forBundle: bundle, vision: false))
        #expect(!LocalModelStorage.engineCachePresent(forBundle: bundle, vision: true), "a text cache is not a vision one")
    }

    @Test func aFileWrittenDuringTheLoadChangesTheSnapshot() throws {
        let bundle = try scratchBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let cache = LocalModelStorage.engineCacheDirectory(forBundle: bundle)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let before = LocalModelStorage.engineCacheSnapshot(forBundle: bundle)
        #expect(LocalModelStorage.engineCacheSnapshot(forBundle: bundle) == before)
        try Data(count: 1).write(to: cache.appending(component: "m.litertlm_1792699638_1234_mldrift_program_cache.bin"))
        #expect(LocalModelStorage.engineCacheSnapshot(forBundle: bundle) != before)
    }

    @Test func aLoadIsPlacedOnTheTurnsClock() {
        let send = Date(timeIntervalSince1970: 1000)
        let observed = EngineLoadObserver.Observed(started: send.addingTimeInterval(-2.5), ended: send.addingTimeInterval(4),
                                                   imageCapable: true, cachePresent: true, rebuildSeen: nil)
        #expect(observed.load(sentAt: send) == .init(loadStartMs: -2500, loadEndsAtMs: 4000, imageCapable: true,
                                                     cachePresent: true, rebuildSeenAtMs: nil))
        let finishedBefore = EngineLoadObserver.Observed(started: send.addingTimeInterval(-9), ended: send.addingTimeInterval(-1),
                                                         imageCapable: true, cachePresent: false, rebuildSeen: nil)
        #expect(finishedBefore.load(sentAt: send).loadStartMs == nil, "a load that finished before the send is no load")
    }

    @Test func theChipGetsALineOnlyForALoadingLine() {
        let observer = EngineLoadObserver()
        let send = Date(timeIntervalSince1970: 1000)
        #expect(observer.line(sentAt: send, now: send.addingTimeInterval(5)) == nil)
        observer.began(at: send, imageCapable: true, cachePresent: false)
        #expect(observer.line(sentAt: send, now: send.addingTimeInterval(1)) == EngineLoadLine.preparingForImages)
        observer.ended(at: send.addingTimeInterval(30))
        #expect(observer.line(sentAt: send, now: send.addingTimeInterval(31)) == nil, "after the load it reads as thinking")
        observer.began(at: send, imageCapable: false, cachePresent: true)
        #expect(observer.line(sentAt: send, now: send.addingTimeInterval(2)) == nil)
        #expect(observer.line(sentAt: send, now: send.addingTimeInterval(3)) == EngineLoadLine.loading)
        observer.rebuildSeen(at: send.addingTimeInterval(4))
        #expect(observer.line(sentAt: send, now: send.addingTimeInterval(5)) == EngineLoadLine.loading,
                "a text-only rebuild never says images")
    }
}
