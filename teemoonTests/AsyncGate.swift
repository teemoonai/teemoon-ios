//
//  AsyncGate.swift
//  teemoonTests
//
//  Holds an injected async seam until the test opens it, so a test can finish
//  one request before another and see which late result is allowed to write.
//

import Foundation

actor AsyncGate {
    private var isOpen = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called by the seam: records arrival, then waits for `open()`.
    func pass() async {
        entered = true
        enterWaiters.forEach { $0.resume() }
        enterWaiters = []
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Returns once the seam has been reached.
    func reached() async {
        guard !entered else { return }
        await withCheckedContinuation { enterWaiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
