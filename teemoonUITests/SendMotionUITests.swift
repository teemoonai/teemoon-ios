//
//  SendMotionUITests.swift
//  teemoonUITests
//
//  Drives a photo send for tools/measure_send_motion.py, which reads the frames of a simulator recording
//  (docs/COMPOSER_PANEL.md §Motion). XCUI waits for the app to idle after a tap, so it cannot see a 0.25 s motion
//  itself: the maintainer found the bad one by stepping through frames (2026-11-13, pm/evidence/1.1-ui/ios/send-motion-2026-11-13).
//  A capture rig: run with TEEMOON_CAPTURE=1 while recording.
//

import UIKit
import UniformTypeIdentifiers
import XCTest

final class SendMotionUITests: XCTestCase {

    private var server: EmbeddedFakeSSEServer!

    override func setUpWithError() throws {
        try CaptureRig.skipUnlessAsked()
        server = try EmbeddedFakeSSEServer(lines: 3, delay: 0.05)
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    /// Pure magenta, so the script can tell the composer's thumbnail from everything else on screen.
    private func pasteMagenta(_ app: XCUIApplication) {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).pngData { ctx in
            UIColor(red: 1, green: 0, blue: 1, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        UIPasteboard.general.setItems([[UTType.png.identifier: png]])
        let field = ProductE2E.composer(app)
        field.tap(); field.press(forDuration: 1.2)
        let item = app.descendants(matching: .any)["Paste"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 6), "no Paste")
        item.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.pendingImage"].firstMatch.waitForExistence(timeout: 6))
    }

    /// Photo + "Explain", a still second, the send, then the reply. The still second marks the send in the recording.
    private func sendPhoto(_ app: XCUIApplication) {
        pasteMagenta(app)
        // The paste's edit menu closes first, or the helper's tap reopens it and the text goes nowhere.
        Thread.sleep(forTimeInterval: 1.0)
        ProductE2E.typeIntoComposer(app, "Explain")
        XCTAssertEqual(ProductE2E.composer(app).value as? String, "Explain", "the text never reached the composer; no send to measure")
        Thread.sleep(forTimeInterval: 2.0)
        app.buttons["chat.send"].firstMatch.tap()
        XCTAssertFalse(app.descendants(matching: .any)["chat.pendingImage"].firstMatch.exists, "the photo was not sent")
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 30))
        Thread.sleep(forTimeInterval: 2.0)
    }

    /// The first send of a new chat: the screen goes from the empty state to the transcript.
    func testTheFirstSendOfANewChat() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20))
        sendPhoto(app)
    }

    /// A chat that already has messages: no change of screen (pm, 2026-11-13: is there a second cause?).
    func testASendInAChatWithMessages() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20))
        ProductE2E.typeIntoComposer(app, "hello")
        ProductE2E.send(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 30))
        sendPhoto(app)
    }

    /// The first photo arriving (the strip fades in with it) and the last one leaving by its x (at once; only the
    /// panel's height moves). For the card's frames, not the send script (design review, 2026-11-13).
    func testAPhotoArrivesThenItsXRemovesIt() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20))
        pasteMagenta(app)
        Thread.sleep(forTimeInterval: 2.0)
        let x = app.buttons["remove image"].firstMatch
        XCTAssertTrue(x.waitForExistence(timeout: 5))
        x.tap()
        XCTAssertFalse(app.descendants(matching: .any)["chat.pendingImage"].firstMatch.waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 2.0)
    }
}
