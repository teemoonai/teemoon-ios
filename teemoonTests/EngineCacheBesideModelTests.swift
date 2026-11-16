//
//  EngineCacheBesideModelTests.swift
//  teemoonTests
//
//  The maintainer's decision (2026-10-26, via pm, for the audit's disk gate): LiteRT's
//  compiled caches — the GPU's packed weights (~780 MB for E2B), its program
//  cache, the drafter's, and the vision encoder's — sit BESIDE the model and go
//  with it. Through 1.1.0's betas iOS passed `tmp/` as `cacheDir`: iOS could
//  purge it (the next load cold, ~23 s instead of ~2.8 s), deleting a model
//  left it behind, and the "frees …" line left it out. Same rule as Android
//  b6a5191.
//

import Foundation
import Testing
@testable import teemoon

@Suite(.serialized) struct EngineCacheBesideModelTests {
    /// A scratch model folder, never a real download's.
    private func scratchModelFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(component: "engine-cache-\(UUID().uuidString)")
            .appending(component: "litert-community").appending(component: "model")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func theCacheDirectoryIsInsideTheModelsFolder() throws {
        let model = try #require(LocalModelCatalog.all.first)
        let bundle = LocalModelStorage.file(for: model)
        let cache = LocalModelStorage.engineCacheDirectory(forBundle: bundle)
        #expect(cache.deletingLastPathComponent().path == LocalModelStorage.directory(for: model.id).path)
        #expect(cache.lastPathComponent == "litert-cache")
        #expect(!cache.path.hasPrefix(FileManager.default.temporaryDirectory.path),
                "the cache is back in tmp/, where iOS may purge it and a model's delete never reaches it")
    }

    @Test func theCacheIsExcludedFromBackup() throws {
        let model = try #require(LocalModelCatalog.all.first)
        let cache = LocalModelStorage.engineCacheDirectory(forBundle: LocalModelStorage.file(for: model))
        // Excluding LocalModels excludes everything under it; pin the ancestor
        // the cache actually inherits from.
        let values = try LocalModelStorage.baseDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(cache.path.hasPrefix(LocalModelStorage.baseDirectory.path))
    }

    @Test func theModelsSizeCountsItsCache() throws {
        let folder = try scratchModelFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        try Data(count: 1000).write(to: folder.appending(component: "m.litertlm"))
        let cache = LocalModelStorage.engineCacheDirectory(forBundle: folder.appending(component: "m.litertlm"))
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(count: 500).write(to: cache.appending(component: "m.litertlm_mldrift_weight_cache.bin"))
        #expect(LocalModelStorage.bytesOnDisk(in: folder) == 1500)
    }

    @Test func theDeleteLineNamesTheSizeOnDiskWhenItIsKnown() throws {
        let model = try #require(LocalModelCatalog.all.first)
        let bytes: Int = 3_379 * 1_048_576
        #expect(LocalModelStorage.sizeLabel(bytes: bytes, else: model) == "3.3 GB")
        #expect(LocalModelStorage.sizeLabel(bytes: 0, else: model) == model.sizeLabel)
    }

    /// Deleting the model takes its cache. Runs against the real folder only
    /// when no real bundle is there, like `deletingAModelRemovesTheBundle`.
    @Test func deletingTheModelRemovesItsCache() throws {
        let model = try #require(LocalModelCatalog.all.first)
        let file = LocalModelStorage.file(for: model)
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        let cache = LocalModelStorage.engineCacheDirectory(forBundle: file)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("not a real bundle".utf8).write(to: file)
        try Data(count: 10).write(to: cache.appending(component: "\(model.fileName)_mldrift_weight_cache.bin"))
        try LocalModelStorage.delete(model)
        #expect(!FileManager.default.fileExists(atPath: cache.path), "deleting the model left its cache")
    }

    @Test func theOldTmpCachesAreRecognisedAndNothingElse() {
        #expect(LocalModelStorage.isStaleEngineCacheFile("gemma-4-E2B-it.litertlm_mldrift_weight_cache.bin"))
        #expect(LocalModelStorage.isStaleEngineCacheFile("gemma-4-E2B-it.litertlm_mldrift_program_cache.bin"))
        #expect(LocalModelStorage.isStaleEngineCacheFile("gemma-4-E2B-it.litertlm_mtp_drafter_mldrift_weight_cache.bin"))
        #expect(LocalModelStorage.isStaleEngineCacheFile("gemma-4-E2B-it.litertlm.xnnpack_cache"))
        #expect(!LocalModelStorage.isStaleEngineCacheFile("gemma-4-E2B-it.litertlm"))
        #expect(!LocalModelStorage.isStaleEngineCacheFile("download.unverified"))
        #expect(!LocalModelStorage.isStaleEngineCacheFile("uitest-store"))
    }

    /// The sweep takes the old tmp/ set and the dev-phone set written beside
    /// the bundle by the 2026-09-21 bench (cacheDir nil), and spares the bundle
    /// and the new cache folder.
    @Test func theSweepTakesOnlyStaleCaches() throws {
        let folder = try scratchModelFolder()
        let root = folder.deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let tmp = root.appending(component: "tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bundle = folder.appending(component: "m.litertlm")
        let cache = LocalModelStorage.engineCacheDirectory(forBundle: bundle)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let stale = [tmp.appending(component: "m.litertlm_mldrift_weight_cache.bin"),
                     folder.appending(component: "m.litertlm_mldrift_program_cache.bin")]
        let kept = [bundle, tmp.appending(component: "other.txt"),
                    cache.appending(component: "m.litertlm_mldrift_weight_cache.bin")]
        for url in stale + kept { try Data(count: 100).write(to: url) }

        let freed = LocalModelStorage.reclaimStaleEngineCaches(in: [tmp, folder])

        #expect(freed == 200)
        for url in stale { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) survived") }
        for url in kept { #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) was swept") }
    }
}
