import Foundation
import Testing
@testable import teemoon

@Suite("PlaceLabel")
struct PlaceLabelTests {

    @Test func emptyNameTakesPreset() {
        let next = PlaceLabel.proposed(
            currentName: "", lastAuto: "", presetName: "near.ai", host: "example.com")
        #expect(next == "near.ai")
    }

    @Test func emptyNameTakesFriendlyHostWhenNoPreset() {
        let next = PlaceLabel.proposed(
            currentName: "", lastAuto: "", presetName: "", host: "ringzero.tailnet.ts.net")
        #expect(next == "ringzero")
    }

    @Test func matchingAutoLabelRefreshes() {
        let next = PlaceLabel.proposed(
            currentName: "near.ai", lastAuto: "near.ai", presetName: "grok", host: nil)
        #expect(next == "grok")
    }

    @Test func typedNameIsNeverOverwritten() {
        let next = PlaceLabel.proposed(
            currentName: "work box", lastAuto: "near.ai", presetName: "grok", host: "x.com")
        #expect(next == nil)
    }

    @Test func nothingToNameReturnsNil() {
        let next = PlaceLabel.proposed(
            currentName: "", lastAuto: "", presetName: "", host: nil)
        #expect(next == nil)
    }
}
