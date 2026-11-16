//
//  ComposerPanelPolicyTests.swift
//  teemoonTests
//
//  The composer as one panel (docs/COMPOSER_PANEL.md, the maintainer 2026-11-12): what the bottom row shows.
//

import Testing
@testable import teemoon

@Suite("Composer panel — the bottom row")
struct ComposerPanelPolicyTests {

    @Test func theWebChipHidesOnlyForAModelThatCantTakeTools() {
        #expect(!ComposerPanelPolicy(modelTakesTools: false).showsWebChip)
        #expect(ComposerPanelPolicy(modelTakesTools: true).showsWebChip)
        #expect(ComposerPanelPolicy(modelTakesTools: nil).showsWebChip, "unknown is optimistic, as modelSupportsTools")
    }

    @Test func aChipWithAStatusOrALargeSizePutsWebIconOnly() {
        #expect(!ComposerPanelPolicy(modelTakesTools: true).webIconOnly)
        #expect(ComposerPanelPolicy(modelTakesTools: true, chipHasStatus: true).webIconOnly)
        #expect(ComposerPanelPolicy(modelTakesTools: true, accessibilitySize: true).webIconOnly)
    }

    @Test func atAccessibilitySizesTheChipDropsItsNameNotItsStatus() {
        let large = ComposerPanelPolicy(modelTakesTools: true, chipHasStatus: true, accessibilitySize: true)
        #expect(!large.chipShowsName)
        #expect(large.chipShowsStatus)
        #expect(ComposerPanelPolicy(modelTakesTools: true).chipShowsName)
    }

    @Test func theTextGrowsToSixLinesThenScrolls() {
        #expect(ComposerPanelPolicy(modelTakesTools: true).maxLines == 6)
        #expect(ComposerPanelPolicy(modelTakesTools: true, accessibilitySize: true).maxLines == 4)
    }

    /// Developer mode's level on the where chip keeps the name whole: web goes glyph-only, as for a status.
    @Test func aLevelOnTheChipPutsWebIconOnly() {
        #expect(ComposerPanelPolicy(modelTakesTools: true, chipShowsLevel: true).webIconOnly)
        #expect(!ComposerPanelPolicy(modelTakesTools: true, chipShowsLevel: false).webIconOnly)
    }
}
