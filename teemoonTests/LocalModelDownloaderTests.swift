//
//  LocalModelDownloaderTests.swift
//  teemoonTests
//
//  A model download has to survive the user leaving: backgrounding, the app
//  being killed, the phone walking off wi-fi. A user reported the opposite —
//  "it doesn't restart" after navigating away — and the download of the day was
//  a foreground URLSession with no resume data and nothing to re-attach on
//  launch, so it was exactly right. These pin the replacement:
//
//  - the transfer runs through a background session (`LocalModelDownloadSession`)
//    whose delegate can hand a result to a caller that arrives late;
//  - a cancel or failure leaves resume data behind, and the next start uses it;
//  - stale resume data falls back to a fresh download, once;
//  - a landed-but-unverified file is picked up by `reconnect()`;
//  - a tap on mobile data asks first (`CellularDownloadGate`).
//
//  The wire is a URLProtocol stub bound to an ephemeral configuration, so
//  nothing here touches the network or the shared background sessions.
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

// MARK: - Stub server

/// Serves one blob, honouring `Range`, so URLSession's own resume machinery can
/// be exercised end to end. Scripted per test through `plan`.
private final class DownloadStub: URLProtocol, @unchecked Sendable {
    struct Plan: @unchecked Sendable {
        var body: Data
        /// Stop after this many bytes and never finish — the client has to cancel.
        var stallAfter: Int?
        /// Answer every request with this status and an empty body.
        var status: Int?
    }

