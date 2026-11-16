//
//  AddedSetupWatch.swift
//  teemoon
//
//  Did the key form the picker pushed save a new setup? The picker pops on save
//  and stays on cancel.
//

import Foundation

struct AddedSetupWatch {
    /// nil until the picker leaves for a form; an empty set is a real "before" (no setups yet).
    private var before: Set<UUID>?

    mutating func leaving(with ids: [UUID]) { before = Set(ids) }

    /// True once, on the return from a form that saved a new setup.
    mutating func returned(with ids: [UUID]) -> Bool {
        guard let before else { return false }
        self.before = nil
        return ids.contains { !before.contains($0) }
    }
}
