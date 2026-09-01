//
//  ScrollUpMidStreamFreezeUITests.swift
//  teemoonUITests
//
//  THE DEVICE FREEZE, as a red test instead of a thumb.
//
//  Reproduced three times on hardware (2026-08-06): send into a long thread
//  whose history carries markdown tables, scroll up within a second, and the
//  main thread never returns — the reply streams to completion into a dead
//  UI (wire trace kept writing for 17s+ after the last main-thread line).
//  The simulator absorbs the cost and does not wedge, so THIS SUITE'S VERDICT
//  ONLY MEANS SOMETHING ON A PHYSICAL DEVICE:
//
//  Start the fake SSE server on 0.0.0.0:8765 (reachable over the LAN), then:
//      TEST_RUNNER_TEEMOON_FAKE_SSE=http://<mac-lan-ip>:8765/v1 \
//        xcodebuild test -project teemoon.xcodeproj -scheme teemoon \
//          -destination 'platform=iOS,id=<udid>' \
//          -only-testing:teemoonUITests/ScrollUpMidStreamFreezeUITests
//
//  Liveness is measured the only way XCUI can: every query waits for the app
//  to idle, so a wedged main thread turns a cheap existence check into a
//  timeout. A healthy app answers in single-digit seconds even mid-stream.
//

import XCTest

final class ScrollUpMidStreamFreezeUITests: XCTestCase {

    private static let turns = 200

    @MainActor
    func testScrollingUpMidStreamLeavesTheMainThreadAlive() throws {
        // Self-hosted: the runner runs ON the device, so the app streams from
        // loopback — no LAN, no ATS exception exercised, no Local Network
        // permission dialog. See EmbeddedFakeSSEServer for the graveyard of
        // network-path attempts this replaces.
        let server = try EmbeddedFakeSSEServer()
        defer { server.stop() }
        XCTAssertNotEqual(server.port, 0, "embedded SSE server failed to bind")

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        app.launchEnvironment["UITEST_SEED_LONG_THREAD"] = String(Self.turns)
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = server.baseURL
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launch()

        let chatsButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chatsButton.waitForExistence(timeout: 30))
        chatsButton.tap()
        let row = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "question 0:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let transcript = app.transcript
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        // THE TRIGGER, exactly as the first freeze trace timed it: the main
        // thread died 17 SECONDS BEFORE the first wire event — the user
        // scrolled up in the window between tapping send and the stream
        // starting, while the send-time layout (user-message insert,
        // streaming-view mount, follow scrollTo) was still settling. An
        // earlier draft of this test waited for `chat.streamingText` first
        // and passed politely on a build a thumb froze in seconds. NO
        // waiting: send, then swipe immediately, then roam.
        for i in 0..<8 {
            transcript.swipeDown(velocity: .fast)
            if i % 3 == 2 { transcript.swipeUp(velocity: .slow) }
            Thread.sleep(forTimeInterval: 1.0)
        }

        // THE LIVENESS PROBE. A healthy app answers an existence check in
        // single-digit seconds even mid-stream; the wedge makes it take the
        // full timeout (queries wait for idle, and idle never comes). The
        // probe element is the chats button — always present, nothing to do
        // with the transcript under suspicion.
        let probeStart = Date()
        let alive = chatsButton.waitForExistence(timeout: 60)
        let probeSeconds = Date().timeIntervalSince(probeStart)
        XCTAssertTrue(alive && probeSeconds < 30,
            "main thread liveness probe took \(Int(probeSeconds))s — the "
            + "scroll-up-mid-stream wedge (a healthy app answers in seconds)")

        // And the turn must END: the wedge's other face is the reply
        // finishing on the wire while the UI never finalises it.
        XCTAssertTrue(app.buttons["chat.stop"].waitForNonExistence(timeout: 120),
            "the turn never finalised after scrolling up mid-stream")
    }

    /// The THINKING-WINDOW variant (reported 2026-08-07, round 4): scroll up
    /// while a reasoning model is still in its "thinking..." phase — before
    /// any visible content — and the main thread wedges. In that window the
    /// transcript's only live element is the activity chip; the streamed
    /// reasoning stays off-screen until turn end.
    @MainActor
    func testScrollingUpDuringThinkingLeavesTheMainThreadAlive() throws {
        let server = try EmbeddedFakeSSEServer(lines: 20, reasoningLines: 12)
        defer { server.stop() }
        XCTAssertNotEqual(server.port, 0, "embedded SSE server failed to bind")

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        app.launchEnvironment["UITEST_SEED_LONG_THREAD"] = String(Self.turns)
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = server.baseURL
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launch()

        let chatsButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chatsButton.waitForExistence(timeout: 30))
        chatsButton.tap()
        let row = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "question 0:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let transcript = app.transcript
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        // THE REPORTED GESTURE, verbatim (2026-08-07): "enter a query and
        // submit and then scroll back. in less than half a screen it
        // freezes." Not a fling through pages of history — a small, slow,
        // half-screen drag right after submit, while the previous reply (a
        // heading-bearing one; the two-pass flap needs headings) has just
        // settled into the row cache. Full-screen fast swipes never
        // reproduced what this does.
        let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = start.withOffset(CGVector(dx: 0, dy: 320))
        start.press(forDuration: 0.1, thenDragTo: end,
                    withVelocity: 250, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 2.0)
        // A second small nudge, as a thumb would.
        start.press(forDuration: 0.1, thenDragTo: end,
                    withVelocity: 250, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 2.0)

        let probeStart = Date()
        let alive = chatsButton.waitForExistence(timeout: 60)
        let probeSeconds = Date().timeIntervalSince(probeStart)
        XCTAssertTrue(alive && probeSeconds < 30,
            "main thread liveness probe took \(Int(probeSeconds))s — the "
            + "scroll-up-during-thinking wedge (a healthy app answers in seconds)")
        XCTAssertTrue(app.buttons["chat.stop"].waitForNonExistence(timeout: 120),
            "the turn never finalised after scrolling up during thinking")
    }
}
