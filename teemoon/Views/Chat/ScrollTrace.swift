//
//  ScrollTrace.swift
//  teemoon
//
//  Ground truth for "how does the transcript actually move while a reply
//  streams" — the question behind every scroll-smoothness change to
//  ConversationView.
//
//  It exists because the two obvious ways to answer it are both wrong:
//
//  - **XCUI polling.** Every frame query round-trips into the app and waits for
//    it to go idle. Measured: ~290 queries over a 6-second stream added 63
//    seconds, identically to both arms being compared. It perturbs the thing it
//    measures until only the perturbation is left.
//  - **Screen recording plus frame correlation.** Non-invasive, but it only
//    recovers motion it can search for. A jump larger than the search window
//    comes back as a small wrong number rather than as a jump — which is
//    exactly backwards, since jumps are the defect.
//
//  - **Handing the number to the test through the accessibility tree.** Tried,
//    and abandoned: the probe read 525pt on the broken build and 11,409pt on
//    the fixed one, because a value sampled across generation boundaries and
//    keyboard-driven inset changes is not the same quantity the trace measures.
//    Three separate in-test pins each read clean on the broken build for a
//    different reason before that one read garbage on the good build.
//
//  The scroll view knows its own offset. Asking it costs one `os_log` per
//  geometry change and answers precisely — and the answer is read out of band,
//  by the follow-checker reading the log stream, with the app left completely alone.
//
//  DEBUG-only and off unless `-scrollTrace 1` is passed, so a shipping build
//  cannot reach it and an ordinary debug run does not pay for it.
//
//      xcrun simctl spawn booted log stream --level debug \
//        --predicate 'subsystem == "ai.teemoon" AND category == "scroll"'
//
//  Each line is `offset contentHeight visibleHeight generating`, which is
//  enough to reconstruct velocity, the distance to the end of the content, and
//  whether a movement happened during generation or after it.
//

import SwiftUI
import os

#if DEBUG
private let scrollLogger = Logger(subsystem: "ai.teemoon", category: "scroll")

/// How many transcript rows the lazy stack currently has realised.
///
/// The reported defect is "the screen blanked out in the middle of generation
/// and I had to scroll down to refresh it" — a LazyVStack showing a region it
/// has not built. That is a STATE of the view tree, and it cannot be read from
/// outside: an XCUI query walks the accessibility tree, which forces the rows
/// to be built, so the measurement performs the very refresh the user had to do
/// by hand. The transcript has to count itself.
@MainActor
final class RealizedRowCounter {
    static let shared = RealizedRowCounter()
    private(set) var count = 0
    func entered() { count += 1 }
    func left() { count = max(0, count - 1) }
}

/// Records the streaming pipeline's two lengths so a stall can be attributed.
///
/// `output` is what the model layer has received; `paced` is what the renderer
/// is showing. If both stall together the delay is upstream — network, SSE
/// parsing, the engine. If `output` keeps growing while `paced` sits still, the
/// main thread is not getting to render, and whatever it is doing instead is
/// the defect. "It returns the bottom half of a fast generation in one batch"
/// is one of those two and they want opposite fixes.
@MainActor
enum StreamTrace {
    /// One sample of the whole pipeline's state. `kind` says what triggered it:
    /// `tick` (paced text changed) or `beat` (the periodic heartbeat below).
    ///
    /// The heartbeat exists because a tick-only trace is structurally blind to
    /// the very thing being diagnosed: ticks fire when text moves, so a stall
    /// is a GAP in the trace, with no record of what the app was doing or
    /// showing inside it. The flags answer that: was a tool executing, was a
    /// follow-up turn in flight, and was the activity chip actually VISIBLE.
    static func record(output: Int, paced: Int,
                       executingTools: Bool, awaitingModel: Bool,
                       thinking: Bool, sources: Int,
                       chipVisible: Bool, kind: String = "tick") {
        guard ScrollTraceEnabled.value else { return }
        ScrollTraceFileAccess.append(
            "[streamtrace] t=\(ProcessInfo.processInfo.systemUptime) "
            + "outLen=\(output) pacedLen=\(paced) "
            + "tools=\(executingTools ? 1 : 0) await=\(awaitingModel ? 1 : 0) "
            + "think=\(thinking ? 1 : 0) sources=\(sources) "
            + "chip=\(chipVisible ? 1 : 0) kind=\(kind)")
    }

