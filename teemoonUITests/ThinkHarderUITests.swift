//
//  ThinkHarderUITests.swift
//  teemoonUITests
//
//  Long-press a reply → "Think Harder" (above Copy) → the reply is replaced by a
//  new answer to the same question. The effort fields themselves are pinned in
//  ReasoningEffortTests; a local server is sent none.
//

import XCTest

final class ThinkHarderUITests: XCTestCase {

    func testThinkHarderReplacesTheReply() throws {
        let server = try EmbeddedFakeSSEServer(lines: 3, delay: 0.006)
        // Replies are keyed by how many user turns a request carries, so the re-ask streams the same text.
        server.replies = ["The first answer, about sourdough starters and their yeast.",
                          "The second answer, about proofing baskets."]
        addTeardownBlock { server.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = server.baseURL
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launchEnvironment["UITEST_SEED_LOCAL_KIND"] = "ollama"
        app.launch()
        ProductE2E.sendAndWait(app, "What makes sourdough rise?", timeout: 60)
        ProductE2E.sendAndWait(app, "And proofing baskets?", timeout: 60)

        // An earlier reply offers Copy only: Think Harder there would delete every later turn.
        let older = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "first answer")).firstMatch
        XCTAssertTrue(older.waitForExistence(timeout: 10))
        app.swipeDown()
        Thread.sleep(forTimeInterval: 1)
        older.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        XCTAssertTrue(app.menuItems["copy"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["think harder"].exists, "Think Harder is on the newest reply only")
        app.menuItems["copy"].tap()
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)

        let first = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "second answer")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        let item = app.menuItems["think harder"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Think Harder in the reply's menu")
        XCTAssertEqual(item.label, "think harder", "menu items are lowercase on both platforms")
        XCTAssertTrue(app.menuItems["copy"].exists, "Copy is still offered")
        item.tap()

        let deadline = Date().addingTimeInterval(20)
        while server.requestLines.filter({ $0.hasPrefix("POST /v1/chat/completions") }).count < 3, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 30))
        Thread.sleep(forTimeInterval: 1)
        let chats = server.requestLines.filter { $0.hasPrefix("POST /v1/chat/completions") }
        XCTAssertEqual(chats.count, 3, "the newest question goes out a second time: \(server.requestLines)")
        let replies = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "second answer"))
        XCTAssertEqual(replies.count, 1, "the reply is replaced, not added under the old one")
        let bodies = server.requestBodies.filter { $0.contains("And proofing baskets?") }
        XCTAssertEqual(bodies.count, 2)
    }

    /// Android 3917.7 / release: a Think Harder stopped while the provider still held the
    /// request kept running, and its late reply was drawn over the restored one.
    /// The maintainer (56): "Why cant it work the way it used to? ... Double tap". A double-tap selects one
    /// word with handles; a long-press is still the reply's menu, not a selection.
    func testDoubleTapSelectsAWordAndLongPressIsTheMenu() throws {
        let server = try EmbeddedFakeSSEServer(lines: 3, delay: 0.006)
        server.replies = ["Tide pools hold anemones, hermit crabs, sea stars and small fish between the tides."]
        addTeardownBlock { server.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = server.baseURL
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launchEnvironment["UITEST_SEED_LOCAL_KIND"] = "ollama"
        app.launch()
        ProductE2E.sendAndWait(app, "What lives in tide pools?", timeout: 60)

        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "hermit crabs")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        let word = reply.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))

        word.press(forDuration: 1.0)
        XCTAssertTrue(app.menuItems["think harder"].waitForExistence(timeout: 5), "a long-press is the reply's menu")
        XCTAssertFalse(app.menuItems["Copy"].exists, "a long-press must not start a selection")
        attachScreenshot("long-press-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()   // empty transcript: dismisses the menu
        Thread.sleep(forTimeInterval: 1)

        word.doubleTap()
        let copy = app.menuItems["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "a double-tap selected nothing")
        attachScreenshot("double-tap-word")
        copy.tap()
        // read it back INSIDE the app: the runner reading UIPasteboard raises the simulator's paste prompt and hangs
        let composer = ProductE2E.composer(app)
        composer.tap(); composer.press(forDuration: 1.2)
        let paste = app.menuItems.matching(NSPredicate(format: "label ==[c] %@", "paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the composer offered no paste")
        paste.tap()
        let filled = NSPredicate(format: "value != nil AND value != '' AND value != 'message'")
        _ = XCTWaiter.wait(for: [expectation(for: filled, evaluatedWith: composer)], timeout: 5)
        let pasted = (composer.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(pasted.isEmpty, "nothing was selected")
        XCTAssertFalse(pasted.contains(" "), "a double-tap picked more than one word: \(pasted)")
        XCTAssertTrue(server.replies[0].contains(pasted), "what was selected is not from the reply: \(pasted)")
    }

    /// A server that may ignore the effort field (no known kind: LM Studio, llama.cpp, custom)
    /// offers no think harder; it would only ask again. Copy stays.
    func testAServerOfUnknownKindOffersNoThinkHarder() throws {
        let server = try EmbeddedFakeSSEServer(lines: 3, delay: 0.006)
        server.replies = ["The first answer, about tide pools."]
        addTeardownBlock { server.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = server.baseURL
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launch()
        ProductE2E.sendAndWait(app, "What lives in tide pools?", timeout: 60)
        let reply = ProductE2E.elementContaining(app, "first answer")
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        XCTAssertTrue(app.menuItems["copy"].waitForExistence(timeout: 5), "the reply's menu opened")
        XCTAssertFalse(app.menuItems["think harder"].exists, "no think harder where it cannot change anything")
        attachScreenshot("no-think-harder-unknown-server")
    }

    private func attachScreenshot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }

    func testAStoppedThinkHarderDrawsNoLateReply() throws {
        let server = try EmbeddedFakeSSEServer(lines: 3, delay: 0.006)
        server.replies = ["The first answer, about tide pools."]
        addTeardownBlock { server.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = server.baseURL
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launchEnvironment["UITEST_SEED_LOCAL_KIND"] = "ollama"
        app.launch()
        ProductE2E.sendAndWait(app, "What lives in tide pools?", timeout: 60)
        server.replies = ["A LATE REPLY that must never be drawn."]
        server.headerDelay = 6

        let reply = ProductE2E.elementContaining(app, "first answer")
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        let item = app.menuItems["think harder"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        Thread.sleep(forTimeInterval: 3)
        app.buttons["chat.stop"].tap()
        Thread.sleep(forTimeInterval: 8)   // past the server's 6 s hold
        XCTAssertTrue(ProductE2E.elementContaining(app, "first answer").exists, "the old reply is back")
        XCTAssertFalse(ProductE2E.elementContaining(app, "LATE REPLY").exists, "a stopped turn draws nothing late")
    }
}
