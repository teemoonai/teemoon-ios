//
//  teemoonUITests.swift
//  teemoonUITests
//

import XCTest

final class teemoonUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    // MARK: - Launch & Core UI

    @MainActor
    func testLaunchShowsChatInput() throws {
        let messageField = app.textFields["message"]
        XCTAssertTrue(messageField.waitForExistence(timeout: 5), "Chat input field should exist on launch")
    }

    @MainActor
    func testSettingsButtonExists() throws {
        // The gear button uses SF Symbol "gear" — XCUI exposes it via accessibility label
        let toolbar = app.navigationBars.firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        let settingsButton = toolbar.buttons.element(boundBy: toolbar.buttons.count - 1)
        XCTAssertTrue(settingsButton.exists, "Last toolbar button (settings) should exist")
    }

    // MARK: - Settings Navigation

    @MainActor
    func testOpenAndDismissSettings() throws {
        // Find and tap the settings (gear) button — it's the trailing toolbar button
        let toolbar = app.navigationBars.firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))

        // Tap the rightmost button in the toolbar (gear)
        let buttons = toolbar.buttons
        let settingsButton = buttons.element(boundBy: buttons.count - 1)
        settingsButton.tap()

        // Settings sheet should show known labels
        let settingsTitle = app.navigationBars["settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5), "Settings navigation bar should appear")

        XCTAssertTrue(app.staticTexts["appearance"].exists, "Appearance link should exist")
        XCTAssertTrue(app.staticTexts["chats"].exists, "Chats link should exist")
        XCTAssertTrue(app.staticTexts["providers"].exists, "Providers link should exist")
        XCTAssertTrue(app.staticTexts["search"].exists, "Search link should exist")

        // Dismiss via the X button (first button in settings toolbar)
        let settingsNav = app.navigationBars["settings"]
        let closeButton = settingsNav.buttons.firstMatch
        closeButton.tap()

        // Chat input should be visible again
        let messageField = app.textFields["message"]
        XCTAssertTrue(messageField.waitForExistence(timeout: 5), "Chat input should be visible after dismissing settings")
    }

    @MainActor
    func testNavigateToProviders() throws {
        openSettings()

        let providersLink = app.staticTexts["providers"]
        guard providersLink.waitForExistence(timeout: 5) else {
            XCTFail("Providers link not found")
            return
        }
        providersLink.tap()

        // Should navigate to providers page
        let providersNav = app.navigationBars["providers"]
        XCTAssertTrue(providersNav.waitForExistence(timeout: 5), "Should navigate to providers settings")
    }

    @MainActor
    func testNavigateToAppearance() throws {
        openSettings()

        let appearanceLink = app.staticTexts["appearance"]
        guard appearanceLink.waitForExistence(timeout: 5) else {
            XCTFail("Appearance link not found")
            return
        }
        appearanceLink.tap()

        let appearanceNav = app.navigationBars["appearance"]
        XCTAssertTrue(appearanceNav.waitForExistence(timeout: 5), "Should navigate to appearance settings")
    }

    @MainActor
    func testNavigateToChatsSettings() throws {
        openSettings()

        let chatsLink = app.staticTexts["chats"]
        guard chatsLink.waitForExistence(timeout: 5) else {
            XCTFail("Chats link not found")
            return
        }
        chatsLink.tap()

        let chatsNav = app.navigationBars["chats"]
        XCTAssertTrue(chatsNav.waitForExistence(timeout: 5), "Should navigate to chats settings")
    }

    // MARK: - Chat Input

    @MainActor
    func testSendButtonDisabledWhenEmpty() throws {
        let messageField = app.textFields["message"]
        guard messageField.waitForExistence(timeout: 5) else {
            XCTFail("Message field not found")
            return
        }
        // The send button should be disabled when input is empty
        // It uses SF Symbol arrow.up.circle.fill
        let sendButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'arrow'")).firstMatch
        if sendButton.exists {
            XCTAssertFalse(sendButton.isEnabled, "Send button should be disabled when prompt is empty")
        }
    }

    @MainActor
    func testTypeInChatInputEnablesSend() throws {
        let messageField = app.textFields["message"]
        guard messageField.waitForExistence(timeout: 5) else {
            XCTFail("Message field not found")
            return
        }
        messageField.tap()
        messageField.typeText("Hello")

        // After typing, the send button should become enabled
        // (we verify side-effect rather than reading field value which can be flaky)
        let sendButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'arrow'")).firstMatch
        if sendButton.waitForExistence(timeout: 3) {
            XCTAssertTrue(sendButton.isEnabled, "Send button should be enabled after typing")
        }
    }

    // MARK: - Launch Performance

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    // MARK: - Helpers

    private func openSettings() {
        let toolbar = app.navigationBars.firstMatch
        _ = toolbar.waitForExistence(timeout: 5)
        let buttons = toolbar.buttons
        let settingsButton = buttons.element(boundBy: buttons.count - 1)
        settingsButton.tap()
        _ = app.navigationBars["settings"].waitForExistence(timeout: 5)
    }
}
