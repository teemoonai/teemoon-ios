//
//  NoKeySendGateCaptureUITests.swift
//  teemoonUITests
//
//  A cloud setup saved without a key. Captures the send gate's alert and the
//  places & keys badge that now says so — the two screens a tester saw as
//  "HTTP 422 Field required" and "cloud keys 1".
//
//  Extract the images after a run:
//    xcrun xcresulttool export attachments --path <run>.xcresult --output-path out
//

import XCTest

final class NoKeySendGateCaptureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testKeylessBraveAnswersIsGatedAndBadged() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment = ["UITEST_SEED_PRESET": "brave", "UITEST_SEED_NO_KEY": "1"]
        app.launch()

        ProductE2E.typeIntoComposer(app, "What's the best boutique shop in Paris")
        ProductE2E.send(app)

        let alert = app.alerts["no api key"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the no-key alert did not appear")
        Thread.sleep(forTimeInterval: 0.5)
        ProductE2E.attachScreenshot(app, name: "SHOT-1-no-key-alert", to: self)
        // Nothing went out: the prompt is still in the composer, not in the transcript.
        XCTAssertFalse(app.buttons["chat.stop"].exists)

        // "add a key" lands on THIS setup's edit screen, key field included.
        alert.buttons["add a key"].tap()
        let keyField = app.secureTextFields.firstMatch
        XCTAssertTrue(keyField.waitForExistence(timeout: 8), "the edit screen with a key field did not open")
        Thread.sleep(forTimeInterval: 0.5)
        ProductE2E.attachScreenshot(app, name: "SHOT-1b-add-key-lands-on-edit", to: self)

        // Saving the EDIT with the key still blank is refused the same way —
        // the path a tester used to strip a key from a saved setup.
        let editSave = app.buttons["save"].firstMatch
        XCTAssertTrue(editSave.isEnabled)
        editSave.tap()
        XCTAssertTrue(app.descendants(matching: .any)["provider.keyFieldError"].firstMatch
            .waitForExistence(timeout: 3), "editing must refuse an empty key")
        Thread.sleep(forTimeInterval: 0.6)
        ProductE2E.attachScreenshot(app, name: "SHOT-1c-edit-save-refused-without-key", to: self)
        app.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 0.5)

        ProductE2E.openSettings(app)
        let places = app.buttons["settings.providers"].firstMatch
        XCTAssertTrue(places.waitForExistence(timeout: 5))
        places.tap()
        let badge = app.staticTexts["1 needs key"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "hub badge did not say the key is missing")
        Thread.sleep(forTimeInterval: 0.5)
        ProductE2E.attachScreenshot(app, name: "SHOT-2-places-keys-badge", to: self)

        app.staticTexts["cloud keys"].firstMatch.tap()
        _ = app.navigationBars["cloud keys"].waitForExistence(timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        ProductE2E.attachScreenshot(app, name: "SHOT-3-cloud-keys-row", to: self)

        // Adding another cloud setup with the key blank: save refuses with an
        // inline error on the field. This is the tap that used to create the
        // keyless setup.
        app.buttons["add cloud key"].firstMatch.tap()
        // Step one: the provider list.
        XCTAssertTrue(app.navigationBars["add cloud key"].waitForExistence(timeout: 5),
                      "add cloud key should push the provider list")
        Thread.sleep(forTimeInterval: 0.5)
        ProductE2E.attachScreenshot(app, name: "SHOT-5b-add-cloud-key-provider-list", to: self)
        // The row's label is "name, description". The chat's Where chip and the
        // cloud-keys row behind both start with the same name, so match on the
        // description, which only this row carries.
        let tile = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'answers from live web search'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 8), "brave answers provider row missing")
        tile.tap()
        XCTAssertTrue(app.textFields["brave answers"].firstMatch.waitForExistence(timeout: 5),
                      "the brave answers preset did not fill the form")
        let save = app.buttons["save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled, "save stays enabled — the refusal is inline")
        save.tap()
        XCTAssertTrue(app.descendants(matching: .any)["provider.keyFieldError"].firstMatch
            .waitForExistence(timeout: 3), "the key field must show the validation error")
        XCTAssertTrue(app.buttons["save"].firstMatch.exists, "the form must stay on screen")
        Thread.sleep(forTimeInterval: 0.6)
        ProductE2E.attachScreenshot(app, name: "SHOT-6-add-brave-save-tapped-no-key", to: self)
    }
}
