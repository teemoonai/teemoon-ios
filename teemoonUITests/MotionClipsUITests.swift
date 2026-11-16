//
//  MotionClipsUITests.swift
//  teemoonUITests
//
//  The motion pass's moments as short real-time clips for the cards (the maintainer 2026-11-14: he judges motion moving, not
//  from strips). Each test prints "CLIP <name> begin|end <epoch>" around its motion; the host records the simulator
//  and cuts each clip at those marks. A capture rig: run with TEEMOON_CAPTURE=1 while recording.
//

import UIKit
import UniformTypeIdentifiers
import XCTest

final class MotionClipsUITests: XCTestCase {

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

    private func launch(developerMode: Bool = false, extra: [String: String] = [:]) -> XCUIApplication {
        var env = ["UITEST_SEED_LOCAL_ENDPOINT": server.baseURL, "UITEST_SEED_LOCAL_MODEL": "fake-model",
                   "UITEST_SEED_LOCAL_KIND": "ollama", "UITEST_SEED_LOCAL_SEES_IMAGES": "1"]
        extra.forEach { env[$0] = $1 }
        let app = ProductE2E.launch(arguments: ["--uitesting", "-developerModeEnabled", developerMode ? "YES" : "NO"],
                                    environment: env)
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20))
        return app
    }

    private func mark(_ clip: String, _ phase: String) {
        print("CLIP \(clip) \(phase) \(Date().timeIntervalSince1970)")
    }

    private func still(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func paste(_ app: XCUIApplication, _ color: UIColor) {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).pngData { ctx in
            color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        UIPasteboard.general.setItems([[UTType.png.identifier: png]])
        let field = ProductE2E.composer(app)
        field.tap(); field.press(forDuration: 1.2)
        let item = app.descendants(matching: .any)["Paste"].firstMatch
        if item.waitForExistence(timeout: 6) { item.tap() }
        still(1)
    }

    /// A sent photo's tile, scrolled on screen (a long message pushes it above).
    private func onScreen(_ app: XCUIApplication, _ tile: XCUIElement) {
        let window = app.windows.firstMatch.frame
        for _ in 0..<6 where tile.frame.minY < 110 || tile.frame.maxY > window.maxY - 160 {
            if tile.frame.minY < 110 { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
        still(1)
    }

    private func tapCentre(_ e: XCUIElement) { e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }

    private static let prose = (0..<24).map { n in
        "Paragraph \(n + 1). The attestation report binds the enclave's measurement to the key the app encrypts to, "
            + "so a reply can only come from the code that was measured. When the host changes its image, the "
            + "measurement changes with it, and the app checks the new one against the published build before it "
            + "sends anything. A mismatch stops the send and says which part failed, rather than falling back quietly."
    }.joined(separator: "\n\n")

    /// A slow drag down the transcript (about 100 pt/s), so the text passes under the panel for ~4 s.
    private func slowDrag(_ app: XCUIApplication, from: CGFloat, to: CGFloat) {
        let w = app.windows.firstMatch
        let start = w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: from))
        let end = w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: to))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 100, thenHoldForDuration: 0.3)
    }

    private func glassTake(_ app: XCUIApplication, _ clip: String) {
        ProductE2E.sendAndWait(app, "tell me how the check works")
        still(1)
        mark(clip, "begin")
        // Keyboard down: the text runs down through the panel.
        slowDrag(app, from: 200, to: 600)
        still(1)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "\(clip)-still"; a.lifetime = .keepAlways; add(a)
        // Keyboard up, and the same the other way (a drag down would take the keyboard with it).
        ProductE2E.composer(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "no keyboard: a hardware keyboard is attached")
        still(1.2)
        slowDrag(app, from: 420, to: 120)
        still(1)
        mark(clip, "end")
    }

    /// (0a) Liquid Glass: dense paragraphs scrolled slowly under the composer, keyboard down, then up.
    func test00GlassScroll() {
        server.replies = [Self.prose]
        glassTake(launch(), "0a-glass")
    }

    /// (0b) the same with a photo in the panel.
    func test00GlassScrollWithAPhoto() {
        server.replies = [Self.prose]
        let app = launch()
        ProductE2E.sendAndWait(app, "first")
        server.replies = [Self.prose]
        paste(app, .systemOrange)
        // The photo stays in the panel, unsent, with the keyboard up from the paste: up first, then a drag into the
        // keyboard takes it down (XCUI's swipe doesn't), then down.
        let clip = "0b-glass-photo"
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "no keyboard: a hardware keyboard is attached")
        still(1)
        mark(clip, "begin")
        slowDrag(app, from: 420, to: 120)
        still(1)
        slowDrag(app, from: 250, to: 820)
        still(1)
        XCTAssertEqual(app.keyboards.count, 0, "the keyboard is still up")
        mark(clip, "keyboard-down")
        slowDrag(app, from: 200, to: 600)
        still(1)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "\(clip)-still"; a.lifetime = .keepAlways; add(a)
        mark(clip, "end")
    }

    /// The title bar on a new chat's first send (the maintainer 2026-11-14: the title "slides in" after the first message).
    func test00TitleOnFirstSend() {
        server.replies = ["A short answer."]
        let app = launch()
        ProductE2E.typeIntoComposer(app, "what makes liquid glass look right")
        still(1)
        mark("title-first-send", "begin")
        ProductE2E.send(app)
        _ = ProductE2E.waitUntilSettled(app, timeout: 30)
        still(2)
        mark("title-first-send", "end")
    }

    /// A slow photo: its tile shows a spinner at once and send dims; the photo fades in over the tile and send comes
    /// back (the maintainer 2026-11-14). A very large image, so the decode really takes a moment.
    func test11SlowPick() {
        let app = launch()
        ProductE2E.typeIntoComposer(app, "look")
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000),
                                          format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .pngData { ctx in
                let colors = [UIColor.systemOrange.cgColor, UIColor.systemPurple.cgColor] as CFArray
                let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: nil)!
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 4000, y: 3000), options: [])
            }
        UIPasteboard.general.setItems([[UTType.png.identifier: png]])
        let field = ProductE2E.composer(app)
        field.press(forDuration: 1.2)
        let item = app.descendants(matching: .any)["Paste"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 6))
        mark("10-slow-pick", "begin")
        item.tap()
        let loading = app.descendants(matching: .any)["chat.loadingImage"].firstMatch
        if loading.waitForExistence(timeout: 2) {
            let a = XCTAttachment(screenshot: app.screenshot()); a.name = "slow-pick-loading"; a.lifetime = .keepAlways; add(a)
            XCTAssertFalse(app.buttons["chat.send"].isEnabled, "send is not dimmed while the photo loads")
        }
        XCTAssertTrue(app.descendants(matching: .any)["chat.pendingImage"].firstMatch.waitForExistence(timeout: 20))
        still(1.5)
        XCTAssertTrue(app.buttons["chat.send"].isEnabled, "send did not come back")
        mark("10-slow-pick", "end")
    }

    /// (1a) a photo zooms open from its thumbnail and closes back into it.
    func test01ZoomOne() {
        let app = launch()
        paste(app, .systemOrange)
        ProductE2E.typeIntoComposer(app, "look")
        ProductE2E.send(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 30))
        let tile = app.descendants(matching: .any)["chat.messageImage"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        onScreen(app, tile)
        mark("1a-zoom", "begin")
        tapCentre(tile)
        still(1.5)
        XCTAssertTrue(app.descendants(matching: .any)["chat.viewerImage"].firstMatch.exists, "the viewer did not open")
        app.swipeDown(velocity: .fast)
        still(1.2)
        mark("1a-zoom", "end")
    }

    /// (1b) eight photos: open the "+N" tile, page past the fourth, close back into the "+N" tile.
    func test02ZoomPlusN() {
        let app = launch()
        let colors: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue,
                                 .systemIndigo, .systemPink]
        colors.forEach { paste(app, $0) }
        ProductE2E.typeIntoComposer(app, "eight")
        ProductE2E.send(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 30))
        let tiles = app.descendants(matching: .any).matching(identifier: "chat.messageImage")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 5))
        let plus = tiles.element(boundBy: tiles.count - 1)
        onScreen(app, plus)
        mark("1b-zoom-plus-n", "begin")
        tapCentre(plus)
        still(1.2)
        app.swipeLeft()
        still(1.2)
        app.swipeDown(velocity: .fast)
        still(1.2)
        mark("1b-zoom-plus-n", "end")
    }

    /// The sent grid at 1, 2, 3, 4, 5 and 10 photos, one still each (MessageImageGrid, the maintainer 2026-11-14).
    func test12GridStills() {
        let app = launch()
        let colors: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue,
                                 .systemIndigo, .systemPink, .systemPurple, .systemBrown]
        for count in [1, 2, 3, 4, 5, 10] {
            server.replies = ["ok"]
            colors.prefix(count).forEach { paste(app, $0) }
            ProductE2E.typeIntoComposer(app, "\(count)")
            ProductE2E.send(app)
            XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 30))
            if app.keyboards.firstMatch.exists { app.swipeDown(velocity: .slow) }
            still(1.5)
            let a = XCTAttachment(screenshot: app.screenshot()); a.name = "grid-\(count)"; a.lifetime = .keepAlways; add(a)
        }
    }

    /// The top bar at rest over a long reply, then while a second long reply streams up under it (top-bar probe).
    func test13TopEdge() {
        server.replies = [Self.prose]
        let app = launch()
        ProductE2E.sendAndWait(app, "first")
        if app.keyboards.firstMatch.exists { app.swipeDown(velocity: .slow) }
        slowDrag(app, from: 300, to: 500)
        still(1.5)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "top-rest"; a.lifetime = .keepAlways; add(a)
        server.replies = [Self.prose]
        server.stallEvery = 8
        server.stallDuration = 0.15
        ProductE2E.typeIntoComposer(app, "again")
        mark("13-top-streaming", "begin")
        ProductE2E.send(app)
        still(6)
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "top-streaming"; b.lifetime = .keepAlways; add(b)
        _ = ProductE2E.waitUntilSettled(app, timeout: 90)
        mark("13-top-streaming", "end")
    }

    /// The top bar over a long reply at rest, nudged a few points between stills so one lands on a line boundary and one
    /// with a line straddling the bar's edge (the maintainer 2026-11-14: "the space just needs to be a little smaller").
    func test14TopStills() {
        server.replies = [Self.prose]
        let app = launch()
        ProductE2E.sendAndWait(app, "first")
        if app.keyboards.firstMatch.exists { app.swipeDown(velocity: .slow) }
        slowDrag(app, from: 300, to: 500)
        still(1.5)
        for n in 0..<5 {
            let a = XCTAttachment(screenshot: app.screenshot()); a.name = "top-step\(n)"; a.lifetime = .keepAlways; add(a)
            // Past the touch slop and back: a net 7 pt per step.
            slowDrag(app, from: 400, to: 430)
            slowDrag(app, from: 430, to: 407)
            still(1.2)
        }
    }

    /// (2) a model switch: the where chip's name changes.
    func test03ModelSwitch() {
        let app = launch()
        still(1)
        app.buttons["chat.whereChip"].firstMatch.tap()
        let other = app.staticTexts["other-model"].firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        still(1)
        mark("2-model-switch", "begin")
        other.tap()
        still(2)
        mark("2-model-switch", "end")
        // Back to the default for the next test.
        app.buttons["chat.whereChip"].firstMatch.tap()
        let first = app.staticTexts["fake-model"].firstMatch
        if first.waitForExistence(timeout: 5) { first.tap() }
        still(1)
    }

    /// (3) checking → verified on near.ai (live attestation; reads the host's key, sends nothing).
    func test04Verify() {
        let app = ProductE2E.launchNearAI()
        _ = ProductE2E.composer(app).waitForExistence(timeout: 20)
        let title = app.descendants(matching: .any)["chat.titleBlock"].firstMatch
        let done = NSPredicate(format: "NOT (label CONTAINS[c] %@)", "verifying")
        let verified = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: done, object: title)], timeout: 120)
        XCTAssertEqual(verified, .completed, "still verifying after 120 s: \(title.label)")
        mark("3-verify", "event")
        still(2)
    }

    /// (4) a searched reply: its sources chip grows in on its own.
    func test05Sources() {
        server.emitToolRound = true
        // As UseCaseJourneysTests' web chip journey: a plain local server, a placeholder key, the fake Brave.
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_GROUNDING": "placeholder",
                                                                    "UITEST_BRAVE_ENDPOINT": server.braveEndpoint])
        ProductE2E.typeIntoComposer(app, "what is the weather in paris")
        ProductE2E.send(app)
        let chip = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "source")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 40), "no sources chip")
        mark("4-sources", "event")
        still(2)
    }

    /// (5) a failed turn: the retry button fades in.
    func test06Retry() {
        server.statusCode = 500
        let app = launch()
        ProductE2E.typeIntoComposer(app, "retry-me")
        ProductE2E.send(app)
        let retry = app.buttons["chat.retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 20), "no retry button")
        mark("5-retry", "event")
        still(2)
    }

    /// (6) the keyboard up and down under the glass composer, over a long reply.
    func test07Keyboard() {
        server.replies = [(0..<40).map { "Paragraph \($0): the reply keeps going down the screen so it runs on behind the glass panel." }
            .joined(separator: "\n\n")]
        let app = launch()
        ProductE2E.sendAndWait(app, "long")
        app.swipeDown(velocity: .slow)
        still(1.5)
        mark("6-keyboard", "begin")
        ProductE2E.composer(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "no keyboard: a hardware keyboard is attached")
        still(1.5)
        // A drag into the keyboard takes it down (XCUI's swipe doesn't).
        slowDrag(app, from: 250, to: 820)
        XCTAssertEqual(app.keyboards.count, 0, "the keyboard is still up")
        still(1.5)
        mark("6-keyboard", "end")
    }

    /// (7) the where sheet opens; the reasoning bar pushes to the levels and back.
    func test08WhereAndLevels() {
        let app = launch(developerMode: true)
        still(1)
        mark("7-where-levels", "begin")
        app.buttons["chat.whereChip"].firstMatch.tap()
        let bar = app.descendants(matching: .any)["where.reasoningBar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no reasoning bar")
        still(1.2)
        bar.tap()
        let low = app.buttons["reasoning.level.low"].firstMatch
        XCTAssertTrue(low.waitForExistence(timeout: 5), "the bar did not push to the levels")
        still(1.2)
        // Back, not the sheet's close.
        let back = app.navigationBars["reasoning"].buttons.firstMatch
        XCTAssertTrue(back.exists, "no back button on the levels page")
        back.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 3), "back did not return to the where sheet")
        still(1.5)
        mark("7-where-levels", "end")
    }

    /// (8) a send in a long chat.
    func test09SendInALongChat() {
        server.replies = [(0..<30).map { "Line \($0) of an earlier reply." }.joined(separator: "\n\n")]
        let app = launch()
        ProductE2E.sendAndWait(app, "first")
        server.replies = ["A short answer to the second question."]
        ProductE2E.typeIntoComposer(app, "and the second question")
        still(1)
        mark("8-send-long-chat", "begin")
        ProductE2E.send(app)
        _ = ProductE2E.waitUntilSettled(app, timeout: 30)
        still(1.5)
        mark("8-send-long-chat", "end")
    }

    /// (9) think harder: the chip reads the level it sends, then the pick again.
    func test10ThinkHarder() {
        let app = launch(developerMode: true)
        ProductE2E.sendAndWait(app, "hello")
        server.startDelay = 3
        let lines = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Paragraph"))
        _ = lines.firstMatch.waitForExistence(timeout: 10)
        let screen = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 120)
        let reply = lines.allElementsBoundByIndex.first { screen.contains($0.frame) } ?? lines.firstMatch
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        let item = app.menuItems["think harder"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no think harder in the reply's menu")
        mark("9-think-harder", "begin")
        item.tap()
        _ = ProductE2E.waitUntilSettled(app, timeout: 30)
        still(1.5)
        mark("9-think-harder", "end")
    }
}
