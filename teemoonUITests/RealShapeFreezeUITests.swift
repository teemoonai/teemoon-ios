//
//  RealShapeFreezeUITests.swift
//  teemoonUITests
//
//  The user's freezing threads, rebuilt from their MEASURED STRUCTURE.
//
//  thread_shapes.json carries per-message character counts and markdown
//  feature counts (headings, table rows, links, code fences, lists, bold)
//  extracted from the real store — numbers only, no content; the store copy
//  was deleted after extraction. The app's seeder regenerates messages
//  matching each shape from a word bank. Shape 0 is the 16-message
//  heading-heavy thread; shape 2 is the 54-message, 92k-char monster with
//  90 table rows and 72 links whose single replies run to 7,150 chars —
//  the scale hand-written fixtures never approached, which is why a day of
//  them failed to reproduce what the real threads froze in seconds.
//
//  The model under reproduction is a long-reasoning one (deepseek-v4-flash
//  via fireworks), so the embedded server streams a reasoning phase first.
//
//  Device-only in spirit: the simulator absorbs what wedges a phone.
//

import XCTest

final class RealShapeFreezeUITests: XCTestCase {

    /// Opens shaped thread `t` via its deterministic preview marker
    /// ("shaped-t opening" — the chat list shows message previews, not
    /// titles).
    @MainActor
    private func openShapedThread(_ t: Int, in app: XCUIApplication) throws {
        XCTAssertFalse(app.staticTexts["SHAPE DECODE FAILED"].exists,
                       "the bundled shape JSON failed to decode")
        let row = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "shaped-\(t) opening")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "shaped thread \(t) not seeded")
        row.tap()
    }

    /// Shape 0 is the reported freezer: the 16-message, heading-rich recipe
    /// thread (three queries, one thread — user clarification 2026-08-07).
    /// No tables in it at all: headings + a reasoning phase suffice.
    @MainActor
    func testSubmitThenSmallScrollBackOnTheRecipeShape() throws {
        try runGesture(onShapedThread: 0)
    }

    /// Shape 2 is the monster: 54 messages, 92k chars, 90 table rows, 72
    /// links, single replies to 7,150 chars — the other thread that froze.
    @MainActor
    func testSubmitThenSmallScrollBackOnTheMonsterShape() throws {
        try runGesture(onShapedThread: 2)
    }

    /// Drives one generation and then LEAVES THE APP ALONE — no queries, no
    /// gestures — so the -scrollTrace pipeline records an unperturbed wire
    /// vs. paced vs. offset timeline, and an externally attached profiler
    /// sees the real workload. For the 2026-08-07 report: "screen blanks
    /// mid-generation; characters stream, then a huge dump at the end."
    @MainActor
    func testUnwatchedGenerationForTraceCapture() throws {
        let server = try EmbeddedFakeSSEServer(lines: 30, reasoningLines: 10)
        defer { server.stop() }
        XCTAssertNotEqual(server.port, 0)

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        app.launchEnvironment["UITEST_SEED_SHAPED_THREAD"] = "bundled"
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = server.baseURL
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        // The user's real configuration: developer mode ON. Its end-of-turn
        // debug panel changes the hand-off layout; a trace captured without
        // it verified a different app than the one being reported on.
        app.launchEnvironment["UITEST_DEVELOPER_MODE"] = "1"
        app.launch()

        let chatsButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chatsButton.waitForExistence(timeout: 30))
        chatsButton.tap()
        try openShapedThread(0, in: app)
        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()
        // Reasoning + 30 rich paragraphs at 0.02s/word, plus pacer drain —
        // and a LONG tail: the reported end-state defect is the viewport
        // resting over unrealised rows, which only shows at rest.
        Thread.sleep(forTimeInterval: 85)
    }

    /// Submit, then scroll back less than half a screen during the reasoning
    /// phase. Then assert the three ways this has failed on device:
    /// main-thread liveness, a non-blank transcript, and turn finalisation.
    @MainActor
    private func runGesture(onShapedThread t: Int) throws {
        let server = try EmbeddedFakeSSEServer(lines: 20, reasoningLines: 12)
        defer { server.stop() }
        XCTAssertNotEqual(server.port, 0, "embedded SSE server failed to bind")

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        // "bundled": the shapes live in the APP bundle — a 12KB env payload
        // never survived the device test transport.
        app.launchEnvironment["UITEST_SEED_SHAPED_THREAD"] = "bundled"
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = server.baseURL
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launch()

        let chatsButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chatsButton.waitForExistence(timeout: 30))
        chatsButton.tap()
        try openShapedThread(t, in: app)
        let transcript = app.transcript
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        // "in less than half a screen it freezes": one small, slow drag,
        // immediately after submit, during the reasoning phase.
        let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = start.withOffset(CGVector(dx: 0, dy: 320))
        start.press(forDuration: 0.1, thenDragTo: end,
                    withVelocity: 250, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 2.0)
        start.press(forDuration: 0.1, thenDragTo: end,
                    withVelocity: 250, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 2.0)

        // 1. Liveness.
        let probeStart = Date()
        let alive = chatsButton.waitForExistence(timeout: 60)
        let probeSeconds = Date().timeIntervalSince(probeStart)
        XCTAssertTrue(alive && probeSeconds < 30,
            "main thread liveness probe took \(Int(probeSeconds))s — the wedge")

        // 2. Not blank: SOMETHING from the thread is on screen.
        let anyText = transcript.staticTexts.firstMatch
        XCTAssertTrue(anyText.waitForExistence(timeout: 10),
            "the transcript went BLANK after the gesture")

        // 3. The turn ends.
        XCTAssertTrue(app.buttons["chat.stop"].waitForNonExistence(timeout: 120),
            "the turn never finalised")
    }
}
