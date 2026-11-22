//
//  CandidateListFetchTests.swift
//  teemoonTests
//
//  Audit 1.1.1 A11 + A15: the list of enclaves near.ai lists for a model is one key-bearing request with our nonce. It
//  is cancelled at the cap and with its caller, an over-size list is a list that didn't load, and the URL, header,
//  nonce, retry and 4xx paths are pinned.
//

import Foundation
import Testing
@testable import teemoon

@Suite("The listed-enclaves request (A11)")
struct CandidateListFetchTests {

    /// Answers each request from `answer`; records every request and whether a hung one was cancelled.
    final class Stub: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        private var cancelledFlag = false
        let answer: @Sendable (Int) async throws -> (Int, Data)
        init(_ answer: @escaping @Sendable (Int) async throws -> (Int, Data)) { self.answer = answer }
        var requests: [URLRequest] { lock.withLock { seen } }
        var cancelled: Bool { lock.withLock { cancelledFlag } }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let n = lock.withLock { seen.append(request); return seen.count }
            do {
                let (status, body) = try await answer(n)
                return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            } catch {
                lock.withLock { cancelledFlag = true }
                throw error
            }
        }
    }

    static let base = URL(string: "https://cloud-api.near.ai/v1")!

    static func body(entries: Int, pad: Int = 0) -> Data {
        let one: [String: Any] = ["signing_public_key": "ab", "pad": String(repeating: "x", count: pad)]
        return try! JSONSerialization.data(withJSONObject: ["model_attestations": Array(repeating: one, count: entries)])
    }

    @Test func theRequestCarriesTheModelTheKeyAndTheNonceItReturns() async throws {
        let stub = Stub { _ in (200, Self.body(entries: 3)) }
        let got = try #require(await AttestationService.fetchCandidateList(baseURL: Self.base, model: "z-ai/glm-5.3-flash",
                                                                           apiKey: "k", http: stub))
        let request = try #require(stub.requests.first)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        #expect(request.url!.path.hasSuffix("/attestation/report"))
        #expect(items.first { $0.name == "model" }?.value == "z-ai/glm-5.3-flash")
        #expect(items.first { $0.name == "signing_algo" }?.value == "ed25519")
        #expect(items.first { $0.name == "nonce" }?.value == got.nonce)   // the nonce checked is the nonce sent
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(stub.requests.count == 1)
    }

    @Test func aServerErrorIsRetriedAndA4xxIsNot() async {
        let flaky = Stub { n in n == 1 ? (503, Data()) : (200, Self.body(entries: 1)) }
        #expect(await AttestationService.fetchCandidateList(baseURL: Self.base, model: "m", apiKey: "k", http: flaky) != nil)
        #expect(flaky.requests.count == 2)
        let refused = Stub { _ in (403, Data()) }
        #expect(await AttestationService.fetchCandidateList(baseURL: Self.base, model: "m", apiKey: "k", http: refused) == nil)
        #expect(refused.requests.count == 1)
        let empty = Stub { _ in (200, Self.body(entries: 0)) }
        #expect(await AttestationService.fetchCandidateList(baseURL: Self.base, model: "m", apiKey: "k", http: empty) == nil)
    }

    /// Audit 1.1.1 A15: a refusal is final even when its body reads as a list; a thrown transport error is retried.
    @Test func aRefusalCarryingAListIsNotAdoptedAndATransportErrorIsRetried() async {
        let refused = Stub { _ in (403, Self.body(entries: 3)) }
        #expect(await AttestationService.fetchCandidateList(baseURL: Self.base, model: "m", apiKey: "k", http: refused) == nil)
        #expect(refused.requests.count == 1)
        let dropped = Stub { n in if n == 1 { throw URLError(.networkConnectionLost) }; return (200, Self.body(entries: 1)) }
        #expect(await AttestationService.fetchCandidateList(baseURL: Self.base, model: "m", apiKey: "k", http: dropped) != nil)
        #expect(dropped.requests.count == 2)
    }

    @Test func anOversizeListIsAListThatDidNotLoad() async {
        let many = Stub { _ in (200, Self.body(entries: AttestationService.maxListedEnclaves + 1)) }
        #expect(await AttestationService.fetchCandidateList(baseURL: Self.base, model: "m", apiKey: "k", http: many) == nil)
        let atCap = Stub { _ in (200, Self.body(entries: AttestationService.maxListedEnclaves)) }
        #expect(await AttestationService.fetchCandidateList(baseURL: Self.base, model: "m", apiKey: "k", http: atCap) != nil)
        let big = Stub { _ in (200, Self.body(entries: 1, pad: AttestationService.maxListBytes)) }
        #expect(await AttestationService.fetchCandidateList(baseURL: Self.base, model: "m", apiKey: "k", http: big) == nil)
    }

    @Test func theRequestIsCancelledAtTheCap() async throws {
        let hung = Stub { _ in try await Task.sleep(for: .seconds(30)); return (200, Data()) }
        let got = await AttestationService.candidateList(baseURL: Self.base, model: "m", apiKey: "k", http: hung,
                                                         timeout: 50_000_000)
        #expect(got == nil)
        await waitFor(timeout: .seconds(2)) { hung.cancelled }
        #expect(hung.cancelled)
        #expect(hung.requests.count == 1)
    }

    @Test func theRequestIsCancelledWithItsCaller() async throws {
        let hung = Stub { _ in try await Task.sleep(for: .seconds(30)); return (200, Data()) }
        let caller = Task { await AttestationService.candidateList(baseURL: Self.base, model: "m", apiKey: "k", http: hung) }
        await waitFor(timeout: .seconds(2)) { hung.requests.count == 1 }
        caller.cancel()
        await waitFor(timeout: .seconds(2)) { hung.cancelled }
        #expect(hung.cancelled)
        #expect(await caller.value == nil)
        #expect(hung.requests.count == 1)
    }

    /// Serves an endless-looking body in 256 KB chunks, with no Content-Length, and counts what it sent before the
    /// client hung up.
    final class ChunkedProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var sent = 0
        nonisolated(unsafe) static var stopped = false
        static let chunk = Data(repeating: 0x20, count: 256 * 1024)
        static let chunks = 64   // 16 MB if nobody stops reading
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.sent = 0; Self.stopped = false
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            DispatchQueue.global().async {
                for _ in 0..<Self.chunks {
                    if Self.stopped { return }
                    self.client?.urlProtocol(self, didLoad: Self.chunk)
                    Self.sent += 1
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if !Self.stopped { self.client?.urlProtocolDidFinishLoading(self) }
            }
        }
        override func stopLoading() { Self.stopped = true }
    }

    /// Audit read of 86c7c6ce: the cap must stop the download, not judge it after the whole body arrived.
    @Test func theCapStopsTheDownload() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkedProtocol.self]
        let http = URLSessionHTTP(session: URLSession(configuration: config))
        await #expect(throws: HTTPBodyTooLarge.self) {
            _ = try await http.data(for: URLRequest(url: URL(string: "https://example.invalid/list")!), limit: 1_000_000)
        }
        await waitFor(timeout: .seconds(2)) { ChunkedProtocol.stopped }
        #expect(ChunkedProtocol.stopped)
        #expect(ChunkedProtocol.sent < ChunkedProtocol.chunks / 2, "sent \(ChunkedProtocol.sent) of \(ChunkedProtocol.chunks) chunks")
    }
}
