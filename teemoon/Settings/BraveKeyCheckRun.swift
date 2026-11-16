//
//  BraveKeyCheckRun.swift
//  teemoon
//
//  The brave key check behind the search settings field: what brave said, and
//  whether a check is running.
//

import Foundation
import Observation

@MainActor
@Observable
final class BraveKeyCheckRun {
    typealias Checker = @Sendable (String) async -> BraveWebSearchTool.KeyCheck

    private(set) var result: BraveWebSearchTool.KeyCheck?
    private(set) var checking = false
    @ObservationIgnored private let checker: Checker
    /// Bumped by every check and edit: a check that is no longer the latest writes nothing.
    @ObservationIgnored private var run = 0

    init(checker: @escaping Checker = { await BraveWebSearchTool.checkKey($0) },
         result: BraveWebSearchTool.KeyCheck? = nil) {
        self.checker = checker
        self.result = result
    }

    /// The field changed: brave's answer, and any check still running, were about the old text.
    func keyEdited() {
        run += 1
        checking = false
        result = nil
    }

    /// Brave's answer for `key`, or nil when an edit or a later check overtook it.
    func check(_ key: String) async -> BraveWebSearchTool.KeyCheck? {
        run += 1
        let mine = run
        checking = true
        let verdict = await checker(key)
        guard mine == run else { return nil }
        checking = false
        result = verdict
        return verdict
    }
}
