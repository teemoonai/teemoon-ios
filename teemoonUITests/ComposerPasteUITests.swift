//
//  ComposerPasteUITests.swift
//  teemoonUITests
//
//  docs/IMAGES.md §4c: the edit menu's Paste of an image attaches it like a picked photo, with no
//  "Allow Paste" prompt. The paste destination is iOS 27+; below that the suite skips.
//

import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

final class ComposerPasteUITests: XCTestCase {

    private var server: EmbeddedFakeSSEServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard #available(iOS 27.0, *) else { throw XCTSkip("image paste needs iOS 27") }
        server = try EmbeddedFakeSSEServer(lines: 1, delay: 0.005)
        server.replies = ["first-reply-alpha"]
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    // MARK: pasteboard contents (encoded here, in the test runner only)

    static func encoded(_ type: UTType) -> Data {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(dest), "encode \(type.identifier)")
        return out as Data
    }

    // MARK: driver

    private func launch(seesImages: Bool = true) -> XCUIApplication {
        ProductE2E.launchLocal(server: server, extraEnv: seesImages ? ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"] : [:])
    }

    private func pasteFromEditMenu(_ app: XCUIApplication) {
        let composer = ProductE2E.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "composer missing")
        composer.tap()
        composer.press(forDuration: 1.2)
        let paste = app.descendants(matching: .any)["Paste"].firstMatch
        guard paste.waitForExistence(timeout: 6) else {
            screenshot(app, "no-paste")
            XCTFail("the edit menu offers no Paste")
            return
        }
        paste.tap()
    }

    private func assertNoAllowPastePrompt(_ app: XCUIApplication) {
        let prompt = NSPredicate(format: "label CONTAINS[c] 'paste'")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(app.alerts.containing(prompt).firstMatch.waitForExistence(timeout: 2)
                       || springboard.alerts.containing(prompt).firstMatch.exists, "an Allow Paste prompt appeared")
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: cases

    func testPastingAPNGAttachesIt() {
        UIPasteboard.general.setItems([[UTType.png.identifier: Self.encoded(.png)]])
        let app = launch()
        pasteFromEditMenu(app)
        assertNoAllowPastePrompt(app)
        XCTAssertTrue(element(app, "chat.pendingImages").waitForExistence(timeout: 8), "the pasted PNG was not attached")
        XCTAssertFalse(element(app, "chat.imageNote").exists, "a note showed for a readable PNG")
        screenshot(app, "png-attached")
    }

    /// An image neither decoder reads (ICO here) is refused unread. (SVG conforms to text: the field pastes its source.)
    func testPastingAnICOSaysItCouldNotBeRead() {
        UIPasteboard.general.setItems([[UTType.ico.identifier: Data([0, 0, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 32, 0])]])
        let app = launch()
        pasteFromEditMenu(app)
        let note = element(app, "chat.imageNote")
        XCTAssertTrue(note.waitForExistence(timeout: 8), "an ICO paste showed no note")
        XCTAssertEqual(note.label, "this image couldn't be read")
        XCTAssertFalse(element(app, "chat.pendingImages").exists, "an ICO paste attached something")
        screenshot(app, "ico-note")
    }

    func testPastingHEICWithAJPEGAttachesTheJPEG() {
        UIPasteboard.general.setItems([[UTType.heic.identifier: Self.encoded(.heic),
                                        UTType.jpeg.identifier: Self.encoded(.jpeg)]])
        let app = launch()
        pasteFromEditMenu(app)
        XCTAssertTrue(element(app, "chat.pendingImages").waitForExistence(timeout: 8), "the JPEG beside the HEIC was not attached")
        XCTAssertFalse(element(app, "chat.imageNote").exists, "a note showed though the item offered a JPEG")
    }

    /// §4d (the maintainer 2026-11-11, 21:30Z): a paste attaches on any model; the send is where one that can't see stops it.
    func testPastingIntoAModelThatCantSeeImagesAttaches() {
        UIPasteboard.general.setItems([[UTType.png.identifier: Self.encoded(.png)]])
        let app = launch(seesImages: false)
        pasteFromEditMenu(app)
        XCTAssertTrue(element(app, "chat.pendingImages").waitForExistence(timeout: 8), "the paste did not attach")
    }

    // MARK: a data: URL as text (Brave on iOS copies an image as its data: URL)

    static var jpegDataURL: String { "data:image/jpeg;base64," + encoded(.jpeg).base64EncodedString() }

    private func assertDataURLBecameAnImage(_ app: XCUIApplication, _ name: String) {
        XCTAssertTrue(element(app, "chat.pendingImages").waitForExistence(timeout: 8), "\(name): the data: URL was not attached")
        XCTAssertFalse(element(app, "chat.imageNote").exists, "\(name): a note showed for a readable data: URL")
        let text = ProductE2E.composer(app).value as? String ?? ""
        XCTAssertFalse(text.contains("data:"), "\(name): the data: URL went into the composer as text")
        screenshot(app, name)
    }

    func testPastingADataURLAsPlainTextAttachesTheImage() {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: Self.jpegDataURL]])
        let app = launch()
        pasteFromEditMenu(app)
        assertDataURLBecameAnImage(app, "dataurl-text")
    }

    func testPastingADataURLAsAURLAttachesTheImage() {
        UIPasteboard.general.setItems([[UTType.url.identifier: URL(string: Self.jpegDataURL)!]])
        let app = launch()
        pasteFromEditMenu(app)
        assertDataURLBecameAnImage(app, "dataurl-url")
    }

    func testPastingADataURLAsTextAndURLAttachesTheImage() {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: Self.jpegDataURL,
                                        UTType.url.identifier: URL(string: Self.jpegDataURL)!]])
        let app = launch()
        pasteFromEditMenu(app)
        assertDataURLBecameAnImage(app, "dataurl-text-url")
    }

    func testPastingADataURLBesideAJPEGAttachesOneImage() {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: Self.jpegDataURL,
                                        UTType.jpeg.identifier: Self.encoded(.jpeg)]])
        let app = launch()
        pasteFromEditMenu(app)
        assertDataURLBecameAnImage(app, "dataurl-text-jpeg")
    }

    /// What Safari's Copy of an image gives on the iOS 27 simulator, for an http or a data: src alike.
    func testPastingSafarisJPEGAndDataURLAttachesOneImage() {
        UIPasteboard.general.setItems([[UTType.jpeg.identifier: Self.encoded(.jpeg),
                                        UTType.url.identifier: URL(string: Self.jpegDataURL)!]])
        let app = launch()
        pasteFromEditMenu(app)
        assertDataURLBecameAnImage(app, "safari-jpeg-url")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'remove image'")).count, 1,
                       "one copy gave other than one attachment")
    }

    // MARK: an item that offers an image is an image, whatever text it also offers (Messages-like)

    static let pageURL = URL(string: "https://example.com/photos/cat.jpg")!

    private func composerText(_ app: XCUIApplication) -> String {
        let value = ProductE2E.composer(app).value as? String ?? ""
        return value == "message" ? "" : value
    }

    private func assertOneImageAndNoText(_ app: XCUIApplication, _ name: String) {
        XCTAssertTrue(element(app, "chat.pendingImages").waitForExistence(timeout: 8),
                      "\(name): the image was not attached; composer: \(composerText(app))")
        assertNoAllowPastePrompt(app)
        XCTAssertFalse(element(app, "chat.imageNote").exists, "\(name): a note showed for a readable image")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'remove image'")).count, 1,
                       "\(name): one copy gave other than one attachment")
        XCTAssertEqual(composerText(app), "", "\(name): the item's text went into the composer")
        screenshot(app, name)
    }

    private func waitForComposerText(_ app: XCUIApplication, _ text: String) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if composerText(app) == text { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// A browser's Copy of an image on an http page: one item, a JPEG and its URL.
    func testPastingAJPEGWithAnHTTPURLAttachesTheImageAndNoText() {
        UIPasteboard.general.setItems([[UTType.jpeg.identifier: Self.encoded(.jpeg), UTType.url.identifier: Self.pageURL]])
        let app = launch()
        pasteFromEditMenu(app)
        assertOneImageAndNoText(app, "jpeg-http-url")
    }

    func testPastingAJPEGWithADataURLAttachesTheImageAndNoText() {
        UIPasteboard.general.setItems([[UTType.jpeg.identifier: Self.encoded(.jpeg),
                                        UTType.url.identifier: URL(string: Self.jpegDataURL)!]])
        let app = launch()
        pasteFromEditMenu(app)
        assertOneImageAndNoText(app, "jpeg-data-url")
    }

    /// Only a URL is taken back out: an image item whose text is words pastes the words (autocorrect inserts words too).
    func testPastingAPNGWithPlainWordsPastesTheWords() {
        UIPasteboard.general.setItems([[UTType.png.identifier: Self.encoded(.png),
                                        UTType.utf8PlainText.identifier: "a caption the copy carried"]])
        let app = launch()
        pasteFromEditMenu(app)
        assertNoAllowPastePrompt(app)
        XCTAssertTrue(waitForComposerText(app, "a caption the copy carried"), "composer: \(composerText(app))")
        XCTAssertFalse(element(app, "chat.pendingImages").exists, "words beside an image attached it")
    }

    func testPastingTextOnlyStaysText() {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: "just some words"]])
        let app = launch()
        pasteFromEditMenu(app)
        XCTAssertTrue(waitForComposerText(app, "just some words"), "text-only paste lost its text")
        XCTAssertFalse(element(app, "chat.pendingImages").exists, "a text-only paste attached something")
    }

    func testPastingAURLOnlyStaysText() {
        UIPasteboard.general.setItems([[UTType.url.identifier: Self.pageURL]])
        let app = launch()
        pasteFromEditMenu(app)
        XCTAssertTrue(waitForComposerText(app, Self.pageURL.absoluteString), "a URL-only paste lost its text")
        XCTAssertFalse(element(app, "chat.pendingImages").exists, "a URL-only paste attached something")
    }

    func testPastingAnImageWithAURLIntoAModelThatCantSeeImagesAttachesItAndNoText() {
        UIPasteboard.general.setItems([[UTType.jpeg.identifier: Self.encoded(.jpeg), UTType.url.identifier: Self.pageURL]])
        let app = launch(seesImages: false)
        pasteFromEditMenu(app)
        XCTAssertTrue(element(app, "chat.pendingImages").waitForExistence(timeout: 8), "the paste did not attach")
        assertNoAllowPastePrompt(app)
        XCTAssertEqual(composerText(app), "", "the image item's URL went into the composer")
    }

    /// Typing never reads the pasteboard: one character at a time is not a paste, so no prompt and nothing attached.
    func testTypingWithABrowserImageCopiedReadsNothing() {
        UIPasteboard.general.setItems([[UTType.jpeg.identifier: Self.encoded(.jpeg), UTType.url.identifier: Self.pageURL]])
        let app = launch()
        let composer = ProductE2E.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "composer missing")
        composer.tap()
        composer.typeText("hello")
        assertNoAllowPastePrompt(app)
        XCTAssertTrue(waitForComposerText(app, "hello"), "typed text changed: \(composerText(app))")
        XCTAssertFalse(element(app, "chat.pendingImages").exists, "typing attached the copied image")
    }

    /// Case 6b (the maintainer 2026-11-09, like Messages and Android 15ede5d1): a URL in its own item beside an image goes in neither.
    func testPastingAnImageItemBesideAURLItemAttachesOnlyTheImage() {
        UIPasteboard.general.setItems([[UTType.jpeg.identifier: Self.encoded(.jpeg)], [UTType.url.identifier: Self.pageURL]])
        let app = launch()
        pasteFromEditMenu(app)
        assertOneImageAndNoText(app, "jpeg-then-url-item")
    }

    /// Wuffs decodes GIF, so a copied GIF attaches as Messages would (its first frame).
    func testPastingAGIFAttachesIt() {
        UIPasteboard.general.setItems([[UTType.gif.identifier: Self.encoded(.gif)]])
        let app = launch()
        pasteFromEditMenu(app)
        assertOneImageAndNoText(app, "gif-alone")
    }

    /// Two image items, one carrying a URL: both attach in order, no text.
    func testPastingTwoImageItemsAttachesBothAndNoText() {
        UIPasteboard.general.setItems([[UTType.jpeg.identifier: Self.encoded(.jpeg), UTType.url.identifier: Self.pageURL],
                                       [UTType.png.identifier: Self.encoded(.png)]])
        let app = launch()
        pasteFromEditMenu(app)
        XCTAssertTrue(element(app, "chat.pendingImages").waitForExistence(timeout: 8),
                      "the image items were not attached; composer: \(composerText(app))")
        assertNoAllowPastePrompt(app)
        screenshot(app, "two-image-items")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'remove image'")).count, 2)
        XCTAssertEqual(composerText(app), "", "an image item's URL went into the composer")
    }

    /// S41 (the maintainer 2026-11-09, Android a9adbcd4): an image-only item beside a data: URL text item attaches both, in order.
    func testAnImageOnlyItemBesideADataURLTextAttachesBoth() {
        UIPasteboard.general.setItems([[UTType.png.identifier: Self.encoded(.png)],
                                       [UTType.utf8PlainText.identifier: Self.jpegDataURL]])
        let app = launch()
        pasteFromEditMenu(app)
        XCTAssertTrue(element(app, "chat.pendingImages").waitForExistence(timeout: 8),
                      "nothing attached; composer: \(composerText(app))")
        let removes = app.buttons.matching(NSPredicate(format: "label == 'remove image'"))
        let deadline = Date().addingTimeInterval(5)
        while removes.count < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        screenshot(app, "image-beside-dataurl")
        XCTAssertEqual(removes.count, 2, "both items did not attach")
        XCTAssertEqual(composerText(app), "", "the data: URL went into the composer")
        assertNoAllowPastePrompt(app)
    }

    /// trip.com (the maintainer's device check 2026-11-09): an app's UIImage set beside its page URL pasted as the URL.
    func testPastingAnAppsUIImageWithItsURLAttachesTheImageAndNoText() {
        let image = UIImage(data: Self.encoded(.png))!
        UIPasteboard.general.setItems([["com.apple.uikit.image": image, UTType.url.identifier: Self.pageURL]])
        let app = launch()
        pasteFromEditMenu(app)
        assertOneImageAndNoText(app, "uiimage-url")
    }

    func testPastingAnAppsUIImageBesideAURLItemAttachesTheImageAndNoText() {
        let image = UIImage(data: Self.encoded(.png))!
        UIPasteboard.general.setItems([["com.apple.uikit.image": image], [UTType.url.identifier: Self.pageURL]])
        let app = launch()
        pasteFromEditMenu(app)
        assertOneImageAndNoText(app, "uiimage-then-url-item")
    }

    /// Known gap: with no text in the item, SwiftUI's paste destination never hands this type over. The 1.1.1
    /// UITextView composer reads item providers (PastedImage.load already sniffs it); this then starts passing.
    func testPastingAnAppsUIImageAloneAttachesIt() {
        UIPasteboard.general.setItems([["com.apple.uikit.image": UIImage(data: Self.encoded(.png))!]])
        let app = launch()
        pasteFromEditMenu(app)
        XCTAssertTrue(element(app, "chat.pendingImages").waitForExistence(timeout: 8), "uiimage-alone: not attached")
    }

    /// A HEIC copy (no JPEG or PNG beside it) attaches through the system decode, like Messages (the maintainer 2026-11-11).
    func testPastingAHEICAloneAttachesIt() {
        UIPasteboard.general.setItems([[UTType.heic.identifier: Self.encoded(.heic)]])
        let app = launch()
        pasteFromEditMenu(app)
        assertOneImageAndNoText(app, "heic-alone")
    }

    /// trip.com-like: a HEIC with its page URL in one item attaches the image, no text.
    func testPastingAHEICWithAURLAttachesTheImageAndNoText() {
        UIPasteboard.general.setItems([[UTType.heic.identifier: Self.encoded(.heic), UTType.url.identifier: Self.pageURL]])
        let app = launch()
        pasteFromEditMenu(app)
        assertOneImageAndNoText(app, "heic-url")
    }

    func testPastingAMalformedDataURLSaysItCouldNotBeRead() {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: "data:image/jpeg;base64,!!!!"]])
        let app = launch()
        pasteFromEditMenu(app)
        let note = element(app, "chat.imageNote")
        XCTAssertTrue(note.waitForExistence(timeout: 8), "a malformed data: URL showed no note")
        XCTAssertEqual(note.label, "this image couldn't be read")
        XCTAssertFalse(element(app, "chat.pendingImages").exists, "a malformed data: URL attached something")
        XCTAssertFalse((ProductE2E.composer(app).value as? String ?? "").contains("data:"), "the malformed URL went in as text")
    }
}

/// Its own class, sorted after ComposerPasteUITests: after a typeKey ⌘V the simulator's edit menu stops offering
/// Paste for the rest of the run. Do not fold it back into that class.
final class ComposerPasteViaKeyUITests: XCTestCase {

    /// ⌘V reaches the same destination as the edit menu's Paste.
    func testCommandVPastesAnImage() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("image paste needs iOS 27") }
        let server = try EmbeddedFakeSSEServer(lines: 1, delay: 0.005)
        defer { server.stop() }
        UIPasteboard.general.setItems([[UTType.png.identifier: ComposerPasteUITests.encoded(.png)]])
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        let composer = ProductE2E.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "composer missing")
        composer.tap()
        // The simulator drops the first hardware key after launch into a UIKit text view (repro 2026-11-11: plain
        // UITextView, the composer, first after launch → nothing; after one key → pasted). One key first, as a person
        // at a keyboard has always typed something.
        composer.typeKey("a", modifierFlags: [])
        composer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["chat.pendingImages"].firstMatch.waitForExistence(timeout: 8),
                      "⌘V attached nothing")
    }
}
