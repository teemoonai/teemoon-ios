//
//  RunningPairCheck.swift
//  teemoon
//
//  Trust scope (c), option A (audit 2026-11-04): fetch each (commit, file) the action log names as
//  running from near.ai's compose-files repo and check SHA256(body) == file_sha256. A mismatch is hard;
//  a 404 at the pinned commit is "unpublished"; network trouble is inconclusive. Answers are cached by
//  (commit, file) with no expiry: a file at a commit never changes.
//

import CryptoKit
import Foundation

actor RunningPairCheck {
    enum Outcome: String, Equatable, Sendable {
        case verified
        case mismatch
        /// 404 at the pinned commit.
        case unpublished
        /// Network or rate limit: no evidence either way; never cached.
        case inconclusive
        /// Past the cap.
        case notFetched
    }

    static let repo = "nearai/cvm-compose-files"

    private let session: URLSession
    private let defaults: UserDefaults
    /// Per fetch, whole request: the pairs run in parallel inside the send gate's 15 s settle, so a slow or
    /// black-holed GitHub ends as inconclusive instead of holding every send.
    private let timeout: Duration
    private static let cacheKey = "runningPairCheck.outcomes"

    init(session: URLSession = .shared, defaults: UserDefaults = .standard, timeout: Duration = .seconds(5)) {
        self.session = session
        self.defaults = defaults
        self.timeout = timeout
    }

    nonisolated static func url(for source: ActionLogReading.Source) -> URL? {
        URL(string: "https://raw.githubusercontent.com/\(repo)/\(source.commit)/\(source.file)")
    }

    func check(_ source: ActionLogReading.Source) async -> Outcome {
        await resolve(source, needBody: false).outcome
    }

    /// A whole-file entry's services, read from the file at its commit once its hash checks. nil when it
    /// can't be read or doesn't match; the pair check then says which. The log pins no hash on a down, so a
    /// down's file is read at its commit unhashed, as audit's tool does: it only retires, never lists.
    func serviceNames(_ source: ActionLogReading.Source) async -> [String]? {
        let key = Self.key(source)
        if let names = (defaults.dictionary(forKey: Self.namesKey) as? [String: [String]])?[key] { return names }
        let body: Data
        if source.fileSHA256.isEmpty {
            guard let url = Self.url(for: source), let (data, status) = await fetch(url), status == 200 else { return nil }
            body = data
        } else {
            guard case (.verified, let data?) = await resolve(source, needBody: true) else { return nil }
            body = data
        }
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        let names = ActionLogReading.serviceNames(inCompose: text)
        var cache = defaults.dictionary(forKey: Self.namesKey) as? [String: [String]] ?? [:]
        cache[key] = names
        defaults.set(cache, forKey: Self.namesKey)
        return names
    }

    /// Every whole-file source at once, before the walk.
    func serviceNames(for sources: [ActionLogReading.Source]) async -> [ActionLogReading.Source: [String]] {
        await withTaskGroup(of: (ActionLogReading.Source, [String]?).self) { group in
            for source in sources { group.addTask { (source, await self.serviceNames(source)) } }
            var out: [ActionLogReading.Source: [String]] = [:]
            for await (source, names) in group { out[source] = names }
            return out
        }
    }

    /// Bodies fetched this launch, for the chat path. Memory only: a file at a commit never changes.
    private var bodies: [String: Data] = [:]

    /// The running revisions' files, hash-checked, for the chat path. Missing entries couldn't be read.
    func bodies(for sources: [ActionLogReading.Source]) async -> [ActionLogReading.Source: String] {
        await withTaskGroup(of: (ActionLogReading.Source, String?).self) { group in
            for source in Set(sources) {
                group.addTask {
                    if let data = await self.cachedBody(source) { return (source, String(data: data, encoding: .utf8)) }
                    guard case (.verified, let data?) = await self.resolve(source, needBody: true) else { return (source, nil) }
                    return (source, String(data: data, encoding: .utf8))
                }
            }
            var out: [ActionLogReading.Source: String] = [:]
            for await (source, text) in group { if let text { out[source] = text } }
            return out
        }
    }

    private func cachedBody(_ source: ActionLogReading.Source) -> Data? { bodies[Self.key(source)] }

    private static let namesKey = "runningPairCheck.serviceNames"
    private static func key(_ s: ActionLogReading.Source) -> String { "\(s.commit)|\(s.file)|\(s.fileSHA256)" }

    /// The outcome, and the body when this call fetched it. A cached outcome comes back without one.
    private func resolve(_ source: ActionLogReading.Source, needBody: Bool) async -> (outcome: Outcome, body: Data?) {
        let key = Self.key(source)
        if !needBody, let cached = (defaults.dictionary(forKey: Self.cacheKey) as? [String: String])?[key],
           let outcome = Outcome(rawValue: cached) {
            return (outcome, nil)
        }
        guard let url = Self.url(for: source),
              let (data, status) = await fetch(url) else { return (.inconclusive, nil) }
        let outcome: Outcome
        switch status {
        case 200:
            outcome = Data(SHA256.hash(data: data)).hexString == source.fileSHA256.lowercased() ? .verified : .mismatch
        case 404:
            outcome = .unpublished
        default:
            return (.inconclusive, nil)
        }
        var cache = defaults.dictionary(forKey: Self.cacheKey) as? [String: String] ?? [:]
        cache[key] = outcome.rawValue
        defaults.set(cache, forKey: Self.cacheKey)
        if outcome == .verified { bodies[key] = data }
        return (outcome, data)
    }

    /// The body and status, or nil when the deadline passed first or the request failed.
    private func fetch(_ url: URL) async -> (Data, Int)? {
        let session = self.session
        let timeout = self.timeout
        return await withTaskGroup(of: (Data, Int)?.self) { group in
            group.addTask {
                var request = URLRequest(url: url)
                request.timeoutInterval = Double(timeout.components.seconds) + 1
                guard let (data, response) = try? await session.data(for: request),
                      let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
                return (data, status)
            }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Option A: every pair at once, each fetched once; past the cap, "not fetched". Order is kept.
    func check(pairs: (check: [ActionLogReading.Source], notFetched: [ActionLogReading.Source]))
        async -> [(ActionLogReading.Source, Outcome)] {
        let outcomes = await withTaskGroup(of: (Int, Outcome).self) { group in
            for (i, source) in pairs.check.enumerated() {
                group.addTask { (i, await self.check(source)) }
            }
            var byIndex: [Int: Outcome] = [:]
            for await (i, outcome) in group { byIndex[i] = outcome }
            return byIndex
        }
        return pairs.check.enumerated().map { ($0.element, outcomes[$0.offset] ?? .inconclusive) }
            + pairs.notFetched.map { ($0, .notFetched) }
    }
}
