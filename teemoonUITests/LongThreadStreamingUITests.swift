//
//  LongThreadStreamingUITests.swift
//  teemoonUITests
//
//  Generating a reply AT THE END of a long transcript.
//
//  This is the interaction a lazy transcript is most likely to break in a way
//  the scroll tests cannot see. The streaming view, the error card and the
//  "bottom" sentinel deliberately live OUTSIDE the LazyVStack so
//  `scrollTo("bottom")` always has a realised target — but the stack still sits
//  above them, its content height is an estimate over unrealised rows, and the
//  finished reply is appended INTO it when generation ends. If any of that
//  shifts the offset, the transcript jumps at the exact moment the user is
//  reading the answer.
//
//  Driven by the fake SSE server, so it is deterministic and offline —
//  no model, no key, no network.
//
//  Start the fake SSE server on :8765, then:
//      TEST_RUNNER_TEEMOON_FAKE_SSE=http://127.0.0.1:8765/v1 \
//        xcodebuild test … -only-testing:teemoonUITests/LongThreadStreamingUITests
//
//  The `TEST_RUNNER_` prefix is load-bearing: without it xcodebuild does not
//  forward the variable, the guard below skips, and the run still reports
//  success. (Same trap as ChatBottomEdgeCaptureUITests.)
//

import XCTest

final class LongThreadStreamingUITests: XCTestCase {

    private static let turns = 200

    /// Index of the reply's final paragraph, i.e. the server's `--lines` minus
    /// one. Read from the environment rather than hardcoded: this suite is run
    /// against whatever fake SSE server is already up, and a test that
    /// silently waits for a paragraph the server never sends reports a product
    /// bug that is really a fixture mismatch. The fallback MUST equal the
    /// server's `--lines` default (40): with the lazy transcript pinned to the
    /// bottom, an earlier paragraph is off-screen and unrealised, so expecting
    /// one fails "the finished reply never landed" against a working follow.
    private var lastParagraph: Int {
        (Int(ProcessInfo.processInfo.environment["TEEMOON_STREAM_LINES"] ?? "") ?? 40) - 1
    }

    /// `developerMode` turns the end-of-turn debug card on. It is off for every
    /// test that predates it, because the card is a ~400pt animated tail insert
    /// that changes the hand-off — a gate that ran with it OFF verified a
    /// different app than the one on a developer's phone.
    private func launchedApp(developerMode: Bool = false) throws -> XCUIApplication {
        guard let endpoint = ProcessInfo.processInfo.environment["TEEMOON_FAKE_SSE"] else {
            throw XCTSkip("set TEEMOON_FAKE_SSE to the fake SSE server's base URL to run this")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        app.launchEnvironment["UITEST_SEED_LONG_THREAD"] = String(Self.turns)
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = endpoint
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        if developerMode { app.launchEnvironment["UITEST_DEVELOPER_MODE"] = "1" }
        app.launch()
        return app
    }

    /// PHASE A: SENDING ANCHORS THE PROMPT, IT DOES NOT SLAM THE COMPOSER.
    ///
    /// The old follow pinned the newest token to the bottom, so the first
    /// thing a send did was throw an EMPTY answer against the composer and
    /// then drag it upward a wrap at a time. The anchor rule puts the user's
    /// message near the top and grows the reply into slack below it, so for
    /// any reply that fits the remaining viewport the offset never moves.
    ///
    /// THE FIXTURE HAS TO BE SHORT IN HEIGHT AND SLOW IN TIME, and it took
    /// three runs to learn that both halves matter:
    ///
    ///   - 3 paragraphs at 0.006s/word: the reply nearly fills the viewport,
    ///     so there is no slack and the anchor coincides with the pin. Both
    ///     builds read 35.0pt and the test proved nothing.
    ///   - 1 paragraph at 0.006s/word: over in ~0.25s, long before XCUI's
    ///     first query, so both builds measure the same SETTLED state. Both
    ///     read 301.0pt and the test proved nothing.
    ///   - 2 paragraphs at 0.12s/word: ~10s of streaming with real slack
    ///     under it. Anchor 148pt / moved 20pt; pin-to-end 414pt / moved
    ///     246pt as the growing reply drags the prompt up the screen.
    ///
    ///     the fake SSE server on :8768, 2 lines at 0.12 s delay, with
    ///     TEEMOON_STREAM_LINES=2 TEST_RUNNER_TEEMOON_FAKE_SSE=http://127.0.0.1:8768/v1
    ///
    /// Skipped rather than failed under the default 40-line fixture: there the
    /// reply outgrows the viewport in a second and phase B is *entitled* to
    /// scroll the prompt off.
    @MainActor
    func testSendingAnchorsThePromptNearTheTop() throws {
        try XCTSkipUnless(lastParagraph + 1 <= 4,
            "needs the short slow fixture — see this test's note")
        let app = try launchedApp()
        let transcript = openLongThread(app)

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "composer never appeared")
        composer.tap()
        composer.typeText("anchor me")
        app.buttons["chat.send"].tap()

        let prompt = transcript.staticTexts
            .matching(NSPredicate(format: "label == %@", "anchor me")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 20),
                      "the sent message never appeared in the transcript")

