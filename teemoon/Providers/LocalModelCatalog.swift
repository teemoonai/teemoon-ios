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

    /// Where a finished download waits for its checksum. Same directory as the
    /// bundle, so a relaunch can find it; a different name, so nothing can load
    /// it before it is verified.
    static func unverifiedFile(for repoID: String) -> URL {
        directory(for: repoID).appending(component: "download.unverified")
    }

    /// Resume data the system handed back for an interrupted download, kept
    /// next to the bundle so `delete(_:)` clears it with everything else.
    static func resumeDataFile(for repoID: String) -> URL {
        directory(for: repoID).appending(component: "download.resume")
    }

    static func resumeData(for repoID: String) -> Data? {
        try? Data(contentsOf: resumeDataFile(for: repoID))
    }

    static func saveResumeData(_ data: Data, for repoID: String) {
        let url = resumeDataFile(for: repoID)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("[local] could not save resume data for \(repoID, privacy: .public): \(error)")
        }
    }

    static func clearResumeData(for repoID: String) {
        try? FileManager.default.removeItem(at: resumeDataFile(for: repoID))
    }

    /// The last failure, on disk: a background relaunch that meets one is
    /// suspended seconds later, and the next foreground launch has to be able
    /// to say why the row went back to "download".
    static func failureFile(for repoID: String) -> URL {
        directory(for: repoID).appending(component: "download.failed")
    }

    static func failure(for repoID: String) -> String? {
        guard let text = try? String(contentsOf: failureFile(for: repoID), encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    static func saveFailure(_ message: String, for repoID: String) {
        let url = failureFile(for: repoID)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try message.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.error("[local] could not save failure for \(repoID, privacy: .public): \(error)")
        }
    }

    static func clearFailure(for repoID: String) {
        try? FileManager.default.removeItem(at: failureFile(for: repoID))
    }

    /// A download to start over the next time the app is on screen, with the
    /// network policy it had. Written when its link expired under a process
    /// about to be suspended; consumed by the restart, or by the user's own
    /// start.
    static func restartIntentFile(for repoID: String) -> URL {
        directory(for: repoID).appending(component: "download.restart")
    }

    static func restartIntent(for repoID: String) -> DownloadNetwork? {
        guard let text = try? String(contentsOf: restartIntentFile(for: repoID), encoding: .utf8)
        else { return nil }
        return DownloadNetwork(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func saveRestartIntent(_ network: DownloadNetwork, for repoID: String) {
        let url = restartIntentFile(for: repoID)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try network.rawValue.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.error("[local] could not save restart intent for \(repoID, privacy: .public): \(error)")
        }
    }

    static func clearRestartIntent(for repoID: String) {
        try? FileManager.default.removeItem(at: restartIntentFile(for: repoID))
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

/// What went wrong with a download, in one row-caption-sized line. These are
/// shown as-is under the model's name, so they stay short and say what to do.
enum LocalModelDownloadError: LocalizedError, Equatable {
    /// The bytes arrived but do not match the pinned digest; the file was discarded.
    case integrityCheckFailed
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .integrityCheckFailed: return "download failed its integrity check — try again"
        case .http(401), .http(403): return "download link expired — tap to start again"
        case .http(let status): return "download failed (HTTP \(status)) — try again"
        }
    }
}

/// Which networks a download may use. Picked per download, at the tap.
enum DownloadNetwork: String, Sendable, CaseIterable {
    /// Pauses off Wi-Fi and continues when it is back — what a download started
    /// on Wi-Fi does unless the user said otherwise.
    case wifiOnly
    /// Mobile data too. Only ever the result of an explicit choice.
    case any
}

/// Downloads model bundles, with progress, through a background session.
///
/// The transfer belongs to the system: it survives the app being suspended or
/// killed, and `reconnect()` picks it up again — mid-flight, with progress, or
/// already landed and waiting for its checksum. Cancelling or failing leaves
/// resume data behind, so the next start continues where it stopped.
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
        var network: DownloadNetwork = .any
        /// A wi-fi-only download the app has stopped because the phone is on
        /// mobile data. No task exists while parked; `pathChanged` restarts it
        /// from resume data when wi-fi is back.
        var parked = false
        /// Started over by the app after its link expired. A second expiry on
        /// such a job is reported, not retried — only the user's own start
        /// earns another.
        var restarted = false
    }

    /// Whether a scene is on screen, from `scenePhaseChanged`. A transfer the
    /// app starts while it is about to be suspended is deferred by the daemon
    /// indefinitely, so a restart waits for this.
    private var sceneIsActive = false

    /// The last path the app was told about; a wi-fi-only start on a
    /// restricted path parks immediately instead of trusting the daemon.
    private var pathIsRestricted = false

    /// Active + queued downloads, keyed by repo id.
    private(set) var jobs: [String: Job] = [:]
    /// Last failure per repo id, cleared when a retry starts.
    private(set) var failures: [String: String] = [:]

    /// One run per repo id. The token tells a finishing run whether it is still
    /// the current one — a cancel-and-restart replaces it before it has finished.
    private var runs: [String: UUID] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    private let sessions: [DownloadNetwork: LocalModelDownloadSession]
    /// What a relaunch may attach to and where its bytes come from. The app
    /// uses the shipped catalog and HuggingFace; tests use their own entries
    /// and a local server.
    private let catalog: [LocalModel]
    private let hub: URL

    /// iOS relaunched the app in the background to deliver a finished download.
    /// Held until every landed file has been verified, so the process is not
    /// suspended with a bundle half-hashed.
    @ObservationIgnored
    private var relaunchCompletion: (@Sendable () -> Void)?
    private var relaunchEventsDelivered = false
    /// `reconnect()` has run once. A relaunch that delivers a FAILURE leaves no
    /// landing file to hold the completion, so without this the process is
    /// suspended before the failure is even read (audit 2026-09-08, finding 8).
    private var hasReconnected = false

    /// Called on the main actor when a download has landed AND verified.
    ///
    /// Wired at the app entry point to register the model as a provider, so a
    /// finished download shows up as something you can run without a second
    /// "use" tap. Same shape as `ProviderStore.onActiveProviderChanged`: this
    /// type has no business knowing what a provider is.
    @ObservationIgnored
    var onInstalled: ((LocalModel) -> Void)?

    /// The app uses the two background sessions. Tests pass their own, backed by
    /// an ephemeral configuration and a URLProtocol stub.
    init(sessions: [DownloadNetwork: LocalModelDownloadSession],
         catalog: [LocalModel] = LocalModelCatalog.all,
         hub: URL = URL(string: "https://huggingface.co")!) {
        self.sessions = sessions
        self.catalog = catalog
        self.hub = hub
        for model in catalog {
            if let saved = LocalModelStorage.failure(for: model.id) { failures[model.id] = saved }
        }
        for session in sessions.values {
            session.onProgress = { [weak self] repoID, fraction in
                Task { @MainActor in
                    guard let self, let job = self.jobs[repoID] else { return }
                    if Int(job.fraction * 100) != Int(fraction * 100) {
                        DiagLog.note("[local] \(repoID) \(Int(fraction * 100))% via \(job.network.rawValue)")
                    }
                    self.jobs[repoID]?.fraction = fraction
                }
            }
            session.onResumeData = { repoID, data in
                LocalModelStorage.saveResumeData(data, for: repoID)
            }
            session.onFinishedEvents = { [weak self] in
                Task { @MainActor in
                    self?.relaunchEventsDelivered = true
                    self?.completeRelaunchIfDone()
                }
            }
        }
    }

    private convenience init() {
        var hub = URL(string: "https://huggingface.co")!
        #if DEBUG
        // A UI test can stand in for the Hub — a local server that hands back
        // the wrong bytes is the only way to watch the failure rows on a
        // simulator without waiting on a 2.4 GB transfer.
        if let override = ProcessInfo.processInfo.environment["UITEST_HUB_BASE_URL"],
           let url = URL(string: override) {
            hub = url
        }
        #endif
        self.init(sessions: [.wifiOnly: .wifiOnly, .any: .any], hub: hub)
    }

    /// A downloader with jobs already in flight and no tasks behind them, for
    /// previews.
    ///
    /// Mid-download is a state the real singleton can only reach by actually
    /// pulling gigabytes, so without this the progress row — bar, percentage,
    /// cancel — could not be looked at before shipping.
    static func previewing(_ jobs: [(LocalModel, Double)],
                           network: DownloadNetwork = .any) -> LocalModelDownloader {
        let downloader = LocalModelDownloader(sessions: [:])
        for (model, fraction) in jobs {
            downloader.jobs[model.id] = Job(id: model.id, fraction: fraction, model: model, network: network)
        }
        return downloader
    }

    func isDownloading(_ repoID: String) -> Bool { jobs[repoID] != nil }

    func progress(_ repoID: String) -> Double? { jobs[repoID]?.fraction }

    func network(_ repoID: String) -> DownloadNetwork? { jobs[repoID]?.network }

    func failure(_ repoID: String) -> String? { failures[repoID] }

    /// Starts, resumes, or re-homes a download.
    ///
    /// Resume data from an earlier cancel or failure is used when present. A
    /// download already running under a different network choice is cancelled
    /// (keeping its resume data) and continued under the new one.
    func start(_ model: LocalModel, network: DownloadNetwork = .any) {
        if let job = jobs[model.id], job.network == network, !job.parked { return }
        record(failure: nil, for: model.id)
        LocalModelStorage.clearRestartIntent(for: model.id)
        jobs[model.id] = Job(id: model.id, fraction: jobs[model.id]?.fraction ?? 0,
                             model: model, network: network)
        if network == .wifiOnly && pathIsRestricted {
            park(model.id)
            return
        }
        launch(model, network: network)
    }

    /// The app's own wi-fi-only enforcement, fed from `NetworkPathObserver`.
    ///
    /// The daemon is told three ways not to use cellular, and still carried an
    /// in-flight transfer onto mobile data when wi-fi was switched off. So
    /// while the app is alive it does not rely on that: a wi-fi-only transfer is
    /// cancelled (keeping its resume data) the moment the path is expensive or
    /// constrained, and started again from that data when it is not.
    func pathChanged(isMobileData: Bool, isConstrained: Bool) {
        pathIsRestricted = isMobileData || isConstrained
        logger.info("[local] path mobileData=\(isMobileData) constrained=\(isConstrained) jobs=\(self.jobs.count)")
        DiagLog.note("[local] pathChanged mobileData=\(isMobileData) constrained=\(isConstrained) jobs=\(jobs.values.map { "\($0.id.split(separator: "/").last ?? "?"):\($0.network.rawValue):\(Int($0.fraction * 100))%:\($0.parked ? "parked" : "running")" })")
        if pathIsRestricted {
            // Not straight away. On the phone the default route flips to
            // cellular for a few seconds during a wi-fi hiccup with the wi-fi
            // icon never leaving the status bar; parking on every blip cancels
            // and relaunches the transfer for nothing. The daemon's own
            // `allowsCellularAccess = false` covers the wait.
            guard pendingPark == nil else { return }
            pendingPark = Task { [weak self] in
                try? await Task.sleep(for: self?.parkDelay ?? .zero)
                guard !Task.isCancelled, let self, self.pathIsRestricted else { return }
                self.pendingPark = nil
                self.parkWifiOnlyJobs()
            }
        } else {
            pendingPark?.cancel()
            pendingPark = nil
            for job in jobs.values where job.network == .wifiOnly && job.parked {
                logger.info("[local] wi-fi back, resuming \(job.id, privacy: .public)")
                DiagLog.note("[local] wi-fi back, resuming \(job.id)")
                jobs[job.id]?.parked = false
                launch(job.model, network: .wifiOnly)
            }
        }
    }

    /// How long the path must stay on mobile data before a wi-fi-only transfer
    /// is parked. Tests shorten it.
    var parkDelay: Duration = .seconds(4)
    private var pendingPark: Task<Void, Never>?

    private func parkWifiOnlyJobs() {
        for job in jobs.values where job.network == .wifiOnly && !job.parked {
            logger.info("[local] parking \(job.id, privacy: .public) at \(Int(job.fraction * 100))%")
            DiagLog.note("[local] parking \(job.id) at \(Int(job.fraction * 100))%")
            park(job.id)
        }
    }

    func isParked(_ repoID: String) -> Bool { jobs[repoID]?.parked ?? false }

    /// Stops the transfer but keeps the job, so the row still shows where it got
    /// to and says it is waiting.
    private func park(_ repoID: String) {
        tasks[repoID]?.cancel()
        tasks[repoID] = nil
        runs[repoID] = nil          // the dying run sees a foreign token and leaves the job alone
        jobs[repoID]?.parked = true
    }

    /// Creates the transfer for an existing job, after any previous run for the
    /// model has finished writing its resume data.
    private func launch(_ model: LocalModel, network: DownloadNetwork) {
        guard let session = sessions[network] else { return }
        let previous = tasks[model.id]
        previous?.cancel()
        let token = UUID()
        let url = url(for: model)
        runs[model.id] = token
        tasks[model.id] = Task { [weak self] in
            // The old run writes its resume data as it dies; only then is there
            // something to continue from.
            await previous?.value
            let resume = LocalModelStorage.resumeData(for: model.id)
            let task = session.makeTask(url: url, resumeData: resume, repoID: model.id, network: network)
            DiagLog.note("[local] launch \(model.id) network=\(network.rawValue) resume=\(resume != nil)")
            task.resume()
            await self?.run(model, task: task, session: session, resuming: resume != nil, token: token)
        }
    }

    /// Re-attaches to whatever outlived the last process: transfers the daemon
    /// is still running, and finished files that were never verified. Call once
    /// at launch, before any UI can start a download.
    func reconnect() async {
        var inFlight = Set<String>()
        var adopted = Set<Int>()
        for (network, session) in sessions {
            for task in await session.inFlightTasks() {
                guard let repoID = task.taskDescription,
                      let model = catalog.first(where: { $0.id == repoID }),
                      tasks[repoID] == nil else {
                    // Nothing to attach it to — a retired model, or a duplicate.
                    task.cancel()
                    continue
                }
                inFlight.insert(repoID)
                adopted.insert(task.taskIdentifier)
                jobs[repoID] = Job(id: repoID, fraction: 0, model: model, network: network)
                let token = UUID()
                runs[repoID] = token
                tasks[repoID] = Task { [weak self] in
                    await self?.run(model, task: task, session: session, resuming: false, token: token)
                }
            }
        }
        // Finished before the list above was read, so no longer on it. The
        // daemon can deliver a whole transfer in the first milliseconds of a
        // background relaunch; a result left unread here vanishes with the
        // process, and the phone showed exactly that.
        var seen = Set<ObjectIdentifier>()
        for (network, session) in sessions where seen.insert(ObjectIdentifier(session)).inserted {
            for (repoID, result, wifiOnly) in session.takeUnclaimedResults(adopted: adopted) {
                guard let model = catalog.first(where: { $0.id == repoID }), tasks[repoID] == nil else { continue }
                let network = wifiOnly.map { $0 ? DownloadNetwork.wifiOnly : .any } ?? network
                inFlight.insert(repoID)
                switch result {
                case .success(let landed):
                    jobs[repoID] = Job(id: repoID, fraction: 1, model: model, network: network)
                    let token = UUID()
                    runs[repoID] = token
                    tasks[repoID] = Task { [weak self] in
                        await self?.install(model, from: landed, token: token)
                    }
                case .failure(let error):
                    logger.error("[local] \(repoID, privacy: .public) finished unattached: \(error)")
                    jobs[repoID] = Job(id: repoID, fraction: 0, model: model, network: network)
                    if !scheduleRestartIfLinkExpired(model, after: error) {
                        record(failure: Self.message(for: error), for: repoID)
                        finish(repoID)
                    }
                }
            }
        }
        for model in catalog where !inFlight.contains(model.id) && tasks[model.id] == nil {
            let landed = LocalModelStorage.unverifiedFile(for: model.id)
            guard FileManager.default.fileExists(atPath: landed.path) else { continue }
            jobs[model.id] = Job(id: model.id, fraction: 1, model: model)
            let token = UUID()
            runs[model.id] = token
            tasks[model.id] = Task { [weak self] in
                await self?.install(model, from: landed, token: token)
            }
        }
        // Adopted on mobile data: park now, so the row says why the daemon is
        // holding it rather than showing a frozen percentage.
        if pathIsRestricted { parkWifiOnlyJobs() }
        if sceneIsActive { restartExpiredLinks() }
        hasReconnected = true
        completeRelaunchIfDone()
    }

    /// Fed from the scene phase. Going active is when a download whose link
    /// expired is started over: the process stays alive to drive it.
    func scenePhaseChanged(isActive: Bool) {
        sceneIsActive = isActive
        if isActive { restartExpiredLinks() }
    }

    /// iOS relaunched the app to deliver a download and will suspend it once
    /// this handler is called; hold it until every landed file is verified.
    func handleBackgroundRelaunch(completion: @escaping @Sendable () -> Void) {
        // The events may already have been delivered — the sessions are created
        // in the app's init, before UIKit hands over this handler.
        relaunchCompletion = completion
        completeRelaunchIfDone()
    }

    private func completeRelaunchIfDone() {
        guard relaunchEventsDelivered, hasReconnected, let completion = relaunchCompletion else { return }
        let stillVerifying = catalog.contains {
            FileManager.default.fileExists(atPath: LocalModelStorage.unverifiedFile(for: $0.id).path)
        }
        guard !stillVerifying else { return }
        relaunchCompletion = nil
        completion()
    }

    private func run(_ model: LocalModel, task: URLSessionDownloadTask,
                     session: LocalModelDownloadSession, resuming: Bool, token: UUID) async {
        do {
            let landed: URL
            do {
                landed = try await session.completion(of: task)
            } catch where resuming && !Task.isCancelled && !Self.isCancellation(error) {
                // Stale resume data — the CDN's signed URL expired, or the daemon
                // dropped the partial file. Once, from the start; a second
                // failure is a real one.
                logger.error("[local] resume of \(model.id, privacy: .public) failed, restarting: \(error)")
                LocalModelStorage.clearResumeData(for: model.id)
                jobs[model.id]?.fraction = 0
                let fresh = session.makeTask(url: url(for: model), resumeData: nil, repoID: model.id,
                                             network: jobs[model.id]?.network ?? .any)
                fresh.resume()
                landed = try await session.completion(of: fresh)
            }
            LocalModelStorage.clearResumeData(for: model.id)
            await install(model, from: landed, token: token)
        } catch {
            guard runs[model.id] == token else { return }   // replaced by a restart
            if !(Task.isCancelled || Self.isCancellation(error)) {
                logger.error("[local] download failed for \(model.id, privacy: .public): \(error)")
                if scheduleRestartIfLinkExpired(model, after: error) { return }
                record(failure: Self.message(for: error), for: model.id)
            }
            finish(model.id)
        }
    }

    /// Verifies a landed file and moves it into place.
    ///
    /// Bracketed as background work: on a relaunch-to-deliver the system gives
    /// seconds, not minutes, and hashing gigabytes is the step that must not be
    /// suspended halfway. If it is anyway, the `.unverified` file is still
    /// there for the next `reconnect()`.
    private func install(_ model: LocalModel, from landed: URL, token: UUID) async {
        let bg = BackgroundWork.begin("model verify") {}
        defer { BackgroundWork.end(bg) }
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.verifyAndPlace(model, from: landed)
            }.value
            guard runs[model.id] == token else { return }
            // Trust the file, not the callback: a "finished" download that left
            // nothing behind is a failure, and reporting it as success just moves
            // the error to the first chat instead.
            if !LocalModelStorage.isInstalled(model) {
                record(failure: "The download finished but the model file is missing. Try again.", for: model.id)
            } else {
                record(failure: nil, for: model.id)
                LocalModelStorage.clearRestartIntent(for: model.id)
                // Only after the file is confirmed on disk — the checksum has
                // already been verified before the move, so reaching here means
                // it is genuinely runnable.
                onInstalled?(model)
            }
        } catch {
            guard runs[model.id] == token else { return }
            record(failure: Self.message(for: error), for: model.id)
        }
        finish(model.id)
    }

    /// Verify BEFORE the file is moved into place. Once it is at the destination
    /// it is indistinguishable from a good download, and the next launch will
    /// happily memory-map it.
    nonisolated static func verifyAndPlace(_ model: LocalModel, from landed: URL) throws {
        defer { try? FileManager.default.removeItem(at: landed) }
        let actual = try sha256OfFile(at: landed)
        guard actual.caseInsensitiveCompare(model.sha256) == .orderedSame else {
            logger.error("""
                [local] checksum mismatch for \(model.id, privacy: .public): \
                expected \(model.sha256, privacy: .public), got \(actual, privacy: .public)
                """)
            throw LocalModelDownloadError.integrityCheckFailed
        }
        let destination = LocalModelStorage.file(for: model)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: landed, to: destination)
    }

    nonisolated func url(for model: LocalModel) -> URL {
        hub.appending(path: "\(model.id)/resolve/\(model.revision)/\(model.fileName)")
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

    /// Stops the transfer. Its resume data is kept, so the next `start` continues.
    func cancel(_ repoID: String) {
        tasks[repoID]?.cancel()
        finish(repoID)
    }

    /// Drops a remembered failure. Called when the user deletes or abandons a
    /// model: an error from a download they no longer want is stale, and leaving
    /// it on the row makes the next state look broken.
    func clearFailure(_ repoID: String) {
        record(failure: nil, for: repoID)
        LocalModelStorage.clearRestartIntent(for: repoID)
    }

    private func record(failure message: String?, for repoID: String) {
        failures[repoID] = message
        if let message {
            LocalModelStorage.saveFailure(message, for: repoID)
        } else {
            LocalModelStorage.clearFailure(for: repoID)
        }
    }

    /// A delivered download with status 401/403 is the CDN's signed link having
    /// expired under a transfer the daemon paused — off wi-fi for longer than
    /// the link's hour. The partial is gone; the row shows why, and the
    /// download is started over the next time a scene is active. Do NOT start
    /// the new task here: a background relaunch is suspended seconds later and
    /// the daemon then defers the transfer for good.
    private func scheduleRestartIfLinkExpired(_ model: LocalModel, after error: Error) -> Bool {
        guard Self.isExpiredLink(error), let job = jobs[model.id], !job.restarted else { return false }
        LocalModelStorage.clearResumeData(for: model.id)
        LocalModelStorage.saveRestartIntent(job.network, for: model.id)
        record(failure: Self.message(for: error), for: model.id)
        DiagLog.note("[local] link expired for \(model.id), starting over on \(job.network.rawValue) when active")
        finish(model.id)
        if sceneIsActive { restartExpiredLinks() }
        return true
    }

    private func restartExpiredLinks() {
        for model in catalog where tasks[model.id] == nil {
            guard let network = LocalModelStorage.restartIntent(for: model.id) else { continue }
            DiagLog.note("[local] starting \(model.id) over on \(network.rawValue) after its link expired")
            start(model, network: network)      // consumes the intent
            jobs[model.id]?.restarted = true
        }
    }

    nonisolated private static func isExpiredLink(_ error: Error) -> Bool {
        guard let download = error as? LocalModelDownloadError, case .http(let status) = download
        else { return false }
        return status == 401 || status == 403
    }

    private func finish(_ repoID: String) {
        tasks[repoID] = nil
        runs[repoID] = nil
        jobs[repoID] = nil
        completeRelaunchIfDone()
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    private static func message(for error: Error) -> String {
        if let download = error as? LocalModelDownloadError, let description = download.errorDescription {
            return description
        }
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

