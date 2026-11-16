//
//  SettingsMenuPicker.swift
//  teemoon
//
//  How a Settings menu Picker is inked (review item appearance-plain-values, 2026-11-07).
//

import SwiftUI

enum SettingsMenuPicker {
    /// The value and its chevrons are information, not an action: never the tint.
    static let valueTint = Color.secondary

    /// `valueTint` on the Picker would grey the row's glyph too; the glyph keeps the app tint like every Settings row.
    static func glyphTint(_ tint: AppTintColor) -> Color { tint.getColor() }
}
