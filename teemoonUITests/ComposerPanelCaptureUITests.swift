//
//  ComposerPanelCaptureUITests.swift
//  teemoonUITests
//
//  Every state of the one-panel composer for the review card `composer-one-panel` (docs/COMPOSER_PANEL.md). A capture
//  rig: screenshots only, run with TEEMOON_CAPTURE=1.
//

import UIKit
import UniformTypeIdentifiers
import XCTest

final class ComposerPanelCaptureUITests: XCTestCase {

    private var server: EmbeddedFakeSSEServer!

    override func setUpWithError() throws {
        try CaptureRig.skipUnlessAsked()
        continueAfterFailure = true
        server = try EmbeddedFakeSSEServer(lines: 60, delay: 0.08)
    }

    override func tearDown() {
        server?.stop()
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "panel-\(name)"; a.lifetime = .keepAlways; add(a)
    }

    private func paste(_ app: XCUIApplication, _ color: UIColor) {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).pngData { ctx in
            color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        UIPasteboard.general.setItems([[UTType.png.identifier: png]])
        let field = ProductE2E.composer(app)
        field.tap(); field.press(forDuration: 1.2)
        let item = app.descendants(matching: .any)["Paste"].firstMatch
        if item.waitForExistence(timeout: 6) { item.tap() }
        _ = app.descendants(matching: .any)["chat.pendingImage"].firstMatch.waitForExistence(timeout: 6)
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        // An empty chat has no transcript to tap: the empty space under the title takes the tap instead.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        if app.keyboards.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        }
        Thread.sleep(forTimeInterval: 0.8)
    }

    func testEveryState() {
        let prefix = ProcessInfo.processInfo.environment["TEEMOON_CAPTURE_PREFIX"] ?? ""
        let app = ProductE2E.launchLocal(server: server)
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20))
        shot(app, "\(prefix)empty")
        ProductE2E.typeIntoComposer(app, "one line")
        shot(app, "\(prefix)one-line-keyboard")
        ProductE2E.typeIntoComposer(app, "\ntwo\nthree")
        shot(app, "\(prefix)three-lines")
        ProductE2E.typeIntoComposer(app, "\nfour\nfive\nsix\nseven\neight\nnine")
        shot(app, "\(prefix)max-lines")
        dismissKeyboard(app)
        shot(app, "\(prefix)keyboard-down")
        // A text-only send, so the reply runs and stop shows.
        app.buttons["chat.send"].firstMatch.tap()
        _ = app.buttons["chat.stop"].firstMatch.waitForExistence(timeout: 5)
        shot(app, "\(prefix)sending-stop")
        _ = ProductE2E.waitUntilSettled(app, timeout: 30)
        paste(app, .systemRed); paste(app, .systemBlue); paste(app, .systemGreen)
        ProductE2E.typeIntoComposer(app, "what are these?\nsecond line\nthird line")
        shot(app, "\(prefix)photos-three-lines-keyboard")
        dismissKeyboard(app)
        shot(app, "\(prefix)with-photos")
    }

    func testALongModelName() {
        let prefix = ProcessInfo.processInfo.environment["TEEMOON_CAPTURE_PREFIX"] ?? ""
        let app = ProductE2E.launchLocal(server: server,
                                         model: "meta-llama/llama-3.3-70b-instruct-turbo-with-a-really-long-name")
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20))
        shot(app, "\(prefix)long-name")
    }
}
