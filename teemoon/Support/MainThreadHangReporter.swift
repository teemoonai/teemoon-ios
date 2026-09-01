//
//  MainThreadHangReporter.swift
//  teemoon
//
//  When the main thread stops answering, capture WHAT IT IS DOING — from
//  inside the app, on the user's real data, with no cable and no Instruments.
//
//  Exists because the 2026-08-07 freeze ("submit, scroll back half a screen")
//  reproduced under a thumb in the user's real thread but never under XCUI
//  against seeded fixtures, across an embarrassing number of increasingly
//  faithful attempts. The variable that can't be synthesised is the real
//  store's content — so the instrument goes to the freeze instead of the
//  freeze coming to the instrument.
//
//  Mechanism: a watchdog thread pings the main queue every 250ms. When the
//  pong is more than 2s stale, it sends SIGPROF directly to the main
//  thread; the signal handler — running ON the wedged main thread —
//  captures a raw backtrace into a static buffer (async-signal-safe: just
//  `backtrace(3)` into preallocated memory). The watchdog then symbolicates
//  outside the handler and appends to Documents/hangstacks.log, sampling
//  every 2s while the hang lasts — a spinning main thread yields a poor
//  man's time profile, which is exactly what a livelock needs.
//
//  DEBUG-only, and armed by the same `-scrollTrace` flag as the traces, so
//  it costs release builds nothing and idle debug sessions one thread.
//

#if DEBUG
import Foundation
import Darwin

// Signal-handler state is FILE SCOPE so a C `sa_handler` can touch it.
// Written from the handler on the main thread; read by the watchdog after
// polling the done counter. The benign race is acceptable in a debug
// instrument.
//
// MUST be a raw C buffer, never a Swift Array. The 2026-08-15 crash
// (EXC_BREAKPOINT / _os_unfair_lock_recursive_abort) was `gHangFrames`
// as `[UnsafeMutableRawPointer?](repeating:count:)`: first SIGPROF lazily
// initialized the Array, Swift metadata took the runtime lock, and main
// was already in `objc_lookUpImpOrForward` (UIKit trait / XCUI AX snapshot).
private let gHangCapacity: Int32 = 128
private var gHangFrames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
private var gHangFrameCount: Int32 = 0
private var gHangCaptureDone: Int32 = 0
private var gHangArmed = false

/// C handler — no Swift closure, no Array, no allocate. Buffer must already
/// exist (`preallocateFrames` runs on the main thread before `sigaction`).
private func hangProfilerHandler(_: Int32) {
    guard let frames = gHangFrames else { return }
    gHangFrameCount = backtrace(frames, gHangCapacity)
    gHangCaptureDone &+= 1
}

/// Allocate the frame buffer on a normal thread. Call before installing the
/// handler, and never from the handler itself.
private func preallocateHangFrames() {
    guard gHangFrames == nil else { return }
    let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(gHangCapacity))
    frames.initialize(repeating: nil, count: Int(gHangCapacity))
    gHangFrames = frames
}

enum MainThreadHangReporter {

    private static var mainPThread: pthread_t?

    private static let pongLock = NSLock()
    private static var lastPong = ProcessInfo.processInfo.systemUptime

    /// Test seam: prove the handler can run without touching Swift Array
    /// lazy-init. Does not arm the watchdog or install SIGPROF.
    static func captureOnceForTesting() -> Int {
        preallocateHangFrames()
        hangProfilerHandler(SIGPROF)
        return Int(gHangFrameCount)
    }

