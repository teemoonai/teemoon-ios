//
//  OnePageFollowProbeUITests.swift
//  teemoonUITests
//
//  The one-page repro: a FRESH thread, one generation whose answer grows past
//  a single viewport height, and NOT ONE TOUCH after send. The reported
//  failure is that the follow dies at the moment the answer first exceeds the
//  screen — the first moment the transcript has to actually scroll.
//
//  Drives and waits only; the measurement is the `-scrollTrace` file, read by
//  the out-of-band follow-checker. Simulator + fake SSE server, deterministic,
//  no tokens.
//
//  Start the fake SSE server on :8765 (40 lines, 0.02 s delay), then:
//      TEST_RUNNER_TEEMOON_FAKE_SSE=http://127.0.0.1:8765/v1 xcodebuild test … \
//        -only-testing:teemoonUITests/OnePageFollowProbeUITests
//

import XCTest

final class OnePageFollowProbeUITests: XCTestCase {

    @MainActor
    func testOneGenerationPastOnePageInAFreshThread() throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TEEMOON_FAKE_SSE"] else {
            throw XCTSkip("set TEEMOON_FAKE_SSE to the fake SSE server's base URL to run this")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = endpoint
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launch()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer never appeared")
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        // The answer streams past one viewport height while the app is left
        // completely alone — an XCUI query idles the app and masks the defect.
        let streamSeconds = Double(ProcessInfo.processInfo
            .environment["TEEMOON_STREAM_SECONDS"] ?? "") ?? 25
        Thread.sleep(forTimeInterval: streamSeconds)
    }

    /// Scroll away mid-answer, then come back. The contract has two halves:
    /// away STOPS the follow (tested in LongThreadStreamingUITests), and
    /// coming back to the end RESUMES it. This drives the second half; the
    /// verdict is read from the `-scrollTrace` flags (intr/drag/follow), not
    /// from XCUI, which cannot see the follow honestly.
    @MainActor
    func testScrollAwayThenReturnMidStream() throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TEEMOON_FAKE_SSE"] else {
            throw XCTSkip("set TEEMOON_FAKE_SSE to the fake SSE server's base URL to run this")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = endpoint
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launch()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer never appeared")
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        let transcript = app.transcript
        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "generation never started")
        // Let the answer grow past a page so there is history to scroll into.
        Thread.sleep(forTimeInterval: 5)

        // AWAY: up into the history.
        transcript.swipeDown(velocity: .fast)
        transcript.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 3)

        // BACK: toward the end. The end is a moving target while the reply
        // streams — which is the point under test.
        transcript.swipeUp(velocity: .fast)
        transcript.swipeUp(velocity: .fast)
        transcript.swipeUp(velocity: .fast)
        // Leave the app alone for the rest of the stream.
        Thread.sleep(forTimeInterval: 12)

        // AFTER generation: is the scroll view still a scroll view? Each swipe
        // shows up in the trace as phase events; a responsive view moves its
        // offset, a wedged one emits phases with a frozen offset. The verdict
        // is read from the trace, not asserted here.
        transcript.swipeDown(velocity: .slow)
        Thread.sleep(forTimeInterval: 1.5)
        transcript.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 1.5)
    }
}
