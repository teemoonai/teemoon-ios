//
//  LocalModelCatalog.swift
//  teemoon
//
//  What models can run on this phone, where their weights live, and how they
//  get there.
//
//  ONE RUNTIME: LiteRT-LM. MLX was removed before release — not because it was
//  slow (measured on the same model it was ~2x FASTER) but because every model
//  teemoon shipped on it was poor product: Gemma 3n E2B called tools 0/6 and
//  fabricated prices, Qwen3.5 4B needed 45s+ per grounded answer, Qwen3-0.6B was
//  erratic. Gemma 4 E2B calls tools 12/12 at 6.7s and MLX cannot load it at all.
//  A faster runtime carrying worse models did not justify a second code path.
//
//  Dropping it also closed four MLX-only problems for free: unverifiable
//  multi-file downloads, an MLX Metal cache that held ~4.7 GB after eviction, a
//  hard `abort()` in the simulator, and the CudaBuild plugin trust prompt.
//
//  Every model here is ONE `.litertlm` file, pinned to a git revision and
//  verified by SHA-256 before it is used.
//
//  Related: LiteRTTransport.swift (loads what this downloads),
//  LocalLanguageModel.swift.
//

import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "local.models")

// MARK: - Catalog

/// A model teemoon will offer to run on-device.
///
/// Curated rather than a live search: an arbitrary repo is a multi-gigabyte
/// download that may not fit, may not be a LiteRT bundle at all, and may have a
/// chat template teemoon has never seen. Pasting an arbitrary repo id can come
/// later — this is the set we can stand behind.
struct LocalModel: Identifiable, Hashable, Sendable {
    /// HuggingFace repo id. Also the identity teemoon stores on the provider.
    let id: String
    let displayName: String
    /// Download size in MB, from the Hub API's blob metadata for `fileName` —
    /// not estimated from the parameter count.
    let sizeMB: Int
    /// One line on what it's for.
    let blurb: String

    /// Whether this model calls tools usefully — **measured on device**, not
    /// claimed from a model card.
    ///
    /// This becomes `modelCapabilities: [.tools]` on the provider, which decides
    /// whether tools are attached at all. `LocalToolSupportSweepTests` measures
    /// each entry through the app's own stack; the numbers are recorded below.
    ///
    /// **THE BAR IS NOT THE CALL RATE — IT IS THE FAILURE MODE.** A model that
    /// sometimes declines to search and then says nothing useful is merely
    /// unimpressive. A model that declines and *fabricates* the answer is
    /// actively harmful, and attaching a web-search tool to it buys nothing
    /// while making teemoon look like it searched. Measured on the model this
    /// retired: Gemma 3n E2B called 0/6 and answered "As of July 27, 2026, at
    /// 4:00 AM UTC, WTI crude is approximately $95.80 per barrel" — invented
    /// price, timestamp and sourcing alike.
    let supportsTools: Bool

    /// The single `.litertlm` artefact to fetch from the repo.
    let fileName: String

    /// Git revision to fetch, instead of whatever `main` points at today.
    ///
    /// Pinned together with `sha256`, and it has to be both: a digest against a
    /// moving branch rejects a legitimate upstream update as corruption, and a
    /// revision without a digest still trusts whatever arrives.
    let revision: String

    /// Expected SHA-256, from HuggingFace's LFS metadata. Verified after
    /// download, before the file is moved into place.
    ///
    /// Honest limit: this proves the bytes match what the API advertised at the
    /// pinned revision. Integrity, not provenance — it does not establish that
    /// Google built what the repo claims.
    let sha256: String

    var sizeLabel: String {
        sizeMB >= 1024
            ? String(format: "%.1f GB", Double(sizeMB) / 1024)
            : "\(sizeMB) MB"
    }
}