    /// A discrete pipeline event — tool round edges, awaiting-model edges —
    /// stamped on the same clock as the samples so the two interleave.
    static func event(_ name: String) {
        guard ScrollTraceEnabled.value else { return }
        ScrollTraceFileAccess.append(
            "[streamevent] t=\(ProcessInfo.processInfo.systemUptime) \(name)")
    }
}

/// Appends the trace to a file inside the app container as well as os_log.
///
/// `log collect` against an attached device requires root, which a test run
/// should not need. A file in Documents comes back with
/// `devicectl device copy from`, no privileges involved.
enum ScrollTraceFileAccess {
    @MainActor static func append(_ line: String) { ScrollTraceFile.shared.append(line) }
}

/// Wire-side samples, stamped where the bytes ARRIVE — `HTTPTransport`'s SSE
/// loop, off the main actor. One line per SSE event:
///
///     [wiretrace] t=… turn=N raw=… vis=… reas=…
///
/// `raw` is everything the parser has accumulated (elided markup included),
/// `vis` is what has been forwarded for display, `reas` is reasoning tokens.
/// The three cumulative curves are the attribution: if `raw` itself is bursty,
/// the unevenness is upstream (model or network — `reas` growing through a
/// `raw` pause names the model); if `raw` is smooth while `vis` is bursty, the
/// elider is batching and the defect is ours.
enum WireTrace {
    static func record(turn: Int, raw: Int, visible: Int, reasoning: Int) {
        guard ScrollTraceEnabled.value else { return }
        ScrollTraceFile.shared.append(
            "[wiretrace] t=\(ProcessInfo.processInfo.systemUptime) "
            + "turn=\(turn) raw=\(raw) vis=\(visible) reas=\(reasoning)")
    }

    static func event(turn: Int, _ name: String) {
        guard ScrollTraceEnabled.value else { return }
        ScrollTraceFile.shared.append(
            "[wireevent] t=\(ProcessInfo.processInfo.systemUptime) turn=\(turn) \(name)")
    }

    /// Turn ordinal for correlating wire lines with the engine's events. Wire
    /// code is not on the main actor, so this is its own counter rather than a
    /// read of UI state; it resets when the app does, which a trace run is.
    static func nextTurn() -> Int {
        turnLock.withLock { turnCounter += 1; return turnCounter }
    }
    private static let turnLock = NSLock()
    private static nonisolated(unsafe) var turnCounter = 0
}

/// The UIKit transcript's geometry sampler.
///
/// Emits the SAME `[scrolltrace]` line, with the same columns in the same
/// order, as the `ScrollTrace` view modifier below — because the whole value of
/// the overscroll metric is that the two implementations are comparable.
/// The trace analyzer counts samples where
/// `offset + visible > contentH + 250`; the SwiftUI transcript traced ~600 of
/// them per generation (the blank screen) and the collection view's target is
/// zero. A trace in a different format would have made that comparison
/// impossible to make.
@MainActor
enum TranscriptTrace {
    static func geometry(offset: CGFloat, contentHeight: CGFloat, visibleHeight: CGFloat,
                         generating: Bool, interrupted: Bool, dragged: Bool, following: Bool) {
        guard ScrollTraceEnabled.value else { return }
        let line = "[scrolltrace] t=\(ProcessInfo.processInfo.systemUptime) "
            + "offset=\(offset) contentH=\(contentHeight) "
            + "visibleH=\(visibleHeight) rows=\(RealizedRowCounter.shared.count) "
            + "gen=\(generating ? 1 : 0) intr=\(interrupted ? 1 : 0) "
            + "drag=\(dragged ? 1 : 0) follow=\(following ? 1 : 0)"
        scrollLogger.debug("\(line, privacy: .public)")
        ScrollTraceFile.shared.append(line)
    }
}

