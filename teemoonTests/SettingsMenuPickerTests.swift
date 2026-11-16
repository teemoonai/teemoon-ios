//
//  SettingsMenuPickerTests.swift
//  teemoonTests
//
//  appearance-plain-values (2026-11-07): a Settings menu Picker's value and its chevrons are secondary, not the
//  tint; the row's glyph keeps the app tint, as every Settings glyph does.
//

import SwiftUI
import Testing
@testable import teemoon

@Suite("Settings menu pickers")
struct SettingsMenuPickerTests {
    @Test func theValueIsSecondaryAndTheGlyphKeepsTheAppTint() {
        #expect(SettingsMenuPicker.valueTint == Color.secondary)
        for tint in AppTintColor.allCases {
            #expect(SettingsMenuPicker.glyphTint(tint) == tint.getColor())
        }
    }
}
