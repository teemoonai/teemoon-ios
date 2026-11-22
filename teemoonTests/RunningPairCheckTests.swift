//
//  RunningPairCheckTests.swift
//  teemoonTests
//
//  Trust scope (c), option A, against a scripted raw.githubusercontent.com and audit's mutation set: flip a
//  fetched row's file_sha256 → mismatch; repoint a row's commit → that pair is a new fetch; past the cap → not
//  fetched. 404 at the pinned commit is unpublished; a 429 is inconclusive and never cached.
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

@Suite("Trust scope — the running compose files", .serialized)
struct RunningPairCheckTests {
    static let body = Data("services:\n  proxy:\n    image: nearaidev/proxy@sha256:abc\n".utf8)
    static var sha: String { Data(SHA256.hash(data: body)).hexString }

    private func checker(_ responses: [String: (Int, Data)]) -> RunningPairCheck {
        RawGitHub.responses = responses; RawGitHub.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RawGitHub.self]
        return RunningPairCheck(session: URLSession(configuration: config),
                                defaults: UserDefaults(suiteName: "pairs-\(UUID().uuidString)")!)
    }

    private func source(commit: String = "7ee4a4c", file: String = "prod/a.yaml", sha: String? = nil) -> ActionLogReading.Source {
        .init(commit: commit, file: file, fileSHA256: sha ?? Self.sha)
    }

    @Test func aMatchingFileIsVerifiedAndCachedWithoutExpiry() async {
        let c = checker(["/nearai/cvm-compose-files/7ee4a4c/prod/a.yaml": (200, Self.body)])
        #expect(await c.check(source()) == .verified)
        #expect(await c.check(source()) == .verified)
        #expect(RawGitHub.requests.count == 1, "fetched once")
        #expect(RawGitHub.requests.first?.host == "raw.githubusercontent.com")
    }

    @Test func aFlippedHashIsAMismatchA404IsUnpublishedARateLimitIsInconclusive() async {
        var flipped = Self.sha; flipped.removeLast(); flipped += Self.sha.hasSuffix("0") ? "1" : "0"
        let c = checker(["/nearai/cvm-compose-files/7ee4a4c/prod/a.yaml": (200, Self.body),
                         "/nearai/cvm-compose-files/7ee4a4c/prod/gone.yaml": (404, Data()),
                         "/nearai/cvm-compose-files/7ee4a4c/prod/busy.yaml": (429, Data())])
        #expect(await c.check(source(sha: flipped)) == .mismatch)
        #expect(await c.check(source(file: "prod/gone.yaml")) == .unpublished)
        #expect(await c.check(source(file: "prod/busy.yaml")) == .inconclusive)
        #expect(await c.check(source(file: "prod/busy.yaml")) == .inconclusive)
        #expect(RawGitHub.requests.filter { $0.path.hasSuffix("busy.yaml") }.count == 2, "inconclusive is never cached")
    }

    @Test func aRepointedCommitIsItsOwnFetchAndPastTheCapIsNotFetched() async {
        let c = checker(["/nearai/cvm-compose-files/7ee4a4c/prod/a.yaml": (200, Self.body),
                         "/nearai/cvm-compose-files/0000000/prod/a.yaml": (404, Data())])
        let pairs = (check: [source(), source(commit: "0000000")], notFetched: [source(file: "prod/later.yaml")])
        let results = await c.check(pairs: pairs).map(\.1)
        #expect(results == [.verified, .unpublished, .notFetched])
        #expect(!RawGitHub.requests.contains { $0.path.hasSuffix("later.yaml") })
    }
}

