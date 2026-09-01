//
//  TopFadeCaptureUITests.swift
//  teemoonUITests
//
//  Opens a long thread, writes the screen to /tmp/teemoon-fade/title.png
//  so the title-overlap dissolve can be judged from pixels, not from
//  a safe-area number.
//

import XCTest

final class TopFadeCaptureUITests: XCTestCase {

    func testCaptureTitleOverlap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_LONG_THREAD"] = "80"
        // Same two-line header as a sealed near.ai chat. Without this the
        // fixture is a one-line title and the overlay is tuned to the
        // wrong chrome.
        app.launchEnvironment["UITEST_SEED_ATTESTATION"] = "ok"
        app.launch()

        let chats = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 20))
        chats.tap()
        let row = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "question 0:"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(app.transcript.waitForExistence(timeout: 20))
        // Land is the newest message. One nudge up puts body text under
        // the title the way a long streaming reply does.
        app.transcript.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 0.6)

        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "title-overlap"
        attachment.lifetime = .keepAlways
        add(attachment)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try shot.pngRepresentation.write(to: docs.appendingPathComponent("title-overlap.png"))
    }
}
