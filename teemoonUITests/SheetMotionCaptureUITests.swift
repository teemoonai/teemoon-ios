//
//  SheetMotionCaptureUITests.swift
//  teemoonUITests
//
//  Capture-only: the where sheet driven up from its medium detent, a slow drag and a flick, for a screen recording
//  to measure against Android's IosSheet (teemoon-android, 2026-10-06). Skips unless SHEET_MOTION=1.
//

import XCTest

final class SheetMotionCaptureUITests: XCTestCase {
    private func openWhere() throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["SHEET_MOTION"] == "1" else { throw XCTSkip("capture only (SHEET_MOTION=1)") }
        let server = try EmbeddedFakeSSEServer(lines: 2, delay: 0.005)
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.whereChip(app).tap()
        sleep(2)
        return app
    }

    /// 0.7 s from the sheet's middle to near the top, as Android's `input swipe 540 1250 540 500 700`.
    func testDragUp() throws {
        let app = try openWhere()
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.21))
        sleep(1)   // the recording's quiet lead-in
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: 450, thenHoldForDuration: 0)
        sleep(2)
    }

    /// A flick: the same distance in ~0.12 s.
    func testFlickUp() throws {
        let app = try openWhere()
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.21))
        sleep(1)
        from.press(forDuration: 0.02, thenDragTo: to, withVelocity: 2600, thenHoldForDuration: 0)
        sleep(2)
    }
}
