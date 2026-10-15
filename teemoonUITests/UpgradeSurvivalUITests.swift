//
//  UpgradeSurvivalUITests.swift
//  teemoonUITests
//
//  I8 (the Android port's use-case list): an update installed over the previous release keeps every chat, key and
//  place. Two phases with an install between them — the runner cannot outlive the app it replaces:
//
//    UPGRADE_PHASE=seed    the PREVIOUS release is the target app: a plain launch (no --uitesting, so the real store
//                          and Keychain), then the user's own steps — connect a computer, chat on it, add a cloud key
//    UPGRADE_PHASE=verify  THIS build installed over it (an upgrade install keeps the container, as the App Store's
//                          does): a plain launch reads it all back
//
//  Both skip unless the phase is set (TEST_RUNNER_UPGRADE_PHASE on xcodebuild). On a device, run against the
//  ai.teemoon.app.e2e install only — never "teemoon dev", which may hold real chats and keys.
//
//  How (iPhone 16 Pro, 2026-10-05 — green: 1.0.4 (38) seeded, build 39 installed over it read everything back):
//    1. the previous release as the e2e app: `xcodebuild build` in a worktree at its tag (v1.0.4) with
//       PRODUCT_BUNDLE_IDENTIFIER=ai.teemoon.app.e2e, its own -derivedDataPath
//    2. this tree: `xcodebuild build-for-testing` with the same id and CURRENT_PROJECT_VERSION one above the release's,
//       so the phone's installed version says which build is there (`devicectl device info apps`)
//    3. a copy of the .xctestrun with every `__TESTROOT__/Debug-iphoneos/teemoon.app` replaced by the OLD app's path;
//       `TEST_RUNNER_UPGRADE_PHASE=seed xcodebuild test-without-building -xctestrun <copy> -only-testing:…Seed…`
//    4. `TEST_RUNNER_UPGRADE_PHASE=verify xcodebuild test-without-building -xctestrun <original> -only-testing:…Survives…`
//       — xcodebuild installs this build over the old one, as an update does
//

import XCTest

final class UpgradeSurvivalUITests: XCTestCase {

    private static let probe = "upgrade-survival-probe"
    private static let reply = "upgrade-survival-reply"
    private static let place = "upgrade box"

    private var phase: String? { ProcessInfo.processInfo.environment["UPGRADE_PHASE"] }

    override func setUp() { continueAfterFailure = false }

    private func element(_ app: XCUIApplication, _ fragment: String) -> XCUIElement {
        ProductE2E.elementContaining(app, fragment)
    }

    /// The where sheet: from the chip, or already up on a first run.
    private func openWhere(_ app: XCUIApplication) {
        let chip = ProductE2E.whereChip(app)
        if chip.waitForExistence(timeout: 8) { chip.tap() }
        else if element(app, "choose where").exists { element(app, "choose where").tap() }   // an empty store's chip
        XCTAssertTrue(element(app, "connect a computer").waitForExistence(timeout: 10) || app.buttons["cloud"].firstMatch.waitForExistence(timeout: 5),
                      "the where sheet did not open")
    }

    private func cloudRow(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons["cloud"].firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND identifier != %@", name, "chat.whereChip")).firstMatch
        for _ in 0..<8 where !row.exists { app.swipeUp(velocity: .slow); sleep(1) }
        return row
    }

    func testSeedTheOldBuild() throws {
        guard phase == "seed" else { throw XCTSkip("run by the I8 upgrade flow (UPGRADE_PHASE=seed)") }
        let server = try EmbeddedFakeSSEServer(lines: 2, delay: 0.005)
        server.replies = [Self.reply]
        defer { server.stop() }
        let app = XCUIApplication()
        app.launch()   // plain: the store and Keychain an update must keep
        // an earlier seed already wrote it all (the chip names its computer): the old build's data is there to verify
        if ProductE2E.whereChip(app).waitForExistence(timeout: 8), ProductE2E.whereChip(app).label.contains("fake-model") {
            throw XCTSkip("already seeded by an earlier run — the old build's data is in place")
        }

        // a computer, by the user's own steps
        openWhere(app)
        element(app, "connect a computer").tap()
        let label = app.textFields["label"].firstMatch
        if label.waitForExistence(timeout: 5) { label.tap(); label.typeText(Self.place) }
        let endpoint = app.textFields["api.example.com/v1"].firstMatch
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5), "the endpoint field is missing")
        endpoint.tap(); endpoint.typeText(server.baseURL.replacingOccurrences(of: "http://", with: ""))
        app.staticTexts["model"].firstMatch.tap()
        let fetch = app.buttons["fetch models"].firstMatch
        if fetch.waitForExistence(timeout: 4) { fetch.tap() }
        let model = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "fake-model")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 30), "the server's model never appeared")
        model.tap()
        app.buttons["save"].firstMatch.tap()
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 10), "save did not end in the chat")

        // a chat on it
        ProductE2E.sendAndWait(app, Self.probe)
        XCTAssertTrue(element(app, Self.reply).waitForExistence(timeout: 15), "the reply never landed")

        // a cloud key
        openWhere(app)
        let fireworks = cloudRow(app, "fireworks")
        XCTAssertTrue(fireworks.waitForExistence(timeout: 10), "the cloud filter has no fireworks row")
        fireworks.tap()
        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 10), "fireworks' key form did not open")
        key.tap(); key.typeText("uitest-upgrade-key")
        app.buttons["save"].firstMatch.tap()
        sleep(2)
        app.terminate()   // let SwiftData write through before the install
    }

    func testEverythingTheOldBuildWroteSurvivesTheUpdate() throws {
        guard phase == "verify" else { throw XCTSkip("run by the I8 upgrade flow (UPGRADE_PHASE=verify)") }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20), "the updated app did not reach the chat")

        // the chat
        ProductE2E.openChats(app)
        let thread = element(app, Self.probe)
        XCTAssertTrue(thread.waitForExistence(timeout: 10), "the chat from the old build is gone")
        thread.tap()
        XCTAssertTrue(element(app, Self.reply).waitForExistence(timeout: 10), "the chat survived without its reply")

        // the place and the key
        openWhere(app)
        XCTAssertTrue(element(app, Self.place).waitForExistence(timeout: 10) || element(app, "127.0.0.1").exists, "the computer from the old build is gone")
        let fireworks = cloudRow(app, "fireworks")
        XCTAssertTrue(fireworks.waitForExistence(timeout: 10), "the cloud filter has no fireworks row")
        XCTAssertFalse(fireworks.label.contains("add key"), "the fireworks key did not survive the update: \(fireworks.label)")
    }
}
