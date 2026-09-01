//
//  ChipTransitionRecordingUITests.swift
//  teemoonUITests
//
//  Drives the one moment on teemoon.ai that a screenshot cannot carry: the
//  where chip going from "choose where" to a model downloading on the phone,
//  in a single tap, with no key and no account.
//
//  PACED FOR VIDEO, not for speed. A UI test normally taps as fast as the
//  accessibility layer allows, which on film reads as a jump cut — the sheet is
//  simply there before you register that anything was pressed. The sleeps are
//  the point: they leave the chip's settle animation (420ms delay + 550ms
//  ease-out, see WhereChip.swift) and the sheet presentation visible, because
//  those transitions ARE the content.
//
//  Screen recording is started by the HOST around this test:
//      xcrun simctl io <udid> recordVideo --codec h264 out.mp4 &
//      xcodebuild test -only-testing:.../ChipTransitionRecordingUITests
//      kill -INT %1
//
//  Clean device required, same as the other first-run captures — an installed
//  model turns "start here" into a ready row and there is no download to show.
//

import XCTest

final class ChipTransitionRecordingUITests: XCTestCase {

    func testRecordChipToDownloading() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-capture"]
        app.launch()

        // Hold on the unconfigured state. The chip's accent fill settles ~1s in
        // and it is the only lit thing on screen — the viewer needs a beat to
        // find it before it is pressed.
        Thread.sleep(forTimeInterval: 3.0)

        let chip = app.buttons["chat.whereChip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no where chip")
        chip.tap()

        // The sheet rising is a transition worth seeing whole, and the viewer
        // then has to read "start here / gemma 4 e2b / download · 2.4 gb"
        // before the next tap makes sense.
        Thread.sleep(forTimeInterval: 3.0)

        let download = app.buttons["where.firstRun.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5),
                      "no first-run download button — the sheet is in some other state")
        download.tap()

        // The payoff: the sheet goes, and the chip is now naming a model and
        // counting. Long enough for a real percentage to appear rather than 0%.
        Thread.sleep(forTimeInterval: 8.0)
    }
}
