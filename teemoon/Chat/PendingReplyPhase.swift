//
//  PendingReplyPhase.swift
//  teemoon
//
//  What the reply placeholder says before any text arrives. Nothing has been sent while the gate waits, so it never
//  reads thinking then (formal/ ThinkingOnlyAfterSend). PendingReplyPhaseTests pins it.
//

import Foundation

enum PendingReplyPhase: Equatable {
    case waitingForVerification
    case thinking
    case thinkingHarder
    case loadingModel(String)

    /// `gateWaiting`: prepareTurn is holding this turn's send. `loadLine`: an on-device engine load (EngineLoadLine).
    static func of(gateWaiting: Bool, loadLine: String?, thinkingHarder: Bool) -> PendingReplyPhase {
        if let loadLine { return .loadingModel(loadLine) }
        if gateWaiting { return .waitingForVerification }
        return thinkingHarder ? .thinkingHarder : .thinking
    }
}
