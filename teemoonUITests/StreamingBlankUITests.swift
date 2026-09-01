//
//  StreamingBlankUITests.swift
//  teemoonUITests
//
//  "The screen blanked out in the middle of generation and I had to scroll
//  down to refresh it." — Fireworks deepseek-v4-flash-0731, long conversation.
//
//  Reported against the build carrying the lazy transcript and the
//  `.sizeChanges` scroll anchor, and "had to scroll to refresh it" is the
//  signature of a LazyVStack showing a region it has not realised: the content
//  is there, the offset is somewhere the stack has nothing laid out for, and
//  only a scroll event makes it build the rows.
//
//  The detector is deliberately crude, because blankness is a STATE rather than
//  a timing: count the message paragraphs the transcript is showing. A
//  transcript mid-generation always has something — the streamed answer if
//  nothing else. Zero means blank.
//
//  Start the fake SSE server on :8765 (200 lines, 0.004 s delay), then:
//      TEST_RUNNER_TEEMOON_FAKE_SSE=http://127.0.0.1:8765/v1 \
//        xcodebuild test … -only-testing:teemoonUITests/StreamingBlankUITests
//

import XCTest

final class StreamingBlankUITests: XCTestCase {

    private func launched(turns: Int) throws -> XCUIApplication {
        guard let endpoint = ProcessInfo.processInfo.environment["TEEMOON_FAKE_SSE"] else {
            throw XCTSkip("set TEEMOON_FAKE_SSE to the fake SSE server's base URL to run this")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        app.launchEnvironment["UITEST_SEED_LONG_THREAD"] = String(turns)
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = endpoint
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launch()
        return app
    }

    private func openLongThread(_ app: XCUIApplication) -> XCUIElement {
        let chats = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 30))
        chats.tap()
        let row = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "question 0:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        let transcript = app.transcript
        XCTAssertTrue(transcript.waitForExistence(timeout: 30))
        return transcript
    }

    /// Generates a reply several screens long into a long thread and watches
    /// for the transcript going empty at any point.
    func testTranscriptNeverGoesBlankDuringGeneration() throws {
        let app = try launched(turns: 200)
        let transcript = openLongThread(app)

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()

        let anyText = NSPredicate(
            format: "label BEGINSWITH 'reply ' OR label BEGINSWITH 'question ' "
                  + "OR label CONTAINS 'Paragraph '")
        var counts: [Int] = []
        var blankAt: [Int] = []
        for i in 0..<45 {
            let n = transcript.staticTexts.matching(anyText).count
            counts.append(n)
            if n == 0 { blankAt.append(i) }
            Thread.sleep(forTimeInterval: 0.5)
        }
        print("[blank] visible paragraph counts over generation: \(counts)")
        XCTAssertTrue(blankAt.isEmpty,
            "the transcript went BLANK at sample(s) \(blankAt) during generation "
            + "(counts: \(counts)) — the lazy stack is showing an unrealised region")
    }
}
