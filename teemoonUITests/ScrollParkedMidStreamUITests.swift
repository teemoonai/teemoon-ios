//
//  ScrollParkedMidStreamUITests.swift
//  teemoonUITests
//
//  THE JITTER, as a driver instead of a thumb.
//
//  Reported 2026-08-25 with a screen recording: during a long generation, a
//  reader who has scrolled up sees the transcript shift and settle back every
//  few seconds. Measured off that recording (iPhone 16 Pro, 37 variable-rate
//  frames): the screen is pixel-identical for 1.04s, then the content moves
//  17.7pt in ONE frame and springs back to the SAME position over ~0.27s.
//  Only rows 105-745pt change — the toolbar and composer never move, so the
//  bottom inset is not resizing and this is not the keyboard path.
//
//  Two numbers name the mechanism. 1.04s is `StreamingMessageView.stallDelay`
//  (1s) running out, which sets `isStalled` and mounts the trailing activity
//  chip; ~0.27s is that view's `.spring(duration: 0.3, bounce: 0.1)` settling
//  the height change. The chip grows the streaming view, the streaming view's
//  height is `contentInset.bottom`, and the bottom inset is what the
//  scrollable end is measured from.
//
//  TWO WAYS THIS FIXTURE GOES QUIETLY GREEN AGAINST A BROKEN BUILD, both
//  paid for on device (2026-08-25):
//
//    1. No stalls. `stallDelay` is 1s, so a continuous stream never mounts
//       the chip. The first run of this driver also had the reply FINISH
//       before the park began — 20s of "nothing moved" that measured a
//       settled transcript, not a parked one. `parkCoversStream` below is
//       asserted for that reason; do not delete it.
//    2. Parking too far up. `swipeDown` twice travelled 2,350pt into the
//       thread's history (offset=24093 against contentH=26447, five history
//       rows on screen). The chip toggled SEVEN times in that park and the
//       transcript did not move once — correctly, because the chip is the
//       last view in the streaming VStack and can only move the content
//       END. A reader up in history is unreachable from there. The drag
//       below is small on purpose.
//
//  This suite DRIVES and does not assert position, for the reason
//  LongThreadStreamingUITests already documents: while streaming, each block
//  is its own element, so a label anchor reports "left the screen" whether
//  the viewport moved 0pt or 3,000pt. The verdict is the `-scrollTrace`
//  file — `[unpinned]` lines, emitted only when the offset moved and WE DID
//  NOT MOVE IT.
//
//  Parking is the whole point. Every XCUI query waits for the app to idle,
//  which serialises against the main thread and can hide the frame-level
//  motion being measured, so the park window below holds NO queries.
//

import XCTest

final class ScrollParkedMidStreamUITests: XCTestCase {

    private static let turns = 200
    private static let replyBlocks = 20
    private static let wordDelay: TimeInterval = 0.025
    /// Every other block, so the parked window below spans several toggles
    /// rather than catching one and calling it a pattern.
    private static let stallEvery = 2
    /// Over the 1s `stallDelay`, with margin for the pacer's own lag — at
    /// 1.0s exactly the chip races the next token and mounts intermittently.
    private static let stallDuration: TimeInterval = 1.5
    /// A THINKING BLOCK ABOVE THE ANSWER, which `reasoningLines: 0` has none
    /// of. It renders inside `TimelineView(.periodic(by: 1))` and carries a
    /// live label, so it re-lays-out once a second from OFFSCREEN ABOVE a
    /// parked reader — and one line of it is ~17.7pt, which is what the
    /// 2026-08-25 recording measured, after exactly 1.04s of a still screen.
    private static let reasoningBlocks = 6
    /// Streaming time before the drag, so the reply spans the viewport.
    private static let growSeconds: TimeInterval = 10
    private static let parkSeconds: TimeInterval = 16