    nonisolated(unsafe) static var plan = Plan(body: Data())
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    static func reset(_ p: Plan) {
        lock.lock(); defer { lock.unlock() }
        plan = p
        requests = []
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    // Garbage resume data yields a task whose request has no URL at all; let
    // URLSession fail that one itself, the way it would against the real CDN.
    override class func canInit(with request: URLRequest) -> Bool { request.url != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let plan = Self.plan
        Self.requests.append(request)
        Self.lock.unlock()

        let url = request.url!
        if let status = plan.status {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "0"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        // `Range: bytes=N-` is how a resumed download asks for the rest.
        var start = 0
        if let range = request.value(forHTTPHeaderField: "Range"),
           range.hasPrefix("bytes="),
           let n = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
            start = n
        }
        let total = plan.body.count
        var headers = [
            "Accept-Ranges": "bytes",
            "ETag": "\"blob-v1\"",
            "Content-Length": "\(total - start)",
        ]
        if start > 0 { headers["Content-Range"] = "bytes \(start)-\(total - 1)/\(total)" }
        let response = HTTPURLResponse(url: url, statusCode: start > 0 ? 206 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let end = plan.stallAfter.map { min(start + $0, total) } ?? total
        // In slices, so a stall leaves a partial file rather than nothing.
        var offset = start
        while offset < end {
            let next = min(offset + 4096, end)
            client?.urlProtocol(self, didLoad: plan.body[offset..<next])
            offset = next
        }
        if plan.stallAfter == nil {
            client?.urlProtocolDidFinishLoading(self)
        }
        // else: hang until stopLoading — the cancel path.
    }

    override func stopLoading() {}
}

// MARK: - Fixture

@MainActor
private struct Rig {
    let model: LocalModel
    let payload: Data
    let session: LocalModelDownloadSession
    let downloader: LocalModelDownloader
    var installed: [String] = []

    init(payloadSize: Int = 64 * 1024, sha256Override: String? = nil) {
        payload = Data((0..<payloadSize).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        model = LocalModel(
            id: "test/dl-\(UUID().uuidString.prefix(8))", displayName: "Test blob",
            sizeMB: 1, blurb: "", supportsTools: false, fileName: "blob.litertlm",
            revision: "r1", sha256: sha256Override ?? digest
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadStub.self]
        session = LocalModelDownloadSession(configuration: config)
        downloader = LocalModelDownloader(
            sessions: [.any: session, .wifiOnly: session],
            catalog: [model],
            hub: URL(string: "https://stub.invalid")!
        )
    }

    func cleanUp() {
        try? LocalModelStorage.delete(model)
    }

    /// Polls until the job is gone; the downloader has no completion hook
    /// besides `onInstalled`, and a failure has none.
    func waitUntilIdle(timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while downloader.isDownloading(model.id) {
            guard ContinuousClock.now < deadline else {
                throw TimeoutError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    struct TimeoutError: Error {}
}

// MARK: - Tests

@Suite("Local model downloader", .serialized)
@MainActor
struct LocalModelDownloaderTests {

    @Test func downloadLandsVerifiesAndInstalls() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        DownloadStub.reset(.init(body: rig.payload))

        var installed: [String] = []
        rig.downloader.onInstalled = { installed.append($0.id) }
        rig.downloader.start(rig.model)
        #expect(rig.downloader.isDownloading(rig.model.id))
        try await rig.waitUntilIdle()

        #expect(installed == [rig.model.id])
        #expect(LocalModelStorage.isInstalled(rig.model))
        #expect(rig.downloader.failure(rig.model.id) == nil)
        #expect(try Data(contentsOf: LocalModelStorage.file(for: rig.model)) == rig.payload)
        #expect(!FileManager.default.fileExists(atPath: LocalModelStorage.unverifiedFile(for: rig.model.id).path),
                "the landing file must not outlive verification")
        #expect(LocalModelStorage.resumeData(for: rig.model.id) == nil)
    }

    /// The URL is built from the injected hub, so the stub sees the same path
    /// shape the real CDN would.
    @Test func requestTargetsTheHubResolvePath() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        DownloadStub.reset(.init(body: rig.payload))
        rig.downloader.start(rig.model)
        try await rig.waitUntilIdle()
        let path = DownloadStub.recordedRequests().first?.url?.path ?? ""
        #expect(path == "/\(rig.model.id)/resolve/r1/blob.litertlm")
    }

    @Test func checksumMismatchIsDiscardedAndReported() async throws {
        let rig = Rig(sha256Override: String(repeating: "0", count: 64))
        defer { rig.cleanUp() }
        DownloadStub.reset(.init(body: rig.payload))

        var installed: [String] = []
        rig.downloader.onInstalled = { installed.append($0.id) }
        rig.downloader.start(rig.model)
        try await rig.waitUntilIdle()

        #expect(installed.isEmpty)
        #expect(!LocalModelStorage.isInstalled(rig.model))
        #expect(rig.downloader.failure(rig.model.id)?.contains("integrity") == true)
        #expect(!FileManager.default.fileExists(atPath: LocalModelStorage.unverifiedFile(for: rig.model.id).path))
    }

    @Test func httpErrorIsAFailureNotAnInstall() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        DownloadStub.reset(.init(body: Data(), status: 404))
        rig.downloader.start(rig.model)
        try await rig.waitUntilIdle()
        #expect(rig.downloader.failure(rig.model.id)?.contains("404") == true)
        #expect(!LocalModelStorage.isInstalled(rig.model))
    }

    /// The user's case: cancel mid-way (what a kill or a network change does to a
    /// foreground session), start again, and the second request asks for the
    /// rest rather than the whole file.
    @Test func cancelKeepsResumeDataAndTheNextStartResumes() async throws {
        let rig = Rig(payloadSize: 256 * 1024)
        defer { rig.cleanUp() }
        DownloadStub.reset(.init(body: rig.payload, stallAfter: 100 * 1024))

        rig.downloader.start(rig.model)
        // Let the first slices land before cancelling.
        let deadline = ContinuousClock.now + .seconds(5)
        while (rig.downloader.progress(rig.model.id) ?? 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((rig.downloader.progress(rig.model.id) ?? 0) > 0, "no bytes arrived before the cancel")

        rig.downloader.cancel(rig.model.id)
        #expect(!rig.downloader.isDownloading(rig.model.id))

        // Resume data is written by the delegate, off the main actor.
        let resumeDeadline = ContinuousClock.now + .seconds(5)
        while LocalModelStorage.resumeData(for: rig.model.id) == nil, ContinuousClock.now < resumeDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(LocalModelStorage.resumeData(for: rig.model.id) != nil, "cancel produced no resume data")

        // Second act: the server now finishes what it is asked for.
        DownloadStub.reset(.init(body: rig.payload))
        var installed: [String] = []
        rig.downloader.onInstalled = { installed.append($0.id) }
        rig.downloader.start(rig.model)
        try await rig.waitUntilIdle()

        #expect(installed == [rig.model.id])
        #expect(try Data(contentsOf: LocalModelStorage.file(for: rig.model)) == rig.payload)
        let resumed = DownloadStub.recordedRequests().first
        let range = resumed?.value(forHTTPHeaderField: "Range") ?? ""
        #expect(range.hasPrefix("bytes="), "the restart fetched from zero instead of resuming (Range: '\(range)')")
        #expect(LocalModelStorage.resumeData(for: rig.model.id) == nil, "resume data must be cleared after success")
    }

    /// THE critical one: a wi-fi-only download must stop the moment the phone is
    /// on mobile data, whatever the daemon does, and continue from where it was
    /// once wi-fi is back. Pinned after an iPhone kept pulling over cellular
    /// with only the session flags set.
    @Test func wifiOnlyDownloadParksOnMobileDataAndResumesOnWifi() async throws {
        let rig = Rig(payloadSize: 256 * 1024)
        defer { rig.cleanUp() }
        DownloadStub.reset(.init(body: rig.payload, stallAfter: 100 * 1024))

        rig.downloader.parkDelay = .milliseconds(150)
        rig.downloader.pathChanged(isMobileData: false, isConstrained: false)
        rig.downloader.start(rig.model, network: .wifiOnly)
        let deadline = ContinuousClock.now + .seconds(5)
        while (rig.downloader.progress(rig.model.id) ?? 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((rig.downloader.progress(rig.model.id) ?? 0) > 0)

        // A route blip: cellular for less than the park delay. Nothing happens.
        rig.downloader.pathChanged(isMobileData: true, isConstrained: false)
        try await Task.sleep(for: .milliseconds(40))
        rig.downloader.pathChanged(isMobileData: false, isConstrained: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!rig.downloader.isParked(rig.model.id), "a sub-delay blip parked the transfer")
        #expect(LocalModelStorage.resumeData(for: rig.model.id) == nil, "a blip cancelled the transfer")

        // Wi-fi really goes away: parked once the delay has passed.
        rig.downloader.pathChanged(isMobileData: true, isConstrained: false)
        #expect(!rig.downloader.isParked(rig.model.id), "parked before the delay elapsed")
        let parkDeadline = ContinuousClock.now + .seconds(3)
        while !rig.downloader.isParked(rig.model.id), ContinuousClock.now < parkDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(rig.downloader.isParked(rig.model.id))
        #expect(rig.downloader.isDownloading(rig.model.id), "the row must keep showing the parked download")
        let resumeDeadline = ContinuousClock.now + .seconds(5)
        while LocalModelStorage.resumeData(for: rig.model.id) == nil, ContinuousClock.now < resumeDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(LocalModelStorage.resumeData(for: rig.model.id) != nil, "parking produced no resume data")
        let requestsWhileParked = DownloadStub.recordedRequests().count

        // Still on mobile data: nothing may be fetched, and a fresh start parks too.
        try await Task.sleep(for: .milliseconds(200))
        #expect(DownloadStub.recordedRequests().count == requestsWhileParked, "a request went out while parked")
        rig.downloader.start(rig.model, network: .wifiOnly)
        #expect(rig.downloader.isParked(rig.model.id))

        // Wi-fi is back: continue, and from the offset rather than from zero.
        DownloadStub.reset(.init(body: rig.payload))
        var installed: [String] = []
        rig.downloader.onInstalled = { installed.append($0.id) }
        rig.downloader.pathChanged(isMobileData: false, isConstrained: false)
        #expect(!rig.downloader.isParked(rig.model.id))
        try await rig.waitUntilIdle()

        #expect(installed == [rig.model.id])
        let range = DownloadStub.recordedRequests().first?.value(forHTTPHeaderField: "Range") ?? ""
        #expect(range.hasPrefix("bytes="), "the restart after wi-fi returned began from zero")
    }

    /// The session and request both refuse cellular for a wi-fi-only download.
    @Test func wifiOnlyRequestsRefuseCellular() {
        let config = URLSessionConfiguration.ephemeral
        let session = LocalModelDownloadSession(configuration: config)
        let task = session.makeTask(url: URL(string: "https://stub.invalid/x")!, resumeData: nil,
                                    repoID: "test/x", network: .wifiOnly)
        #expect(task.originalRequest?.allowsCellularAccess == false)
        #expect(task.originalRequest?.allowsExpensiveNetworkAccess == false)
        #expect(task.originalRequest?.allowsConstrainedNetworkAccess == false)
        let open = session.makeTask(url: URL(string: "https://stub.invalid/x")!, resumeData: nil,
                                    repoID: "test/x", network: .any)
        #expect(open.originalRequest?.allowsCellularAccess == true)
    }

    /// Resume data that the system can no longer honour — the CDN's signed URL
    /// expired, the partial file was purged — must not strand the user on an
    /// error. One fresh attempt, and it succeeds.
    @Test func staleResumeDataFallsBackToAFreshDownload() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        LocalModelStorage.saveResumeData(Data("not resume data".utf8), for: rig.model.id)
        DownloadStub.reset(.init(body: rig.payload))

        var installed: [String] = []
        rig.downloader.onInstalled = { installed.append($0.id) }
        rig.downloader.start(rig.model)
        try await rig.waitUntilIdle()

        #expect(installed == [rig.model.id], "failure: \(rig.downloader.failure(rig.model.id) ?? "none")")
        #expect(LocalModelStorage.resumeData(for: rig.model.id) == nil)
    }

    /// The process died after the bytes landed but before the hash finished.
    /// The next launch must finish the job rather than offer the download again.
    @Test func reconnectVerifiesAStrandedLandingFile() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        let landing = LocalModelStorage.unverifiedFile(for: rig.model.id)
        try FileManager.default.createDirectory(at: landing.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try rig.payload.write(to: landing)

        var installed: [String] = []
        rig.downloader.onInstalled = { installed.append($0.id) }
        await rig.downloader.reconnect()
        try await rig.waitUntilIdle()

        #expect(installed == [rig.model.id])
        #expect(LocalModelStorage.isInstalled(rig.model))
        #expect(!FileManager.default.fileExists(atPath: landing.path))
    }

    /// A background relaunch's completion handler is held until the landed file
    /// has been verified — calling it earlier lets iOS suspend the app with the
    /// hash half done.
    @Test func relaunchCompletionWaitsForVerification() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        let landing = LocalModelStorage.unverifiedFile(for: rig.model.id)
        try FileManager.default.createDirectory(at: landing.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try rig.payload.write(to: landing)

        let completed = Completed()
        rig.downloader.handleBackgroundRelaunch { completed.mark() }
        rig.session.onFinishedEvents?()   // what the system does once events are delivered
        try await Task.sleep(for: .milliseconds(100))
        #expect(!completed.value, "completion fired with an unverified file still on disk")

        await rig.downloader.reconnect()
        try await rig.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(50))
        #expect(completed.value, "completion never fired after verification")
    }

    /// A relaunch that delivers a FAILURE leaves no landing file to hold the
    /// completion, so it must wait for `reconnect()` to have read the result —
    /// otherwise the process is suspended before the reason is written.
    @Test func relaunchCompletionWaitsForReconnectToReadADeliveredFailure() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        DownloadStub.reset(.init(body: Data(), status: 403))
        let task = rig.session.makeTask(url: URL(string: "https://stub.invalid/x")!, resumeData: nil,
                                        repoID: rig.model.id, network: .wifiOnly)
        task.resume()
        try await waitFor { DownloadStub.recordedRequests().count == 1 }
        try await Task.sleep(for: .milliseconds(200))

        let completed = Completed()
        rig.downloader.handleBackgroundRelaunch { completed.mark() }
        rig.session.onFinishedEvents?()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!completed.value, "completion fired before reconnect() had read the delivered failure")

        await rig.downloader.reconnect()
        try await rig.waitUntilIdle()
        #expect(completed.value, "completion never fired after reconnect()")
        #expect(rig.downloader.failure(rig.model.id)?.contains("expired") == true)
        #expect(LocalModelStorage.restartIntent(for: rig.model.id) == .wifiOnly)
    }

