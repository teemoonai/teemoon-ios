//
//  AppTintWindowTests.swift
//  teemoonTests
//
//  The maintainer (2026-10-21): "settings appearance tint shows the orange color before
//  applying the selected color. Sometimes it stays orange". Menu-style pickers
//  are UIKit buttons: they read the window's tintColor, which SwiftUI's `.tint`
//  never sets, so they drew the orange AccentColor asset whatever was chosen.
//  An already-drawn one also keeps its colour, hence the `.id` on the
//  appearance form (checked on the simulator with screenshots, not here).
//

#if os(iOS)
import Testing
import UIKit
import SwiftUI
@testable import teemoon

@Suite("App tint reaches UIKit")
@MainActor
struct AppTintWindowTests {

    @Test func theChosenTintIsTheWindowsTint() throws {
        let window = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first, "the test host has no window")
        let before = window.tintColor
        defer { window.tintColor = before }

        AppTintColor.green.applyToWindows()
        #expect(window.tintColor == UIColor(Color.green))

        AppTintColor.monochrome.applyToWindows()
        #expect(window.tintColor == UIColor.label, "monochrome follows the text colour in light and dark")
    }
}
#endif
