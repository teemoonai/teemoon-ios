//
//  MotionCaptureUITests.swift
//  teemoonUITests
//
//  Drives the motion pass's moments for a screen recording (card `motion-pass`, docs/MOTION.md): a photo opening and
//  closing, a model switch, a near.ai verification, and the chip during a Think Harder (card
//  `chip-level-during-think-harder`). Each step leaves a still second so the recording can be cut into strips. A capture
//  rig: run with TEEMOON_CAPTURE=1 while recording.
//

import UIKit
import UniformTypeIdentifiers
import XCTest

final class MotionCaptureUITests: XCTestCase {

    private var server: EmbeddedFakeSSEServer!

    override func setUpWithError() throws {
        try CaptureRig.skipUnlessAsked()
        continueAfterFailure = true
        server = try EmbeddedFakeSSEServer(lines: 2, delay: 0.01)
        server.modelIDs = ["fake-model", "other-model"]
    }

    override func tearDown() {
        server?.stop()
    }

    private func launch(developerMode: Bool = false) -> XCUIApplication {
        let app = ProductE2E.launch(
            arguments: ["--uitesting", "-developerModeEnabled", developerMode ? "YES" : "NO"],
            environment: ["UITEST_SEED_LOCAL_ENDPOINT": server.baseURL, "UITEST_SEED_LOCAL_MODEL": "fake-model",
                          "UITEST_SEED_LOCAL_KIND": "ollama", "UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20))
        return app
    }

    private func still(_ seconds: TimeInterval = 1.5) { Thread.sleep(forTimeInterval: seconds) }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "motion-\(name)"; a.lifetime = .keepAlways; add(a)
    }

    /// #7: the photo zooms from its thumbnail and back.
    func test1PhotoZoom() {
        let app = launch()
        let png = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).pngData { ctx in
            UIColor.systemOrange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        UIPasteboard.general.setItems([[UTType.png.identifier: png]])
        let field = ProductE2E.composer(app)
        field.tap(); field.press(forDuration: 1.2)
        let paste = app.descendants(matching: .any)["Paste"].firstMatch
        if paste.waitForExistence(timeout: 6) { paste.tap() }
        _ = app.descendants(matching: .any)["chat.pendingImage"].firstMatch.waitForExistence(timeout: 6)
        ProductE2E.typeIntoComposer(app, "look")
        ProductE2E.send(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 30))
        still(2)
        let tile = app.descendants(matching: .any)["chat.messageImage"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        // On an SE the reply pushes the photo above the screen: bring it back before tapping its centre.
        for _ in 0..<4 where tile.frame.minY < 100 { app.swipeDown(velocity: .slow) }
        still(1)
        // By its centre: XCUI calls the tile not hittable even on screen (iPhone 17 Pro probe, 2026-11-14).
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        still(2)
        XCTAssertTrue(app.descendants(matching: .any)["chat.viewerImage"].firstMatch.exists, "the viewer did not open")
        app.swipeDown(velocity: .fast)
        still(2)
    }

    /// #8: a model switch crossfades the where chip's name.
    func test2ModelSwitch() {
        let app = launch()
        still(1)
        app.buttons["chat.whereChip"].firstMatch.tap()
        still(1.5)
        let other = app.staticTexts["other-model"].firstMatch
        if other.waitForExistence(timeout: 5) { other.tap() }
        still(1.5)
        // Back: the chip's name crossfades.
        app.buttons["chat.whereChip"].firstMatch.tap()
        still(1.5)
        let first = app.staticTexts["fake-model"].firstMatch
        if first.waitForExistence(timeout: 5) { first.tap() }
        still(2.5)
    }

    /// #4: checking → verified on near.ai (live attestation; reads the host's key, sends nothing).
    func test3Verify() {
        let app = ProductE2E.launchNearAI()
        _ = ProductE2E.composer(app).waitForExistence(timeout: 20)
        let title = app.descendants(matching: .any)["chat.titleBlock"].firstMatch
        let done = NSPredicate(format: "NOT (label CONTAINS[c] %@)", "verifying")
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: done, object: title)], timeout: 60)
        still(3)
    }

    /// The chip during a Think Harder reads the level it sends, then the pick again.
    func test4ChipDuringThinkHarder() {
        let app = launch(developerMode: true)
        ProductE2E.sendAndWait(app, "hello")
        server.startDelay = 4
        let lines = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Paragraph"))
        _ = lines.firstMatch.waitForExistence(timeout: 10)
        // A line on screen: on an SE the first one has scrolled above it.
        let screen = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 120)
        let reply = lines.allElementsBoundByIndex.first { screen.contains($0.frame) } ?? lines.firstMatch
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        let item = app.menuItems["think harder"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no think harder in the reply's menu")
        item.tap()
        still(1.5)
        shot(app, "chip-during-think-harder")
        _ = ProductE2E.waitUntilSettled(app, timeout: 30)
        still(1)
        shot(app, "chip-after-think-harder")
    }
}
