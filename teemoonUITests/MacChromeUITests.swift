//
//  MacChromeUITests.swift
//  teemoonUITests
//
//  The Mac-native behaviour that CANNOT be asserted headlessly.
//
//  MacDesignSnapshotTests covers component rendering in the background, but it
//  rasterizes a SwiftUI tree — it has no window, no menu bar, no responder chain
//  and no key equivalents. Everything here is about the app as an app, so it
//  needs a real launch:
//
//      xcodebuild test -destination 'platform=macOS,arch=arm64' \
//        -only-testing:teemoonUITests/MacChromeUITests
//
//  RUNNING THIS TAKES OVER THE SCREEN. XCUITest drives the developer's own
//  console session — it launches teemoon frontmost and raises the "automation
//  running" notice — because it works through the accessibility API inside a
//  WindowServer session and there is exactly one active one. There is no
//  headless flag. For background runs the options are a macOS VM (Tart,
//  Virtualization.framework) or a remote runner.
//

#if os(macOS)

import CoreImage
import XCTest

final class MacChromeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    /// The app must present a window, not just take the menu bar.
    ///
    /// This was red for a while, and the cause was worth writing down: AppKit
    /// creates a `WindowGroup`'s first window in response to the LaunchServices
    /// open/reopen Apple Event, which a directly `exec`'d process never receives
    /// — and XCUITest launches macOS apps by exec'ing the binary. Launched by
    /// `open teemoon.app` the app owned an on-screen 1000x640 window; launched by
    /// the harness it owned five windows, none of them the content window. Never
    /// created, not invisible to accessibility.
    ///
    /// `AppDelegate.presentInitialWindow()` now sends that event to itself at
    /// launch, so the window exists however the process was started. This test is
    /// the regression guard for it, and the two window-dependent tests below
    /// (⌘, and the appearance check) ride on the same fix.
    func testLaunchPresentsAWindow() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10),
                      "teemoon launched without presenting a window")

        let frame = window.frame
        XCTAssertGreaterThan(frame.width, 400, "window is implausibly narrow: \(frame)")
        XCTAssertGreaterThan(frame.height, 300, "window is implausibly short: \(frame)")

        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "macOS window at launch"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Closing the last window must not strand the app without one.
    ///
    /// The Dock-icon route to this cannot be tested here — `activate()` does not
    /// deliver a reopen Apple Event, measured by instrumenting the delegate (one
    /// reopen per run, the launch one). Window ▸ Show Main Window is the same
    /// recovery through a path XCUITest can actually drive, and it is the item
    /// this suite already asserts the existence of; existing and working are
    /// different claims.
    ///
    /// Until the launch fix there was no way to test any of this, because there
    /// was no window under XCUITest to close in the first place.
    func testShowMainWindowRecoversAfterClosingTheLastWindow() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("w", modifierFlags: .command)
        let gone = NSPredicate(format: "count == 0")
        expectation(for: gone, evaluatedWith: app.windows, handler: nil)
        waitForExpectations(timeout: 5) { error in
            XCTAssertNil(error, "⌘W did not close the window")
        }

        let windowMenu = app.menuBars.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 5), "no Window menu")
        windowMenu.click()
        app.menuBars.menuItems["Show Main Window"].click()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10),
                      "Show Main Window brought nothing back — with no window open the app is unreachable")
    }

    /// File ▸ New Chat exists.
    ///
    /// It did not before: `CommandGroup(replacing: .newItem)` had put "Show Main
    /// Window" in its place, leaving File with no New at all.
    func testFileMenuHasNewChat() throws {
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 10), "no File menu")
        fileMenu.click()

        let newChat = app.menuBars.menuItems["New Chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5),
                      "File menu has no New Chat — an empty File menu is the clearest tell of a port")
        fileMenu.typeKey(.escape, modifierFlags: [])
    }

    /// "Show Main Window" belongs in Window, not File.
    func testShowMainWindowIsInTheWindowMenu() throws {
        let windowMenu = app.menuBars.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 10), "no Window menu")
        windowMenu.click()

        XCTAssertTrue(app.menuBars.menuItems["Show Main Window"].waitForExistence(timeout: 5),
                      "Show Main Window is not in the Window menu")
        windowMenu.typeKey(.escape, modifierFlags: [])
    }

    /// The standard Settings item exists, which only happens when the app
    /// declares a `Settings` scene. Every Mac user tries ⌘, first.
    func testAppMenuHasSettings() throws {
        let appMenu = app.menuBars.menuBarItems["teemoon"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 10), "no application menu")
        appMenu.click()

        let settings = app.menuBars.menuItems.matching(
            NSPredicate(format: "title BEGINSWITH 'Settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5),
                      "no Settings item — the app declares no Settings scene, so ⌘, does nothing")
        appMenu.typeKey(.escape, modifierFlags: [])
    }

    /// ⌘, actually opens the settings window, from the main window's context.
    func testCommandCommaOpensSettings() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let before = app.windows.count

        app.typeKey(",", modifierFlags: .command)

        let opened = NSPredicate(format: "count > %d", before)
        expectation(for: opened, evaluatedWith: app.windows, handler: nil)
        waitForExpectations(timeout: 5) { error in
            XCTAssertNil(error, "⌘, did not open a settings window")
        }
    }

    /// teemoon is a dark app on every platform. `UIUserInterfaceStyle` is a UIKit
    /// key macOS ignores, so `AppDelegate` sets `NSApp.appearance` instead — and
    /// it is asserted here because a wrong appearance has no error state, it just
    /// looks wrong.
    ///
    /// MEASURED FROM THE PIXELS, BECAUSE A UI TEST CANNOT READ THE APP'S STATE.
    ///
    /// This asserted `NSApp.effectiveAppearance.name == .darkAqua`, which looks
    /// like it inspects teemoon and does not. A UI test runs in its own process
    /// driving teemoon over the accessibility API; `NSApp` there is the *runner's*
    /// application object, and it is nil. So the check could never pass and never
    /// measured the app — it was simply masked by the window failure ahead of it.
    ///
    /// The window's own pixels are the thing the assertion was always about, and
    /// they are readable across the process boundary. Measured on the dark build:
    /// rgb 0.133/0.141/0.149, luminance 0.140 — so the 0.35 bound has ~2.5x of
    /// headroom, while the light appearance this guards against is mostly white
    /// chrome and lands far above it.
    func testAppIsDarkRegardlessOfSystemAppearance() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let screenshot = window.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = "appearance check — expected dark"
        shot.lifetime = .keepAlways
        add(shot)

        let luminance = try meanLuminance(of: screenshot)
        XCTAssertLessThan(luminance, 0.35,
                          "the window renders light (mean luminance \(luminance)) — a light Mac is showing the design's rejected combination")
    }

    /// Mean relative luminance of a screenshot, 0 (black) to 1 (white).
    private func meanLuminance(of screenshot: XCUIScreenshot) throws -> Double {
        var rect = CGRect(origin: .zero, size: screenshot.image.size)
        let cgImage = try XCTUnwrap(
            screenshot.image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
            "window screenshot has no bitmap")

        let image = CIImage(cgImage: cgImage)
        let average = try XCTUnwrap(CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: image.extent),
        ])?.outputImage, "could not average the screenshot")

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil)

        let (r, g, b) = (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

#endif