enum LocalModelCatalog {
    /// Ordered smallest-first: the top of the list should be the one a user can
    /// try without committing to a multi-gigabyte download over cellular.
    static let all: [LocalModel] = [
        LocalModel(
            id: "litert-community/gemma-4-E2B-it-litert-lm",
            displayName: "Gemma 4 E2B",
            sizeMB: 2468,
            // One line, comparative, and it has to survive being read next to
            // E4B's: these two are the only choice on this screen, so the copy's
            // job is to separate them, not to praise either.
            // No trailing period, and short enough for one line at caption size
            // in a list row — the rows are the only place these are read, and a
            // blurb that wraps makes the list ragged.
            blurb: "Best balance of speed and quality",
            // Measured 12/12 across four sweeps at 6.7s mean — the only local
            // model that calls tools reliably, and the reason this runtime won.
            supportsTools: true,
            fileName: "gemma-4-E2B-it.litertlm",
            revision: "9262660a1676eed6d0c477ab1a86344430854664",
            sha256: "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
        ),
        LocalModel(
            id: "litert-community/gemma-4-E4B-it-litert-lm",
            displayName: "Gemma 4 E4B",
            sizeMB: 3490,
            // Slower is measured (12.3s vs 6.7s mean). Higher quality is the
            // reasonable expectation from the larger model, but note that
            // ON_DEVICE_INFERENCE still lists E4B's answer quality as
            // unmeasured — if that measurement lands and goes the other way,
            // this line is the thing to change.
            blurb: "Higher quality but slower generation",
            // MEASURED 3/3 — as reliable a tool-caller as the E2B above, at
            // 12.3s mean against its 6.7s. Same rate, 1.8x the latency, 1 GB
            // more to download, so it does NOT lead the catalog: on the axis
            // that was measured it is not better, only bigger.
            //
            // What is NOT measured is ANSWER QUALITY, which is the thing a
            // larger model is actually bought for and which this sweep cannot
            // see — it asserts that a tool was called, not that the reply was
            // good. If E4B is ever promoted, it should be on the back of a
            // grounded-answer accuracy comparison, not this number.
            supportsTools: true,
            fileName: "gemma-4-E4B-it.litertlm",
            revision: "f7ad3343bd6ebc9607f4dc3bc4f2398bd5749bc5",
            sha256: "0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0"
        ),
    ]

    static func model(id: String) -> LocalModel? { all.first { $0.id == id } }
}

// MARK: - Storage

enum LocalModelStorage {
    /// Weights live in Application Support, NOT Caches.
    ///
    /// Caches may be purged under disk pressure — losing a multi-gigabyte
    /// download the user waited for, silently, and leaving a provider pointing
    /// at nothing. Application Support is not purged; the cost is that teemoon
    /// must exclude it from iCloud backup itself (Apple requires that for large
    /// re-downloadable data), which `prepare()` does.
    static var baseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = support.appending(component: "LocalModels")
        prepare(base)
        return base
    }

    private static func prepare(_ directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            logger.error("[local] could not prepare model directory: \(error)")
        }
    }

    /// Where a model's bundle lands. Namespaced by repo id so two models sharing
    /// a file name cannot collide.
    static func directory(for repoID: String) -> URL {
        baseDirectory.appending(component: "litert").appending(component: repoID)
    }

    /// The single artefact a model is loaded from.
    static func file(for model: LocalModel) -> URL {
        directory(for: model.id).appending(component: model.fileName)
    }

    static func isInstalled(_ model: LocalModel) -> Bool {
        FileManager.default.fileExists(atPath: file(for: model).path)
    }

    static func delete(_ model: LocalModel) throws {
        try FileManager.default.removeItem(at: directory(for: model.id))
    }

    /// Everything needed to run this model, or nil if it isn't installed.
    static func ref(for repoID: String) -> LocalModelRef? {
        guard let model = LocalModelCatalog.model(id: repoID), isInstalled(model) else { return nil }
        return LocalModelRef(id: repoID, directory: directory(for: repoID),
                             sizeMB: model.sizeMB, bundleFile: file(for: model))
    }

    /// Deletes downloaded bundles for models the catalog no longer lists.
    ///
    /// A model dropped from the catalog does not disappear from the phone — its
    /// bundle stays, invisible, because the only screen that could offer to
    /// delete it iterates the catalog. Qwen3 0.6B was retired at 474 MB; a
    /// larger entry would be gigabytes.
    ///
    /// Deliberately conservative: only touches the `litert` tree teemoon owns,
    /// and only ids that are not in the catalog *right now*.
    @discardableResult
    static func reclaimUncatalogedBundles() -> Int {
        let root = baseDirectory.appending(component: "litert")
        let known = Set(LocalModelCatalog.all.map(\.id))
        var freedMB = 0

        // Repo ids are "org/name", so the tree is two levels deep.
        let fm = FileManager.default
        guard let orgs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return 0 }
        for org in orgs {
            guard let names = try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil) else { continue }
            for name in names {
                let id = "\(org.lastPathComponent)/\(name.lastPathComponent)"
                guard !known.contains(id) else { continue }
                var bytes = 0
                if let e = fm.enumerator(at: name, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let url as URL in e {
                        bytes += ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                }
                do {
                    try fm.removeItem(at: name)
                    freedMB += bytes / (1024 * 1024)
                    logger.info("[local] reclaimed retired model \(id, privacy: .public)")
                } catch {
                    logger.error("[local] could not reclaim \(id, privacy: .public): \(error)")
                }
            }
        }
        return freedMB
    }

    /// Reclaims the MLX weight tree left behind by an earlier version.
    ///
    /// Anyone who used on-device inference before this release has gigabytes of
    /// `.safetensors` under `LocalModels/models/` that nothing can load any
    /// more. Leaving them is not neutral — these are multi-gigabyte directories
    /// on a phone, invisible in teemoon's own UI because the catalog no longer
    /// lists the models they belong to.
    ///
    /// Providers pointing at those models fail politely: `ref(for:)` returns nil
    /// and `ChatGeneration` already reports "isn't downloaded on this device".
    @discardableResult
    static func reclaimRetiredMLXWeights() -> Int {
        let legacy = baseDirectory.appending(component: "models")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return 0 }

        var freedMB = 0
        if let e = FileManager.default.enumerator(at: legacy, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in e {
                freedMB += ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            freedMB /= (1024 * 1024)
        }
        do {
            try FileManager.default.removeItem(at: legacy)
            logger.info("[local] reclaimed \(freedMB, privacy: .public) MB of retired MLX weights")
        } catch {
            logger.error("[local] could not reclaim retired MLX weights: \(error)")
            return 0
        }
        return freedMB
    }
}

