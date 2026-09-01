//
//  LongThreadScrollUITests.swift
//  teemoonUITests
//
//  Drives a real 200-turn transcript in the real app and flicks through it.
//
//  The headless census in `ConversationScrollBenchmarks` proves the object
//  graph no longer grows with thread length, which is the mechanism. It cannot
//  prove the SCROLL still behaves — that a lazy transcript still opens on the
//  newest message, still reaches the first message when you drag up, and does
//  not stutter or jump while it does. Only a driven app can say that, so this
//  is where the user-visible claim gets tested.
//
//  Fixture: `UITEST_SEED_LONG_THREAD=200` (see UITestStoreSeeding.seedLongThread) —
//  one deterministic thread, in the in-memory store, so a run never touches
//  real conversations and two runs compare the same transcript.
//

import XCTest

final class LongThreadScrollUITests: XCTestCase {

    private var app: XCUIApplication!

    /// How many turns the fixture seeds. Long enough that the old non-lazy
    /// transcript held ~7 000 CALayers, which is where the complaint lives.
    private static let turns = 200

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_LONG_THREAD"] = String(Self.turns)
    }

    /// Re-seeds with a different thread length. Must be called before `launch`.
    private func seed(turns: Int) {
        app.launchEnvironment["UITEST_SEED_LONG_THREAD"] = String(turns)
    }

    /// How many of the transcript's message paragraphs are live in the
    /// accessibility tree — i.e. how many rows the transcript is actually
    /// holding, as opposed to how many the thread has.
    private func realizedMessageCount(in transcript: XCUIElement) -> Int {
        transcript.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'reply ' OR label BEGINSWITH 'question '")).count
    }

    /// The user-visible form of the census in ConversationScrollBenchmarks, in
    /// the shipping app rather than a hosted view: a 200-turn thread must not
    /// hold ten times what a 20-turn thread holds. Before the transcript went
    /// lazy this ratio was 1:1 with thread length.
    @MainActor
    func testRealizedRowsDoNotScaleWithThreadLength() throws {
        seed(turns: 20)
        app.launch()
        let short = realizedMessageCount(in: openLongThread())
        app.terminate()

        seed(turns: Self.turns)
        app.launch()
        let long = realizedMessageCount(in: openLongThread())
        app.terminate()

        print("[long-thread] realized rows — 20 turns: \(short), \(Self.turns) turns: \(long)")
        XCTAssertGreaterThan(short, 0, "no message rows realized at all — the query is wrong")
        XCTAssertLessThan(long, short * 3,
            "a \(Self.turns)-turn transcript holds \(long) live rows against \(short) for 20 turns; "
            + "the transcript is materialising the whole thread again")
    }

    /// Opens the seeded thread from the chats list and returns once the
    /// transcript is on screen.
    @discardableResult
    private func openLongThread() -> XCUIElement {
        let chatsButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chatsButton.waitForExistence(timeout: 20), "chats-list button never appeared")
        chatsButton.tap()

        // Matched on the row's TITLE TEXT, which ChatRowView derives from the
        // thread's first message — `Thread.title` is written by the seeder but
        // nothing in the app reads it, so a title query finds nothing. Not
        // `cells.firstMatch` either: the first cell is the "earlier" section
        // header, and tapping that silently does nothing.
        let row = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "question 0:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded long thread not in the chats list")
        row.tap()

        // The chats list is a sheet; selecting dismisses it. Waiting on the
        // transcript rather than the composer, because the composer is behind
        // the sheet and exists whether or not the sheet went away.
        let transcript = app.transcript
        XCTAssertTrue(transcript.waitForExistence(timeout: 20), "never landed back in the thread")
        return transcript
    }

    // MARK: - Correctness

    /// The contract a lazy transcript is most likely to break: a thread opens
    /// on its NEWEST message. The fixture's final turn is `reply 199`, and the
    /// two turns before it are the only other things that can legitimately
    /// share the screen with it.
    @MainActor
    func testLongThreadOpensOnTheNewestMessage() throws {
        app.launch()
        let transcript = openLongThread()

        let last = transcript.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "reply \(Self.turns - 1):")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 10),
                      "a \(Self.turns)-turn thread did not open on its last message")

        // And the FIRST turn must not be — if it were, the transcript opened at
        // the top, which is the failure mode this is guarding.
        //
        // Scoped to the transcript ON PURPOSE. `app.staticTexts` also matches
        // the navigation title, and ChatView derives that title from the
        // thread's FIRST message — so an app-wide query for "question 0:"
        // matches the title bar and reports the top of the thread as visible on
        // a transcript that is correctly sitting at the bottom.
        let firstInTranscript = transcript.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "question 0:")).firstMatch
        XCTAssertFalse(firstInTranscript.exists, "the transcript opened at the top of the thread")
    }

    /// A lazy transcript must still be able to reach its beginning. This is the
    /// other classic failure: rows realise as you drag, the content size keeps
    /// growing underneath the scroll view, and the top recedes forever.
    @MainActor
    func testDraggingUpReachesTheFirstMessage() throws {
        app.launch()
        let transcript = openLongThread()
        // Scoped to the transcript — see the note in the test above about the
        // navigation title matching the same text.
        let first = transcript.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "question 0:")).firstMatch

        // Generous but bounded: 200 turns is a lot of screens. If the top is
        // reachable at all this finds it well inside the budget; if the content
        // grows as fast as it is consumed, it never does.
        for _ in 0..<400 {
            if first.exists { break }
            transcript.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(first.exists,
                      "dragging up through a \(Self.turns)-turn thread never reached the first message")
    }

    // MARK: - Scroll cost

    /// Flicks through the transcript under the system's own hitch
    /// instrumentation. `scrollDecelerationMetric` reports the frames dropped
    /// while a flick coasts — the number that corresponds to what "laggy"
    /// means when someone says it about a scroll view.
    ///
    /// Simulator numbers are soft (no real display link, Debug build); this is
    /// run for the RELATIVE comparison against the same test on `main`, and the
    /// absolute figure is only meaningful from a device.
    // iOS-only: `scrollDecelerationMetric` does not exist on macOS.
    #if os(iOS)
    @MainActor
    func testScrollHitchesInALongThread() throws {
        app.launch()
        let transcript = openLongThread()

        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric,
                          XCTCPUMetric(application: app),
                          XCTMemoryMetric(application: app)]) {
            for _ in 0..<6 { transcript.swipeUp(velocity: .fast) }
            for _ in 0..<6 { transcript.swipeDown(velocity: .fast) }
        }
    }
    #endif

    /// Cold open of a long thread: from tapping the row in the chats list to
    /// the newest message being on screen.
    ///
    /// Manually bracketed, and that is the point. The obvious version wraps
    /// `app.launch()` and `app.terminate()` in the measured block, and then
    /// reports app launch — ~10s of it in this harness — with the thread open
    /// buried inside as noise. The reset (back to the list, new chat, so the
    /// next selection is a genuine re-open rather than a no-op) is deliberately
    /// outside the brackets; it is identical on both arms either way.
    @MainActor
    func testOpenLongThread() throws {
        app.launch()
        _ = app.buttons["list.bullet"].firstMatch.waitForExistence(timeout: 20)

        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]

        measure(metrics: [XCTClockMetric()], options: options) {
            startMeasuring()
            let transcript = openLongThread()
            _ = transcript.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH %@", "reply \(Self.turns - 1):"))
                .firstMatch.waitForExistence(timeout: 20)
            stopMeasuring()

            // Reset by going somewhere else: selecting the thread already on
            // screen is a no-op, so without this the next iteration would
            // measure nothing. Deliberately NOT the list's "+" button — that
            // calls requestReviewIfAppropriate(), and a StoreKit review prompt
            // over the app takes the rest of the run with it.
            app.buttons["list.bullet"].firstMatch.tap()
            let scratch = app.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH %@", "scratch")).firstMatch
            XCTAssertTrue(scratch.waitForExistence(timeout: 20), "scratch thread missing from fixture")
            scratch.tap()
        }
    }
}
