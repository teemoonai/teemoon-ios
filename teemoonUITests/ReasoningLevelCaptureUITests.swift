//
//  ReasoningLevelCaptureUITests.swift
//  teemoonUITests
//
//  Renders for the card `composer-reasoning-chip` (docs/COMPOSER_PANEL.md §Developer mode): the chip with its level,
//  the where sheet's bar at half and full height, the pushed levels, a refusal, the largest text, and developer mode
//  off on all three screens. A capture rig: screenshots only, run with TEEMOON_CAPTURE=1 (TEEMOON_CAPTURE_PREFIX
//  names a second device's set).
//

import XCTest

final class ReasoningLevelCaptureUITests: XCTestCase {

    private var server: EmbeddedFakeSSEServer!
    private let prefix = ProcessInfo.processInfo.environment["TEEMOON_CAPTURE_PREFIX"] ?? ""
    private static let longName = "meta-llama/llama-3.3-70b-instruct-turbo-with-a-really-long-name"

    override func setUpWithError() throws {
        try CaptureRig.skipUnlessAsked()
        continueAfterFailure = true
        server = try EmbeddedFakeSSEServer(lines: 1, delay: 0.005)
        // A long list for the where sheet, so the bar is seen over rows that scroll under it.
        server.modelIDs = [Self.longName] + (1...14).map { "model-\($0)" }
    }

    override func tearDown() {
        server?.stop()
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "reasoning-\(prefix)\(name)"; a.lifetime = .keepAlways; add(a)
    }

    private func launch(developerMode: Bool, large: Bool = false, model: String = longName) -> XCUIApplication {
        var arguments = ["--uitesting", "-developerModeEnabled", developerMode ? "YES" : "NO"]
        if large { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        let app = ProductE2E.launch(arguments: arguments,
                                    environment: ["UITEST_SEED_LOCAL_ENDPOINT": server.baseURL,
                                                  "UITEST_SEED_LOCAL_MODEL": model,
                                                  "UITEST_SEED_LOCAL_KIND": "ollama"])
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20))
        // A software keyboard (the SE simulator) would cover the panel and the sheet.
        if app.keyboards.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            Thread.sleep(forTimeInterval: 0.8)
        }
        return app
    }

    private func openWhereSheet(_ app: XCUIApplication) {
        app.buttons["chat.whereChip"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.8)
    }

    /// The where sheet's own close button first (a swipe on a full-height sheet scrolls its list instead); else a drag
    /// from the sheet's top edge (model info has no close button).
    private func closeSheet(_ app: XCUIApplication) {
        // A pushed levels page first goes back to the sheet's root, where the close button is.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !app.buttons["close"].firstMatch.exists, back.exists, back.isHittable { back.tap(); Thread.sleep(forTimeInterval: 0.6) }
        let close = app.buttons["close"].firstMatch
        if close.exists, close.isHittable { close.tap(); Thread.sleep(forTimeInterval: 1.0) }
        for _ in 0..<3 where !ProductE2E.composer(app).isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            Thread.sleep(forTimeInterval: 1.0)
        }
        Thread.sleep(forTimeInterval: 0.4)
    }

    private func openModelInfo(_ app: XCUIApplication) {
        app.buttons["chat.whereChip"].firstMatch.press(forDuration: 1.0)
        let info = app.buttons["model info"].firstMatch
        if info.waitForExistence(timeout: 4) { info.tap() }
        Thread.sleep(forTimeInterval: 2.0)
    }

    private func pick(_ app: XCUIApplication, _ level: String) {
        openWhereSheet(app)
        app.descendants(matching: .any)["where.reasoningBar"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        app.buttons["reasoning.level.\(level)"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.5)
    }

    func testDeveloperModeOn() {
        let app = launch(developerMode: true)
        pick(app, "medium")
        shot(app, "4-levels-medium-picked")
        closeSheet(app)
        shot(app, "1-composer-long-name-medium")
        openWhereSheet(app)
        shot(app, "2-where-half")
        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 1.0)
        shot(app, "3-where-full")
        closeSheet(app)
        // A refusal: the server turns the level down, the turn goes without it.
        server.rejectEffortWith400 = true
        ProductE2E.typeIntoComposer(app, "hello")
        ProductE2E.send(app)
        _ = ProductE2E.waitUntilSettled(app, timeout: 30)
        server.rejectEffortWith400 = false
        shot(app, "6-refused-composer")
        openWhereSheet(app)
        shot(app, "7-refused-where")
        app.descendants(matching: .any)["where.reasoningBar"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        shot(app, "8-refused-levels")
        closeSheet(app)
        // Model info last: its sheet is the one the rig can't always close.
        openModelInfo(app)
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.6)
        shot(app, "5-model-info-read-only")
        app.terminate()
        // Leave the default for the next run (a fresh launch forgets the refusal).
        let again = launch(developerMode: true)
        pick(again, "low")
    }

    func testDeveloperModeOff() {
        let app = launch(developerMode: false)
        shot(app, "9-off-composer")
        openWhereSheet(app)
        shot(app, "10-off-where")
        closeSheet(app)
        openModelInfo(app)
        shot(app, "11-off-model-info")
    }

    func testLargestText() {
        let app = launch(developerMode: true, large: true)
        shot(app, "12-ax5-composer")
        openWhereSheet(app)
        shot(app, "13-ax5-where")
    }

    /// An OpenRouter model lists "reasoning" among its capabilities: with developer mode off model info hides it too
    /// (the maintainer 2026-11-13). Reads /models with the host's key; nothing is sent.
    func testOpenRouterCapabilitiesWithDeveloperModeOff() {
        for developerMode in [false, true] {
            let app = ProductE2E.launch(
                arguments: ["--uitesting", "-developerModeEnabled", developerMode ? "YES" : "NO"],
                environment: ["UITEST_SEED_PRESET": "openrouter", "UITEST_SEED_MODEL": "openai/gpt-5-mini"])
            XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20))
            if app.keyboards.firstMatch.exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
                Thread.sleep(forTimeInterval: 0.8)
            }
            openModelInfo(app)
            Thread.sleep(forTimeInterval: 2.0)
            // A short drag: "what it can do" (the capability chips) sits just under the prices.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
            Thread.sleep(forTimeInterval: 0.8)
            shot(app, developerMode ? "15-openrouter-model-info-on" : "14-openrouter-model-info-off")
            app.terminate()
        }
    }
}
