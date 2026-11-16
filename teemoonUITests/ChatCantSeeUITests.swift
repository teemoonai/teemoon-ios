//
//  ChatCantSeeUITests.swift
//  teemoonUITests
//
//  docs/IMAGES.md §4d (the maintainer 2026-11-11, 21:30Z): on a model that can't see images a paste still attaches, the send is
//  where it stops — the alert offers "choose model", and "send text only" when there is text. The where
//  chip with images attached opens with "reads images" on. Images get in by paste, so the suite is iOS 27+.
//

import UIKit
import UniformTypeIdentifiers
import XCTest

final class ChatCantSeeUITests: XCTestCase {

    private var server: EmbeddedFakeSSEServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard #available(iOS 27.0, *) else { throw XCTSkip("attaching by paste needs iOS 27") }
        server = try EmbeddedFakeSSEServer(lines: 1, delay: 0.005)
        server.replies = ["first-reply-alpha"]
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    private func pasteAnImage(_ app: XCUIApplication) {
        UIPasteboard.general.setItems([[UTType.png.identifier: ComposerPasteUITests.encoded(.png)]])
        let composer = ProductE2E.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "composer missing")
        composer.tap()
        composer.press(forDuration: 1.2)
        let paste = app.descendants(matching: .any)["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 6), "the edit menu offers no Paste")
        paste.tap()
    }

    private var pending: (XCUIApplication) -> XCUIElement = { $0.descendants(matching: .any)["chat.pendingImages"].firstMatch }

    func testAPasteOnAModelThatCantSeeAttaches() {
        let app = ProductE2E.launchLocal(server: server)
        pasteAnImage(app)
        XCTAssertTrue(pending(app).waitForExistence(timeout: 8), "the paste did not attach")
        XCTAssertFalse(app.descendants(matching: .any)["chat.imageModelNote"].exists, "the old note showed")
    }

    func testSendingImagesToAModelThatCantSeeOffersAModelOrTheTextAlone() {
        let app = ProductE2E.launchLocal(server: server)
        pasteAnImage(app)
        XCTAssertTrue(pending(app).waitForExistence(timeout: 8), "the paste did not attach")
        ProductE2E.typeIntoComposer(app, "describe this")
        ProductE2E.send(app)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no refusal")
        // The short alert (the maintainer 2026-11-12, DRAFT strings).
        XCTAssertTrue(alert.staticTexts["fake-model can't see images"].exists, "the title does not name the model")
        XCTAssertTrue(alert.staticTexts["your message wasn't sent. pick a model that can, or send just the text."].exists,
                      "not the short message")
        XCTAssertEqual(alert.buttons.allElementsBoundByIndex.map(\.label), ["choose model", "send text only", "cancel"])
        let textAlone = alert.buttons["send text only"]
        textAlone.tap()
        XCTAssertTrue(ProductE2E.waitUntilSettled(app), "the text did not go")
        XCTAssertTrue(ProductE2E.elementContaining(app, "first-reply-alpha").waitForExistence(timeout: 10), "no reply")
        XCTAssertFalse(app.buttons["chat.messageImage"].exists, "an image went with the text")
        XCTAssertFalse(pending(app).exists, "the images stayed in the composer")
    }

    func testWithNoTextTheRefusalOffersOnlyAModel() {
        let app = ProductE2E.launchLocal(server: server)
        pasteAnImage(app)
        XCTAssertTrue(pending(app).waitForExistence(timeout: 8), "the paste did not attach")
        ProductE2E.send(app)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no refusal")
        XCTAssertTrue(alert.staticTexts["your message wasn't sent. pick a model that can."].exists, "not the short message")
        // Two buttons sit side by side and iOS puts cancel on the left, so only the set is ours.
        XCTAssertEqual(Set(alert.buttons.allElementsBoundByIndex.map(\.label)), ["choose model", "cancel"])
        alert.buttons["choose model"].tap()
        let filter = app.buttons["where.showOnly"]
        XCTAssertTrue(filter.waitForExistence(timeout: 8), "the where sheet did not open")
        XCTAssertTrue(filter.label.contains("reads images"), "the where sheet is not filtered: \(filter.label)")
    }

    /// the maintainer 2026-11-12 (device): "choose an image-capable model" showed the composer, then the where sheet. The sheet
    /// rises straight from the alert: no keyboard coming back up on the way.
    private func assertNoKeyboardUntilWhere(_ app: XCUIApplication, _ route: String) {
        let filter = app.buttons["where.showOnly"]
        // The sheet is in the tree before it has risen and the keyboard comes back after (filmed 2026-11-12), so watch
        // the whole rise rather than stopping when the sheet first exists.
        let deadline = Date().addingTimeInterval(4)
        var sawKeyboard = false
        while Date() < deadline {
            if app.keyboards.firstMatch.exists { sawKeyboard = true }
        }
        XCTAssertTrue(filter.exists, "\(route): the where sheet did not open")
        XCTAssertFalse(sawKeyboard, "\(route): the keyboard came back before the where sheet")
    }

    func testTheRefusalGoesStraightToTheWhereSheet() {
        let app = ProductE2E.launchLocal(server: server)
        pasteAnImage(app)
        XCTAssertTrue(pending(app).waitForExistence(timeout: 8), "the paste did not attach")
        ProductE2E.typeIntoComposer(app, "describe this")
        ProductE2E.send(app)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no refusal")
        alert.buttons["choose model"].tap()
        assertNoKeyboardUntilWhere(app, "the refusal")
    }

    func testTheAttachSheetGoesStraightToTheWhereSheet() {
        let app = ProductE2E.launchLocal(server: server)
        let composer = ProductE2E.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard to begin with")
        app.buttons["chat.attach"].firstMatch.tap()
        let choose = app.buttons["choose an image-capable model"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 5), "no choose an image-capable model")
        choose.tap()
        assertNoKeyboardUntilWhere(app, "the attach sheet")
    }

    func testTheWhereChipWithImagesAttachedOpensFiltered() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        pasteAnImage(app)
        XCTAssertTrue(pending(app).waitForExistence(timeout: 8), "the paste did not attach")
        ProductE2E.whereChip(app).tap()
        let filter = app.buttons["where.showOnly"]
        XCTAssertTrue(filter.waitForExistence(timeout: 8), "the where sheet did not open")
        XCTAssertTrue(filter.label.contains("reads images"), "the where sheet is not filtered: \(filter.label)")
    }
}
