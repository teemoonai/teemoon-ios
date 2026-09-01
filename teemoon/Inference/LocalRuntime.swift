//
//  LocalRuntime.swift
//  teemoon
//
//  The parts of on-device inference that are not specific to one runtime: the
//  error type, the memory gate, and the one-generation-at-a-time lock.
//
//  These lived in `MLXTransport.swift` until MLX was removed. Keeping them
//  runtime-neutral is deliberate — LiteRT is the only backend today, but the
//  memory gate and the serialization lock are properties of the *phone*, not of
//  whichever library happens to be loading the weights.
//
//  Related: LiteRTTransport.swift (the runtime), LocalLanguageModel.swift,
//  GenerationTransport.swift (the seam that made swapping runtimes cheap).
//

import Foundation
import os

#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "ai.teemoon", category: "local.runtime")

// MARK: - Errors

enum LocalInferenceError: LocalizedError {
    case modelNotDownloaded(String)
    case insufficientMemory(needMB: Int, availableMB: Int)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let id):
            return "\(id) isn't downloaded yet. Download it before starting a chat."
        case .insufficientMemory(let need, let available):
            return "Not enough free memory to load this model (needs about \(need) MB, \(available) MB available). Close some apps, or pick a smaller model."
        case .loadFailed(let detail):
            return "The model couldn't be loaded: \(detail)"
        }
    }
}

// MARK: - Memory

/// The pre-load memory gate.
///
/// A model that does not fit must be refused *before* loading rather than
/// discovered by the jetsam killer, which takes the whole app down mid-answer.
enum LocalMemory {

    /// Memory teemoon refuses to dip below, over and above the weights. KV cache
    /// and activations grow with context length, and being jetsammed mid-answer
    /// is a far worse failure than declining to start.
    static let headroomMB = 512

    /// Memory this process may still allocate, in MB.
    ///
    /// `os_proc_available_memory()` is the honest number: it accounts for the
    /// jetsam limit teemoon is actually held to, including the bump from the
    /// `com.apple.developer.kernel.increased-memory-limit` entitlement. Total
    /// physical RAM would badly overstate the budget.
    static func availableMB() -> Int {
        #if os(iOS)
        return Int(os_proc_available_memory()) / (1024 * 1024)
        #else
        return Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        #endif
    }

    static func check(needMB: Int) throws {
        let available = availableMB()
        // 0 means the API is unavailable (simulator, some macOS paths) — don't
        // block on a number we couldn't read.
        guard available > 0 else { return }
        guard available >= needMB else {
            throw LocalInferenceError.insufficientMemory(needMB: needMB, availableMB: available)
        }
    }

    /// Download size vs process budget. `availableMB == 0` means the API is
    /// silent — do not warn. See WhereGetPolicyTests.
    static func exceedsAvailable(sizeMB: Int, availableMB: Int = availableMB()) -> Bool {
        availableMB > 0 && sizeMB > availableMB
    }
}

extension LocalMemory {

    /// "around 4.1gb free for loading weights", or nil when the API won't say.
    ///
    /// MEMORY, not disk — the prototype's footer measured the same thing, and it
    /// is the number that decides whether a model can run. Disk only decides
    /// whether it can be stored, and a phone with 40 GB spare can still fail to
    /// load a 3 GB model. "around" because the figure moves as other apps come
    /// and go; a precise-looking number here would be false precision.
    /// `availableMB` is a parameter so the formatting can be tested: the real
    /// reading is 0 on the simulator, which hides the footer and makes this
    /// string unreviewable there.
    /// Just the figure — "8.1 gb" — for callers that supply their own sentence.
    static func weightsHeadroomFigure(availableMB mb: Int = availableMB()) -> String? {
        guard mb > 0 else { return nil }
        let gb = Double(mb) / 1024
        return gb >= 10 ? "\(Int(gb.rounded())) gb" : String(format: "%.1f gb", gb)
    }

    static func weightsHeadroomLabel(availableMB mb: Int = availableMB()) -> String? {
        guard mb > 0 else { return nil }
        let gb = Double(mb) / 1024
        let value = gb >= 10
            ? "\(Int(gb.rounded()))"
            : String(format: "%.1f", gb)
        return "around \(value)gb free for loading weights"
    }
}

// MARK: - Generation serialization

