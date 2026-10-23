//
//  ProviderWaitUITests.swift
//  teemoonUITests
//
//  A provider that sends no response headers for a while: the chip says the
//  request is waiting on it, on the first request and on a search turn's
//  follow-up.
//

import XCTest

final class ProviderWaitUITests: XCTestCase {
    private var server: EmbeddedFakeSSEServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try EmbeddedFakeSSEServer(lines: 6, delay: 0.02)
        server.headerDelay = 9
    }

    override func tearDown() { server?.stop(); server = nil }

    private func chipLabel(_ app: XCUIApplication) -> String {
        let chip = app.descendants(matching: .any)["chat.activityChip"].firstMatch
        return chip.exists ? chip.label : ""
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testTheChipNamesTheProviderAfterFiveSecondsWithoutHeaders() {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.typeIntoComposer(app, "Why is the sky blue?")
        ProductE2E.send(app)
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(chipLabel(app).contains("waiting for"), "shown before the threshold: \(chipLabel(app))")
        Thread.sleep(forTimeInterval: 4.5)
        XCTAssertTrue(chipLabel(app).contains("waiting for"), "got \(chipLabel(app))")
        shot("waiting-first-request")
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 30))
        XCTAssertFalse(chipLabel(app).contains("waiting for"))
    }

    func testASearchTurnsFollowUpWaitsToo() {
        server.emitToolRound = true
        server.toolFollowUpReply = "tool-round-ok-zeta"
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.typeIntoComposer(app, "tool-round-please-search")
        ProductE2E.send(app)
        let deadline = Date().addingTimeInterval(30)
        while server.requestLines.filter({ $0.hasPrefix("POST /v1/chat/completions") }).count < 2, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 6.5)
        shot("waiting-search-follow-up")
        let posts = server.requestLines.filter { $0.hasPrefix("POST /v1/chat/completions") }.count
        XCTAssertTrue(chipLabel(app).contains("waiting for"), "got '\(chipLabel(app))' after \(posts) requests")
        XCTAssertTrue(ProductE2E.elementContaining(app, "tool-round-ok-zeta").waitForExistence(timeout: 20))
    }
}
