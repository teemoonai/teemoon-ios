//
//  ComposerGlassCaptureUITests.swift
//  teemoonUITests
//
//  A reply scrolled under the composer panel, for tools/measure_glass_showthrough.py and the card
//  `ios-composer-glass` (the maintainer 2026-11-13: "Others use liquid style and have some text liquid through"). Each shot
//  carries the panel's frame so the script measures inside it. A capture rig: run with TEEMOON_CAPTURE=1.
//

import UIKit
import UniformTypeIdentifiers
import XCTest

final class ComposerGlassCaptureUITests: XCTestCase {

    private var server: EmbeddedFakeSSEServer!
    private let prefix = ProcessInfo.processInfo.environment["TEEMOON_CAPTURE_PREFIX"] ?? ""

    override func setUpWithError() throws {
        try CaptureRig.skipUnlessAsked()
        continueAfterFailure = true
        server = try EmbeddedFakeSSEServer(lines: 40, delay: 0.005)
        // Prose only: the default reply's tables put sparse rows behind the panel in some runs, and the show-through
        // spread then measures the content, not the glass.
        server.replies = [(1...60).map { "Paragraph \($0): the sourdough starter rises, folds and rests before the "
            + "loaf is shaped, scored and baked in a hot covered pot." }.joined(separator: "\n\n")]
    }

    override func tearDown() {
        server?.stop()
    }

    /// The screenshot, and the panel's frame in points beside it ("x y w h"), for the script.
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "glass-\(prefix)\(name)"; a.lifetime = .keepAlways; add(a)
        let f = app.descendants(matching: .any)["chat.composerCard"].firstMatch.frame
        let scale = UIScreen.main.scale
        let frame = XCTAttachment(string: "\(f.minX) \(f.minY) \(f.width) \(f.height) \(scale)")
        frame.name = "glassframe-\(prefix)\(name)"; frame.lifetime = .keepAlways; add(frame)
    }

    private func launch(large: Bool = false) -> XCUIApplication {
        var arguments = ["--uitesting"]
        if large { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        let app = ProductE2E.launch(arguments: arguments,
                                    environment: ["UITEST_SEED_LOCAL_ENDPOINT": server.baseURL,
                                                  "UITEST_SEED_LOCAL_MODEL": "fake-model",
                                                  "UITEST_SEED_LOCAL_KIND": "ollama",
                                                  "UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20))
        ProductE2E.sendAndWait(app, "Tell me about sourdough", timeout: 60)
        return app
    }

    private func dropKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Scrolls up into the middle of the reply, so its lines run on behind the panel (at the bottom they end above it,
    /// and a short pull springs back before the screenshot).
    private func scrollUnderThePanel(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 1.2)
    }

    func testAReplyUnderThePanel() {
        let app = launch()
        dropKeyboard(app)
        scrollUnderThePanel(app)
        shot(app, "1-keyboard-down")
        // Focus after the scroll: a drag in the transcript dismisses the keyboard.
        ProductE2E.composer(app).tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard is not up for the keyboard-up shot")
        shot(app, "2-keyboard-up")
        // "Ok make bigger": the where sheet's middle stop, its top as a fraction of the screen.
        app.buttons["chat.whereChip"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.8)
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "glass-\(prefix)5-where-middle"; a.lifetime = .keepAlways; add(a)
        let top = app.navigationBars["where"].firstMatch.frame.minY
        let note = XCTAttachment(string: "where sheet nav bar top \(top) of \(app.frame.height) = \(top / app.frame.height)")
        note.name = "glassframe-\(prefix)5-where-top"; note.lifetime = .keepAlways; add(note)
    }

    func testWithAPhoto() {
        let app = launch()
        let png = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).pngData { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        UIPasteboard.general.setItems([[UTType.png.identifier: png]])
        let field = ProductE2E.composer(app)
        field.tap(); field.press(forDuration: 1.2)
        let paste = app.descendants(matching: .any)["Paste"].firstMatch
        if paste.waitForExistence(timeout: 6) { paste.tap() }
        _ = app.descendants(matching: .any)["chat.pendingImage"].firstMatch.waitForExistence(timeout: 6)
        dropKeyboard(app)
        scrollUnderThePanel(app)
        shot(app, "3-photo")
    }

    func testLargestText() {
        let app = launch(large: true)
        dropKeyboard(app)
        scrollUnderThePanel(app)
        shot(app, "4-ax5")
    }
}
