//
//  teemoonUITestsLaunchTests.swift
//  teemoonUITests
//

import XCTest

final class teemoonUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // SCOPE THE SCREENSHOT TO THE APP'S OWN WINDOW.
        //
        // `app.screenshot()` is window-scoped on iOS but captures the ENTIRE
        // DISPLAY on macOS — every other app the developer had open goes into the
        // .xcresult, which is both useless for reviewing teemoon and a real
        // privacy leak into an artifact that gets attached to CI runs and shared.
        //
        // Falls back to the app-wide screenshot only when there is no window to
        // photograph, which is itself worth seeing: on macOS the app currently
        // takes the menu bar and presents no window on launch.
        let window = app.windows.firstMatch
        let shot = window.exists ? window.screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = window.exists ? "Launch Screen" : "Launch Screen (NO WINDOW — full display)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
