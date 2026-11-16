//
//  AddedSetupWatchTests.swift
//  teemoonTests
//
//  "add cloud key" with no setups yet: saving the key form left the picker up,
//  because an empty "before" set read as "never left for a form".
//

import Foundation
import Testing
@testable import teemoon

@Suite("Cloud key picker pops after a save")
struct AddedSetupWatchTests {
    @Test func theFirstSetupEverSavedPopsThePicker() {
        var watch = AddedSetupWatch()
        watch.leaving(with: [])
        let popped = watch.returned(with: [UUID()])
        #expect(popped)
    }

    @Test func aCancelLeavesThePickerUp() {
        let existing = UUID()
        var watch = AddedSetupWatch()
        let onFirstAppearance = watch.returned(with: [existing])
        #expect(!onFirstAppearance, "first appearance is not a return")
        watch.leaving(with: [])
        let afterEmptyCancel = watch.returned(with: [])
        #expect(!afterEmptyCancel)
        watch.leaving(with: [existing])
        let afterCancel = watch.returned(with: [existing])
        #expect(!afterCancel)
    }
}