/// Lets exactly one on-device generation run at a time.
///
/// It matters in the app in a way it never does in a test: a retry, a second
/// send before the first finishes, or a tool round overlapping a cancelled
/// generation all put two generations in flight. Queueing costs a little
/// latency; not queueing means two multi-gigabyte engines resident at once on a
/// device that is already gating loads on free memory.
actor LocalGenerationGate {
    static let shared = LocalGenerationGate()

    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    /// Waits for the lock, and HONOURS CANCELLATION while waiting.
    ///
    /// `withCheckedContinuation` is not cancellation-aware: a task cancelled
    /// while queued here waits forever, because nothing ever resumes it. That is
    /// what made a wedged generation unrecoverable — pressing stop cancelled the
    /// task, the task stayed parked on this continuation, the composer never
    /// re-enabled, and the only way out was force-quitting the app.
    ///
    /// Throwing on cancellation lets the caller unwind and the UI reset.
    func acquire() async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}

// MARK: - Which on-device model is resident

/// Which downloaded model currently has an engine built — so the picker can say
/// whether a phone row answers now or pays a load first.
///
/// A MIRROR, not the truth. The truth is `LiteRTTransport.EngineCache`, a
/// fileprivate actor, and list rows render synchronously — they cannot await it.
/// So the cache pushes here after every mutation it makes.
///
/// Measured on an iPhone 16 Pro (`measuresWhatAColdStartCosts`): a cold start
/// costs 2.3–4.0 s before the first token against 0.86 s warm, which is what
/// makes this worth showing at all.
@Observable
@MainActor
final class LocalEngineResidency {
    static let shared = LocalEngineResidency()

    /// A SET, though the cache holds one engine at a time on purpose. Mirroring
    /// the shape rather than the current policy means a cache that later keeps
    /// two resident doesn't silently start lying here.
    private(set) var resident: Set<URL> = []

    /// What the last engine build cost, and for which model.
    ///
    /// Surfaced on the developer-mode debug card. Measured 2.3–4.0 s on an iPhone
    /// 16 Pro (`measuresWhatAColdStartCosts`), against 0.86 s warm — the number
    /// that explains a slow first answer, and the reason the picker shows warmth at
    /// all. Nil until something has been built this session.
    ///
    /// A property of the ENGINE, not of a request: one build serves every turn until
    /// it's evicted, so the card labels it "last model load" rather than implying
    /// this turn paid it.
    private(set) var lastLoad: (file: URL, took: Duration)?

    private init() {}

    func isResident(_ file: URL) -> Bool { resident.contains(file) }

    /// Called by the cache — after a build, after an eviction, and after a build
    /// that FAILED the memory gate, which leaves nothing resident and has to be
    /// visible as such.
    func update(resident files: Set<URL>) { resident = files }

    /// Called after a successful build, with what it cost.
    func recordLoad(of file: URL, took: Duration) { lastLoad = (file, took) }

    /// Previews and tests. Never touches the real engine cache.
    ///
    /// `lastLoad` is settable here too, because the debug card renders it and a
    /// canvas has no engine to build: the only way to see that row was to run a
    /// cold generation on a device, which is exactly the state a preview exists to
    /// spare you.
    static func previewing(
        _ files: [URL], lastLoad: (file: URL, took: Duration)? = nil
    ) -> LocalEngineResidency {
        let residency = LocalEngineResidency()
        residency.resident = Set(files)
        residency.lastLoad = lastLoad
        return residency
    }
}

// MARK: - Memory pressure

/// Releases loaded weights when the system asks for memory back.
///
/// Previously noted as "NOT WIRED YET" and left that way — a backgrounded
/// teemoon holding a 2.5 GB engine is a prime jetsam candidate, and the pre-load
/// gate does nothing about a model that is *already* resident.
///
/// Start once, from the app. Both notifications matter: the memory-warning one
/// fires while in the foreground, and backgrounding is the moment the app is
/// most likely to be killed for holding weights nobody is using.
@MainActor
enum LocalMemoryPressure {
    private static var started = false

    static func startObserving() {
        guard !started else { return }
        started = true
        #if canImport(UIKit)
        let center = NotificationCenter.default
        for name in [UIApplication.didReceiveMemoryWarningNotification,
                     UIApplication.didEnterBackgroundNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                logger.info("[local] \(note.name.rawValue, privacy: .public) — releasing on-device models")
                Task { await LiteRTTransport.evictEngines() }
            }
        }
        #endif
    }
}
