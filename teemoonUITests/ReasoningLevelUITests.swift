//
//  ReasoningLevelUITests.swift
//  teemoonUITests
//
//  Developer mode's reasoning level (docs/REASONING_LEVEL.md; the maintainer 2026-11-13 15:54Z): the level on the where chip, a
//  pinned "reasoning … <level> ›" bar in the where sheet that pushes to the levels, model info read-only, and with
//  developer mode off no reasoning text anywhere ("the reasoning information should only be visible on developer
//  mode, including the chip that shows the model").
//

import XCTest

final class ReasoningLevelUITests: XCTestCase {

    private var server: EmbeddedFakeSSEServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try EmbeddedFakeSSEServer(lines: 1, delay: 0.005)
        server.replies = ["first-reply-alpha", "second-reply-beta", "third-reply-gamma"]
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    /// The fake server stands in for Ollama, which takes `reasoning_effort`.
    private func launch(developerMode: Bool) -> XCUIApplication {
        // Developer mode persists in the simulator between launches; the argument domain wins over it for this
        // launch only, so "off" really is off.
        let app = ProductE2E.launch(
            arguments: ["--uitesting", "-developerModeEnabled", developerMode ? "YES" : "NO"],
            environment: ["UITEST_SEED_LOCAL_ENDPOINT": server.baseURL, "UITEST_SEED_LOCAL_MODEL": "fake-model",
                          "UITEST_SEED_LOCAL_KIND": "ollama"])
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20))
        return app
    }

    private func chip(_ app: XCUIApplication) -> XCUIElement {
        let chip = app.buttons["chat.whereChip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no where chip")
        return chip
    }

    private func openWhereSheet(_ app: XCUIApplication) {
        chip(app).tap()
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// The where sheet's own close button (back first from the levels page); a swipe can't close a full-height sheet,
    /// which the where sheet is on short phones. Model info has no close button: a drag from its navigation bar.
    private func closeSheet(_ app: XCUIApplication) {
        let close = app.buttons["close"].firstMatch
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if !(close.exists && close.isHittable), back.exists, back.isHittable, back.label != "close" {
            back.tap(); Thread.sleep(forTimeInterval: 0.6)
        }
        if close.exists, close.isHittable {
            close.tap()
        } else {
            dragSheetDown(app)
        }
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// From the sheet's navigation bar (not above it: on a full-height sheet that is the status bar).
    private func dragSheetDown(_ app: XCUIApplication) {
        // The sheet's own bar by its title: `firstMatch` is the chat screen's bar underneath.
        let titled = ["reasoning", "model", "where"].map { app.navigationBars[$0] }.first { $0.exists }
        let bar = (titled ?? app.navigationBars.firstMatch).frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (bar.minY + 8) / app.frame.height))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
    }

    private func openModelInfo(_ app: XCUIApplication) {
        chip(app).press(forDuration: 1.0)
        let info = app.buttons["model info"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5), "the chip's menu has no model info")
        info.tap()
        Thread.sleep(forTimeInterval: 2.0)
    }

    /// The bodies this send produced: the chat turn, and any title request after it.
    private func send(_ app: XCUIApplication, _ text: String) -> String {
        let before = server.requestBodies.count
        ProductE2E.typeIntoComposer(app, text)
        ProductE2E.send(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 30))
        return server.requestBodies.dropFirst(before).joined(separator: "\n")
    }

    private func reasoningText(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'reasoning'"))
    }

    func testDeveloperModeOffShowsNoReasoningAnywhere() {
        let app = launch(developerMode: false)
        XCTAssertFalse(chip(app).label.lowercased().contains("reasoning"), "the chip: \(chip(app).label)")
        openWhereSheet(app)
        XCTAssertFalse(app.descendants(matching: .any)["where.reasoningBar"].exists, "a reasoning bar with developer mode off")
        XCTAssertEqual(reasoningText(app).count, 0, "reasoning text in the where sheet")
        closeSheet(app)
        openModelInfo(app)
        XCTAssertEqual(reasoningText(app).count, 0, "reasoning text in model info")
        closeSheet(app)
        let sent = send(app, "hello")
        XCTAssertTrue(sent.contains(#""reasoning_effort":"low""#), sent)
    }

    func testDeveloperModeOnShowsTheLevelAndTheBarSetsIt() {
        let app = launch(developerMode: true)
        // Start from the default: a pick persists in the simulator.
        openWhereSheet(app)
        let bar = app.descendants(matching: .any)["where.reasoningBar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no reasoning bar in developer mode")
        bar.tap()
        let low = app.buttons["reasoning.level.low"].firstMatch
        XCTAssertTrue(low.waitForExistence(timeout: 5), "the bar did not push to the levels")
        low.tap()
        closeSheet(app)
        XCTAssertTrue(chip(app).label.contains("reasoning low"), "the chip: \(chip(app).label)")

        openWhereSheet(app)
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.label.contains("low (default)"), "the bar: \(bar.label)")
        bar.tap()
        let medium = app.buttons["reasoning.level.medium"].firstMatch
        XCTAssertTrue(medium.waitForExistence(timeout: 5))
        medium.tap()
        closeSheet(app)
        XCTAssertTrue(chip(app).label.contains("reasoning medium"), "the chip follows the pick: \(chip(app).label)")
        let first = send(app, "hello")
        XCTAssertTrue(first.contains(#""reasoning_effort":"medium""#), "the send carries the pick: \(first)")

        // Model info is read-only: the levels, no control.
        openModelInfo(app)
        XCTAssertTrue(app.staticTexts["low, medium, high"].waitForExistence(timeout: 5), "model info's read-only levels")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "model.reasoningLevel").count, 0)
        closeSheet(app)

        // Back to the default, which is also what the next run starts from.
        openWhereSheet(app)
        bar.tap()
        XCTAssertTrue(low.waitForExistence(timeout: 5))
        low.tap()
        closeSheet(app)
        let second = send(app, "again")
        XCTAssertTrue(second.contains(#""reasoning_effort":"low""#), second)
    }

    /// Model info from the chip while typing: the composer gives up the keyboard before the page covers it, or a
    /// menu on the page brought it back over the page (seen on the SE simulator, 2026-11-13).
    func testTheKeyboardStaysDownUnderTheModelPage() {
        let app = launch(developerMode: true)
        let composer = ProductE2E.composer(app)
        composer.tap()
        XCTAssertTrue(composer.value(forKey: "hasKeyboardFocus") as? Bool == true, "the composer has the keyboard")
        openModelInfo(app)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard over the model page")
        XCTAssertFalse(composer.value(forKey: "hasKeyboardFocus") as? Bool == true, "the composer kept the keyboard")
    }

    /// Closing the sheet from the pushed levels page and opening it again starts at the sheet's root, not the levels
    /// (the capture rig reopened on the levels page, 2026-11-13).
    func testTheWhereSheetReopensAtItsRoot() {
        let app = launch(developerMode: true)
        openWhereSheet(app)
        let bar = app.descendants(matching: .any)["where.reasoningBar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.tap()
        XCTAssertTrue(app.buttons["reasoning.level.low"].firstMatch.waitForExistence(timeout: 5))
        // Dismissed from the levels page by a drag, not the close button.
        dragSheetDown(app)
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(ProductE2E.composer(app).isHittable, "the sheet did not close")
        openWhereSheet(app)
        XCTAssertFalse(app.buttons["reasoning.level.low"].firstMatch.exists, "the sheet reopened on the levels page")
        XCTAssertTrue(bar.exists, "the sheet's root, with its bar")
    }

    /// "For the duration of a think harder, the composer should show the actual reasoning level which then goes back to
    /// low afterwards" (the maintainer 2026-11-14).
    func testTheChipShowsTheThinkHarderLevelWhileItRuns() {
        let app = launch(developerMode: true)
        _ = send(app, "hello")
        XCTAssertTrue(chip(app).label.contains("reasoning low"), "before: \(chip(app).label)")
        server.startDelay = 4.0
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "first-reply-alpha")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        let item = app.menuItems["think harder"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no think harder on the reply")
        item.tap()
        let during = NSPredicate(format: "label CONTAINS %@", "reasoning high")
        XCTAssertTrue(chip(app).waitFor(during, timeout: 3), "during: \(chip(app).label)")
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 30))
        XCTAssertTrue(chip(app).waitFor(NSPredicate(format: "label CONTAINS %@", "reasoning low"), timeout: 3),
                      "after: \(chip(app).label)")
    }
}


extension ReasoningLevelUITests {
    /// A refused level is resent with none: the chip drops the Think Harder's level on the resend, mid-turn.
    func testTheChipDropsTheLevelWhenTheServerRefusesIt() {
        let app = launch(developerMode: true)
        _ = send(app, "hello")
        server.startDelay = 4.0
        server.rejectEffortWith400 = true
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "first-reply-alpha")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        let item = app.menuItems["think harder"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 3), "the resent turn is running")
        let noLevel = NSPredicate(format: "NOT (label CONTAINS %@)", "reasoning high")
        XCTAssertTrue(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: noLevel, object: chip(app))],
                                       timeout: 3) == .completed, "during the resend: \(chip(app).label)")
        XCTAssertTrue(app.buttons["chat.stop"].exists, "checked mid-turn")
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 30))
    }
}

private extension XCUIElement {
    func waitFor(_ predicate: NSPredicate, timeout: TimeInterval) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}