// MARK: - Downloader

/// Downloads model bundles, one at a time, with progress.
///
/// Serial by design: two concurrent multi-gigabyte downloads on a phone compete
/// for bandwidth and disk and finish later than if they had queued.
@Observable
@MainActor
final class LocalModelDownloader {
    static let shared = LocalModelDownloader()

    struct Job: Identifiable, Sendable {
        let id: String          // repo id
        var fraction: Double    // 0...1
        var model: LocalModel
    }

    /// Active + queued downloads, keyed by repo id.
    private(set) var jobs: [String: Job] = [:]
    /// Last failure per repo id, cleared when a retry starts.
    private(set) var failures: [String: String] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]

    /// A downloader with jobs already in flight and no tasks behind them, for
    /// previews.
    ///
    /// Mid-download is a state the real singleton can only reach by actually
    /// pulling gigabytes, so without this the progress row — bar, percentage,
    /// cancel — could not be looked at before shipping.
    static func previewing(_ jobs: [(LocalModel, Double)]) -> LocalModelDownloader {
        let downloader = LocalModelDownloader()
        for (model, fraction) in jobs {
            downloader.jobs[model.id] = Job(id: model.id, fraction: fraction, model: model)
        }
        return downloader
    }

    /// Called on the main actor when a download has landed AND verified.
    ///
    /// Wired at the app entry point to register the model as a provider, so a
    /// finished download shows up as something you can run without a second
    /// "use" tap. Same shape as `ProviderStore.onActiveProviderChanged`: this
    /// type has no business knowing what a provider is.
    @ObservationIgnored
    var onInstalled: ((LocalModel) -> Void)?

    func isDownloading(_ repoID: String) -> Bool { jobs[repoID] != nil }

    func progress(_ repoID: String) -> Double? { jobs[repoID]?.fraction }

    func failure(_ repoID: String) -> String? { failures[repoID] }

    func start(_ model: LocalModel) {
        guard tasks[model.id] == nil else { return }
        failures[model.id] = nil
        jobs[model.id] = Job(id: model.id, fraction: 0, model: model)

        // Bound to the singleton rather than re-capturing `self`: this closure is
        // called from the download delegate's queue, and a nested `[weak self]`
        // inside an already weakly-captured Task is a "captured var in
        // concurrently-executing code" race (a hard error under Swift 6).
        let repoID = model.id
        let onProgress: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in
                LocalModelDownloader.shared.jobs[repoID]?.fraction = fraction
            }
        }

        tasks[model.id] = Task { [weak self] in
            do {
                try await Self.downloadBundle(model, onProgress: onProgress)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Trust the file, not the callback: a "finished" download
                    // that left nothing behind is a failure, and reporting it as
                    // success just moves the error to the first chat instead.
                    if !LocalModelStorage.isInstalled(model) {
                        self.failures[model.id] = "The download finished but the model file is missing. Try again."
                    } else {
                        // Only after the file is confirmed on disk — the
                        // checksum has already been verified before the move, so
                        // reaching here means it is genuinely runnable.
                        self.onInstalled?(model)
                    }
                    self.finish(model.id)
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in self?.finish(model.id) }
            } catch {
                logger.error("[local] download failed for \(model.id, privacy: .public): \(error)")
                await MainActor.run { [weak self] in
                    self?.failures[model.id] = Self.message(for: error)
                    self?.finish(model.id)
                }
            }
        }
    }

    private static func downloadBundle(
        _ model: LocalModel, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let destination = LocalModelStorage.file(for: model)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let url = URL(string:
            "https://huggingface.co/\(model.id)/resolve/\(model.revision)/\(model.fileName)")!

        let temp = try await ProgressReportingDownload.run(url: url, onProgress: onProgress)
        defer { try? FileManager.default.removeItem(at: temp) }

        // Verify BEFORE the file is moved into place. Once it is at the
        // destination it is indistinguishable from a good download, and the next
        // launch will happily memory-map it.
        let actual = try sha256OfFile(at: temp)
        guard actual.caseInsensitiveCompare(model.sha256) == .orderedSame else {
            logger.error("""
                [local] checksum mismatch for \(model.id, privacy: .public): \
                expected \(model.sha256, privacy: .public), got \(actual, privacy: .public)
                """)
            throw LocalInferenceError.loadFailed(
                "The downloaded model failed its integrity check and was discarded."
            )
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        onProgress(1.0)
    }

    /// SHA-256 of a file, read in chunks.
    ///
    /// `nonisolated` deliberately: this type is `@MainActor`, and hashing
    /// gigabytes on the main actor would freeze the UI for the length of the
    /// read. Nothing here touches actor state.
    nonisolated static func sha256OfFile(at url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // Read straight through rather than filling the unified buffer cache
        // with gigabytes that will never be read again.
        //
        // Belt and braces, and worth saying plainly: this was NOT the fix for
        // the memory problem below — adding it changed nothing, which is what
        // ruled out the page cache and pointed at the autorelease pool instead.
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)

        // EVERY CHUNK NEEDS ITS OWN AUTORELEASE POOL.
        //
        // `read(upToCount:)` hands back Data bridged from NSData, which is
        // autoreleased — so without a pool per iteration, all 2,468
        // one-megabyte chunks stay alive until the loop finishes, and
        // "streaming" hashing holds the entire file. Measured exactly that:
        // available memory fell by 2,479 MB against a 2,468 MB file — and with
        // the pool, 6,078 -> 6,082 MB, i.e. flat. Verification runs immediately
        // before a multi-gigabyte model load gated on that same number, so
        // without this the integrity check would have caused the very failure it
        // exists to prevent.
        var hasher = SHA256()
        var reading = true
        while reading {
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    reading = false
                    return
                }
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func cancel(_ repoID: String) {
        tasks[repoID]?.cancel()
        finish(repoID)
    }

    /// Drops a remembered failure. Called when the user deletes or abandons a
    /// model: an error from a download they no longer want is stale, and leaving
    /// it on the row makes the next state look broken.
    func clearFailure(_ repoID: String) {
        failures[repoID] = nil
    }

    private func finish(_ repoID: String) {
        tasks[repoID] = nil
        jobs[repoID] = nil
    }

    private static func message(for error: Error) -> String {
        if let local = error as? LocalInferenceError, let description = local.errorDescription {
            return description
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet:
                return "No internet connection."
            case NSURLErrorTimedOut:
                return "The download timed out. Try again."
            case NSURLErrorCancelled:
                return "Download cancelled."
            default:
                return "Network error (\(ns.code))."
            }
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return "Not enough free space on this device."
        }
        return error.localizedDescription
    }
}

// MARK: - Download with progress

/// A `URLSession` download that reports progress.
///
/// `URLSession.download(from:)` returns only when the whole file has arrived,
/// which for a 2.5 GB bundle is minutes of a progress bar sitting at zero. That
/// was tolerable when MLX's Hub client drove the visible downloads; now that
/// this is the only path, it is the download experience.
///
/// A delegate rather than `bytes(for:)`: `AsyncBytes` iterates one byte at a
/// time, which is the wrong shape for gigabytes.
private final class ProgressReportingDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    static func run(url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = ProgressReportingDownload(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The delegate's temp file is deleted the moment this returns, so it has
        // to be moved somewhere durable HERE, synchronously.
        let destination = FileManager.default.temporaryDirectory
            .appending(component: "litertlm-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
                try? FileManager.default.removeItem(at: destination)
                continuation?.resume(throwing: LocalInferenceError.loadFailed(
                    "download failed (HTTP \(http.statusCode))"))
            } else {
                continuation?.resume(returning: destination)
            }
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }   // success already resumed above
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
