//
//  WebSearchOfferModel.swift
//  teemoon
//
//  The offer card's paste → check → accept run. The card only draws `key`,
//  `checking`, `check` and `accepted`.
//

import Foundation
import Observation

@MainActor
@Observable
final class WebSearchOfferModel {
    private(set) var key: String
    private(set) var accepted: Bool
    let keyCheck: BraveKeyCheckRun
    @ObservationIgnored private let beat: () async -> Void
    /// Bumped by every paste and by dismiss: only the latest paste may hand a key over.
    @ObservationIgnored private var run = 0

    var checking: Bool { keyCheck.checking }
    var check: BraveWebSearchTool.KeyCheck? { keyCheck.result }

    init(key: String = "",
         check: BraveWebSearchTool.KeyCheck? = nil,
         accepted: Bool = false,
         checker: @escaping BraveKeyCheckRun.Checker = { await BraveWebSearchTool.checkKey($0) },
         beat: @escaping () async -> Void = { try? await Task.sleep(for: .milliseconds(1700)) }) {
        self.key = key
        self.accepted = accepted
        self.keyCheck = BraveKeyCheckRun(checker: checker, result: check)
        self.beat = beat
    }

    /// Checks the pasted key; only a key brave accepted is handed to `onAccepted`, after the beat.
    func paste(_ text: String, onAccepted: @escaping (String) -> Void) async {
        run += 1
        let mine = run
        key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        accepted = false
        guard await keyCheck.check(key) == .valid, mine == run else { return }
        accepted = true
        await beat()
        guard mine == run else { return }
        onAccepted(key)
    }

    /// Declining stops a check or beat still running: nothing is saved after the card is gone.
    func dismiss(_ onDismiss: () -> Void) {
        run += 1
        onDismiss()
    }
}
