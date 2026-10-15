//
//  ModelBrowserCaptureUITests.swift
//  teemoonUITests
//
//  The cloud model picker, for teemoon.ai's models section — which today is a
//  hardcoded table of seven names, sizes and providers that near.ai's catalog
//  will outrun.
//
//  The picker is the better asset for two reasons. NearAIModelCatalog.fetchLive
//  merges the live /v1/models response with curated metadata, so this is a
//  snapshot of a catalog that maintains itself. And it shows the confidentiality
//  ladder — `e2ee` filled green, `tee · third-party` outlined, `proxied` bare
//  grey — a distinction the site's table flattens into "e2ee" or "—".
//
//  Needs a near.ai key in this simulator's Keychain, same as
//  WireProofCaptureUITests. Skips rather than fails without one.
//

import XCTest

final class ModelBrowserCaptureUITests: XCTestCase {

    /// From `TEST_RUNNER_SITE_E2EE_MODEL` (teemoon-web's model registry); was a
    /// literal "z-ai/glm-5.2", which near.ai retired on 2026-09-12.
    private static var model: String {
        ProcessInfo.processInfo.environment["SITE_E2EE_MODEL"] ?? "z-ai/glm-5.3-flash"
    }

    override func setUp() { continueAfterFailure = false }

    private func save(_ shot: XCUIScreenshot, as name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testCaptureCloudModelBrowser() throws {
        // ProductE2E stages the host key files; a bare launch left the slot
        // empty on a fresh simulator and the test skipped with no browser.
        let app = ProductE2E.launchNearAI(model: Self.model)

        let chip = app.buttons["chat.whereChip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no where chip")
        chip.tap()
        Thread.sleep(forTimeInterval: 1.6)

        // The `get` row carries no accessibility identifier, so match its
        // label: the name with settings' caption under it. near.ai is the
        // e2ee tier — the one whose badge the site's table cannot represent.
        // Full detent first: at medium the near.ai row sits under the fold and
        // a tap on its text landed on "connect a computer" instead.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.47))
           .press(forDuration: 0.15,
                  thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)))
        Thread.sleep(forTimeInterval: 1.4)
        let browse = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@ AND label CONTAINS[c] %@",
                                  "near.ai", "open models"))
            .firstMatch
        guard browse.waitForExistence(timeout: 8) else {
            save(XCUIScreen.main.screenshot(), as: "59-model-browser-unexpected-state")
            throw XCTSkip("no near.ai row in get — the sheet is in some other state")
        }
        browse.tap()
        Thread.sleep(forTimeInterval: 2.5)

        // The row used to open the PROVIDER screen, whose "all N models" row
        // led to the catalogue. It now opens the browser directly (the where
        // sheet's `browse near.ai` door). Accept either.
        if !app.staticTexts["browse models"].waitForExistence(timeout: 4) {
            let allModels = app.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH[c] %@", "all "))
                .firstMatch
            guard allModels.waitForExistence(timeout: 8) else {
                save(XCUIScreen.main.screenshot(), as: "59-model-browser-unexpected-state")
                throw XCTSkip("neither the browser nor an 'all N models' row — some other state")
            }
            allModels.tap()
        }

        // The live catalogue fetch is a network round trip; the curated list
        // paints first and is replaced, so capturing early gets the fallback.
        Thread.sleep(forTimeInterval: 8)
        save(XCUIScreen.main.screenshot(), as: "50-model-browser")

        // Scrolled, to reach rows below the e2ee group where the outlined
        // `tee · third-party` and bare `proxied` badges live — the contrast is
        // the point of the shot.
        app.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 1.2)
        save(XCUIScreen.main.screenshot(), as: "51-model-browser-scrolled")
    }
}
