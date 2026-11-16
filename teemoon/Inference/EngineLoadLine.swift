//
//  EngineLoadLine.swift
//  teemoon
//
//  The activity chip while an on-device engine loads (the maintainer, 2026-10-26). Decided from what the engine and the
//  cache folder report, never a timer guessing at a load. conformance/loading.json pins it with Android.
//

import Foundation

enum EngineLoadLine {
    static let preparingForImages = "preparing the model for images… this happens once"
    static let loading = "loading the model…"
    /// A cached load says nothing until it has taken this long.
    static let quietMs: Double = 3000

    /// One turn's load, in ms from the send. `loadStartMs` nil: the engine was already resident.
    struct Load: Equatable {
        var loadStartMs: Double?
        var loadEndsAtMs: Double?
        var imageCapable: Bool
        /// A cache for this bundle existed when the load started.
        var cachePresent: Bool
        /// When a cache file was first created or rewritten during the load.
        var rebuildSeenAtMs: Double?
    }

    /// The chip's text `atMs` after the send. Outside a load it is the thinking clock, counted from the send.
    static func line(atMs t: Double, load: Load) -> String {
        let thinking = ThinkingClock.liveLabel(elapsed: t / 1000)
        guard let start = load.loadStartMs, t >= start else { return thinking }
        if let end = load.loadEndsAtMs, t >= end { return thinking }
        let rebuilding = !load.cachePresent || load.rebuildSeenAtMs.map { t >= $0 } == true
        if load.imageCapable && rebuilding { return preparingForImages }
        return t - start >= quietMs ? loading : thinking
    }
}

/// The last engine load, as the cache reported it (`LiteRTTransport.EngineCache.build`). A mirror like
/// `LocalEngineResidency`: the chip reads it synchronously.
@Observable
@MainActor
final class EngineLoadObserver {
    static let shared = EngineLoadObserver()

    struct Observed: Equatable {
        var started: Date
        var ended: Date?
        var imageCapable: Bool
        var cachePresent: Bool
        var rebuildSeen: Date?

        /// The rule's input for a turn sent at `send`. A load that ended before the send is no load.
        func load(sentAt send: Date) -> EngineLoadLine.Load {
            if let ended, ended <= send {
                return .init(loadStartMs: nil, loadEndsAtMs: nil, imageCapable: imageCapable, cachePresent: cachePresent)
            }
            func ms(_ d: Date) -> Double { d.timeIntervalSince(send) * 1000 }
            return .init(loadStartMs: ms(started), loadEndsAtMs: ended.map(ms), imageCapable: imageCapable,
                         cachePresent: cachePresent, rebuildSeenAtMs: rebuildSeen.map(ms))
        }
    }

    private(set) var current: Observed?

    init() {}

    func began(at date: Date, imageCapable: Bool, cachePresent: Bool) {
        current = Observed(started: date, imageCapable: imageCapable, cachePresent: cachePresent)
    }

    func rebuildSeen(at date: Date) {
        if current?.rebuildSeen == nil { current?.rebuildSeen = date }
    }

    func ended(at date: Date) { current?.ended = date }

    /// The chip's line for an on-device turn sent at `send`, or nil while it should read as thinking.
    func line(sentAt send: Date?, now: Date) -> String? {
        guard let send, let current else { return nil }
        let line = EngineLoadLine.line(atMs: now.timeIntervalSince(send) * 1000, load: current.load(sentAt: send))
        return line == EngineLoadLine.preparingForImages || line == EngineLoadLine.loading ? line : nil
    }
}
