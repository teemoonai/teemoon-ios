//
//  MarketingCaptureUITests.swift
//  teemoonUITests
//
//  Landing-page captures against the seeded `ai.teemoon.app` install.
//  Navigation only — does NOT send messages (won't pollute chat history).
//
//  Target sim: teemoon-capture-tmp (or whichever has providers configured).
//  NWPathMonitor may still collapse home/cloud on simulator; we still open
//  the sheet and capture whatever the current UI shows.
//

import XCTest

final class MarketingCaptureUITests: XCTestCase {

    private static let bundleID = "ai.teemoon.app"

    private var outputDir: URL {
        URL(fileURLWithPath: "/tmp/teemoon-web-captures")
    }

    private func app() -> XCUIApplication {
        XCUIApplication(bundleIdentifier: Self.bundleID)
    }

    private func save(_ shot: XCUIScreenshot, as name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // Also write to /tmp so we don't need xcresulttool
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let url = outputDir.appendingPathComponent("\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }

    func testMarketingStills() throws {
        let app = app()
        app.launch()
        Thread.sleep(forTimeInterval: 2.5)
        save(XCUIScreen.main.screenshot(), as: "mkt-01-chat")

        let chip = app.buttons["chat.whereChip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "where chip missing — wrong install?")

        // Open Where sheet
        chip.tap()
        Thread.sleep(forTimeInterval: 1.5)
        // Expand the sheet from its medium detent to full so the captures fill the
        // frame (the where popover adapts to a swipe-up-expandable sheet on iPhone).
        let grab = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46))
        grab.press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)))
        Thread.sleep(forTimeInterval: 0.8)
        save(XCUIScreen.main.screenshot(), as: "mkt-02-where-all")

        // Segment: phone
        if app.buttons["phone"].waitForExistence(timeout: 3) {
            app.buttons["phone"].tap()
            Thread.sleep(forTimeInterval: 1.2)
            save(XCUIScreen.main.screenshot(), as: "mkt-03-where-phone")
        }

        // Segment: home
        if app.buttons["home"].waitForExistence(timeout: 3) {
            app.buttons["home"].tap()
            Thread.sleep(forTimeInterval: 1.2)
            save(XCUIScreen.main.screenshot(), as: "mkt-04-where-home")
        }

        // Segment: cloud
        if app.buttons["cloud"].waitForExistence(timeout: 3) {
            app.buttons["cloud"].tap()
            Thread.sleep(forTimeInterval: 1.2)
            save(XCUIScreen.main.screenshot(), as: "mkt-05-where-cloud")
            // scroll for more providers
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
            Thread.sleep(forTimeInterval: 1.0)
            save(XCUIScreen.main.screenshot(), as: "mkt-06-where-cloud-scrolled")
        }

        // Dismiss sheet — swipe down
        app.swipeDown()
        Thread.sleep(forTimeInterval: 1.0)
        save(XCUIScreen.main.screenshot(), as: "mkt-07-chat-after-where")
    }

    /// Real TrustLadder UI via DesignTour fixtures (GLM-5.1 AWQ vs served FP8).
    /// If the sheet opens mid-verify / failed, taps **re-verify** and waits for
    /// a clean verified hero before scrolling pages for the marketing site.
    func testLadderScrollCapture() throws {
        let out = URL(fileURLWithPath: "/tmp/teemoon-web-captures/ladder-pages")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for rung in ["everyday", "expert"] {
            let app = XCUIApplication(bundleIdentifier: Self.bundleID)
            app.launchArguments = [
                "-DesignTour", "ladder-verified",
                "-DesignTourRung", rung,
            ]
            app.launch()
            Thread.sleep(forTimeInterval: 2.5)

            waitForCleanLadder(app)

            // page 0 at top
            savePage(app, dir: out, name: "\(rung)-p00")

            // scroll the ladder content (not the whole app chrome)
            for page in 1...8 {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
                start.press(forDuration: 0.05, thenDragTo: end)
                Thread.sleep(forTimeInterval: 0.9)
                savePage(app, dir: out, name: String(format: "%@-p%02d", rung, page))
            }

            app.terminate()
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    /// Tap re-verify if the ladder is still verifying / paused / failed, then
    /// wait until the verified hero ("encrypted to" / green check language) is up.
    private func waitForCleanLadder(_ app: XCUIApplication) {
        // DesignTour plants a verified GLM-5.1 fixture; live provenance used to
        // clobber it. After freeze + attestation gate fixes, we should land
        // clean — but if not, re-verify is the escape hatch.
        let reverify = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 're-verify' OR label CONTAINS[c] 'reverify'")
        ).firstMatch

        let dump0 = app.debugDescription
        let dirty = dump0.localizedCaseInsensitiveContains("verifying")
            || dump0.localizedCaseInsensitiveContains("sending paused")
            || dump0.localizedCaseInsensitiveContains("couldn't confirm")
            || dump0.localizedCaseInsensitiveContains("not end-to-end")

        if dirty, reverify.waitForExistence(timeout: 2), reverify.isHittable {
            reverify.tap()
            Thread.sleep(forTimeInterval: 1.0)
        }

        // Wait for clean verified copy (GLM-5.1 quant story).
        for _ in 0..<25 {
            let d = app.debugDescription
            let clean = (d.localizedCaseInsensitiveContains("encrypted to")
                    || d.localizedCaseInsensitiveContains("only it can read"))
                && d.localizedCaseInsensitiveContains("GLM-5.1")
                && !d.localizedCaseInsensitiveContains("verifying…")
                && !d.localizedCaseInsensitiveContains("sending paused")
            if clean { return }
            // Keep offering re-verify while dirty.
            if reverify.exists, reverify.isHittable,
               d.localizedCaseInsensitiveContains("verifying")
                || d.localizedCaseInsensitiveContains("paused") {
                reverify.tap()
            }
            Thread.sleep(forTimeInterval: 0.8)
        }
        // Don't fail the capture — still dump pages; marketing can review.
    }

    private func savePage(_ app: XCUIApplication, dir: URL, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = dir.appendingPathComponent("\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }

    /// Strong hero: near.ai / frontier model with a real answer on screen.
    /// Requires a seeded install with near.ai key and glm (or similar) equipped.
    /// Writes one marketing turn into chat history on purpose.
    func testStrongHeroChat() throws {
        let app = app()
        app.launch()
        Thread.sleep(forTimeInterval: 3.0)

        // Prefer a clean thread so the shot isn't full of old noise.
        // list.bullet opens chats; + new chat when available.
        let list = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'list' OR identifier CONTAINS[c] 'list'")).firstMatch
        if list.waitForExistence(timeout: 3) {
            list.tap()
            Thread.sleep(forTimeInterval: 0.8)
            let plus = app.buttons["plus"].firstMatch
            if plus.waitForExistence(timeout: 2) {
                plus.tap()
                Thread.sleep(forTimeInterval: 1.0)
            } else {
                // dismiss list if no plus
                app.swipeDown()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        save(XCUIScreen.main.screenshot(), as: "hero-00-before-send")

        let field = app.descendants(matching: .any)["chat.composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "composer missing")
        field.tap()
        // Short, visual prompt — answer should look good on a phone screen.
        field.typeText("in two sentences: what makes private inference different from a normal api?")
        Thread.sleep(forTimeInterval: 0.5)

        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "send missing")
        send.tap()

        // Wait for a substantial assistant bubble (attestation + stream).
        var sawAnswer = false
        for i in 0..<40 {
            Thread.sleep(forTimeInterval: 1.5)
            if i % 4 == 0 {
                save(XCUIScreen.main.screenshot(), as: String(format: "hero-stream-%02d", i))
            }
            // Heuristic: assistant text longer than the user prompt appears.
            let dump = app.debugDescription
            if dump.localizedCaseInsensitiveContains("enclave")
                || dump.localizedCaseInsensitiveContains("encrypt")
                || dump.localizedCaseInsensitiveContains("attestation")
                || dump.localizedCaseInsensitiveContains("private")
                || dump.localizedCaseInsensitiveContains("tee") {
                // Prefer a moment after streaming has some body
                if i >= 2 {
                    sawAnswer = true
                    break
                }
            }
        }

        Thread.sleep(forTimeInterval: 2.0)
        // Scroll to show user + answer together if needed
        save(XCUIScreen.main.screenshot(), as: "hero-strong")
        if !sawAnswer {
            // Still keep the shot — may be model-specific wording
            save(XCUIScreen.main.screenshot(), as: "hero-strong-fallback")
        }
    }
}
