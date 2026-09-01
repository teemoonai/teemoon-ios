//
//  LocalModelCatalogTests.swift
//  teemoonTests
//
//  Guards against advertising a model that cannot possibly work.
//
//  This suite exists because the catalog once listed four gemma-4 variants
//  chosen by checking that the HuggingFace repos existed. They do exist — and
//  the runtime of the day could not load any of them. The failure surfaced only
//  after a 3.4 GB download to a real phone: a user would have paid that download
//  to reach an error.
//
//  Repo existence is not the property that matters. Every claim the catalog
//  makes — the file exists, the size, the checksum, tool support — is checked
//  against something outside the catalog.
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

@Suite("Local model catalog")
struct LocalModelCatalogTests {

    @Test func catalogIsNotEmptyAndIdsAreUnique() {
        #expect(!LocalModelCatalog.all.isEmpty)
        let ids = LocalModelCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate model ids in the catalog")
    }

    /// Smallest first: the top entry is what a new user is steered to, and it
    /// should not be a multi-gigabyte commitment.
    @Test func catalogIsOrderedSmallestFirst() {
        let sizes = LocalModelCatalog.all.map(\.sizeMB)
        #expect(sizes == sizes.sorted(), "catalog should be ordered smallest-first, got \(sizes)")
    }

    /// The named bundle must exist in the repo, at the declared size.
    ///
    /// An entry is a repo id **plus one exact filename**, and nothing validates
    /// that filename until a download runs. Get it wrong and the downloader 404s
    /// after the user has already committed — the same pay-then-fail shape that
    /// motivated this suite. The size matters separately: it drives the
    /// pre-download memory warning and the pre-load gate, so a wrong figure
    /// tells a user a model fits when it does not.
    ///
    /// Hits the API, so it skips offline rather than failing — a missing network
    /// is not a broken catalog.
    @Test func everyModelNamesABundleThatExistsAtItsDeclaredSize() async throws {
        for model in LocalModelCatalog.all {
            let url = URL(string:
                "https://huggingface.co/api/models/\(model.id)/revision/\(model.revision)?blobs=true")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let data: Data
            do {
                (data, _) = try await URLSession.shared.data(for: request)
            } catch {
                print("[catalog] skipping \(model.id) — network unavailable")
                continue
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let siblings = json["siblings"] as? [[String: Any]] else { continue }

            guard let entry = siblings.first(where: { ($0["rfilename"] as? String) == model.fileName }) else {
                let available = siblings.compactMap { $0["rfilename"] as? String }
                    .filter { $0.hasSuffix(".litertlm") }
                Issue.record("""
                    \(model.id) names "\(model.fileName)", which is not in the repo at \
                    revision \(model.revision). Bundles that ARE there: \
                    \(available.isEmpty ? ["none"] : available)
                    """)
                continue
            }

            guard let bytes = entry["size"] as? Int, bytes > 0 else { continue }
            let actualMB = bytes / (1024 * 1024)
            #expect(abs(actualMB - model.sizeMB) < max(100, actualMB / 10),
                    "\(model.id): catalog says \(model.sizeMB) MB, the bundle is \(actualMB) MB")
        }
    }

    /// The pinned digest must match what HuggingFace serves at the pinned
    /// revision.
    ///
    /// Pinning a revision and a checksum together is only safe if they agree: a
    /// stale digest against a live revision rejects every download as
    /// corruption, which looks exactly like a network problem and would be
    /// debugged as one.
    @Test func pinnedChecksumsMatchTheirPinnedRevision() async throws {
        for model in LocalModelCatalog.all {
            let url = URL(string:
                "https://huggingface.co/api/models/\(model.id)/revision/\(model.revision)?blobs=true")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let data: Data
            do {
                (data, _) = try await URLSession.shared.data(for: request)
            } catch {
                print("[catalog] skipping checksum check for \(model.id) — network unavailable")
                continue
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let siblings = json["siblings"] as? [[String: Any]],
                  let entry = siblings.first(where: { ($0["rfilename"] as? String) == model.fileName }),
                  let lfs = entry["lfs"] as? [String: Any],
                  let upstream = lfs["sha256"] as? String else {
                Issue.record("\(model.id): no LFS sha256 for \(model.fileName) at \(model.revision)")
                continue
            }
            #expect(upstream.caseInsensitiveCompare(model.sha256) == .orderedSame,
                    """
                    \(model.id): pinned checksum does not match the revision it is pinned to. \
                    Catalog says \(model.sha256), HuggingFace says \(upstream). Every download \
                    will be rejected as corrupt until these agree.
                    """)
        }
    }

