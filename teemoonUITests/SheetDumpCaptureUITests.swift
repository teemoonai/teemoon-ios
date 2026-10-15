//
//  SheetDumpCaptureUITests.swift
//  teemoonUITests
//
//  Not a gate: writes every label of a near.ai model's expert sheet, scrolled to its end, to
//  /tmp/teemoon-sheet-<model>.txt — one XCUIElement snapshot per screen, so a whole sheet reads in seconds.
//  Run on purpose: TEST_RUNNER_SHEET_MODEL=<near.ai id>.
//

import XCTest

final class SheetDumpCaptureUITests: XCTestCase {
    func testDumpExpertSheet() throws {
        let model = ProcessInfo.processInfo.environment["SHEET_MODEL"] ?? "Qwen/Qwen3.8-27B"
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = model
        app.launch()
        let chip = ProductE2E.titleBlock(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 15))
        chip.tap()
        XCTAssertTrue(app.staticTexts["who can read this?"].waitForExistence(timeout: 5))
        sleep(15)   // the live record and the audit index land
        if app.buttons["expert"].waitForExistence(timeout: 5) { app.buttons["expert"].tap() }
        sleep(3)
        func labels(_ s: XCUIElementSnapshot) -> [String] { [s.label] + s.children.flatMap { labels($0) } }
        var out: [String] = []
        for i in 0..<30 {
            if let snap = try? app.snapshot() { out.append("--- screen \(i)"); out += labels(snap).filter { !$0.isEmpty } }
            app.swipeUp(velocity: .fast)
        }
        let name = model.replacingOccurrences(of: "/", with: "_")
        try out.joined(separator: "\n").write(to: URL(fileURLWithPath: "/tmp/teemoon-sheet-\(name).txt"), atomically: true, encoding: .utf8)
    }
}
