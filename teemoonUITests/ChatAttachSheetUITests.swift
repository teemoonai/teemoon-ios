//
//  ChatAttachSheetUITests.swift
//  teemoonUITests
//
//  docs/IMAGES.md §4d (the maintainer 2026-11-11): a "+" opens the attach sheet on every model; on one that can't see images
//  the sheet says so and offers the where sheet filtered to "reads images". Thumbnails 64 pt, a lone sent image 240 pt.
//  Images get in by paste, so the suite is iOS 27+.
//

import UIKit
import UniformTypeIdentifiers
import XCTest

final class ChatAttachSheetUITests: XCTestCase {

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

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private static let footnote = "photos are resized on this phone and their location is removed before they're sent."

    func testPlusOpensTheAttachSheet() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        let attach = app.buttons["chat.attach"].firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 20), "no attach button")
        attach.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.attachSheet"].firstMatch.waitForExistence(timeout: 5),
                      "+ opened no attach sheet")
        XCTAssertTrue(app.buttons["choose photos"].firstMatch.exists, "no choose photos")
        XCTAssertTrue(app.staticTexts[Self.footnote].exists, "no footnote")
        XCTAssertFalse(app.staticTexts["fake-model can't see images."].exists, "a model that reads images got the line")
        screenshot(app, "attach-sheet")
    }

    /// the maintainer 2026-11-14, on the phone: pulling the sheet up grew it to the whole screen, the two buttons stretched
    /// to full height. The sheet measured its own content, which filled whatever height the drag gave it.
    func testPullingTheSheetUpDoesNotGrowIt() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        let attach = app.buttons["chat.attach"].firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 20), "no attach button")
        attach.tap()
        let choose = app.buttons["choose photos"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 5), "+ opened no attach sheet")
        Thread.sleep(forTimeInterval: 1)
        let before = choose.frame.height
        let window = app.windows.firstMatch.frame
        for _ in 0..<3 {
            let grab = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.midX, dy: choose.frame.minY - 30))
            grab.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.midX, dy: 80)))
            Thread.sleep(forTimeInterval: 1)
        }
        screenshot(app, "attach-sheet-after-pull")
        XCTAssertTrue(choose.exists, "the pull closed the sheet")
        XCTAssertEqual(choose.frame.height, before, accuracy: 2, "pulling the sheet up stretched its buttons")
    }

    /// the maintainer 2026-11-12: about 12 pt from the + circle to the text, as the mock draws it (it was 22).
    /// the maintainer 2026-11-12, "One panel": the +, the where chip, the web chip and send sit in one row at the bottom of
    /// the field's panel; nothing floats beside or above it (docs/COMPOSER_PANEL.md).
    func testTheComposerIsOnePanel() {
        // No seeded capabilities: unknown takes tools, so the web chip shows (a [.vision]-only model hides it).
        let app = ProductE2E.launchLocal(server: server)
        let card = app.descendants(matching: .any)["chat.composerCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        let row = [app.buttons["chat.attach"].firstMatch, app.descendants(matching: .any)["chat.whereChip"].firstMatch,
                   app.descendants(matching: .any)["chat.webSearchChip"].firstMatch, app.buttons["chat.send"].firstMatch]
        for control in row {
            XCTAssertTrue(control.exists, "\(control) missing")
            XCTAssertTrue(card.frame.insetBy(dx: -1, dy: -1).contains(control.frame), "\(control.identifier) is outside the panel")
        }
        let mids = row.map(\.frame.midY)
        XCTAssertLessThan((mids.max() ?? 0) - (mids.min() ?? 0), 4, "the bottom row is not one row: \(mids)")
        XCTAssertLessThan(abs(card.frame.maxY - (row[0].frame.maxY)), 16, "the row is not at the bottom")
    }

    /// One row height (docs/COMPOSER_PANEL.md spacing): at the largest size the chips grow with the text, they were
    /// taller than the 34 circles beside them (check 7, 2026-11-12).
    func testTheRowIsOneHeightAtTheLargestNonAccessibilitySize() {
        let app = ProductE2E.launch(arguments: ["--uitesting", "-UIPreferredContentSizeCategoryName",
                                                "UICTContentSizeCategoryXXXL"],
                                    environment: ["UITEST_SEED_LOCAL_ENDPOINT": server.baseURL,
                                                  "UITEST_SEED_LOCAL_MODEL": "fake-model"])
        let plus = app.buttons["chat.attach"].firstMatch
        let chip = app.descendants(matching: .any)["chat.whereChip"].firstMatch
        let web = app.descendants(matching: .any)["chat.webSearchChip"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 20) && chip.exists && web.exists)
        // Each item is reported at its 44 hit area (a 34 drawing + 5 each side); a chip that outgrew 34 would outgrow it.
        for item in [chip, web] {
            XCTAssertEqual(item.frame.height, plus.frame.height, accuracy: 1,
                           "\(item.identifier) is \(item.frame.height) tall, the + \(plus.frame.height)")
        }
    }

    /// The row stays pinned as the text grows, and the text stops growing at 6 lines.
    func testTheRowStaysAtTheBottomAndTheTextStopsAtSixLines() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        let card = app.descendants(matching: .any)["chat.composerCard"].firstMatch
        let send = app.buttons["chat.send"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        let oneLine = card.frame.height
        ProductE2E.typeIntoComposer(app, "1\n2\n3")
        XCTAssertGreaterThan(card.frame.height, oneLine + 20, "the panel did not grow")
        XCTAssertLessThan(abs(card.frame.maxY - send.frame.maxY), 16, "the row left the bottom at 3 lines")
        ProductE2E.typeIntoComposer(app, "\n4\n5\n6")
        let six = card.frame.height
        ProductE2E.typeIntoComposer(app, "\n7\n8\n9\n10")
        XCTAssertEqual(card.frame.height, six, accuracy: 2, "the text kept growing past 6 lines")
    }

    func testPlusOnAModelThatCantSeeOpensTheSheetWithTheLine() {
        let app = ProductE2E.launchLocal(server: server)
        let attach = app.buttons["chat.attach"].firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 20), "no attach button")
        attach.tap()
        XCTAssertTrue(app.staticTexts["fake-model can't see images."].waitForExistence(timeout: 5), "no can't-see line")
        XCTAssertTrue(app.buttons["choose photos"].firstMatch.isEnabled, "choose photos is not enabled")
        screenshot(app, "attach-sheet-cant-see")
        let choose = app.buttons["choose an image-capable model"].firstMatch
        XCTAssertTrue(choose.exists, "no choose an image-capable model")
        choose.tap()
        let filter = app.buttons["where.showOnly"]
        XCTAssertTrue(filter.waitForExistence(timeout: 8), "the where sheet did not open")
        XCTAssertTrue(filter.label.contains("reads images"), "the where sheet is not filtered: \(filter.label)")
        XCTAssertFalse(app.descendants(matching: .any)["chat.attachSheet"].firstMatch.exists, "the attach sheet stayed under it")
    }

    private func attachOne(_ app: XCUIApplication) {
        UIPasteboard.general.setItems([[UTType.png.identifier: ComposerPasteUITests.encoded(.png)]])
        let composer = ProductE2E.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "composer missing")
        composer.tap()
        composer.press(forDuration: 1.2)
        let paste = app.descendants(matching: .any)["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 6), "the edit menu offers no Paste")
        paste.tap()
    }

    func testAnAttachedThumbnailIs64Points() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        attachOne(app)
        let thumb = app.descendants(matching: .any)["chat.pendingImage"].firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout: 8), "no attached thumbnail")
        XCTAssertEqual(thumb.frame.width, 64, accuracy: 0.5)
        XCTAssertEqual(thumb.frame.height, 64, accuracy: 0.5)
    }

    /// the maintainer 2026-11-12: even space above and below the attached thumbnails: 16 pt from the field's top edge, 8 pt to
    /// its one-line text row (whose text is 8 lower), the row's leading edge on the text's 16 pt inset.
    func testTheThumbnailsSitEvenlyInTheComposer() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        attachOne(app)
        let thumb = app.descendants(matching: .any)["chat.pendingImage"].firstMatch
        let card = app.descendants(matching: .any)["chat.composerCard"].firstMatch
        let attach = app.buttons["chat.attach"].firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout: 8) && card.exists && attach.exists)
        let above = thumb.frame.minY - card.frame.minY
        // Down to the text, which sits above the bottom row.
        let field = ProductE2E.composer(app)
        let below = field.frame.minY - thumb.frame.maxY
        XCTAssertEqual(above, 17, accuracy: 2, "above the thumbnails: \(above)")
        // The text view starts at the strip; its own 17 top inset (it scrolls with the text) is the gap to its first line.
        XCTAssertEqual(below, 0, accuracy: 2, "the text view does not start at the strip: \(below)")
        // The row starts with the field, not the + (IMAGES.md §4d).
        XCTAssertEqual(thumb.frame.minX - card.frame.minX, 16, accuracy: 2, "thumbnails not on the field's text inset")
    }

    func testALoneSentImageIs240PointsWide() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        attachOne(app)
        XCTAssertTrue(app.descendants(matching: .any)["chat.pendingImages"].firstMatch.waitForExistence(timeout: 8))
        ProductE2E.send(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app), "generation did not settle")
        let image = app.buttons["chat.messageImage"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10), "the sent image is not in the transcript")
        XCTAssertEqual(image.frame.width, 240, accuracy: 0.5)
        XCTAssertEqual(image.frame.height, 180, accuracy: 0.5)
        screenshot(app, "sent-one-image")
    }
}
