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
