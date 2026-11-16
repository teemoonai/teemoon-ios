//
//  RequestCardHeaderUITests.swift
//  teemoonUITests
//
//  The last-request card's header with a long model id (Android broke on near.ai's
//  "DeepSeek-V4.1-Flash-1017-abliterated", 2026-11-13: "HTTP 200" one letter per line). Its tokens never break: the
//  status keeps one line and the id gives way, truncated in the middle.
//

import XCTest

final class RequestCardHeaderUITests: XCTestCase {

    private var server: EmbeddedFakeSSEServer!
    static let longID = "DeepSeek-V4.1-Flash-1017-abliterated"

    override func setUpWithError() throws {
        continueAfterFailure = true
        server = try EmbeddedFakeSSEServer(lines: 1, delay: 0.005)
        server.modelIDs = [Self.longID]
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    private func sendAndFindStatus(large: Bool) -> (XCUIApplication, XCUIElement) {
        var arguments = ["--uitesting", "-developerModeEnabled", "YES"]
        if large { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        let app = ProductE2E.launch(arguments: arguments,
                                    environment: ["UITEST_SEED_LOCAL_ENDPOINT": server.baseURL,
                                                  "UITEST_SEED_LOCAL_MODEL": Self.longID])
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20))
        ProductE2E.typeIntoComposer(app, "hello")
        ProductE2E.send(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 30))
        let status = app.staticTexts["HTTP 200"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), "no request card")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "request-header-\(large ? "ax5" : "default")"; shot.lifetime = .keepAlways; add(shot)
        return (app, status)
    }

    /// One line is wider than tall; a word broken a letter per line is a tall, narrow column.
    private func assertOneLine(_ element: XCUIElement, _ what: String) {
        let f = element.frame
        XCTAssertGreaterThan(f.width, f.height * 2, "\(what) broke across lines: \(f)")
    }

    func testTheHeaderHoldsWithALongIDAtTheDefaultSize() {
        let (_, status) = sendAndFindStatus(large: false)
        assertOneLine(status, "HTTP 200")
    }

    func testTheHeaderHoldsWithALongIDAtTheLargestSize() {
        let (_, status) = sendAndFindStatus(large: true)
        assertOneLine(status, "HTTP 200")
    }
}
