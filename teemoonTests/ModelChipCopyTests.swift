//
//  ModelChipCopyTests.swift
//  teemoonTests
//
//  Copy that sends people to the model chip says where it is: in the message box on iOS since the one-panel composer;
//  above the field on macOS, where the chips still sit (card settings-chip-footer, the maintainer 2026-11-13).
//

import Testing
@testable import teemoon

@Suite("Model chip copy")
struct ModelChipCopyTests {

    @Test func theSettingsFooterIsTheApprovedSentence() {
        #if os(iOS)
        #expect(ModelChipCopy.settingsFooter
                == "manage hosts and keys here. to switch model mid-chat, tap the model chip in the message box.")
        #else
        #expect(ModelChipCopy.settingsFooter
                == "manage hosts and keys here. to switch model mid-chat, click the model chip above the message field.")
        #endif
    }

    @Test func placesAndKeysSaysTheSamePlace() {
        #if os(iOS)
        #expect(ModelChipCopy.placesKeysFooter == "to switch model mid-chat, tap the model chip in the message box — not here.")
        #endif
        #expect(!ModelChipCopy.placesKeysFooter.contains("use the chip"))
    }
}