    static func startIfRequested() {
        // ALWAYS armed in Debug builds (2026-08-07, by request): the dev
        // phone's daily driving is its own monitoring. Home-screen launches
        // pass no arguments, and a freeze that only happens outside a test
        // session is exactly the one worth catching — this file exists
        // because of one. The whole type is #if DEBUG, so Release never
        // carries the watchdog thread.
        guard !gHangArmed else { return }
        precondition(Foundation.Thread.isMainThread, "must arm from the main thread")
        mainPThread = pthread_self()

        // Buffer FIRST. The handler is only safe once this pointer is set.
        preallocateHangFrames()

        // SIGPROF handler: runs on whichever thread the signal is DIRECTED at
        // — pthread_kill targets the main thread specifically. Only
        // async-signal-safe work here: backtrace into the preallocated buffer.
        var action = sigaction()
        action.__sigaction_u.__sa_handler = hangProfilerHandler
        action.sa_flags = 0
        sigemptyset(&action.sa_mask)
        sigaction(SIGPROF, &action, nil)
        gHangArmed = true

        // The pong. Cheap enough to run forever; ~4 timer fires a second.
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            pongLock.lock(); lastPong = ProcessInfo.processInfo.systemUptime; pongLock.unlock()
        }

        Foundation.Thread.detachNewThread {
            Foundation.Thread.current.name = "hang-watchdog"
            watch()
        }
    }

    /// How long the main thread must be silent before it counts as a hang.
    ///
    /// 2s is the daily-driving default: long enough that nothing routine
    /// trips it, short enough to catch a freeze. A shorter one is for
    /// INVESTIGATING a specific stall that is real but under the default —
    /// "the attestation sheet takes a second to close" is not a freeze and
    /// still wants stacks. Set it at launch, no rebuild:
    ///
    ///     xcrun devicectl device process launch --device <udid> \
    ///       ai.teemoon.app -hangThreshold 0.6
    ///
    /// Expect routine noise below ~0.5s (thread opens, first paints).
    private static var hangThreshold: TimeInterval {
        // `double(forKey:)`, NOT `object(forKey:) as? Double`: a launch
        // argument arrives in the NSArgumentDomain as a STRING, so the cast
        // fails and the override silently does nothing (it did, on the first
        // run of this — the log reported 2.2s hangs under a 0.6s threshold).
        // `double(forKey:)` coerces, and returns 0 when absent.
        let requested = UserDefaults.standard.double(forKey: "hangThreshold")
        return requested > 0 ? max(0.2, requested) : 2
    }

    private static func watch() {
        var hangStart: TimeInterval?
        let threshold = hangThreshold
        while true {
            Foundation.Thread.sleep(forTimeInterval: 0.25)
            pongLock.lock(); let pong = lastPong; pongLock.unlock()
            let now = ProcessInfo.processInfo.systemUptime
            let stale = now - pong

            if stale < threshold { hangStart = nil; continue }

            if hangStart == nil {
                hangStart = pong
                append("=== HANG detected t=\(now) (main silent \(String(format: "%.1f", stale))s) ===")
            }
            captureMainStack(label: "t=\(now) silent=\(String(format: "%.1f", stale))s")
            Foundation.Thread.sleep(forTimeInterval: 1.75)  // ~1 sample / 2s while hung
        }
    }

    private static func captureMainStack(label: String) {
        guard let main = mainPThread else { return }
        let before = gHangCaptureDone
        guard pthread_kill(main, SIGPROF) == 0 else {
            append("[hangstack] \(label) — pthread_kill failed"); return
        }
        // The handler runs even on a busy thread (signals interrupt user
        // code; they do NOT need the runloop). A truly deadlocked-in-kernel
        // thread may not take it — that absence is itself a finding.
        for _ in 0..<100 where gHangCaptureDone == before { usleep(2000) }
        guard gHangCaptureDone != before else {
            append("[hangstack] \(label) — main thread did not take the signal (blocked in kernel?)")
            return
        }
        let count = Int(gHangFrameCount)
        var lines = ["[hangstack] \(label) frames=\(count)"]
        guard let frames = gHangFrames else { return }
        let symbols = backtrace_symbols(frames, Int32(count))
        if let symbols {
            for i in 0..<count {
                if let s = symbols[i] { lines.append("  " + String(cString: s)) }
            }
            free(symbols)
        }
        append(lines.joined(separator: "\n"))
    }

    private static let fileLock = NSLock()
    private static func append(_ line: String) {
        fileLock.lock(); defer { fileLock.unlock() }
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let url = dir.appendingPathComponent("hangstacks.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }
}
#endif
