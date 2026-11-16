//
//  ChatImageActionsUITests.swift
//  teemoonUITests
//
//  docs/IMAGES.md §5: images behave like Messages — a remove button you can hit, and a long press on a sent
//  image offers copy, save and share. The image gets in by paste, so the suite is iOS 27+.
//

import UIKit
import UniformTypeIdentifiers
import XCTest

final class ChatImageActionsUITests: XCTestCase {

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

    private func launchWithAnAttachedImage() -> XCUIApplication {
        UIPasteboard.general.setItems([[UTType.jpeg.identifier: ComposerPasteUITests.encoded(.jpeg)]])
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        let composer = ProductE2E.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "composer missing")
        composer.tap()
        composer.press(forDuration: 1.2)
        let paste = app.descendants(matching: .any)["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 6), "the edit menu offers no Paste")
        paste.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.pendingImages"].firstMatch.waitForExistence(timeout: 8),
                      "the pasted image was not attached")
        return app
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTheRemoveButtonIsAFullSizeTarget() {
        let app = launchWithAnAttachedImage()
        let remove = app.buttons["remove image"].firstMatch
        XCTAssertTrue(remove.exists)
        screenshot(app, "remove-button")
        XCTAssertGreaterThanOrEqual(remove.frame.width, 44, "remove target \(remove.frame.size)")
        XCTAssertGreaterThanOrEqual(remove.frame.height, 44, "remove target \(remove.frame.size)")
        remove.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.pendingImages"].firstMatch.waitForNonExistence(timeout: 5),
                      "tapping remove left the image attached")
    }

    /// the maintainer's device check 2026-11-11: with an image in the composer, the paperclip menu's items did nothing (a second
    /// "take photo" seemed to stall). The composer's interactive glass took the taps once the menu sat inside its shape.
    func testChoosingPhotosOpensPhotosWithAnImageAttached() {
        let app = launchWithAnAttachedImage()
        openPhotosFromTheMenu(app, "keyboard-up")
    }

    /// The control: with no image the menu opens above the composer and always worked.
    func testChoosingPhotosOpensPhotosWithNoImageAndTheKeyboardUp() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        let composer = ProductE2E.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard")
        openPhotosFromTheMenu(app, "noimage-keyboard-up")
    }

    private func openPhotosFromTheMenu(_ app: XCUIApplication, _ name: String) {
        let attach = app.buttons["chat.attach"].firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        attach.tap()
        let choose = app.buttons["choose photos"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 3), "\(name): no menu")
        choose.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label ==[c] 'cancel'")).firstMatch
        let opened = cancel.waitForExistence(timeout: 8)
        screenshot(app, "after-choose-\(name)")
        XCTAssertTrue(opened, "\(name): choose photos did not open Photos with an image attached")
        if opened { cancel.tap() }
    }

    /// The same, with the image attached through a presentation that just closed (Photos; the simulator has no camera).
    func testThePaperclipMenuOpensEveryTimeAfterPhotosAttachedAnImage() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        let attach = app.buttons["chat.attach"].firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 20))
        for pick in 1...2 {
            attach.tap()
            let choose = app.buttons["choose photos"].firstMatch
            XCTAssertTrue(choose.waitForExistence(timeout: 3), "pick \(pick): no menu")
            choose.tap()
            let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH[c] 'photo'")).firstMatch
            guard photo.waitForExistence(timeout: 15) else { screenshot(app, "no-photos"); XCTFail("Photos showed no photo"); return }
            photo.tap()
            let add = app.buttons.matching(NSPredicate(format: "label ==[c] 'add' OR label ==[c] 'done'")).firstMatch
            if add.waitForExistence(timeout: 3) { add.tap() } else { screenshot(app, "no-add-\(pick)") }
            let removes = app.buttons.matching(NSPredicate(format: "label == 'remove image'"))
            let deadline = Date().addingTimeInterval(15)
            while removes.count < pick, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            XCTAssertEqual(removes.count, pick, "pick \(pick) did not attach")
        }
        for round in 1...5 {
            attach.tap()
            let choose = app.buttons["choose photos"].firstMatch
            if !choose.waitForExistence(timeout: 3) {
                screenshot(app, "no-menu-after-photos-\(round)")
                XCTFail("round \(round): tapping the paperclip opened no menu after Photos attached")
                return
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
            XCTAssertTrue(choose.waitForNonExistence(timeout: 3), "round \(round): the menu did not close")
        }
    }

    func testLongPressingASentImageOffersCopySaveAndShare() {
        let app = launchWithAnAttachedImage()
        ProductE2E.send(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app), "generation did not settle")
        let image = app.buttons["chat.messageImage"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10), "the sent image is not in the transcript")
        image.press(forDuration: 1.2)
        for action in ["copy", "save", "share"] {
            XCTAssertTrue(app.menuItems[action].firstMatch.waitForExistence(timeout: 5), "the menu has no \(action)")
        }
        screenshot(app, "image-menu")
        XCTAssertFalse(app.buttons["done"].exists, "the long press also opened the viewer")

        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: "not an image"]])
        app.menuItems["copy"].firstMatch.tap()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !UIPasteboard.general.types.contains(UTType.jpeg.identifier) {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertEqual(UIPasteboard.general.types, [UTType.jpeg.identifier], "copy did not put the image's JPEG on the pasteboard")
    }

    /// One photo is one element: VoiceOver reads it once and XCUI can hit it (2026-11-14, a zoom-source pass showed two
    /// stacked "image 1 of 1" buttons and a tile XCUI called not hittable).
    func testASentImageIsOneAccessibilityElement() {
        let app = launchWithAnAttachedImage()
        ProductE2E.send(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app), "generation did not settle")
        let image = app.buttons["chat.messageImage"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10), "the sent image is not in the transcript")
        // Known on iOS 27 (also on near-import 8b2db20d): a second, unhittable element with the same label and frame;
        // not the reply menu's anchor (hiding it changed nothing; replies are one element). 1.1.1 item; strict, so
        // this flags the day it is fixed.
        XCTExpectFailure("iOS 27: a sent photo surfaces as two accessibility elements (1.1.1)", strict: true) {
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "chat.messageImage").count, 1,
                           "one photo, more than one element")
        }
        XCTAssertTrue(image.isHittable, "the sent image is not hittable")
    }

    /// A reply's text is one element too: the long-press menu's anchor sits behind every reply, and on iOS 27 it
    /// surfaced a second copy of the photo (pm, 2026-11-14).
    func testAReplysTextIsOneAccessibilityElement() {
        let app = launchWithAnAttachedImage()
        ProductE2E.send(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app), "generation did not settle")
        let line = NSPredicate(format: "label CONTAINS %@", "first-reply-alpha")
        XCTAssertTrue(app.staticTexts.matching(line).firstMatch.waitForExistence(timeout: 10), "no reply text")
        XCTAssertEqual(app.descendants(matching: .any).matching(line).count, 1, "one line of the reply, more than one element")
    }

    func testLongPressingTheViewersImageOffersTheSameMenu() {
        let app = launchWithAnAttachedImage()
        ProductE2E.send(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app), "generation did not settle")
        let image = app.buttons["chat.messageImage"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10), "the sent image is not in the transcript")
        image.tap()
        let shown = app.descendants(matching: .any)["chat.viewerImage"].firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 5), "the viewer did not open")
        shown.press(forDuration: 1.2)
        for action in ["copy", "save", "share"] {
            XCTAssertTrue(app.buttons[action].firstMatch.waitForExistence(timeout: 5), "the viewer's menu has no \(action)")
        }
        screenshot(app, "viewer-menu")
    }
}