    /// The phone, 2026-09-07: the daemon delivered a finished download — a 403,
    /// the CDN link had expired while the transfer waited for wi-fi — before
    /// `reconnect()` had listed the in-flight tasks, so nothing ever read it
    /// and the row went back to "download" with no reason. A result nobody
    /// awaited is drained, and its reason outlives the process.
    @Test func reconnectRecordsAFailureDeliveredBeforeAdoption() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        DownloadStub.reset(.init(body: Data(), status: 404))
        let task = rig.session.makeTask(url: URL(string: "https://stub.invalid/x")!, resumeData: nil,
                                        repoID: rig.model.id, network: .any)
        task.resume()
        try await waitFor { DownloadStub.recordedRequests().count == 1 }
        try await Task.sleep(for: .milliseconds(200))   // the delegate has delivered by now

        await rig.downloader.reconnect()
        try await rig.waitUntilIdle()
        #expect(rig.downloader.failure(rig.model.id)?.contains("404") == true)

        let relaunched = LocalModelDownloader(sessions: [.any: rig.session], catalog: [rig.model],
                                              hub: URL(string: "https://stub.invalid")!)
        #expect(relaunched.failure(rig.model.id) == rig.downloader.failure(rig.model.id),
                "the reason did not survive a relaunch")
    }

    /// 401/403 on a delivered download is the signed link having expired under
    /// a paused transfer. The bytes are gone, and the process is a background
    /// relaunch about to be suspended, so nothing is started there — the row
    /// says why, and the restart waits for a scene to be active. It runs on
    /// the network policy the transfer had, once: a second expiry is reported.
    @Test func expiredLinkDeliveredOnRelaunchStartsOverWhenNextOnScreen() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        DownloadStub.reset(.init(body: Data(), status: 403))
        let task = rig.session.makeTask(url: URL(string: "https://stub.invalid/x")!, resumeData: nil,
                                        repoID: rig.model.id, network: .wifiOnly)
        task.resume()
        try await waitFor { DownloadStub.recordedRequests().count == 1 }
        try await Task.sleep(for: .milliseconds(200))

        await rig.downloader.reconnect()            // scene not active: a background relaunch
        try await rig.waitUntilIdle()
        #expect(DownloadStub.recordedRequests().count == 1, "a restart was launched into a relaunch")
        #expect(rig.downloader.failure(rig.model.id)?.contains("expired") == true)
        #expect(LocalModelStorage.restartIntent(for: rig.model.id) == .wifiOnly)

        // The next foreground launch is a fresh process.
        let relaunched = LocalModelDownloader(sessions: [.any: rig.session, .wifiOnly: rig.session],
                                              catalog: [rig.model], hub: URL(string: "https://stub.invalid")!)
        #expect(relaunched.failure(rig.model.id)?.contains("expired") == true)
        relaunched.scenePhaseChanged(isActive: true)
        #expect(relaunched.isDownloading(rig.model.id), "going active did not start the download over")
        #expect(LocalModelStorage.restartIntent(for: rig.model.id) == nil, "the intent outlived its restart")
        #expect(relaunched.failure(rig.model.id) == nil)
        try await waitFor { DownloadStub.recordedRequests().count == 2 }
        #expect(DownloadStub.recordedRequests().last?.allowsCellularAccess == false,
                "the restart dropped wi-fi-only")

        // The restart met the same 403: reported, and not started over again.
        while relaunched.isDownloading(rig.model.id) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(relaunched.failure(rig.model.id)?.contains("expired") == true)
        #expect(LocalModelStorage.restartIntent(for: rig.model.id) == nil)
        relaunched.scenePhaseChanged(isActive: false)
        relaunched.scenePhaseChanged(isActive: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(DownloadStub.recordedRequests().count == 2, "a second expiry was retried")
    }

    /// With the app on screen the process stays alive to drive a transfer, so
    /// an expired link is started over at once.
    @Test func expiredLinkWhileOnScreenStartsOverAtOnce() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        DownloadStub.reset(.init(body: Data(), status: 401))
        rig.downloader.scenePhaseChanged(isActive: true)
        let task = rig.session.makeTask(url: URL(string: "https://stub.invalid/x")!, resumeData: nil,
                                        repoID: rig.model.id, network: .any)
        task.resume()
        try await waitFor { DownloadStub.recordedRequests().count == 1 }
        try await Task.sleep(for: .milliseconds(200))

        await rig.downloader.reconnect()
        try await rig.waitUntilIdle()
        #expect(DownloadStub.recordedRequests().count == 2, "expected one fresh request and no third")
        #expect(DownloadStub.recordedRequests().last?.allowsCellularAccess == true)
        #expect(rig.downloader.failure(rig.model.id)?.contains("expired") == true)
        #expect(LocalModelStorage.restartIntent(for: rig.model.id) == nil)
    }

    /// The user's own tap, or abandoning the model, supersedes a pending
    /// restart — otherwise going active later would re-home a running
    /// download onto the old network policy.
    @Test func usersOwnStartConsumesAPendingRestart() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        DownloadStub.reset(.init(body: rig.payload))
        LocalModelStorage.saveRestartIntent(.wifiOnly, for: rig.model.id)
        rig.downloader.start(rig.model, network: .any)
        #expect(LocalModelStorage.restartIntent(for: rig.model.id) == nil)
        try await rig.waitUntilIdle()
        #expect(LocalModelStorage.isInstalled(rig.model))

        LocalModelStorage.saveRestartIntent(.wifiOnly, for: rig.model.id)
        rig.downloader.clearFailure(rig.model.id)
        #expect(LocalModelStorage.restartIntent(for: rig.model.id) == nil)
    }

    /// A task that finished before anyone awaited it — an adopted transfer that
    /// completed between `inFlightTasks()` and `completion(of:)` — still hands
    /// over its file.
    @Test func sessionHoldsAResultForALateCaller() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadStub.self]
        let session = LocalModelDownloadSession(configuration: config)
        let repoID = "test/late-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(at: LocalModelStorage.directory(for: repoID)) }

        let task = session.makeTask(url: URL(string: "https://stub.invalid/x")!, resumeData: nil,
                                    repoID: repoID, network: .any)
        let temp = FileManager.default.temporaryDirectory.appending(component: "late-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: temp)
        // The delegate callback, before any awaiting caller exists.
        session.urlSession(session.session, downloadTask: task, didFinishDownloadingTo: temp)

        let landed = try await session.completion(of: task)
        #expect(landed == LocalModelStorage.unverifiedFile(for: repoID))
        #expect(try Data(contentsOf: landed) == Data("hello".utf8))
    }

    @Test func deletingAModelClearsItsResumeData() {
        let rig = Rig()
        LocalModelStorage.saveResumeData(Data([1, 2, 3]), for: rig.model.id)
        #expect(LocalModelStorage.resumeData(for: rig.model.id) == Data([1, 2, 3]))
        try? LocalModelStorage.delete(rig.model)
        #expect(LocalModelStorage.resumeData(for: rig.model.id) == nil)
    }

    @Test func previewingCarriesTheNetworkChoice() {
        let e2b = LocalModelCatalog.all[0]
        let downloader = LocalModelDownloader.previewing([(e2b, 0.5)], network: .wifiOnly)
        #expect(downloader.network(e2b.id) == .wifiOnly)
        #expect(downloader.progress(e2b.id) == 0.5)
    }
}