    @MainActor
    func testAParkedReaderMidStreamForTraceCapture() throws {
        // Self-hosted on the device: loopback, so no LAN, no ATS exception and
        // no Local Network permission dialog. See EmbeddedFakeSSEServer.
        let server = try EmbeddedFakeSSEServer(lines: Self.replyBlocks,
                                               delay: Self.wordDelay,
                                               reasoningLines: Self.reasoningBlocks)
        server.stallEvery = Self.stallEvery
        server.stallDuration = Self.stallDuration
        // THE READER MUST BE PARKED INSIDE THE TAIL. See `bulletTail`.
        server.bulletTail = true
        defer { server.stop() }
        XCTAssertNotEqual(server.port, 0, "embedded SSE server failed to bind")

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        app.launchEnvironment["UITEST_SEED_LONG_THREAD"] = String(Self.turns)
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = server.baseURL
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launch()

        let chatsButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chatsButton.waitForExistence(timeout: 30), "chats button never appeared")
        chatsButton.tap()
        let row = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "question 0:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded long thread not in the chats list")
        row.tap()

        let transcript = app.transcript
        XCTAssertTrue(transcript.waitForExistence(timeout: 20), "never landed back in the thread")

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "composer never appeared")
        composer.tap()
        composer.typeText("park me")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "generation never started")

        // LET THE REPLY FILL THE SCREEN FIRST. The park has to land INSIDE the
        // live answer, which is the geometry the recording shows; dragging
        // before the reply is a screenful tall lands in history instead.
        Thread.sleep(forTimeInterval: Self.growSeconds)

        // A SMALL, MEASURED DRAG — not `swipeDown`, which overshoots into the
        // thread's past (see note 2 at the top). ~0.25 of the viewport clears
        // the 50pt interruption threshold and stays in the answer.
        let from = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        let to = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        from.press(forDuration: 0.08, thenDragTo: to)

        // PARK. No queries past this point — see the note at the top.
        Thread.sleep(forTimeInterval: Self.parkSeconds)

        // THE FIXTURE'S OWN GATE, and the first query after the park. If the
        // reply finished while the reader was parked, this driver measured a
        // SETTLED transcript and the trace proves nothing — note 1 at the top.
        // `chat.stop` exists exactly while a turn runs.
        let parkCoversStream = app.buttons["chat.stop"].exists
        XCTAssertTrue(parkCoversStream,
                      "the reply ended before the park did, so the trace covers a "
                      + "settled transcript: lengthen the fixture (replyBlocks / "
                      + "stallDuration) or shorten parkSeconds")

        // A wedged app fails here rather than passing silently with an empty trace.
        XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 90),
                      "the app never came back after the park")
    }

    /// THE SAME PARK, OVER THE USER'S REAL THREADS.
    ///
    /// Every synthetic variant above reports the app CORRECT: parked inside a
    /// live reply with the chip toggling offscreen, `offset` and `originY`
    /// both sit still for the whole park (4 runs, 2026-08-25). What they all
    /// share is a seeded history of 200 IDENTICAL rows, so the streaming
    /// view's origin — `contentSize.height` — cannot move. Real history is
    /// rows of wildly different heights that self-size as they realise, and
    /// `originY` moving is the one mechanism left that would shift a parked
    /// reader's view without touching `contentOffset`.
    ///
    /// `UITEST_COPY_REAL_STORE=1` copies the real store to tmp and opens THE
    /// COPY: real content, every write landing in a file that evaporates. The
    /// reply is still the embedded server's, so this costs no tokens and
    /// stays deterministic — only the history is real.
    @MainActor
    func testAParkedReaderOverRealHistoryForTraceCapture() throws {
        let server = try EmbeddedFakeSSEServer(lines: Self.replyBlocks,
                                               delay: Self.wordDelay,
                                               reasoningLines: Self.reasoningBlocks)
        server.stallEvery = Self.stallEvery
        server.stallDuration = Self.stallDuration
        defer { server.stop() }

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        app.launchEnvironment["UITEST_COPY_REAL_STORE"] = "1"
        // Deliberately NO UITEST_SEED_LONG_THREAD: the real threads ARE the
        // fixture, and seeding one would bury them under synthetic rows.
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = server.baseURL
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launch()

        let chatsButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chatsButton.waitForExistence(timeout: 30), "chats button never appeared")
        chatsButton.tap()

        // The longest real thread available, by preference the one the
        // recording came from. Skips rather than fails on a machine whose
        // store does not have it — this is a diagnostic driver, and a fixture
        // that is not there is not a product defect.
        let preferred = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Steel man")).firstMatch
        if preferred.waitForExistence(timeout: 10) {
            preferred.tap()
        } else {
            throw XCTSkip("no 'Steel man' thread in the real store on this device")
        }

        let transcript = app.transcript
        XCTAssertTrue(transcript.waitForExistence(timeout: 20), "never landed in the thread")

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "composer never appeared")
        composer.tap()
        composer.typeText("park me")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 60), "generation never started")

        Thread.sleep(forTimeInterval: Self.growSeconds)
        let from = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        let to = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        from.press(forDuration: 0.08, thenDragTo: to)

        Thread.sleep(forTimeInterval: Self.parkSeconds)

        XCTAssertTrue(app.buttons["chat.stop"].exists,
                      "the reply ended before the park did")
    }

    /// THE PARKED RUN, FILMED — because every trace column is a TOTAL.
    ///
    /// `streamH` is the streaming view's whole height, so content reflowing
    /// ABOVE the reader while the list grows below it reads as ordinary
    /// monotonic growth (+23/tick, one line). `offset` and `originY` cannot
    /// see it either: neither moves when the reflow is internal to the
    /// streaming view. Six instrumented parks (2026-08-25) reported the
    /// transcript perfectly still against a recording that plainly shows it
    /// moving, and this is the gap that could explain it.
    ///
    /// XCUI discards screen recordings of PASSING tests, so this fails on
    /// purpose at the end — the "failure" IS the capture. Measure the recording
    /// with the parked-jitter analyzer (pixel deltas from the park onward), which
    /// is what the eye sees whichever internal quantity moved.
    ///
    /// It found the bug on the first try, and the fix closed it:
    ///
    ///     before   18 jumps over 4pt in the park, worst 18.00pt
    ///     after     0 jumps,                      worst  0.00pt
    ///
    /// The motion was a ~17.5pt displacement every ~3.2s — one per stall,
    /// i.e. one per activity-chip toggle — settling back to exactly zero.
    /// That is half the chip's 35pt, which is the tell: the host's frame was
    /// taking the post-change target from `sizeThatFits` while the content
    /// was still springing, and `UIHostingController` centres the difference.
    /// See the fix in `StreamingMessageView.body`.
    @MainActor
    func testAParkedReaderFilmed() throws {
        let server = try EmbeddedFakeSSEServer(lines: Self.replyBlocks,
                                               delay: Self.wordDelay,
                                               reasoningLines: Self.reasoningBlocks)
        server.stallEvery = Self.stallEvery
        server.stallDuration = Self.stallDuration
        server.bulletTail = true
        defer { server.stop() }

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
        composer.typeText("park me")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30))

        Thread.sleep(forTimeInterval: Self.growSeconds)
        let from = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        let to = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        from.press(forDuration: 0.08, thenDragTo: to)

        Thread.sleep(forTimeInterval: Self.parkSeconds)

        XCTFail("deliberate: keeps the screen recording in the xcresult")
    }

    /// THE CHIP'S BREATHING PULSE, FILMED — the other half of the fix.
    ///
    /// `GenerationActivityChipView.startBreathing()` animates `chipOpacity`
    /// 1.0 <-> 0.4 on an `.easeInOut(duration: 0.85).repeatForever`, i.e. a
    /// 1.7s cycle. A bare `.transaction { $0.animation = nil }` on the
    /// streaming view killed it (reported 2026-08-26), because that overrides
    /// the whole subtree and the chip lives in it. The `value:`-scoped
    /// version must leave it running.
    ///
    /// NO DRAG here on purpose: the parked driver puts the chip offscreen,
    /// which is exactly where a pulse cannot be measured. The follow keeps it
    /// on screen instead. Measure the recording with the chip-pulse
    /// analyzer.
    @MainActor
    func testTheActivityChipBreathesFilmed() throws {
        let server = try EmbeddedFakeSSEServer(lines: Self.replyBlocks,
                                               delay: Self.wordDelay)
        // Long stalls: the chip is only up while the wire is quiet, and the
        // pulse needs several seconds of it to show a cycle at all.
        server.stallEvery = 1
        server.stallDuration = 6.0
        defer { server.stop() }

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

        XCTAssertTrue(app.transcript.waitForExistence(timeout: 20))
        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        // XCUI LOSES THE FIRST TAP HERE sometimes: "Neither element nor any
        // descendant has keyboard focus" killed a run on 2026-08-26 before it
        // ever generated, and the film was 23s of an idle app that still had
        // to be inspected to notice. Confirm focus, retry once.
        composer.tap()
        if app.keyboards.firstMatch.waitForExistence(timeout: 5) == false {
            composer.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        }
        composer.typeText("breathe")
        app.buttons["chat.send"].tap()

        let chip = app.descendants(matching: .any)
            .matching(identifier: "chat.activityChip").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 40), "the activity chip never appeared")
        print("[chip frame] \(chip.frame)")

        // Hold still while it breathes. No queries — they idle the app.
        Thread.sleep(forTimeInterval: 14)

        XCTFail("deliberate: keeps the screen recording in the xcresult")
    }
}
