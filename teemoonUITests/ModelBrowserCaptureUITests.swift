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

    private static let model = "z-ai/glm-5.2"

    override func setUp() { continueAfterFailure = false }

    private func save(_ shot: XCUIScreenshot, as name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testCaptureCloudModelBrowser() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = Self.model
        app.launch()

        let chip = app.buttons["chat.whereChip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no where chip")
        chip.tap()
        Thread.sleep(forTimeInterval: 1.6)

        // The browse row carries no accessibility identifier, so match its
        // label. "browse near.ai" is the e2ee tier — the one whose badge the
        // site's table cannot represent.
        let browse = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "browse near.ai"))
            .firstMatch
        guard browse.waitForExistence(timeout: 8) else {
            throw XCTSkip("no 'browse near.ai' row — the sheet is in some other state")
        }
        browse.tap()
        Thread.sleep(forTimeInterval: 2.5)

        // "browse near.ai" opens the PROVIDER screen, not the catalogue — the
        // door to the browser is the "all N models" row under the recommended
        // one. N varies with the live catalogue, so match the prefix.
        let allModels = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", "all "))
            .firstMatch
        guard allModels.waitForExistence(timeout: 8) else {
            throw XCTSkip("no 'all N models' row — provider screen is in some other state")
        }
        allModels.tap()

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