private struct WaitTimeout: Error {}

private func waitFor(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw WaitTimeout() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private final class Completed: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func mark() { lock.lock(); flag = true; lock.unlock() }
}

// MARK: - Gate

@Suite("Cellular download gate")
struct CellularDownloadGateTests {

    /// On wi-fi a download starts without a word — and stays wi-fi-only, so
    /// leaving the house pauses it instead of moving it onto the plan.
    @Test func wifiStartsSilentlyAsWifiOnly() {
        #expect(CellularDownloadGate.decision(pathIsExpensive: false, pathIsConstrained: false)
                == .download(.wifiOnly))
    }

    @Test func mobileDataAsksFirst() {
        #expect(CellularDownloadGate.decision(pathIsExpensive: true, pathIsConstrained: false)
                == .ask(.mobileData))
    }

    @Test func lowDataModeAsksFirst() {
        #expect(CellularDownloadGate.decision(pathIsExpensive: false, pathIsConstrained: true)
                == .ask(.lowDataMode))
    }

    /// Both at once is still a mobile-data question; that is the cost the user
    /// recognises.
    @Test func mobileDataOutranksLowDataMode() {
        #expect(CellularDownloadGate.decision(pathIsExpensive: true, pathIsConstrained: true)
                == .ask(.mobileData))
    }

    /// Only the downloader's parked verdict shows the label — a live path read
    /// here flickered through every few-second route blip.
    @Test func onlyAParkedWifiOnlyTransferIsWaiting() {
        #expect(CellularDownloadGate.waitingLabel(network: .wifiOnly, parked: true)
                == "waiting for wi-fi")
        #expect(CellularDownloadGate.waitingLabel(network: .wifiOnly, parked: false) == nil)
        #expect(CellularDownloadGate.waitingLabel(network: .any, parked: true) == nil)
    }

    /// A cellular path counts as mobile data even when iOS does not call it
    /// expensive — the test phone reported `expensive=false` on cellular, and
    /// neither the prompt nor the park fired.
    @Test @MainActor func cellularIsMobileDataEvenWhenNotExpensive() {
        let cellular = NetworkPathObserver(simulatingSatisfied: true, expensive: false, cellular: true)
        #expect(cellular.isMobileData)
        let hotspot = NetworkPathObserver(simulatingSatisfied: true, expensive: true, cellular: false)
        #expect(hotspot.isMobileData)
        let wifi = NetworkPathObserver(simulatingSatisfied: true)
        #expect(!wifi.isMobileData)
    }

    /// The alert names the model and its size: the question is "this much, now?"
    @Test func alertCopyNamesTheCost() {
        let e2b = LocalModelCatalog.all[0]
        let message = CellularDownloadGate.message(for: .mobileData, model: e2b)
        #expect(message.contains(e2b.displayName))
        #expect(message.contains(e2b.sizeLabel))
        #expect(CellularDownloadGate.title(for: .mobileData) == "download over mobile data?")
    }
}
