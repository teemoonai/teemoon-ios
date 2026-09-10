//
//  NetworkPathObserver.swift
//  teemoon
//
//  Lightweight reachability for empty states (airplane mode). Not a full
//  networking stack — just “is there a path right now?”
//

import Foundation
import Network
import Observation

@Observable
@MainActor
final class NetworkPathObserver {
    static let shared = NetworkPathObserver()

    /// True when the default path is satisfied (any interface).
    private(set) var isSatisfied: Bool = true
    /// Cellular or a personal hotspot — the system's own definition, the one
    /// URLSession's `allowsExpensiveNetworkAccess` is judged against.
    ///
    /// NOT SUFFICIENT ON ITS OWN. the test phone (iPhone 16 Pro) reports its cellular
    /// path as `expensive=false` (an unlimited plan / "Allow More Data on 5G"
    /// does that), so a download gate keyed on this alone never fired.
    private(set) var isExpensive: Bool = false
    /// The path goes over the cellular radio, whatever iOS thinks it costs.
    private(set) var isCellular: Bool = false
    /// Low Data Mode.
    private(set) var isConstrained: Bool = false

    /// What "mobile data" means to the download gate: the radio is cellular, or
    /// iOS calls the path expensive (a hotspot over wi-fi is the latter).
    var isMobileData: Bool { isCellular || isExpensive }

    /// Called on the main actor after every path update, with the new
    /// (mobile data, constrained) pair — for code that must act on a change, not
    /// merely redraw. Also called once at registration with the current values.
    private var onChange: [(Bool, Bool) -> Void] = []

    func addChangeHandler(_ handler: @escaping (Bool, Bool) -> Void) {
        onChange.append(handler)
        handler(isMobileData, isConstrained)
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.teemoon.network-path")

    private init() {
        // A simulator has no cellular radio, so the mobile-data paths — the
        // prompt, "waiting for wi-fi" — could only ever be looked at on a phone
        // with wi-fi switched off. DEBUG-only, argument-gated.
        #if DEBUG
        let forceExpensive = ProcessInfo.processInfo.arguments.contains("-simulateExpensivePath")
        #else
        let forceExpensive = false
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let expensive = path.isExpensive || forceExpensive
            let cellular = path.usesInterfaceType(.cellular)
            let constrained = path.isConstrained
            DiagLog.note("[path] status=\(path.status) expensive=\(path.isExpensive) constrained=\(path.isConstrained) wifi=\(path.usesInterfaceType(.wifi)) cellular=\(cellular)")
            Task { @MainActor in
                guard let self else { return }
                // Route re-evaluations repeat the same answer; a same-value
                // write to an @Observable property is still an invalidation.
                guard satisfied != self.isSatisfied || expensive != self.isExpensive
                    || cellular != self.isCellular || constrained != self.isConstrained else { return }
                self.isSatisfied = satisfied
                self.isExpensive = expensive
                self.isCellular = cellular
                self.isConstrained = constrained
                for handler in self.onChange { handler(self.isMobileData, constrained) }
            }
        }
        monitor.start(queue: queue)
    }

    /// Preview/test seam: a fixed answer, and no monitor started. The offline
    /// empty states are otherwise only reachable by putting the machine in
    /// airplane mode, which is not something a preview can do — so that copy
    /// went unreviewed.
    init(simulatingSatisfied: Bool, expensive: Bool = false, cellular: Bool = false,
         constrained: Bool = false) {
        isSatisfied = simulatingSatisfied
        isExpensive = expensive
        isCellular = cellular
        isConstrained = constrained
    }
}
