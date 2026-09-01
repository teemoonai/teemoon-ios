//
//  StreamingLagUITests.swift
//  teemoonUITests
//
//  Does the transcript KEEP UP with a fast model, and does that depend on how
//  long the thread already is?
//
//  The report this exists for: with a fast model (DeepSeek V4 Flash on
//  Fireworks) in a long chat, the answer appears slowly at first as though the
//  UI cannot keep up with the token rate, then the remainder dumps at once and
//  animates through quickly.
//
//  The measurement is a race against a known clock. The fake SSE server sends
//  a fixed number of words at a fixed delay, so the stream's duration is
//  arithmetic, not observation: `words × delay`. Anything the UI takes beyond
//  that is lag it added. Running the same stream into a 10-turn and a 200-turn
//  thread isolates whether the lag is a function of THREAD length (a per-token
//  cost that scales with the transcript) or of REPLY length (a per-token cost
//  that scales with the answer) — those want different fixes.
//
//  Start the fake SSE server on :8765 (60 lines, 0.004 s delay), then:
//      TEST_RUNNER_TEEMOON_FAKE_SSE=http://127.0.0.1:8765/v1 \
//      TEST_RUNNER_TEEMOON_STREAM_WORDS=1680 TEST_RUNNER_TEEMOON_STREAM_DELAY=0.004 \
//        xcodebuild test … -only-testing:teemoonUITests/StreamingLagUITests
//

import XCTest

final class StreamingLagUITests: XCTestCase {

    /// Last paragraph index the server emits, i.e. `--lines` minus one.
    private var lastParagraph: Int {
        (Int(ProcessInfo.processInfo.environment["TEEMOON_STREAM_LINES"] ?? "") ?? 60) - 1
    }

    /// How long the server itself spends sending, from arithmetic.
    private var serverSeconds: Double {
        let words = Double(ProcessInfo.processInfo.environment["TEEMOON_STREAM_WORDS"] ?? "") ?? 1680
        let delay = Double(ProcessInfo.processInfo.environment["TEEMOON_STREAM_DELAY"] ?? "") ?? 0.004
        return words * delay
    }

    private func app(turns: Int) throws -> XCUIApplication {
        guard let endpoint = ProcessInfo.processInfo.environment["TEEMOON_FAKE_SSE"] else {
            throw XCTSkip("set TEEMOON_FAKE_SSE to the fake SSE server's base URL to run this")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_LONG_THREAD"] = String(turns)
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = endpoint
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launch()
        return app
    }

    private func openLongThread(_ app: XCUIApplication) -> XCUIElement {
        // Wait for the button before tapping it. On the simulator the app is up
        // by the time `launch()` returns; on a physical phone it is not, and
        // tapping into nothing fails later and misleadingly, at the row query.
        let chatsButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chatsButton.waitForExistence(timeout: 30), "chats-list button never appeared")
        chatsButton.tap()
        let row = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "question 0:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let transcript = app.transcript
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        return transcript
    }

    /// Sends one message and reports how far behind the server the transcript
    /// finished, plus the shape of the growth curve on the way there.
    @discardableResult
    private func measureLag(turns: Int) throws -> Double {
        let app = try self.app(turns: turns)
        let transcript = openLongThread(app)

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")

        let started = Date()
        app.buttons["chat.send"].tap()

        // NO SAMPLING WHILE IT STREAMS, and that is the whole design.
        //
        // The first version of this polled the streaming block's frame in a
        // tight loop to watch the growth curve. Every XCUI frame query
        // round-trips into the app and waits for it to be idle, so ~290 queries
        // over one reply added SIXTY-THREE SECONDS — to both arms equally,
        // which is how it announced itself: a 10-turn and a 200-turn thread
        // came out within a second of each other at +63s, and the "height"
        // it sampled never moved off 88pt. It was measuring the harness.
        //
        // So the only observation is the one at the end, and the clock it is
        // compared against is arithmetic (`words × delay`), not another query.
        let finished = transcript.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Paragraph \(lastParagraph):")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 180),
                      "the reply never completed in the transcript")
        let uiSeconds = Date().timeIntervalSince(started)
        let lag = uiSeconds - serverSeconds

        print(String(format:
            "[lag] turns=%d  server=%.2fs  ui=%.2fs  lag=%+.2fs",
            turns, serverSeconds, uiSeconds, lag))
        app.terminate()
        return lag
    }
    /// The control: the same stream into a nearly-empty thread.
    @MainActor
    func testStreamingLagInAShortThread() throws {
        try measureLag(turns: 10)
    }

    /// The reported case.
    @MainActor
    func testStreamingLagInALongThread() throws {
        try measureLag(turns: 200)
    }

    /// The reported case, reproduced: a REASONING model.
    ///
    /// DeepSeek V4 Flash streams its chain of thought in `reasoning_content`
    /// before any `content` arrives, and `SSEStreamParser` accumulates that
    /// field without ever forwarding it to `onText` — "Reasoning never reaches
    /// onText while it streams", as the parser itself puts it. So for the whole
    /// reasoning phase the transcript has nothing to show, however fast the
    /// model is going.
    ///
    /// This measures the gap the user actually sees: send → first visible
    /// character, against a server whose reasoning phase is a known length.
    @MainActor
    func testTimeToFirstVisibleTextWithAReasoningModel() throws {
        let app = try self.app(turns: 200)
        let transcript = openLongThread(app)

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("go")

        let started = Date()
        app.buttons["chat.send"].tap()

        // The first paragraph of the CONTENT half. Everything before it is the
        // reasoning phase, which the transcript does not render.
        let firstVisible = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Paragraph 0:")).firstMatch
        XCTAssertTrue(firstVisible.waitForExistence(timeout: 180),
                      "no visible text ever arrived")
        let toFirstVisible = Date().timeIntervalSince(started)

        let finished = transcript.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Paragraph \(lastParagraph):")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 180))
        let total = Date().timeIntervalSince(started)

        let reasoningSeconds = Double(ProcessInfo.processInfo
            .environment["TEEMOON_REASONING_SECONDS"] ?? "") ?? 0
        print(String(format:
            "[reasoning] reasoning phase=%.2fs  →  first visible text at %.2fs, "
            + "whole reply done at %.2fs (visible portion took %.2fs)",
            reasoningSeconds, toFirstVisible, total, total - toFirstVisible))
        app.terminate()
    }
}
