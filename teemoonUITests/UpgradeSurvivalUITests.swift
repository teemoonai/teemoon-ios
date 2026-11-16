//
//  UpgradeSurvivalUITests.swift
//  teemoonUITests
//
//  I8 (teemoon-android docs/USE_CASES.md): an update installed over the previous release keeps every chat, key and
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

import UIKit
import XCTest

final class UpgradeSurvivalUITests: XCTestCase {

    private static let probe = "upgrade-survival-probe"
    private static let reply = "upgrade-survival-reply"
    private static let place = "upgrade box"
    private static let prompt = "upgrade-survival-prompt"
    private static let made61 = "upgrade-survival-made-in-61"
    // none of these is a 1.0.6 default (orange, medium, haptics on, developer mode off)
    private static let tint = "teal"
    private static let size = "small"

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

        // settings a 1.0.6 user can change that 1.1.0 still has
        app.launch()
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20), "the old build did not reopen")
        ProductE2E.openSettings(app)
        let developer = developerSwitch(app)
        if developer.value as? String != "1" { developer.switches.firstMatch.exists ? developer.switches.firstMatch.tap() : developer.tap() }
        XCTAssertEqual(developer.value as? String, "1", "developer mode did not turn on")
        openSection(app, "appearance")
        pick(app, "appearance.color", Self.tint)
        pick(app, "appearance.size", Self.size)
        back(app, from: "appearance", to: "settings")
        openSection(app, "chats")
        let editor = Self.promptEditor(app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the system prompt editor is missing")
        editor.tap(); editor.typeText(" \(Self.prompt)")
        XCTAssertTrue(Self.promptShown(editor).contains(Self.prompt), "the old build's editor lacks the typed marker: \(Self.around(Self.promptShown(editor)))")
        let haptics = app.switches["haptics"].firstMatch
        XCTAssertTrue(haptics.waitForExistence(timeout: 5), "the haptics switch is missing")
        if haptics.value as? String != "0" { haptics.switches.firstMatch.exists ? haptics.switches.firstMatch.tap() : haptics.tap() }
        XCTAssertEqual(haptics.value as? String, "0", "haptics did not turn off")
        back(app, from: "chats", to: "settings")
        ProductE2E.dismissSettings(app)
        // the setup the old build left selected, for the verify phase to compare
        let chip = ProductE2E.whereChip(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no where chip")
        try Self.selectedModel(chip.label).write(toFile: try Self.notePath(), atomically: true, encoding: .utf8)
        sleep(2)
        app.terminate()
    }

    /// TEST_RUNNER_UPGRADE_NOTE: a host file the two phases share (the simulator runner can write it).
    private static func notePath() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["UPGRADE_NOTE"] else { throw XCTSkip("UPGRADE_NOTE not set") }
        return path
    }

    /// 1.1.0's composer is a UITextView too, behind the settings sheet; the editor is the other one.
    private static func promptEditor(_ app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "identifier != %@", "chat.composer")).firstMatch
    }

    private static func promptShown(_ editor: XCUIElement) -> String { editor.value as? String ?? "" }

    /// Where the marker should be, or the text's ends when it is missing.
    private static func around(_ text: String) -> String {
        if let r = text.range(of: "survival") {
            let start = text.index(r.lowerBound, offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex
            return String(text[start..<r.upperBound])
        }
        return "\(text.count) chars, starts \(text.prefix(40))… ends …\(text.suffix(60))"
    }

    /// The chip's first part is the model; later parts (place, status, level) differ between versions.
    private static func selectedModel(_ label: String) -> String {
        label.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? label
    }

    private func developerSwitch(_ app: XCUIApplication) -> XCUIElement {
        let toggle = app.switches["settings.developerMode"].firstMatch
        for _ in 0..<8 where !toggle.exists { app.swipeUp() }
        XCTAssertTrue(toggle.exists, "no developer mode switch")
        return toggle
    }

    private func openSection(_ app: XCUIApplication, _ name: String) {
        let row = app.staticTexts[name].firstMatch
        for _ in 0..<6 where !row.isHittable { app.swipeDown() }
        row.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5), "\(name) did not open")
    }

    /// The named bar's back button: the chat's own bar sits behind the settings sheet.
    private func back(_ app: XCUIApplication, from screen: String, to parent: String) {
        app.navigationBars[screen].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars[parent].waitForExistence(timeout: 5), "did not return to \(parent)")
    }

    /// A navigation-link picker: open its list, tap the option; the list pops itself.
    private func pick(_ app: XCUIApplication, _ id: String, _ option: String) {
        app.descendants(matching: .any)[id].firstMatch.tap()
        func row() -> XCUIElement { app.buttons[option].firstMatch.exists ? app.buttons[option].firstMatch : app.staticTexts[option].firstMatch }
        _ = app.staticTexts[option].firstMatch.waitForExistence(timeout: 3)
        for _ in 0..<6 where !(row().exists && row().isHittable) { app.swipeUp(velocity: .slow) }
        let row = row()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(id) offered no \(option)")
        row.tap()
        if !app.navigationBars["appearance"].waitForExistence(timeout: 3) { app.navigationBars.element(boundBy: app.navigationBars.count - 1).buttons.firstMatch.tap() }
        XCTAssertTrue(shows(app, id, option), "\(id) did not take \(option)")
    }

    /// The picker row reads its choice as a whole word ("small", never "xsmall").
    private func shows(_ app: XCUIApplication, _ id: String, _ option: String) -> Bool {
        let row = app.descendants(matching: .any)[id].firstMatch
        guard row.waitForExistence(timeout: 5) else { return false }
        let text = "\(row.label) \(row.value as? String ?? "")"
        return text.range(of: "\\b\(option)\\b", options: .regularExpression) != nil
    }

    func testEverythingTheOldBuildWroteSurvivesTheUpdate() throws {
        guard phase == "verify" else { throw XCTSkip("run by the I8 upgrade flow (UPGRADE_PHASE=verify)") }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20), "the updated app did not reach the chat")

        // the saved setup the chat was on
        let chip = ProductE2E.whereChip(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no where chip")
        let seeded = try String(contentsOfFile: try Self.notePath(), encoding: .utf8)
        XCTAssertEqual(Self.selectedModel(chip.label), seeded, "the selected setup did not survive the update: \(chip.label)")

        // the settings
        ProductE2E.openSettings(app)
        XCTAssertEqual(developerSwitch(app).value as? String, "1", "developer mode did not survive the update")
        openSection(app, "appearance")
        XCTAssertTrue(shows(app, "appearance.color", Self.tint), "the color did not survive the update")
        XCTAssertTrue(shows(app, "appearance.size", Self.size), "the text size did not survive the update")
        back(app, from: "appearance", to: "settings")
        openSection(app, "chats")
        let haptics = app.switches["haptics"].firstMatch
        XCTAssertTrue(haptics.waitForExistence(timeout: 5), "the haptics switch is missing")
        XCTAssertEqual(haptics.value as? String, "0", "haptics did not survive the update")
        XCTAssertTrue(element(app, "custom").waitForExistence(timeout: 5), "the system prompt row does not read custom")
        element(app, "custom").tap()
        let editor = Self.promptEditor(app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the system prompt editor is missing")
        XCTAssertTrue(Self.promptShown(editor).contains(Self.prompt), "the system prompt did not survive the update: \(Self.around(Self.promptShown(editor)))")
        back(app, from: "system prompt", to: "chats")
        back(app, from: "chats", to: "settings")
        ProductE2E.dismissSettings(app)
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 10), "settings did not close")

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

    // MARK: the store's location (docs/DATA_MODEL.md "Where the store lives")

    /// UPGRADE_PHASE=on61, against build 61 after its verify: a chat with an image arrives (a near.ai export with an inline
    /// PNG) and the old build's chat is deleted, so the 1.0.6 file beside 61's group store is stale.
    func testBuild61AddsAnImageChatAndDeletesTheOldOne() throws {
        guard phase == "on61" else { throw XCTSkip("run by the store-location upgrade flow (UPGRADE_PHASE=on61)") }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20), "build 61 did not reach the chat")
        let png = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16)).pngData { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        let item: [String: Any] = [
            "type": "message", "id": "msg_up61", "response_id": "resp_up61", "next_response_ids": [],
            "created_at": 1_763_200_000, "status": "completed", "model": "test-model",
            "previous_response_id": "resp_outside_up61", "role": "user",
            "content": [["type": "input_text", "text": Self.made61],
                        ["type": "input_image", "image_url": "data:image/png;base64," + png.base64EncodedString()]]]
        let file = FileManager.default.temporaryDirectory.appending(path: "up61-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: [item]).write(to: file)
        XCUIDevice.shared.system.open(file)
        let confirm = app.buttons["import.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "the export did not reach the confirm step")
        ProductE2E.tapUntilGone(confirm)
        let done = app.buttons["import.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 15), "the import did not finish")
        done.tap()
        let offer = app.alerts["delete the export file?"]
        if offer.waitForExistence(timeout: 3) { offer.buttons["not now"].tap() }
        Self.deleteChat(app, Self.probe)
        // deleteChat leaves the list open.
        XCTAssertTrue(element(app, Self.made61).waitForExistence(timeout: 10), "the imported chat is not in build 61's list")
    }

    /// UPGRADE_PHASE=delete, on this build over 1.0.6: the old build's chat is deleted here. The flow's script then reads
    /// every store file in both containers: no copy of it may remain.
    func testDeletingTheOldChatOnThisBuild() throws {
        guard phase == "delete" else { throw XCTSkip("run by the store-location upgrade flow (UPGRADE_PHASE=delete)") }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20), "the app did not reach the chat")
        Self.deleteChat(app, Self.probe)
    }

    /// UPGRADE_PHASE=verify61, on this build over 61: 61's live chats moved back, the image with them, and the chat 61
    /// deleted is still gone (the stale 1.0.6 copy still had it).
    func testBuild61sChatsSurviveTheMoveBack() throws {
        guard phase == "verify61" else { throw XCTSkip("run by the store-location upgrade flow (UPGRADE_PHASE=verify61)") }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20), "the updated app did not reach the chat")
        ProductE2E.openChats(app)
        let chat = element(app, Self.made61)
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "the chat made on build 61 is gone")
        XCTAssertFalse(element(app, Self.probe).exists, "the chat deleted on build 61 came back from the 1.0.6 copy")
        chat.tap()
        XCTAssertTrue(app.buttons["chat.messageImage"].firstMatch.waitForExistence(timeout: 10),
                      "the chat made on build 61 lost its image")
    }

    /// The chats list's delete: swipe, the action, the confirmation (labels are lowercase).
    private static func deleteChat(_ app: XCUIApplication, _ title: String) {
        ProductE2E.openChats(app)
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no chat \(title) to delete")
        row.swipeLeft()
        let alert = app.alerts["delete this chat?"].firstMatch
        let swipeDelete = app.buttons["delete"].firstMatch
        if !alert.waitForExistence(timeout: 2) {
            if !swipeDelete.waitForExistence(timeout: 3) { row.swipeLeft() }
            XCTAssertTrue(swipeDelete.waitForExistence(timeout: 5), "swipe never revealed the delete action")
            swipeDelete.tap()
            XCTAssertTrue(alert.waitForExistence(timeout: 5), "delete confirmation alert missing")
        }
        alert.buttons["delete"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "the deleted chat is still in the list")
    }
}
