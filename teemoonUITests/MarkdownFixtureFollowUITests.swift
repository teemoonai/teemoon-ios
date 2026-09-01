//
//  MarkdownFixtureFollowUITests.swift
//  teemoonUITests
//
//  The follow, against the content that actually killed it.
//
//  Every defect in the streaming follow that reached the dev phone got past
//  a green suite whose fixtures were plain paragraphs. The one-page freeze
//  only reproduces against rich markdown — headings make the layout run two
//  passes per frame that disagree about the content height, and that flap is
//  what the `.sizeChanges` anchor died under (offset frozen at one page,
//  3,900pt of answer below the fold). The full drift-over-time measurement
//  still cannot live in XCUI (frames are clipped to the viewport and every
//  query idles the app — see LongThreadStreamingUITests); what CAN live here
//  is the terminal symptom: after a heading-heavy reply, either the
//  transcript ends pinned with the reply's final lines on screen, or the
//  follow died somewhere above and they are pages away.
//
//  Needs the server in FIXTURE mode — a different invocation than the rest
//  of the streaming suites:
//
//  Start the fake SSE server on :8765 serving the markdown-reply fixture
//  (its --fixture mode), then:
//      TEST_RUNNER_TEEMOON_FAKE_SSE=http://127.0.0.1:8765/v1 \
//        xcodebuild test … -only-testing:teemoonUITests/MarkdownFixtureFollowUITests
//
//  The test PROBES the server and skips if it is not serving the fixture, so
//  a stale or bare server reads as a harness mismatch, not a product bug.
//

import XCTest

final class MarkdownFixtureFollowUITests: XCTestCase {

    private static let turns = 200

    /// A string from the fixture's final lines (the last entry of its Sources
    /// list). If this is on screen when the turn ends, the follow held to the
    /// bottom; if the follow froze at one page, it is thousands of points
    /// below the viewport and unrealised.
    private static let sentinel = "Example Lab 6 announcement"

    @MainActor
    func testHeadingHeavyReplyEndsPinnedAndTheTurnEnds() throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TEEMOON_FAKE_SSE"] else {
            throw XCTSkip("set TEEMOON_FAKE_SSE to the fake SSE server's base URL to run this")
        }
        try FakeSSEProbe.requireServedContent(
            endpoint: endpoint, toContain: Self.sentinel,
            mode: "markdown fixture (point --fixture at a markdown reply fixture)")

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        app.launchEnvironment["UITEST_SEED_LONG_THREAD"] = String(Self.turns)
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = endpoint
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launch()

        let chatsButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chatsButton.waitForExistence(timeout: 20))
        chatsButton.tap()
        let row = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "question 0:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(app.transcript.waitForExistence(timeout: 20))

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "composer never appeared")
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "generation never started")

        // Leave the app COMPLETELY ALONE while the fixture streams: queries
        // idle the app and realise lazy rows, both of which mask follow
        // defects (the full account is in LongThreadStreamingUITests). The
        // fixture at the server's default cadence is well under this.
        Thread.sleep(forTimeInterval: 45)

        // THE TURN MUST END. Observed twice on 2026-08-06: full reply on
        // screen, activity chip still counting at 77-86s, stop control still
        // live. Whatever the cause, "the reply finished but the turn didn't"
        // is a defect this suite must fail on, not sleep past. `chat.stop`
        // exists exactly while a turn runs, and unlike the chip it is not
        // scrolled out of the tree.
        XCTAssertTrue(app.buttons["chat.stop"].waitForNonExistence(timeout: 90),
            "the stop control is still up long after the reply finished — "
            + "the turn never finalised")

        // THE TERMINAL FOLLOW ASSERTION: the fixture's last lines are on
        // screen. `.any` rather than `.staticText` because the sentinel is a
        // markdown LINK and may be exposed as its own element type.
        let sentinel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", Self.sentinel)).firstMatch
        XCTAssertTrue(sentinel.waitForExistence(timeout: 20),
            "the fixture's final section never landed in the transcript")

        // POSITION, NOT HITTABILITY — the sentinel is a markdown LINK.
        //
        // `isHittable` asks "does a tap at this element's centre reach this
        // element", which is a question about hit-testing rather than about
        // where the transcript came to rest. Inside a `UIHostingConfiguration`
        // cell the hit test resolves to the CELL, so a link reads
        // un-hittable while being fully drawn on screen — confirmed by
        // screenshot on 2026-08-07, with the reply's closing Sources block and
        // all six links plainly visible and this assertion red.
        //
        // What the test means is "the reply's final lines are on screen", and
        // that is a frame question, so ask it as one. `isEmpty` is the guard
        // that keeps this honest: XCUI clips an element's frame to the visible
        // area, so something scrolled entirely past the fold comes back as an
        // empty rect rather than as an off-screen one — which would otherwise
        // satisfy a naive bounds check.
        let composerTop = app.textFields["chat.composer"].frame.minY
        let transcriptTop = app.transcript.frame.minY
        let frame = sentinel.frame
        XCTAssertFalse(frame.isEmpty,
            "the reply's final lines are off screen — the follow died somewhere "
            + "above and the transcript was left behind")
        XCTAssertTrue(frame.minY >= transcriptTop && frame.maxY <= composerTop,
            "the reply's final lines are outside the transcript's visible band "
            + "(\(frame) against \(transcriptTop)...\(composerTop)) — the "
            + "transcript did not come to rest on the end of the answer")
    }
}
