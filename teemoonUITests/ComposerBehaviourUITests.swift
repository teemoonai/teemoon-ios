//
//  ComposerBehaviourUITests.swift
//  teemoonUITests
//
//  What the chat composer does for the person typing, pinned on the SwiftUI TextField (2026-11-07) before it
//  became a UITextView for image paste. Every case here must pass unchanged on whatever view draws the field:
//  found as a text field named chat.composer with the placeholder "message"; focused on a new chat and released
//  while the chats list is up; the field grows with its text and with Dynamic Type.
//
//  Set TEST_RUNNER_COMPOSER_RENDER_DIR=<dir> on xcodebuild to also write the renders there as PNGs.
//

import XCTest

final class ComposerBehaviourUITests: XCTestCase {

    private var server: EmbeddedFakeSSEServer!
    private static let ax5 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try EmbeddedFakeSSEServer(lines: 1, delay: 0.005)
        server.replies = ["composer-reply-alpha", "composer-reply-beta"]
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    // MARK: driver

    private func launch(_ extraArgs: [String] = []) -> XCUIApplication {
        ProductE2E.launch(arguments: ["--uitesting"] + extraArgs,
                          environment: ["UITEST_SEED_LOCAL_ENDPOINT": server.baseURL,
                                        "UITEST_SEED_LOCAL_MODEL": "fake-model"])
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        let field = ProductE2E.composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 20), "composer missing")
        return field
    }

    private func hasKeyboardFocus(_ field: XCUIElement) -> Bool {
        (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    private func render(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["COMPOSER_RENDER_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: url.appendingPathComponent("\(name).png"))
        }
    }

    // MARK: identity

    /// Since S44b the field is a UIKit text view: twenty-odd UI tests find it as `app.textViews["chat.composer"]`,
    /// named "message" for VoiceOver, with "message" drawn while it is empty.
    func testTheComposerIsATextViewNamedChatComposerWithThePlaceholderMessage() {
        let app = launch()
        XCTAssertTrue(app.textViews["chat.composer"].waitForExistence(timeout: 20), "not a text view named chat.composer")
        XCTAssertEqual(app.textViews["chat.composer"].label, "message")
        render(app, "before-default-empty")
    }

    // MARK: focus

    func testANewChatFocusesTheComposerAndTheChatsListReleasesIt() {
        let app = launch()
        let field = composer(app)
        XCTAssertTrue(waitFor("focus") { hasKeyboardFocus(field) }, "a new chat did not focus the composer")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard on a new chat")

        ProductE2E.openChats(app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard stayed up under the chats list")
        let plus = app.buttons["plus"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "new-chat plus missing")
        plus.tap()
        XCTAssertTrue(waitFor("refocus") { hasKeyboardFocus(self.composer(app)) },
                      "closing the chats list on an empty chat did not focus the composer again")
    }

    // MARK: size

    private static let longDraft = Array(repeating: "grow", count: 40).joined(separator: " ")

    func testTheComposerGrowsWithItsText() {
        let app = launch()
        let field = composer(app)
        let oneLine = field.frame.height
        ProductE2E.typeIntoComposer(app, Self.longDraft)
        XCTAssertTrue(waitFor("grow") { field.frame.height > oneLine * 2 },
                      "the composer did not grow: \(oneLine) → \(field.frame.height)")
        render(app, "before-default-long-draft")
    }

    func testTheComposerTextScalesWithDynamicType() {
        let regular = launch()
        let regularHeight = composer(regular).frame.height
        regular.terminate()

        let large = launch(Self.ax5)
        let field = composer(large)
        XCTAssertTrue(waitFor("ax5") { field.frame.height > regularHeight * 1.5 },
                      "the composer did not grow with AX5 text: \(regularHeight) → \(field.frame.height)")
        ProductE2E.typeIntoComposer(large, "a question at the largest text size")
        render(large, "before-ax5-draft")
    }
}