    /// The hash itself must be right, and must not need the file in memory.
    @Test func fileChecksumIsComputedInChunks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "checksum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Deliberately larger than one 1 MB chunk, so a single-read
        // implementation that happens to work on small files fails here.
        let file = directory.appending(component: "blob.bin")
        let payload = Data(repeating: 0xAB, count: (1 << 20) + 12_345)
        try payload.write(to: file)

        let digest = try LocalModelDownloader.sha256OfFile(at: file)
        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        #expect(digest == expected, "chunked hash disagrees with hashing the whole file at once")
    }

    /// `supportsTools` must be a measured claim, not an inherited default.
    ///
    /// It was once `true` for all six entries when only two had ever been
    /// tested, and one of the untested ones called 0/6 while fabricating a
    /// price, a timestamp and its sourcing. The flag gates whether tools are
    /// attached at all, so a wrong `true` is not a missing feature — it is
    /// teemoon appearing to search when it did not.
    ///
    /// A unit test cannot verify a measurement, so it pins the next best thing:
    /// every `true` must carry a note of what was measured. A bare
    /// `supportsTools: true` fails here.
    @Test(.enabled(if: TestFixture.sourceTreeAvailable()))
    func everyToolSupportClaimCarriesItsEvidence() throws {
        let source = try #require(catalogSource(),
                                  "could not locate LocalModelCatalog.swift to inspect")
        let entries = source.components(separatedBy: "LocalModel(").dropFirst()
        var claiming = 0
        for entry in entries {
            guard let range = entry.range(of: "supportsTools: true") else { continue }
            claiming += 1
            let preamble = String(entry[entry.startIndex..<range.lowerBound])
            #expect(preamble.lowercased().contains("measured"),
                    """
                    an entry declares supportsTools: true with no note of what was measured. \
                    Run LocalToolSupportSweepTests and record the rate. Entry begins: \
                    \(entry.prefix(90))
                    """)
        }
        #expect(claiming > 0, "no entry claims tool support — the check is inspecting the wrong text")
    }

    private func catalogSource() -> String? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let root = dir.appending(component: "teemoon")
            if let found = firstFile(named: "LocalModelCatalog.swift", under: root) {
                return try? String(contentsOf: found, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Walks `teemoon/` so this keeps working after the catalog moves folders.
    private func firstFile(named name: String, under root: URL) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in en where url.lastPathComponent == name { return url }
        return nil
    }

    /// A bundle must live under its repo id, not loose in `litert/`.
    ///
    /// The live suite once invented its own flat path, so the tests and the app
    /// disagreed about where a model lives: six live tests passed against a
    /// downloaded Gemma 4 while `isInstalled` reported it missing, and a user
    /// running both would have stored 2.5 GB twice.
    @Test func theBundlePathIsNamespacedByRepoID() throws {
        let model = try #require(LocalModelCatalog.all.first)
        let file = LocalModelStorage.file(for: model)

        #expect(file.lastPathComponent == model.fileName)
        let relative = file.path.replacingOccurrences(
            of: LocalModelStorage.baseDirectory.path, with: ""
        )
        #expect(relative.contains(model.id),
                "the bundle is not namespaced by repo id — two models sharing a file name would collide: \(relative)")
    }

    /// Deleting a model must actually free the disk.
    ///
    /// A delete that reports success and frees nothing is the worst version of
    /// this bug, because nothing surfaces it until the user runs out of space.
    @Test func deletingAModelRemovesTheBundle() throws {
        let model = try #require(LocalModelCatalog.all.first)
        let file = LocalModelStorage.file(for: model)
        // Never delete a genuinely downloaded bundle to make a point. Returns
        // rather than #require-ing: on a device the model IS installed, and
        // #require turns the intended skip into a failure.
        guard !FileManager.default.fileExists(atPath: file.path) else { return }

        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not a real bundle".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(LocalModelStorage.isInstalled(model))
        try LocalModelStorage.delete(model)
        #expect(!FileManager.default.fileExists(atPath: file.path),
                "the bundle survived deletion — the disk was never freed")
    }

    /// Retired MLX weights must be reclaimed, and only those.
    ///
    /// Anyone who used on-device inference before the runtime change has
    /// gigabytes of `.safetensors` that nothing can load, invisible in teemoon's
    /// UI because the models they belong to are no longer listed. Deleting the
    /// wrong tree would take the user's *current* models with it, so this pins
    /// both halves.
    @Test func reclaimingRetiredWeightsSparesTheCurrentOnes() throws {
        let legacy = LocalModelStorage.baseDirectory.appending(component: "models")
        try #require(!FileManager.default.fileExists(atPath: legacy.path),
                     "skipping: real legacy weights are present")

        let legacyFile = legacy.appending(components: "mlx-community", "old", "model.safetensors")
        try FileManager.default.createDirectory(at: legacyFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x01, count: 2048).write(to: legacyFile)

        let model = try #require(LocalModelCatalog.all.first)
        let current = LocalModelStorage.file(for: model)
        let currentExisted = FileManager.default.fileExists(atPath: current.path)
        if !currentExisted {
            try FileManager.default.createDirectory(at: current.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("current".utf8).write(to: current)
        }
        defer {
            try? FileManager.default.removeItem(at: legacy)
            if !currentExisted { try? FileManager.default.removeItem(at: current) }
        }

        LocalModelStorage.reclaimRetiredMLXWeights()

        #expect(!FileManager.default.fileExists(atPath: legacy.path),
                "retired MLX weights were not reclaimed")
        #expect(FileManager.default.fileExists(atPath: current.path),
                "reclaiming retired weights deleted a CURRENT model")
    }
}