        let band = transcript.frame
        let first = prompt.frame.minY
        // The headline: not in the bottom half, which is where pin-to-end put
        // it (hard against the composer, with a blank answer beneath).
        XCTAssertLessThan(first, band.midY,
            "the prompt was slammed toward the composer: it sits at \(first) "
            + "in a transcript spanning \(band.minY)...\(band.maxY)")

        // And it STAYS: growth of the reply eats the slack, not the offset.
        Thread.sleep(forTimeInterval: 4)
        let after = transcript.staticTexts
            .matching(NSPredicate(format: "label == %@", "anchor me")).firstMatch
        XCTAssertTrue(after.exists, "the prompt was scrolled away while the reply grew")
        let moved = abs(after.frame.minY - first)
        print("[anchor] prompt at \(first)pt in \(band.minY)...\(band.maxY), moved \(moved)pt")
        // 8pt, not 40: this measures 0.0 when the geometry is right, and the
        // two ways it has been wrong are a wrap (22pt) and the home indicator
        // left out of the reserve (34pt). A threshold that admits either is
        // not a gate.
        XCTAssertLessThan(moved, 8,
            "the reply dragged the prompt \(moved)pt: growth is moving the "
            + "offset instead of eating the placeholder")

        // AND ACROSS THE HAND-OFF. At `[DONE]` the streaming view is torn
        // down and the reply becomes a cell. The reserve under the prompt has
        // to be re-backed by that cell in the same breath — if it collapses,
        // the scrollable end falls by exactly the placeholder and the clamp
        // shoves the prompt back down the screen. That is the hand-off jump
        // rebuilt out of the fix for it, and it is invisible to the overscroll
        // gates because offset and content move together.
        Thread.sleep(forTimeInterval: 12)
        let settled = transcript.staticTexts
            .matching(NSPredicate(format: "label == %@", "anchor me")).firstMatch
        XCTAssertTrue(settled.exists, "the prompt was scrolled away by the hand-off")
        let acrossHandoff = abs(settled.frame.minY - first)
        print("[anchor] across the hand-off the prompt moved \(acrossHandoff)pt")
        XCTAssertLessThan(acrossHandoff, 8,
            "the hand-off moved the prompt \(acrossHandoff)pt: the reserve "
            + "collapsed when the streaming view was replaced by its cell")
    }

    /// Swipe back until a history row is actually showing, bounded at 8.
    ///
    /// NOT A FIXED TWO SWIPES. How far a swipe travels depends on how tall
    /// the rows it passes are, and that has changed twice: collapsed 120pt
    /// estimates fitted six to a screen (traced `rows=6`), real heights can
    /// put one reply across the whole viewport (`rows=1`), and since the
    /// anchor landed the follow holds the prompt near the top rather than
    /// the end. Each caller's CONTRACT — the row it anchored on must not
    /// move — is unchanged; only reaching a row is no longer a magic number.
    private func swipeIntoHistory(_ transcript: XCUIElement) -> XCUIElement {
        let historyRow = transcript.staticTexts
            .matching(NSPredicate(
                format: "label BEGINSWITH 'reply ' OR label BEGINSWITH 'question '"))
        for _ in 0..<8 {
            transcript.swipeDown(velocity: .fast)
            if historyRow.firstMatch.exists { break }
        }
        return historyRow.firstMatch
    }

    /// DRIVER: raise the keyboard on a FINISHED turn and leave the app alone.
    ///
    /// Reported: "the debug panel doesn't animate to the top at the same rate
    /// as the keyboard opens." The design says the content rides the keyboard
    /// for free — the composer is a `safeAreaInset`, the scroll view adjusts
    /// for it, and the pin runs at the end of the resulting layout passes. So
    /// the question is whether the offset RAMPS with the keyboard or STEPS
    /// ahead of it, and that is a shape in the trace, not an XCUI assertion.
    ///
    /// Developer mode on: the ~400pt debug panel is the thing whose motion
    /// was reported, and a trace taken without it is a different layout.
    ///
    /// Needs the software keyboard. With a hardware keyboard connected the
    /// simulator changes focus WITHOUT changing the inset, and this driver
    /// then measures nothing at all:
    ///   defaults write com.apple.iphonesimulator DevicePreferences \
    ///     -dict-add <UDID> '{ ConnectHardwareKeyboard = 0; }'
    @MainActor
    func testRaisingTheKeyboardOnAFinishedTurnForTraceCapture() throws {
        let app = try launchedApp(developerMode: true)
        let transcript = openLongThread(app)

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        XCTAssertTrue(app.buttons["chat.stop"].waitForNonExistence(timeout: 120),
                      "the turn never finished")
        // Past the hand-off, the card's reveal and its second measure, so the
        // layout is settled and the only thing moving next is the keyboard.
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(transcript.exists)

        // THE MEASUREMENT. Quiet before, one tap, quiet after — so the first
        // movement after the gap is unambiguously the keyboard's.
        Thread.sleep(forTimeInterval: 2)
        composer.tap()
        Thread.sleep(forTimeInterval: 3)
    }

    private func openLongThread(_ app: XCUIApplication) -> XCUIElement {
        let chatsButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chatsButton.waitForExistence(timeout: 20))
        chatsButton.tap()
        let row = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "question 0:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let transcript = app.transcript
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        return transcript
    }

    /// Sends a message at the end of a 200-turn thread and watches the answer
    /// arrive. Two things have to hold: the transcript FOLLOWS the stream (the
    /// growing text stays on screen rather than running off the bottom), and
    /// the hand-off from the streaming view to the persisted message does not
    /// move the transcript.
    @MainActor
    func testStreamingAtTheEndOfALongThreadStaysPinnedToTheBottom() throws {
        let app = try launchedApp()
        let transcript = openLongThread(app)

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "composer never appeared")
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        // The streaming container is identified so its HEIGHT can be read while
        // the answer grows — see the note on `chat.streamingText`.
        // NOT ONE XCUI QUERY UNTIL THE REPLY IS DONE, and that is the whole
        // reason this reads the way it does.
        //
        // Every XCUI query — including `waitForExistence`, which polls — waits
        // for the app to go idle, and idling repeatedly is exactly the breather
        // a chasing scroll follow needs to catch up. The same broken build that
        // traces at 761pt adrift reported 178pt when this test polled its way
        // through the stream, comfortably inside the threshold. The measurement
        // was erasing the defect.
        //
        // So: a fixed sleep, longer than the fixture's stream (1680 words at
        // 0.006s = ~10s), during which the app is left completely alone.
        let streamSeconds = Double(ProcessInfo.processInfo
            .environment["TEEMOON_STREAM_SECONDS"] ?? "") ?? 12
        Thread.sleep(forTimeInterval: streamSeconds + 8)

        let finished = transcript.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Paragraph \(lastParagraph):")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 60),
                      "the finished reply never landed in the transcript")

        // THE "HOW FAR BEHIND" ASSERTION IS NOT HERE, AND CANNOT BE.
        //
        // The defect this suite exists for — the transcript falling hundreds of
        // points behind the streaming answer and then closing the gap in a jump
        // — is not observable from a UI test. Three plausible pins were written
        // and each failed differently:
        //
        //   1. The gap between `chat.streamingText`'s bottom edge and the
        //      viewport's. XCUI CLIPS element frames to the visible area, so it
        //      reads 0.0pt whether the transcript is 0 or 761 points adrift.
        //      Passed on the broken build.
        //   2. The same, sampled through the stream. Every XCUI query waits for
        //      the app to go idle, and those idles are exactly the breather the
        //      chasing follow needed: 761pt of real drift came back as 178pt.
        //      The measurement was erasing the defect.
        //   3. The number handed out by the app through the accessibility tree.
        //      Read 525pt on the broken build and 11,409pt on the fixed one — a
        //      value sampled across generation boundaries and keyboard-driven
        //      inset changes is not the quantity being asked about.
        //
        // It is measured instead by the out-of-band follow-checker, which drives
        // one generation, leaves the app completely alone for the duration, and
        // reads the offset trace the app logs (see ScrollTrace.swift).
        //
        // What this test asserts is what XCUI can see honestly: generation
        // started, the finished reply landed, and the transcript comes to rest
        // afterwards without bouncing.

        var ys: [CGFloat] = []
        for _ in 0..<20 {
            ys.append(finished.exists ? finished.frame.minY : -1)
            Thread.sleep(forTimeInterval: 0.25)
        }
        print("[streaming] post-generation travel: \(ys)")

        let settled = ys.suffix(6)
        XCTAssertLessThan((settled.max() ?? 0) - (settled.min() ?? 0), 2,
            "the transcript never came to rest after generation: \(Array(settled))")

        // One direction only. A 2pt tolerance absorbs sampling landing
        // mid-animation; anything more is the offset being pulled back.
        let reversals = zip(ys, ys.dropFirst()).filter { $1 > $0 + 2 }.count
        XCTAssertEqual(reversals, 0,
            "the transcript bounced \(reversals) time(s) after generation — the scroll offset "
            + "is being corrected back and forth: \(ys)")
    }

    /// Scrolling away mid-answer must STOP the follow, and this is the test
    /// that earns the `nil` in
    /// `.defaultScrollAnchor(isFollowingStream ? .bottom : nil, for: .sizeChanges)`.
    ///
    /// KNOWN INTERMITTENT (1 in ~6 runs, 2026-08-06): the transcript drifts
    /// back toward the bottom after the swipe (981pt observed). The suspected
    /// mechanism is the interruption's own precondition: if the synthetic
    /// swipe's `.interacting` scroll phase is missed, `userDraggedAway` stays
    /// false and the geometry rule — by design — treats the displacement as
    /// content re-measurement and lets the follow re-pin. Whether a REAL
    /// finger can miss `.interacting` is the question that matters; check on
    /// device before treating a failure here as noise.
    ///
    /// A `.sizeChanges` anchor pins the transcript to the newest text every
    /// time the content grows. That is exactly right while the user is reading
    /// the end of a reply and exactly wrong the moment they scroll up to check
    /// something — an unconditional anchor would haul them back to the bottom
    /// on every token, which is worse than the jumpy follow it replaced.
    @MainActor
    /// SCROLLING AWAY HAS TO SURVIVE THE HAND-OFF, NOT JUST THE STREAM.
    ///
    /// `testScrollingAwayMidAnswerStopsTheFollow` below asserts while the reply
    /// is still arriving and never waits for the turn to finish, so the seam
    /// where the streaming view is replaced by the persisted row — and, in
    /// developer mode, where the debug card is revealed — had no gate at all.
    ///
    /// Reported from the device, 2026-08-18: scroll up to read while the answer
    /// runs, and the moment generation ends the viewport lands on the top of the
    /// new reply. It does NOT happen when the follow is left to ride, and that
    /// asymmetry is the tell. A followed turn arms the settle pin
    /// (`armSettle(1.0)`, guarded on `turnEnded, !interrupted`) and takes a
    /// corrective `scrollToEnd` after the card animates in; an interrupted turn
    /// is deliberately given neither, so whatever the hand-off does to the
    /// offset is where the user is left.
    ///
    /// This runs with developer mode OFF, and it PASSES (0.0pt) — so the
    /// hand-off itself preserves a scrolled-away viewport. That is worth
    /// pinning: nothing covered it before.
    ///
    /// The reported bug is therefore NOT the plain hand-off. It needs the
    /// developer-mode debug card, and a `developerMode: true` variant of this
    /// test cannot yet reach its assertion: after the identical two swipes the
    /// transcript holds only 2 static texts (the sent message and the streaming
    /// reply, measured 2026-08-18), i.e. it never left the bottom — the
    /// swipe-away does not take while the card path is live. That is the next
    /// thing to chase, on device, and it is why this gate stops here rather
    /// than pretending to cover it.
    ///
    /// The blank-frame checker and the trace gate cannot see any of this:
    /// they drive an UNWATCHED generation, which is the case that already
    /// worked.
    func testScrollingAwaySurvivesTheEndOfTheTurn() throws {
        let app = try launchedApp(developerMode: false)
        let transcript = openLongThread(app)

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "generation never started")

        // Away from the end, into the history above — the same gesture the
        // mid-stream test uses, so a failure here is about the hand-off and
        // not about how the interruption was earned.
        let anchored = swipeIntoHistory(transcript)
        XCTAssertTrue(anchored.exists, "nothing from the thread's history is on screen")
        let label = anchored.label
        let before = anchored.frame.minY

        // THE PART THE OTHER TEST STOPS SHORT OF: let the turn actually END.
        // `chat.stop` exists exactly while a turn runs.
        let stop = app.buttons["chat.stop"]
        XCTAssertTrue(stop.waitForNonExistence(timeout: 60), "the turn never finished")
        // The card is revealed a beat after the hand-off (220ms), animates in,
        // and its cell is measured a second time on the next runloop turn. Wait
        // past all of it — the bug is a SUSTAINED landing, not a flicker.
        Thread.sleep(forTimeInterval: 2)

        let after = transcript.staticTexts
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(after.exists,
                      "the row the user was reading left the screen when the turn ended")
        let moved = abs(after.frame.minY - before)
        print("[scroll-away handoff] anchored row moved \(moved)pt across the end of the turn")
        XCTAssertLessThan(moved, 80,
            "the turn ended and the transcript moved \(moved)pt — the user was reading "
            + "history and got taken to the new reply")
    }

    /// DRIVES the case that is actually reported — "it scrolls to the top of
    /// the generation when I'm scrolled up" — and asserts nothing about where
    /// the transcript ended up, because XCUI cannot see that honestly here.
    ///
    /// Two independent reasons, both paid for:
    ///
    ///   1. The anchor does not survive. While streaming, the answer is a
    ///      stack of per-block `StructuredText` views, so a paragraph is its
    ///      own element; once persisted it is ONE `StructuredText`, and the
    ///      paragraph's element ceases to exist. A `label == …` anchor
    ///      therefore reports "the paragraph left the screen" whether the
    ///      viewport moved 0pt or 3,000pt — it failed identically against a
    ///      build the trace proved had not moved at all.
    ///   2. Element frames are clipped to the visible area, which is the same
    ///      trap documented on the follow assertions above.
    ///
    /// So this drives the gesture and leaves the verdict to the offset trace
    /// the app writes, exactly as the follow-checker does for the
    /// follow. Start the fake SSE server on :8765 with 120 lines, then:
    ///
    ///     TEST_RUNNER_TEEMOON_FAKE_SSE=http://127.0.0.1:8765/v1 \
    ///     TEST_RUNNER_TEEMOON_STREAM_LINES=120 \
    ///       xcodebuild test … -only-testing:teemoonUITests/LongThreadStreaming\
    ///       UITests/testAReaderInsideTheAnswerDrivesAWalkAwayHandoff
    ///     and run the trace analyzer on the pulled scrolltrace.log.
    ///
    /// The verdict is the `walk-away handoff` line: a reader who scrolled away
    /// must not be moved AT ALL, and the analyzer exits non-zero if they were.
    /// Measured 2026-08-22: 0pt on the fix, 703pt on the version before it.
    func testAReaderInsideTheAnswerDrivesAWalkAwayHandoff() throws {
        try XCTSkipUnless(lastParagraph >= 79,
            "needs a long reply — run the fake SSE server with --lines 120 and pass "
            + "TEST_RUNNER_TEEMOON_STREAM_LINES=120 (this reader has to stay inside "
            + "the answer after scrolling up, which a 40-line reply cannot do)")

        let app = try launchedApp(developerMode: false)
        let transcript = openLongThread(app)

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "generation never started")

        // Let a few screens of answer accumulate, then step back up INTO it —
        // one swipe, so the viewport stays on the reply rather than clearing
        // it into the history above.
        Thread.sleep(forTimeInterval: 4)
        transcript.swipeDown(velocity: .fast)

        // NOT ONE QUERY from here to the end of the turn: every XCUI query
        // waits for idle, and idling is what lets a moving offset settle
        // between samples. The trace is the instrument; this is the hand.
        let stop = app.buttons["chat.stop"]
        XCTAssertTrue(stop.waitForNonExistence(timeout: 120), "the turn never finished")
        Thread.sleep(forTimeInterval: 3)
    }

    /// DRIVES THE SHAPE FROM THE SCREENSHOTS: developer mode on, so the turn
    /// ends with the debug card in the tail, which is what the reported empty
    /// bands sat above and below.
    ///
    /// Asserts nothing itself — the verdict is the `[column]` dump, which
    /// reports each cell's height beside the FLOOR it was given and the height
    /// its content actually wants. Slack between them is the gap.
    func testDeveloperModeTurnEndDrivesTheColumnDump() throws {
        let app = try launchedApp(developerMode: true)
        let transcript = openLongThread(app)

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "generation never started")

        let stop = app.buttons["chat.stop"]
        XCTAssertTrue(stop.waitForNonExistence(timeout: 120), "the turn never finished")
        // The card is revealed a beat after the hand-off, animates in, and its
        // cell is measured again on the next runloop turn. The dump fires at
        // +1.5s; give it room to land and be flushed.
        Thread.sleep(forTimeInterval: 4)
        _ = transcript.exists
    }

    func testScrollingAwayMidAnswerStopsTheFollow() throws {
        let app = try launchedApp()
        let transcript = openLongThread(app)

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "generation never started")

        // Away from the end, into the history above.
        //
        // SWIPE UNTIL HISTORY IS ACTUALLY SHOWING, rather than a fixed two.
        // How far two swipes travel depends on how tall the rows they pass
        // are, and that is not a constant: until 2026-08-24 a full layout
        // invalidation next to the hand-off reset every unrealised row to its
        // 120pt estimate, so six collapsed rows fitted the screen and two
        // swipes always landed in history. With rows at their real heights a
        // single reply can fill the viewport, and the same two swipes stop
        // inside the answer. The CONTRACT below — an anchored history row
        // must not move while the reply streams — is unchanged and still
        // measures 0.0pt; only getting there is no longer a magic number.
        // Anchor on a message that is now on screen and should stay there. Any
        // old turn will do; take the topmost one the transcript is showing.
        let anchored = swipeIntoHistory(transcript)
        XCTAssertTrue(anchored.exists, "nothing from the thread's history is on screen")
        let label = anchored.label
        let before = anchored.frame.minY

        // Let a good chunk of the remaining answer arrive.
        Thread.sleep(forTimeInterval: 4)

        let after = transcript.staticTexts
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(after.exists,
                      "the transcript was scrolled away from the history it was showing")
        let moved = abs(after.frame.minY - before)
        print("[scroll-away] anchored row moved \(moved)pt while the answer kept streaming")
        XCTAssertLessThan(moved, 80,
            "scrolling away did not stop the follow — the transcript moved \(moved)pt "
            + "while the reply streamed, i.e. it is dragging the user back to the bottom")
    }

    /// A TAP is not a scroll-away, and must not stop the follow.
    ///
    /// KNOWN INTERMITTENT (1 observed in ~10 runs, 2026-08-06): same family
    /// as testScrollingAwayMidAnswerStopsTheFollow's — synthetic-gesture
    /// scroll-phase noise around the interruption rule. 3-for-3 green on
    /// isolated reruns the same day.
    ///
    /// The inverse of the test above, and the regression pin for the
    /// mid-answer follow death: `onScrollPhaseChange`'s `.interacting` fires on
    /// any touch-down in the scroll view, displacement or none — a tap to
    /// dismiss the keyboard, a stray finger while reading. If mere interaction
    /// arms `userDraggedAway`, the next time content growth or lazy
    /// re-estimation makes the 50pt geometry rule true, `scrollInterrupted`
    /// latches and the follow is dead for the rest of the turn — with the user
    /// having scrolled nowhere.
    @MainActor
    func testATapMidAnswerDoesNotStopTheFollow() throws {
        let app = try launchedApp()
        let transcript = openLongThread(app)

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "generation never started")

        // One tap in the middle of the transcript. No drag, no displacement.
        transcript.tap()

        // Let the rest of the answer arrive with the app LEFT ALONE (queries
        // idle the app and mask follow defects — see the note above).
        let streamSeconds = Double(ProcessInfo.processInfo
            .environment["TEEMOON_STREAM_SECONDS"] ?? "") ?? 12
        Thread.sleep(forTimeInterval: streamSeconds + 6)

        // If the follow survived the tap, the transcript ends pinned to the
        // reply's final paragraph.
        let finished = transcript.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Paragraph \(lastParagraph):")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 30),
                      "the finished reply never landed in the transcript")
        XCTAssertTrue(finished.isHittable,
            "the follow stopped after a mere tap: the reply's last paragraph is off screen "
            + "— the transcript was left behind mid-answer")
    }

    /// Skips unless the server is streaming the plain-paragraph reply this
    /// suite's `Paragraph N:` assertions are written against. Added after a
    /// fixture-mode server from an earlier session held the port and every
    /// content assertion here failed against markdown the tests never sent —
    /// see FakeSSEProbe.
    private func requireParagraphServer() throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TEEMOON_FAKE_SSE"] else {
            throw XCTSkip("set TEEMOON_FAKE_SSE to the fake SSE server's base URL to run this")
        }
        try FakeSSEProbe.requireServedContent(
            endpoint: endpoint, toContain: "Paragraph \(lastParagraph):",
            mode: "plain paragraphs (the fake SSE server with no --fixture, "
                + "--lines \(lastParagraph + 1))")
    }

    /// Scrolling away kills the follow FOR THAT TURN — and only that turn.
    /// `ChatGeneration` resets `scrollInterrupted` when a new generation
    /// starts, so a send from up in the history must re-arm the follow and
    /// bring the transcript back to the bottom. The old anchor stack held its
    /// interruption state in four places; this pins the state machine reset
    /// the rebuild promised.
    @MainActor
    func testTheFollowReArmsOnTheNextSend() throws {
        try requireParagraphServer()
        let app = try launchedApp()
        let transcript = openLongThread(app)

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "generation never started")

        // Scroll away — the follow for THIS turn is now dead, which
        // testScrollingAwayMidAnswerStopsTheFollow asserts. Here it is only
        // the setup: the interesting state is what the NEXT turn inherits.
        transcript.swipeDown(velocity: .fast)

        // Wait out the rest of the turn. The activity chip is NOT a usable
        // end-of-turn signal here: scrolled away, it sits at the transcript's
        // end, off screen and out of the accessibility tree, so `!exists`
        // reads "turn over" while the stream is still running (this test's
        // first failure — it then typed into a live turn and found the stop
        // control where it expected `chat.send`). The stop control IS the
        // signal: `chat.stop` exists exactly while a turn runs.
        let stop = app.buttons["chat.stop"]
        XCTAssertTrue(stop.waitForNonExistence(timeout: 90),
                      "the first turn never finished")

        // Send again FROM UP IN THE HISTORY, and leave the app alone.
        composer.tap()
        composer.typeText("again")
        app.buttons["chat.send"].tap()
        let streamSeconds = Double(ProcessInfo.processInfo
            .environment["TEEMOON_STREAM_SECONDS"] ?? "") ?? 12
        Thread.sleep(forTimeInterval: streamSeconds + 8)

        // Assert AFTER the turn ends, not mid-pace. The paced display can lag
        // the wire by seconds; asserting while `chat.stop` is still up matches
        // the STREAMING text — one enormous element whose center is off screen,
        // so `isHittable` reads false against a follow that is working (first
        // observed on this very test: the video showed the follow riding the
        // second stream pinned while the assertion called it dead).
        XCTAssertTrue(stop.waitForNonExistence(timeout: 90),
                      "the second turn never finished")
        let finished = transcript.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Paragraph \(lastParagraph):")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 60),
                      "the second reply never landed in the transcript")
        XCTAssertTrue(finished.isHittable,
            "the follow did not re-arm on the next send: the second reply's last "
            + "paragraph is off screen — scrollInterrupted leaked across turns")
    }

    /// A drag SMALLER than the 50pt interruption threshold, released, must not
    /// kill the follow. This is the boundary the `touchIsDown` guard and the
    /// 50pt rule negotiate over: the guard exists so the follow doesn't cancel
    /// a drag before it can reach 50pt, and the rule exists so only a real
    /// displacement counts as scrolling away. A sub-threshold nudge is the
    /// case between the tested tap (0pt) and the tested swipe (a full page).
    @MainActor
    func testASmallDragUnderTheThresholdDoesNotStopTheFollow() throws {
        try requireParagraphServer()
        let app = try launchedApp()
        let transcript = openLongThread(app)

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "generation never started")

        // ~30pt drag, slow, with a hold before release so there is no fling
        // inertia to carry it past the threshold.
        let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: 30))
        start.press(forDuration: 0.2, thenDragTo: end,
                    withVelocity: 100, thenHoldForDuration: 0.4)

        let streamSeconds = Double(ProcessInfo.processInfo
            .environment["TEEMOON_STREAM_SECONDS"] ?? "") ?? 12
        Thread.sleep(forTimeInterval: streamSeconds + 8)

        let finished = transcript.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Paragraph \(lastParagraph):")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 60),
                      "the finished reply never landed in the transcript")
        XCTAssertTrue(finished.isHittable,
            "a \u{2248}30pt nudge killed the follow: the reply's last paragraph is off "
            + "screen — the interruption rule latched under its own threshold")
    }

    /// Focusing the composer mid-answer raises the keyboard, which shrinks the
    /// visible height — a size change the follow has to ride WITHOUT dying and
    /// without fighting the inset animation. The keyboard inset is named in
    /// the follow's own comments as the thing the `.initialOffset` anchor
    /// would have fought; nothing exercised the collision while streaming.
    @MainActor
    func testRaisingTheKeyboardMidAnswerKeepsTheFollow() throws {
        try requireParagraphServer()
        let app = try launchedApp()
        let transcript = openLongThread(app)

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "generation never started")

        // Raise the keyboard mid-stream, then leave the app alone. (Sending
        // dismissed it; this brings it back while the answer grows.) On a
        // simulator with a hardware keyboard connected only focus changes, not
        // the inset — the test still exercises focus-during-stream.
        composer.tap()

        let streamSeconds = Double(ProcessInfo.processInfo
            .environment["TEEMOON_STREAM_SECONDS"] ?? "") ?? 12
        Thread.sleep(forTimeInterval: streamSeconds + 8)

        // Wait for the turn to actually end before judging the layout — the
        // paced display lags the wire, and mid-pace the reply is one huge
        // streaming element that defeats `isHittable` (see the re-arm test).
        XCTAssertTrue(app.buttons["chat.stop"].waitForNonExistence(timeout: 90),
                      "the turn never finished after the composer was focused mid-stream")
        // Scoped to `app`, NOT to `transcript`, and it stays that way. The
        // original reason has been fixed underneath it: `transcript` used to be
        // `app.scrollViews.firstMatch`, re-resolved at every use, and with the
        // composer focused the text field's internal field-editor scroll view
        // could become the tree's first scroll view — this test then spent 60s
        // searching for the reply inside the composer while the reply sat
        // pinned and visible in the chat (video-confirmed, 2026-08-06). It is
        // addressed by identifier now (see `XCUIApplication.transcript`), so
        // that particular mis-resolution cannot recur; searching from `app` is
        // still the wider net, and this assertion wants the wider net.
        let finished = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Paragraph \(lastParagraph):")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 60),
                      "the finished reply never landed in the transcript")
        XCTAssertTrue(finished.isHittable,
            "the reply's last paragraph is not visible above the keyboard — the "
            + "follow lost to the inset change instead of riding it")
    }
}
