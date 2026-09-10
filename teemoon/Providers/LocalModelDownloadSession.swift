//
//  LocalModelDownloadSession.swift
//  teemoon
//
//  The one URLSession model bundles come down through.
//
//  A BACKGROUND session: the transfer belongs to the system, not the process.
//  It keeps going after the app is suspended or killed, and iOS relaunches the
//  app to take delivery. That is the property a 2.5 GB pull on a phone needs —
//  a foreground session is frozen a few seconds after the user leaves, and
//  gone with the process.
//
//  Exactly one session per identifier may exist in a process; `shared` is the
//  only way to the background one. Tests build their own with an ephemeral
//  configuration and a URLProtocol stub.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "local.download")

final class LocalModelDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// The background session ids. Also what iOS hands the app delegate on a
    /// relaunch, so they must never change between builds — a renamed id orphans
    /// every transfer the daemon is still running for the old one.
    static let identifiers: [DownloadNetwork: String] = [
        .any: "ai.teemoon.local-models",
        .wifiOnly: "ai.teemoon.local-models.wifi",
    ]

    /// Two sessions rather than a per-request flag: the network allowance lives
    /// on the session configuration, which the daemon enforces while the app is
    /// dead, and resume data moves freely between them when the user changes
    /// their mind.
    static let any = LocalModelDownloadSession(configuration: configuration(for: .any))
    static let wifiOnly = LocalModelDownloadSession(configuration: configuration(for: .wifiOnly))

    private static func configuration(for network: DownloadNetwork) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: identifiers[network]!)
        // The user tapped download and is watching a progress bar; this is not
        // a prefetch the system may defer to overnight-on-charger.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        if network == .wifiOnly {
            // ALL THREE. `allowsExpensiveNetworkAccess = false` alone did not
            // stop an in-flight background transfer from carrying on over
            // cellular when wi-fi was switched off (iPhone 16 Pro, 2026-09-05).
            // `allowsCellularAccess` is the older, daemon-honoured switch;
            // expensive also covers a personal hotspot; constrained is Low
            // Data Mode. The app parks the transfer itself as well — see
            // `LocalModelDownloader.pathChanged`.
            config.allowsCellularAccess = false
            config.allowsExpensiveNetworkAccess = false
            config.allowsConstrainedNetworkAccess = false
        }
        return config
    }

    /// Where a task's bytes go the moment they land, before verification.
    ///
    /// `didFinishDownloadingTo` hands over a file that is deleted the instant the
    /// callback returns, so it has to be moved synchronously — and it goes to a
    /// durable spot rather than tmp/, because on a background relaunch the app
    /// may be killed again before it has hashed the file. A stranded
    /// `.unverified` is picked up on the next launch.
    static func landingFile(for repoID: String) -> URL {
        LocalModelStorage.unverifiedFile(for: repoID)
    }

    private struct Slot {
        var continuation: CheckedContinuation<URL, Error>?
        var pending: Result<URL, Error>?
        /// Which model a result that nobody has awaited yet belongs to, and
        /// whether its request refused cellular (nil when unknown).
        var repoID: String?
        var wifiOnly: Bool?
    }

    private let lock = NSLock()
    private var slots: [Int: Slot] = [:]
    private(set) var session: URLSession!

    /// Progress per repo id, 0...1, on the session's queue.
    var onProgress: (@Sendable (String, Double) -> Void)?
    /// Resume data the system produced when a task was cancelled or failed.
    var onResumeData: (@Sendable (String, Data) -> Void)?
    /// iOS delivered every queued event after relaunching the app in the
    /// background; the app's completion handler may be called.
    var onFinishedEvents: (@Sendable () -> Void)?

    init(configuration: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// A download for `url`, not yet resumed. `repoID` rides on the task as its
    /// description, which is the only state that survives a relaunch.
    func makeTask(url: URL, resumeData: Data?, repoID: String,
                  network: DownloadNetwork) -> URLSessionDownloadTask {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            // The request carries the restriction too: the configuration's
            // values are defaults a request may override, so say it here as
            // well rather than trust the precedence.
            var request = URLRequest(url: url)
            if network == .wifiOnly {
                request.allowsCellularAccess = false
                request.allowsExpensiveNetworkAccess = false
                request.allowsConstrainedNetworkAccess = false
            }
            task = session.downloadTask(with: request)
        }
        task.taskDescription = repoID
        return task
    }

    /// Download tasks the daemon still has for this session — after a relaunch,
    /// the transfers that outlived the process.
    func inFlightTasks() async -> [URLSessionDownloadTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.compactMap { $0 as? URLSessionDownloadTask })
            }
        }
    }

    /// The landed file, once `task` finishes. Cancelling the awaiting Swift task
    /// cancels the transfer while keeping its resume data.
    ///
    /// Safe to call after the task has already finished: an adopted task may
    /// complete between `inFlightTasks()` and this call, so the result waits in
    /// the slot until someone asks for it.
    func completion(of task: URLSessionDownloadTask) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                lock.lock()
                var slot = slots[task.taskIdentifier] ?? Slot()
                if let pending = slot.pending {
                    slots[task.taskIdentifier] = nil
                    lock.unlock()
                    continuation.resume(with: pending)
                    return
                }
                slot.continuation = continuation
                slots[task.taskIdentifier] = slot
                lock.unlock()
            }
        } onCancel: {
            task.cancel { _ in }   // resume data arrives through didCompleteWithError
        }
    }

    /// Results delivered while nobody was awaiting them, minus the tasks in
    /// `adopted`, which their own `completion(of:)` will collect.
    ///
    /// On a background relaunch the daemon can deliver a finished transfer
    /// before `reconnect()` has listed the in-flight tasks; by the time it
    /// does, the task is gone from the list and its result would sit here
    /// unread for the life of the process — which on the phone was two
    /// seconds. Taking a result removes it.
    func takeUnclaimedResults(adopted: Set<Int>)
        -> [(repoID: String, result: Result<URL, Error>, wifiOnly: Bool?)] {
        lock.lock(); defer { lock.unlock() }
        var taken: [(String, Result<URL, Error>, Bool?)] = []
        for (id, slot) in slots where slot.continuation == nil && !adopted.contains(id) {
            guard let pending = slot.pending, let repoID = slot.repoID else { continue }
            taken.append((repoID, pending, slot.wifiOnly))
            slots[id] = nil
        }
        return taken
    }

    private func deliver(_ result: Result<URL, Error>, for task: URLSessionTask) {
        lock.lock()
        var slot = slots[task.taskIdentifier] ?? Slot()
        if let continuation = slot.continuation {
            slots[task.taskIdentifier] = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        guard slot.pending == nil else { lock.unlock(); return }   // success already landed
        slot.pending = result
        slot.repoID = task.taskDescription
        slot.wifiOnly = task.originalRequest.map { !$0.allowsCellularAccess }
        slots[task.taskIdentifier] = slot
        lock.unlock()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, let repoID = downloadTask.taskDescription else { return }
        onProgress?(repoID, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        logger.info("[local] resumed \(downloadTask.taskDescription ?? "?", privacy: .public) at \(fileOffset) of \(expectedTotalBytes)")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let repoID = downloadTask.taskDescription else { return }
        let destination = Self.landingFile(for: repoID)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
                try? FileManager.default.removeItem(at: destination)
                deliver(.failure(LocalModelDownloadError.http(http.statusCode)), for: downloadTask)
            } else {
                deliver(.success(destination), for: downloadTask)
            }
        } catch {
            deliver(.failure(error), for: downloadTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }   // success was delivered with the file
        if let repoID = task.taskDescription,
           let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            onResumeData?(repoID, data)
        }
        deliver(.failure(error), for: task)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onFinishedEvents?()
    }
}