@Suite("Grounding budget")
struct GroundingBudgetTests {

    /// On device the payload budget is fixed at 2048, and that is deliberate.
    ///
    /// Across ten live queries 2048 and 4096 return the SAME mean source count
    /// (3.9) and both collapse to a single source twice — so the reason is not
    /// source count, which an earlier n=1 measurement wrongly suggested. The
    /// reason is cost: 1,809 vs 3,547 mean tokens, prefilled on the phone's own
    /// GPU, sharing an 8,192-token KV cache with persona, history and answer.
    @Test func onDeviceAsksForFewerTokensThanRemote() {
        for count in [1, 5, 10, 20, 50] {
            #expect(GroundingBudget.maxTokens(forCount: count, onDevice: true) == 2048,
                    "on-device budget must not scale with count — that is what produced the 4096 single-source case")
        }
        // Remote keeps the count-scaled ladder; its prefill is someone else's.
        #expect(GroundingBudget.maxTokens(forCount: 10, onDevice: false) == 4096)
        #expect(GroundingBudget.maxTokens(forCount: 20, onDevice: false) == 8192)
    }

    /// The URL cap stays 5 on device regardless of what the model asks for.
    @Test func onDeviceCapsSourcesAtFive() {
        #expect(GroundingBudget.urlCap(forCount: 50, onDevice: true) == 5)
        #expect(GroundingBudget.urlCap(forCount: 3, onDevice: true) == 3)
    }
}
