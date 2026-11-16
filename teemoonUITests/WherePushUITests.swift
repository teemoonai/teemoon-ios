//
//  WherePushUITests.swift
//  teemoonUITests
//
//  docs/IMAGES.md §4e (the maintainer 2026-11-11, "Now"): looking at a provider's models pushes inside the where sheet —
//  a back arrow, the same sheet — instead of sliding a second sheet up. Back returns with the tab and filter kept.
//

import XCTest

final class WherePushUITests: XCTestCase {

    private var server: EmbeddedFakeSSEServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try EmbeddedFakeSSEServer(lines: 1, delay: 0.005)
        server.replies = ["first-reply-alpha"]
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openWhereFiltered(_ app: XCUIApplication) -> XCUIElement {
        let chip = ProductE2E.whereChip(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "no where chip")
        chip.tap()
        let control = app.buttons["where.showOnly"]
        XCTAssertTrue(control.waitForExistence(timeout: 8), "no show-only row")
        control.tap()
        let item = app.buttons["reads images"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the menu has no reads images")
        item.tap()
        XCTAssertTrue(control.label.contains("reads images"), control.label)
        return control
    }

    /// The pushed page has a back button named for the sheet; a second sheet has none.
    private func assertPushedAndBack(_ app: XCUIApplication, _ name: String, control: XCUIElement) {
        let back = app.navigationBars.buttons["where"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 8), "\(name) did not push inside the where sheet")
        screenshot(app, "where-push-\(name)")
        back.tap()
        XCTAssertTrue(control.waitForExistence(timeout: 5), "back did not return to the where sheet")
        XCTAssertTrue(control.label.contains("reads images"), "the filter was lost: \(control.label)")
        XCTAssertTrue(app.buttons["all"].isSelected, "the tab was lost")
    }

    func testModelInfoPushesInsideTheWhereSheet() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        let control = openWhereFiltered(app)
        let row = app.descendants(matching: .any)["where.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no ready row")
        row.press(forDuration: 1.0)
        let info = app.buttons["model info"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5), "no model info in the long press")
        info.tap()
        assertPushedAndBack(app, "model-info", control: control)
    }

    func testABrowseRowPushesInsideTheWhereSheet() {
        let app = ProductE2E.launch(environment: ["UITEST_SEED_NEARAI_MODEL": "zai-org/GLM-5.3-Flash",
                                                  "UITEST_SEED_ATTESTATION": "1"])
        let control = openWhereFiltered(app)
        control.tap()
        app.buttons["reads images"].firstMatch.tap()   // off again: near.ai's row stays whatever its list says
        let nearai = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "near.ai")).firstMatch
        if !nearai.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(nearai.waitForExistence(timeout: 5), "no near.ai browse row")
        nearai.tap()
        let back = app.navigationBars.buttons["where"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 8), "the browse list did not push inside the where sheet")
        screenshot(app, "where-push-browse")
        back.tap()
        XCTAssertTrue(control.waitForExistence(timeout: 5), "back did not return to the where sheet")
    }
}