@Suite("Trust scope — a silent GitHub can't hold the send gate")
@MainActor
struct RunningPairDeadlineTests {
    /// pm, 2026-11-06: the pairs ran one by one at URLSession's 60 s default, so a black-holed GitHub kept
    /// trust scope pending — and every send refused — for minutes. Now they run at once under one deadline.
    @Test func aBlackHoledHostEndsInconclusiveWithinTheDeadline() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BlackHole.self]
        let c = RunningPairCheck(session: URLSession(configuration: config),
                                 defaults: UserDefaults(suiteName: "hole-\(UUID().uuidString)")!,
                                 timeout: .milliseconds(500))
        let pairs = (0..<10).map { ActionLogReading.Source(commit: "c\($0)", file: "f.yaml", fileSHA256: "s") }
        let started = ContinuousClock.now
        let results = await c.check(pairs: (check: pairs, notFetched: []))
        let took = ContinuousClock.now - started
        #expect(results.allSatisfy { $0.1 == .inconclusive })
        #expect(took < .seconds(3), "10 silent fetches took \(took): they must run at once under one deadline")
        #expect(ConfidentialSession.verifierSettleTimeout > .seconds(5), "the production deadline fits the settle window")
    }
}

private final class BlackHole: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}   // never answers
    override func stopLoading() {}
}

