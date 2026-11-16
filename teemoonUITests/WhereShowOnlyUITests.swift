//
//  WhereShowOnlyUITests.swift
//  teemoonUITests
//
//  docs/IMAGES.md §4e: the where sheet's count + "show only" row, driven through its menu. The cells themselves
//  are pinned by WhereFilterPolicyTests from conformance/wherefilter.json; this pins that the sheet draws them.
//

import XCTest

final class WhereShowOnlyUITests: XCTestCase {

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

    private func pick(_ app: XCUIApplication, _ option: String) {
        app.buttons["where.showOnly"].tap()
        let item = app.buttons[option].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the menu has no \(option)")
        item.tap()
    }

    /// One home model that reads images: "1 model" either way under reads images, "0 of 1" under end-to-end.
    func testTheRowCountsTheTabAndTheMenuFilters() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_SEES_IMAGES": "1"])
        let chip = ProductE2E.whereChip(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "no where chip")
        chip.tap()

        let control = app.buttons["where.showOnly"]
        XCTAssertTrue(control.waitForExistence(timeout: 8), "no show-only row")
        let count = app.staticTexts["where.showOnly.count"]
        XCTAssertEqual(count.label, "1 model")
        XCTAssertTrue(control.label.contains("show only"), control.label)
        screenshot(app, "where-show-only-off")

        pick(app, "end-to-end encrypted")
        XCTAssertTrue(control.label.contains("end-to-end encrypted"), control.label)
        XCTAssertEqual(count.label, "0 of 1")
        screenshot(app, "where-show-only-e2ee")

        pick(app, "end-to-end encrypted")
        pick(app, "reads images")
        XCTAssertTrue(control.label.contains("reads images"), control.label)
        XCTAssertEqual(count.label, "1 model")
        screenshot(app, "where-show-only-images")
    }
}
