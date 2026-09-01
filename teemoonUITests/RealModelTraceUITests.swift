//
//  RealModelTraceUITests.swift
//  teemoonUITests
//
//  ONE real-model generation, traced. This test launches the REAL app — no
//  --uitesting, live store, live providers — because the thing under
//  measurement is the actual wire cadence of deepseek-v4-flash on fireworks
//  (reasoning stall, then flood), which no fake server reproduces.
//
//  It is deliberately incapable of touching existing chats: a cold launch
//  has no current thread, and the first send CREATES a new one
//  (ChatViewModel). The test's only actions are: type into the composer,
//  send, and wait. The artifact is one new thread in the real store.
//
//  Run with the phone on the charger and the screen unlocked; pull
//  Documents/scrolltrace.log afterwards for the wire/pace/offset timeline.
//

import XCTest

final class RealModelTraceUITests: XCTestCase {

    @MainActor
    func testOneRealGenerationLeavesATrace() throws {
        let app = XCUIApplication()
        // -scrollTrace arms the wire/pace/offset pipeline. NO --uitesting:
        // real providers are the point.
        app.launchArguments = ["-scrollTrace"]
        app.launch()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer never appeared")
        composer.tap()
        composer.typeText(
            "Compare the six best store-bought garam masala brands in a detailed "
            + "markdown table (brand, flavor profile, heat, availability, price), "
            + "then explain how to choose between them, with headings per criterion.")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 60),
                      "generation never started — provider or network problem")

        // Leave the app COMPLETELY alone: queries idle the app and perturb
        // the pacing being measured. Reasoning models take their time.
        Thread.sleep(forTimeInterval: 150)

        // The turn should be over; the trace is the deliverable either way.
        _ = app.buttons["chat.stop"].waitForNonExistence(timeout: 60)
    }

    /// The real-model run, FILMED. XCUI discards screen recordings of passing
    /// tests, so this variant fails on purpose at the end — the "failure" IS
    /// the capture. Frames from the recording, lined up against the trace's
    /// timestamps, are the only instrument for paint-latency symptoms the
    /// geometry trace cannot see ("blanks close to the end", 2026-08-07:
    /// suspected burst-append layout lag inside the streaming view).
    @MainActor
    func testOneRealGenerationFilmed() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-scrollTrace"]
        app.launch()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer never appeared")
        composer.tap()
        composer.typeText(
            "Compare the six best store-bought garam masala brands in a detailed "
            + "markdown table (brand, flavor profile, heat, availability, price), "
            + "then explain how to choose between them, with headings per criterion.")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 60), "generation never started")
        Thread.sleep(forTimeInterval: 90)

        XCTFail("deliberate: keeps the screen recording in the xcresult")
    }

    /// The SAME prompt against near.ai's deepseek — the A/B for the wire
    /// cadence question: is the stall-then-flood fireworks' flush behaviour,
    /// or the model's own? Switches the Where selection to near.ai for the
    /// run and RESTORES fireworks afterwards.
    @MainActor
    func testOneNearAIGenerationLeavesATrace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-scrollTrace"]
        app.launch()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer never appeared")

        try switchWhere(app, toRowContaining: ["near.ai", "eepseek"],
                        skipMessage: "no near.ai deepseek row in the Where sheet")

        composer.tap()
        composer.typeText(
            "Compare the six best store-bought garam masala brands in a detailed "
            + "markdown table (brand, flavor profile, heat, availability, price), "
            + "then explain how to choose between them, with headings per criterion.")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 60),
                      "generation never started — near.ai reachability?")
        Thread.sleep(forTimeInterval: 150)
        _ = app.buttons["chat.stop"].waitForNonExistence(timeout: 60)

        // Put the user's selection back.
        try? switchWhere(app, toRowContaining: ["fireworks"],
                         skipMessage: "fireworks row not found to restore")
    }

    /// A READER PARKED INSIDE A REAL REPLY — the 2026-08-25 jitter, whose
    /// fixture equivalent does not reproduce it.
    ///
    /// `ScrollParkedMidStreamUITests` drives the same gesture against the
    /// embedded server and the transcript does not move: parked 122pt from
    /// the end, inside the live reply, `intr=1`, ELEVEN activity-chip toggles
    /// across a 17.6s park, zero offset samples. So whatever moves the
    /// recording's reader is not the chip's ~21pt on its own, and it is
    /// something the synthetic stream does not have — real reasoning, real
    /// markdown reflow, real burst cadence. This driver supplies all three.
    ///
    /// Uses whatever provider is ALREADY selected and never opens the Where
    /// sheet: the recording came from the active one, and a restore step that
    /// guesses the previous selection would edit the user's config on the way
    /// out. The artifact is one new thread, as with the other tests here.
    @MainActor
    func testAParkedReaderDuringARealGenerationLeavesATrace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-scrollTrace"]
        app.launch()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer never appeared")
        composer.tap()
        composer.typeText(
            "Compare the memory models of Swift, Rust and Go in depth. Use a "
            + "numbered section per language with a bold heading, then bullet "
            + "lists for ownership, reference counting, and escape analysis, "
            + "and finish with a markdown comparison table and a long summary.")
        app.buttons["chat.send"].tap()

        // `chat.stop` says a TURN is running; `chat.streamingText` says VISIBLE
        // TEXT exists. On a reasoning model those are minutes apart, and the
        // identifier lives on the `!pacer.text.isEmpty` branch — so it does
        // not exist at all while the model thinks. A 60s wait on it failed
        // this test on 2026-08-25 against a generation that was running fine.
        XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 60),
                      "the turn never started — provider or network problem")
        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: Self.visibleTextTimeout),
                      "the model never produced visible text (still reasoning?)")

        // Let the reply fill the screen so the park lands INSIDE it.
        Thread.sleep(forTimeInterval: Self.growSeconds)

        let transcript = app.transcript
        XCTAssertTrue(transcript.waitForExistence(timeout: 20), "no transcript")
        // Small and measured, for the reason ScrollParkedMidStreamUITests
        // documents: a full swipe leaves the reply and lands in history,
        // where nothing at the content end can reach the reader.
        let from = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        let to = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        from.press(forDuration: 0.08, thenDragTo: to)

        // PARK. No queries — they idle the app and hide frame-level motion.
        Thread.sleep(forTimeInterval: Self.parkSeconds)

        // Fixture gate: if the reply already finished, the trace covers a
        // settled transcript and proves nothing.
        XCTAssertTrue(app.buttons["chat.stop"].exists,
                      "the reply ended before the park did — raise parkSeconds' "
                      + "counterpart in the prompt, or lower parkSeconds")
        _ = app.buttons["chat.stop"].waitForNonExistence(timeout: 180)
    }

    /// Long enough to outlast a silent reasoning phase. The docs' ~50s for
    /// near.ai deepseek is not the ceiling: this prompt reasoned for ~270s on
    /// 2026-08-25 and blew a 240s budget, which aborted the test BEFORE its
    /// drag and left the app following the end — a run that looks like a
    /// parked-reader test and is not one. If this ever trips again, the
    /// fixture is wrong, not the app.
    private static let visibleTextTimeout: TimeInterval = 600
    private static let growSeconds: TimeInterval = 15
    private static let parkSeconds: TimeInterval = 55

    /// Opens the Where sheet and taps the first row whose label contains all
    /// of `needles`; closes the sheet if selection doesn't dismiss it.
    @MainActor
    private func switchWhere(_ app: XCUIApplication, toRowContaining needles: [String],
                             skipMessage: String) throws {
        let chip = app.descendants(matching: .any)
            .matching(identifier: "chat.whereChip").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "Where chip missing")
        chip.tap()

        let format = needles.map { _ in "label CONTAINS[c] %@" }.joined(separator: " AND ")
        let row = app.descendants(matching: .any)
            .matching(identifier: "where.row")
            .matching(NSPredicate(format: format, argumentArray: needles)).firstMatch
        guard row.waitForExistence(timeout: 10) else {
            // Leave the sheet closed either way.
            let close = app.buttons["close"].firstMatch
            if close.exists { close.tap() }
            throw XCTSkip(skipMessage)
        }
        row.tap()
        Thread.sleep(forTimeInterval: 1)
        let close = app.buttons["close"].firstMatch
        if close.exists { close.tap() }
        Thread.sleep(forTimeInterval: 1)
    }
}