private final class RawGitHub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]
    nonisolated(unsafe) static var requests: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        Self.requests.append(url)
        let (status, body) = Self.responses[url.path] ?? (404, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Audit note on build 64: every running pair and whole-file source of a listed enclave's action log is a keyless fetch
/// from raw.githubusercontent.com, so N listed enclaves multiply them. One `TrustScope.run` (one log) gets
/// `RunningPairCheck.fetchBudget` fetches. How it was set: the 2026-11-20 capture's three logs (fixture
/// nearai_live_actionlogs_20261120.json) name 99, 8 and 21 compose files for the names fetch (whole-file + up
/// revisions, `ActionLogReading`); about twice the largest is 200. `theLiveCaptureLogsFit` prints what each cold run makes.
@Suite("Trust scope — one action log's GitHub budget", .serialized)
struct RunningPairBudgetTests {

    /// Serves `bodies[path]` (200) or `fallback`; counts every request.
    final class Stub: URLProtocol, @unchecked Sendable {
        static let bodies = LockedBox<[String: Data]>([:])
        static let fallback = LockedBox(404)
        static let paths = LockedBox<[String]>([])
        static func reset(_ bodies: [String: Data] = [:], fallback: Int = 404) {
            self.bodies.value = bodies; self.fallback.value = fallback; paths.value = []
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            let url = request.url!
            Self.paths.withValue { $0.append(url.path) }
            let body = Self.bodies.value[url.path]
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: body == nil ? Self.fallback.value : 200,
                                                                  httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    func checker() -> RunningPairCheck {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return RunningPairCheck(session: URLSession(configuration: config),
                                defaults: UserDefaults(suiteName: "budget-\(UUID().uuidString)")!)
    }

    static func path(commit: String, file: String) -> String { "/\(RunningPairCheck.repo)/\(commit)/\(file)" }
    static func body(_ path: String) -> Data { Data("# \(path)\nservices:\n  svc:\n    image: nearaidev/x@sha256:abc\n".utf8) }

    /// Every (commit, file) the log names served, its pinned hash rewritten to match: the healthy cold run.
    static func served(_ actions: [[String: Any]]) -> ([[String: Any]], [String: Data]) {
        var bodies: [String: Data] = [:]
        let rewritten = actions.map { a -> [String: Any] in
            guard let commit = a["commit"] as? String, let file = a["file"] as? String else { return a }
            let p = path(commit: commit, file: file)
            let body = bodies[p] ?? Self.body(p)
            bodies[p] = body
            var a = a
            if a["file_sha256"] != nil { a["file_sha256"] = Data(SHA256.hash(data: body)).hexString }
            return a
        }
        return (rewritten, bodies)
    }

    static func liveLogs() throws -> [[[String: Any]]] {
        let json = try JSONSerialization.jsonObject(with: TestFixture.data("nearai_live_actionlogs_20261120.json")) as? [String: Any]
        return try #require(json?["logs"] as? [[[String: Any]]])
    }

    /// A log naming far more files than the budget: it stops at the budget, and nothing past it reads as checked.
    @Test func aRunawayLogStopsAtTheBudgetAsCouldntCheck() async throws {
        let runaway: [[String: Any]] = (0..<(RunningPairCheck.fetchBudget * 5)).map { i in
            ["action": "compose_up", "commit": "c\(i)", "file": "prod/f\(i).yaml", "file_sha256": "x",
             "timestamp": String(format: "2026-11-20T%05d", i)]
        }
        let (actions, bodies) = Self.served(runaway)
        Stub.reset(bodies)
        let pairs = checker()
        let budget = RunningPairCheck.Budget()
        let (rows, _) = await TrustScope.running(actions: actions, bound: true, model: nil, host: nil, pairs: pairs, budget: budget)
        let fetched = Set(Stub.paths.value)
        #expect(Stub.paths.value.count == RunningPairCheck.fetchBudget, "one log made \(Stub.paths.value.count) GitHub fetches")
        #expect(!rows.isEmpty)
        for row in rows where !fetched.contains(Self.path(commit: row.service.source.commit, file: row.service.source.file)) {
            #expect(row.outcome == .inconclusive || row.outcome == .notFetched, "an unread file read as \(row.outcome)")
        }
        // Past the budget a file is the existing couldn't-check, never cached, and nothing goes to the network.
        let unread = try #require(actions.compactMap { a -> ActionLogReading.Source? in
            let s = ActionLogReading.Source(commit: a["commit"] as! String, file: a["file"] as! String,
                                            fileSHA256: a["file_sha256"] as! String)
            return fetched.contains(Self.path(commit: s.commit, file: s.file)) ? nil : s
        }.first)
        #expect(await pairs.check(unread, budget: budget) == .inconclusive)
        #expect(await pairs.serviceNames(unread, budget: budget) == nil)
        #expect(Stub.paths.value.count == RunningPairCheck.fetchBudget)
        #expect(await pairs.check(unread) == .verified, "an over-budget answer was cached")
    }

    /// The chat path's body fetches draw on the same budget: a runaway list of running files stops there, and a file
    /// past it has no body (couldn't-check), never a checked one.
    @Test func aRunawayBodyListStopsAtTheBudget() async {
        let sources = (0..<(RunningPairCheck.fetchBudget * 5)).map { i -> ActionLogReading.Source in
            let p = Self.path(commit: "b\(i)", file: "prod/f\(i).yaml")
            return .init(commit: "b\(i)", file: "prod/f\(i).yaml", fileSHA256: Data(SHA256.hash(data: Self.body(p))).hexString)
        }
        Stub.reset(Dictionary(uniqueKeysWithValues: sources.map { s in
            let p = Self.path(commit: s.commit, file: s.file); return (p, Self.body(p)) }))
        let pairs = checker()
        let budget = RunningPairCheck.Budget()
        _ = await pairs.check(pairs: (check: Array(sources.prefix(10)), notFetched: []), budget: budget)
        let texts = await pairs.bodies(for: sources, budget: budget)
        #expect(Stub.paths.value.count == RunningPairCheck.fetchBudget, "pairs + bodies made \(Stub.paths.value.count) fetches")
        #expect(texts.count <= RunningPairCheck.fetchBudget)
        #expect(texts.count < sources.count, "every body was read past the budget")
    }

    /// The 2026-11-20 capture's three logs, cold, every file served and matching: each fits with room to spare.
    /// Also cold with nothing published (all 404) and with GitHub rate-limiting (all 429): the worst a real log costs.
    @Test(arguments: [200, 404, 429])
    func theLiveCaptureLogsFit(status: Int) async throws {
        for (i, log) in try Self.liveLogs().enumerated() {
            let (actions, bodies) = Self.served(log)
            Stub.reset(status == 200 ? bodies : [:], fallback: status)
            let budget = RunningPairCheck.Budget()
            let (rows, _) = await TrustScope.running(actions: actions, bound: true, model: "z-ai/glm-5.3-flash", host: nil,
                                                     pairs: checker(), budget: budget)
            let made = Stub.paths.value.count
            print("budget-measure status=\(status) log=\(i) actions=\(log.count) fetches=\(made) distinct=\(Set(Stub.paths.value).count) rows=\(rows.count)")
            #expect(made < RunningPairCheck.fetchBudget, "log \(i) made \(made) fetches at \(status)")
            if status == 200 {
                #expect(made * 2 <= RunningPairCheck.fetchBudget + 2, "the budget is about twice a healthy cold run")
                #expect(!rows.contains { $0.outcome == .inconclusive }, "a healthy live log ran out of budget")
            }
        }
    }
}
