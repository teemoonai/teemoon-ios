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

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.teemoon.network-path")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isSatisfied = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    /// Preview/test seam: a fixed answer, and no monitor started. The offline
    /// empty states are otherwise only reachable by putting the machine in
    /// airplane mode, which is not something a preview can do — so that copy
    /// went unreviewed.
    init(simulatingSatisfied: Bool) {
        isSatisfied = simulatingSatisfied
    }
}