/// Lock-guarded so the wire loop (URLSession task) and the UI (main actor) can
/// interleave lines without tearing; every line carries its own timestamp, so
/// ordering across writers is recovered by the reader.
private final class ScrollTraceFile: @unchecked Sendable {
    static let shared = ScrollTraceFile()
    private let handle: FileHandle?
    private let lock = NSLock()

    init() {
        guard let dir = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask).first else {
            handle = nil; return
        }
        let url = dir.appendingPathComponent("scrolltrace.log")
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func append(_ line: String) {
        guard let handle, let data = (line + "\n").data(using: .utf8) else { return }
        lock.withLock { try? handle.write(contentsOf: data) }
    }
}

private struct ScrollTraceGeometry: Equatable {
    var offset: CGFloat
    var contentHeight: CGFloat
    var visibleHeight: CGFloat
}

private struct ScrollTrace: ViewModifier {
    let isGenerating: Bool
    let interrupted: Bool
    let dragged: Bool
    let following: Bool
    static var enabled: Bool { ScrollTraceEnabled.value }

    func body(content: Content) -> some View {
        if Self.enabled {
            content.onScrollGeometryChange(for: ScrollTraceGeometry.self) { geo in
                ScrollTraceGeometry(offset: geo.contentOffset.y,
                                    contentHeight: geo.contentSize.height,
                                    visibleHeight: geo.visibleRect.height)
            } action: { _, g in
                // Monotonic clock: the reader wants intervals, and wall time can
                // step. %{public} so the values survive log redaction.
                //
                // The flag columns answer "the follow stopped — WHY": a dead
                // follow with dragged=0 is a false interruption, with dragged=1
                // it is the geometry rule honouring a real (or spurious) touch.
                let line = "[scrolltrace] t=\(ProcessInfo.processInfo.systemUptime) "
                    + "offset=\(g.offset) contentH=\(g.contentHeight) "
                    + "visibleH=\(g.visibleHeight) rows=\(RealizedRowCounter.shared.count) "
                    + "gen=\(isGenerating ? 1 : 0) intr=\(interrupted ? 1 : 0) "
                    + "drag=\(dragged ? 1 : 0) follow=\(following ? 1 : 0)"
                scrollLogger.debug("\(line, privacy: .public)")
                ScrollTraceFile.shared.append(line)
            }
        } else {
            content
        }
    }
}
#endif

extension View {
    /// Emits the transcript's scroll offset on every geometry change when
    /// `-scrollTrace` is set. No-op in release, and in debug without the flag.
    @ViewBuilder func scrollTrace(isGenerating: Bool, interrupted: Bool = false,
                                  dragged: Bool = false, following: Bool = false) -> some View {
        #if DEBUG
        modifier(ScrollTrace(isGenerating: isGenerating, interrupted: interrupted,
                             dragged: dragged, following: following))
        #else
        self
        #endif
    }
}

extension View {
    /// Counts this row in `RealizedRowCounter` while it exists, so the trace can
    /// report how much of the transcript the lazy stack is actually holding.
    /// No-op in release, and in debug without `-scrollTrace`.
    @ViewBuilder func countsAsRealizedRow() -> some View {
        #if DEBUG
        if ScrollTraceEnabled.value {
            onAppear { RealizedRowCounter.shared.entered() }
                .onDisappear { RealizedRowCounter.shared.left() }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if DEBUG
enum ScrollTraceEnabled {
    static let value = ProcessInfo.processInfo.arguments.contains("-scrollTrace")
        || ProcessInfo.processInfo.environment["TEEMOON_SCROLL_TRACE"] == "1"
}
#endif
