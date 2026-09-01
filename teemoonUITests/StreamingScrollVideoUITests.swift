//
//  StreamingScrollVideoUITests.swift
//  teemoonUITests
//
//  Generates one reply and then just sits there, so an external screen
//  recording has a clean window over the auto-scroll follow.
//
//  The thing under test is MOTION — how fast the transcript scrolls, moment to
//  moment, while the answer streams. XCUI cannot sample that: every frame query
//  round-trips into the app and waits for idle, which perturbs the very thing
//  being measured (an earlier attempt added 63s to a 6s stream). So this test
//  drives and waits, and the measurement is taken off the video.
//

import XCTest

final class StreamingScrollVideoUITests: XCTestCase {

    @MainActor
    func testGenerateOnceForVideo() throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TEEMOON_FAKE_SSE"] else {
            throw XCTSkip("set TEEMOON_FAKE_SSE to the fake SSE server's base URL to run this")
        }
        let turns = Int(ProcessInfo.processInfo.environment["TEEMOON_TURNS"] ?? "") ?? 200
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        app.launchEnvironment["UITEST_SEED_LONG_THREAD"] = String(turns)
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = endpoint
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launch()

        let chatsButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chatsButton.waitForExistence(timeout: 30))
        chatsButton.tap()
        let row = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "question 0:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(app.transcript.waitForExistence(timeout: 20))

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")

        // Quiet before and after, so the generation is easy to find in the
        // recording's activity timeline.
        Thread.sleep(forTimeInterval: 3)
        app.buttons["chat.send"].tap()
        // Long enough for a reasoning phase plus a multi-screen answer, and NOT
        // ONE QUERY while it runs: an XCUI query walks the accessibility tree,
        // which forces the lazy stack to build its rows — i.e. it performs the
        // "scroll down to refresh it" that the reported defect requires, and
        // hides the very thing being looked for.
        Thread.sleep(forTimeInterval: 75)
    }
}
