//
//  ToolRoundFollowUITests.swift
//  teemoonUITests
//
//  The follow across a mid-stream tool round.
//
//  The suppression fixes (b364fad, d3cabe9) are pinned at the parser: prose
//  before a marker streams, the markup region is elided, prose after resumes
//  streaming instead of arriving in one batch. What nothing exercised is the
//  TRANSCRIPT during that sequence — a tool round is the one place mid-stream
//  where the content's growth pauses, its shape changes, and (with tools
//  armed) a working chip appears and leaves. The follow rides size changes;
//  a tool round is a size-change cliff.
//
//  Needs the server in tool-round mode:
//
//  Start the fake SSE server on :8765 in --tool-round mode, then:
//      TEST_RUNNER_TEEMOON_FAKE_SSE=http://127.0.0.1:8765/v1 \
//        xcodebuild test … -only-testing:teemoonUITests/ToolRoundFollowUITests
//
//  Probes the server first and skips on a mismatch — see FakeSSEProbe.
//

import XCTest

final class ToolRoundFollowUITests: XCTestCase {

    private static let turns = 200

    /// Server default `--lines 40`, numbering continuous across the marker.
    private var lastParagraph: Int {
        (Int(ProcessInfo.processInfo.environment["TEEMOON_STREAM_LINES"] ?? "") ?? 40) - 1
    }

    @MainActor
    func testTheFollowSurvivesAMidStreamToolCall() throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TEEMOON_FAKE_SSE"] else {
            throw XCTSkip("set TEEMOON_FAKE_SSE to the fake SSE server's base URL to run this")
        }
        try FakeSSEProbe.requireServedContent(
            endpoint: endpoint, toContain: "<tool_call>",
            mode: "tool-round (the fake SSE server's --tool-round mode)")

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
        let transcript = app.transcript
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "generation never started")

        // Leave the app alone through prose → marker → prose.
        let streamSeconds = Double(ProcessInfo.processInfo
            .environment["TEEMOON_STREAM_SECONDS"] ?? "") ?? 12
        Thread.sleep(forTimeInterval: streamSeconds + 8)

        let finished = transcript.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Paragraph \(lastParagraph):")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 60),
                      "the prose after the tool call never landed in the transcript")
        XCTAssertTrue(finished.isHittable,
            "the follow died at the tool round: the reply's last paragraph is off "
            + "screen — the transcript stopped at the size-change cliff")
    }
}
