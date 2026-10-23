//
//  StreamStallWatchdog.swift
//  teemoon
//
//  Two different waits on a chat request. Before headers, a free-tier queue
//  (NVIDIA held glm-5.3-flash 253–282 s) is still a live request, so the
//  request timeout is long. After headers, bytes that stop for `streamIdle`
//  mean the stream is dead.
//

import Foundation

final class StreamStallWatchdog: @unchecked Sendable {
    /// `URLRequest.timeoutInterval` for chat: the longest wait for headers.
    static let headerWait: TimeInterval = 600
    /// The longest gap between bytes once the response has started.
    static let streamIdle: TimeInterval = 240

    private let lock = NSLock()
    private var last: Date
    private var fired = false
    private let limit: TimeInterval
    private let now: @Sendable () -> Date

    init(limit: TimeInterval = streamIdle, now: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = limit
        self.now = now
        self.last = now()
    }

    func touch() { lock.withLock { last = now() } }

    var didFire: Bool { lock.withLock { fired } }

    /// Marks the watchdog fired when the gap since the last byte reaches the limit.
    func check() -> Bool {
        lock.withLock {
            if !fired, now().timeIntervalSince(last) >= limit { fired = true }
            return fired
        }
    }

    /// Polls until cancelled; calls `cancel` once when the stream stalls.
    func watch(cancel: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        let poll = Duration.milliseconds(Int(min(5, limit / 4) * 1000))
        return Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                if Task.isCancelled { return }
                if check() { cancel(); return }
            }
        }
    }
}
