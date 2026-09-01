//
//  ScrollStepTraceUITests.swift
//  teemoonUITests
//
//  Leaves the app alone (or only flicks) so -scrollTrace records whether
//  the transcript moves in line-sized jumps. Not a pass/fail gate — the
//  verdict is the out-of-band step analyzer run on Documents/scrolltrace.log.
//

import XCTest

final class ScrollStepTraceUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// One generation, no touches, so the follow's own cadence is visible.
    func testUnwatchedGenerationForStepTrace() throws {
        let server = try EmbeddedFakeSSEServer(lines: 16, delay: 0.02)
        defer { server.stop() }
        XCTAssertNotEqual(server.port, 0)

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = server.baseURL
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launch()

        let composer = app.textFields["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("go")
        app.buttons["chat.send"].tap()
        // 16 rich paragraphs × ~22 words × 0.02s ≈ 7s, plus settle.
        Thread.sleep(forTimeInterval: 16)
        XCTAssertTrue(app.buttons["chat.stop"].waitForNonExistence(timeout: 30))
    }

    /// Same unwatched follow, but the wire is a real cheap model (home
    /// Ollama). The fake server is metronomic; Fireworks-class serving
    /// is bursty. `--uitesting` keeps this out of the user's store.
    func testUnwatchedGenerationAgainstCheapOllama() throws {
        let endpoint = ProcessInfo.processInfo.environment["TEEMOON_OLLAMA_URL"]
            ?? "https://ringzero.tailnet-name.ts.net:11434/v1"
        let model = ProcessInfo.processInfo.environment["TEEMOON_OLLAMA_MODEL"]
            ?? "gemma4:e4b"

        // Reachable from this runner? The phone (or sim) still has to
        // reach it itself; this only skips a guaranteed-dead host.
        guard let url = URL(string: endpoint.hasSuffix("/v1")
                            ? String(endpoint.dropLast(3)) + "/api/tags"
                            : endpoint + "/api/tags") else {
            throw XCTSkip("bad Ollama URL")
        }
        var probe = URLRequest(url: url)
        probe.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0)
        var up = false
        URLSession.shared.dataTask(with: probe) { _, resp, _ in
            up = (resp as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 6)
        if !up { throw XCTSkip("Ollama not reachable at \(endpoint)") }

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = endpoint
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = model
        app.launch()

        let composer = app.textFields["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("Name twelve common herbs. One short sentence each, numbered.")
        app.buttons["chat.send"].tap()
        let streaming = app.descendants(matching: .any)
            .matching(identifier: "chat.streamingText").firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 60),
                      "generation never started — phone cannot reach Ollama?")
        // Leave it alone so the follow's own cadence is what we record.
        Thread.sleep(forTimeInterval: 45)
        XCTAssertTrue(app.buttons["chat.stop"].waitForNonExistence(timeout: 90))
    }

    /// Idle flick through a 200-turn thread — no generation.
    func testIdleFlickForStepTrace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-scrollTrace"]
        app.launchEnvironment["UITEST_SEED_LONG_THREAD"] = "200"
        app.launch()

        let chats = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 20))
        chats.tap()
        let row = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "question 0:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let transcript = app.transcript
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        for _ in 0..<8 { transcript.swipeDown(velocity: .fast) }
        Thread.sleep(forTimeInterval: 1.2)
        for _ in 0..<8 { transcript.swipeUp(velocity: .fast) }
        Thread.sleep(forTimeInterval: 1.2)
    }
}
