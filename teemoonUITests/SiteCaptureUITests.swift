//
//  SiteCaptureUITests.swift
//  teemoonUITests
//
//  Every screenshot teemoon.ai shows, from one seeded launch per frame — no
//  hand-configured simulator. Driven by the website's recapture script,
//  which picks the models from the site's model registry, so a retired model
//  is replaced by re-running the script rather than by re-tapping a setup.
//
//  Inputs (set as TEST_RUNNER_<name> on xcodebuild):
//    SITE_SEED_SETUP    UITEST_SEED_SETUP JSON (see UITestSetupSeed.swift)
//    SITE_E2EE_MODEL    the near.ai model the hero and wire frames use
//    SITE_HERO_PROMPT   the hero's question
//    SITE_WIRE_PROMPT   the wire frame's question
//
//  Output: /tmp/teemoon-site-captures/<frame>.png. SPENDS MONEY: the hero and
//  wire frames are one live near.ai generation each, with a web search.
//

import XCTest

final class SiteCaptureUITests: XCTestCase {

    private let outputDir = URL(fileURLWithPath: "/tmp/teemoon-site-captures")
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var model: String { env["SITE_E2EE_MODEL"] ?? "z-ai/glm-5.3-flash" }

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? shot.pngRepresentation.write(to: outputDir.appendingPathComponent("\(name).png"))
    }

    /// Green before any frame: every where frame has the title block above it,
    /// and a frame that says "verifying…" or "not end-to-end" over a sealed
    /// session is a contradiction on the page.
    private func requireVerified(_ app: XCUIApplication) {
        XCTAssertTrue(ProductE2E.titleBlock(app).waitForExistence(timeout: 15), "no title block")
        XCTAssertTrue(ProductE2E.waitUntilVerified(app, timeout: 120),
                      "session never verified: \(ProductE2E.titleLabel(app))")
    }

    /// where-all / where-phone / where-home / where-cloud.
    func testWhereSegments() throws {
        let setup = try XCTUnwrap(env["SITE_SEED_SETUP"], "SITE_SEED_SETUP not set")
        let app = ProductE2E.launch(environment: ["UITEST_SEED_SETUP": setup])
        requireVerified(app)

        let chip = ProductE2E.whereChip(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no where chip")
        chip.tap()
        Thread.sleep(forTimeInterval: 2.0)

        // Full detent, re-applied per segment — see WhereSegmentsCaptureUITests
        // for why: collapse first so the drag always starts on the grabber.
        func expand() {
            for _ in 0..<3 { app.swipeDown(velocity: .slow); Thread.sleep(forTimeInterval: 0.35) }
            Thread.sleep(forTimeInterval: 0.8)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.47))
               .press(forDuration: 0.15,
                      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)))
            Thread.sleep(forTimeInterval: 1.4)
        }

        for seg in ["all", "phone", "home", "cloud"] {
            let button = app.buttons[seg].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "no '\(seg)' segment")
            button.tap()
            Thread.sleep(forTimeInterval: 1.6)   // rows cross-fade between filters
            expand()
            save("where-\(seg)")
        }
    }

    /// hero-chat — one grounded turn on the E2EE flagship, top of the answer.
    func testHeroChat() throws {
        try ProductE2E.requireHostKey(forPreset: "nearai")
        try ProductE2E.requireGroundingKey()
        let prompt = env["SITE_HERO_PROMPT"]
            ?? "use the Japanese version of tabelog to find the best cost-performance seafood places in hakodate"
        let app = ProductE2E.launchNearAIGrounded(model: model)
        requireVerified(app)

        let web = app.descendants(matching: .any)["chat.webSearchChip"].firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10), "web search chip missing")
        let value = (web.value as? String ?? "").lowercased()
        if !value.contains("on") || value.contains("off") {
            web.tap()
            Thread.sleep(forTimeInterval: 0.6)
        }

        ProductE2E.typeIntoComposer(app, prompt)
        ProductE2E.send(app)
        ProductE2E.confirmSendIfAsked(app)
        XCTAssertTrue(ProductE2E.elementContaining(app, String(prompt.prefix(30))).waitForExistence(timeout: 20),
                      "prompt never landed")
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 300), "turn did not settle")
        Thread.sleep(forTimeInterval: 1.5)

        // The hero is the top of the answer, not its tail.
        for _ in 0..<8 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
               .press(forDuration: 0.05,
                      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
            Thread.sleep(forTimeInterval: 0.4)
        }
        // Dismiss the keyboard if the send left the composer focused.
        if app.keyboards.count > 0 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        }
        Thread.sleep(forTimeInterval: 1.0)
        save("hero-chat")
    }
}
