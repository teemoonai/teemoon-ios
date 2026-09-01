//
//  RealDeepSeekProbeUITests.swift
//  teemoonUITests
//
//  Drives ONE real generation against the user's own configured provider, with
//  web search on — the exact configuration that produced "it returns the bottom
//  half of a fast generation in one batch".
//
//  Deliberately NOT `--uitesting`. That flag now gives an ephemeral provider
//  store (so a test can never again overwrite a real config), which also means
//  it cannot see the user's real Fireworks account or its Keychain key. Only
//  `-scrollTrace` is passed: real providers, real keys, real chat store, plus
//  the trace.
//
//  Consequences, on purpose and worth knowing before running it: this writes a
//  real thread to real chat history and spends real tokens. Opt-in only.
//
//      TEST_RUNNER_TEEMOON_REAL_PROBE=1 xcodebuild test … \
//        -only-testing:teemoonUITests/RealDeepSeekProbeUITests
//

import XCTest

final class RealDeepSeekProbeUITests: XCTestCase {

    func testOneRealGenerationWithWebSearch() throws {
        guard ProcessInfo.processInfo.environment["TEEMOON_REAL_PROBE"] == "1" else {
            throw XCTSkip("set TEEMOON_REAL_PROBE=1 — this spends real tokens and writes a real thread")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-scrollTrace"]
        app.launch()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 40), "composer never appeared")

        // Web search must be ON — it is what attaches a tool, which is what makes
        // a model emit the tool-call markup this is about.
        let webChip = app.buttons["chat.webSearchChip"].firstMatch
        XCTAssertTrue(webChip.waitForExistence(timeout: 20), "web search chip missing")
        let stateBefore = (webChip.value as? String) ?? "unknown"
        print("[probe] web search chip before: \(stateBefore)")
        if stateBefore == "off" {
            webChip.tap()
            Thread.sleep(forTimeInterval: 2)
        }
        let stateAfter = (app.buttons["chat.webSearchChip"].firstMatch.value as? String) ?? "unknown"
        print("[probe] web search chip after: \(stateAfter)")
        guard stateAfter != "off" else {
            throw XCTSkip("web search is off and could not be enabled — a Brave key is probably not configured")
        }

        composer.tap()
        composer.typeText("What are the most notable AI model releases this week? Give a detailed rundown with sources.")
        app.buttons["chat.send"].tap()

        // Fixed sleep, no polling. Every XCUI query idles the app, and idling is
        // exactly what would smooth over a batching defect.
        Thread.sleep(forTimeInterval: 90)
        print("[probe] done waiting")
    }
}
