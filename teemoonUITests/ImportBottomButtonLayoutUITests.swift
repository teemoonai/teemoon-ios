//
//  ImportBottomButtonLayoutUITests.swift
//  teemoonUITests
//
//  The import sheet's bottom button sits where Safari's "Import to Safari" / "Done" does, on every step.
//  Safari's captures (iPhone 17 Pro, 1206×2622, dark, iOS 26.5): the button's bottom is 34 pt above the screen's
//  bottom and 30 pt in from each side (pm evidence/1.1-ui/safari-import-ref/sim 03, 07, 08, 10b, 12b; all five equal).
//  Before 2026-11-07 ours sat higher and wider. Run on an iPhone 17 Pro to compare with those captures.
//

import XCTest

final class ImportBottomButtonLayoutUITests: XCTestCase {

    /// Safari's bottom button, measured from the captures' pixels (px / 3).
    private let safariBottomGap: CGFloat = 34
    private let safariSideInset: CGFloat = 30

    private var server: EmbeddedFakeSSEServer!

    override func setUpWithError() throws {
        continueAfterFailure = true   // every step is captured and measured, even after one is off
        server = try EmbeddedFakeSSEServer(lines: 6, delay: 0.005)
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    private func item(_ id: String, _ i: Int) -> [String: Any] {
        ["type": "message", "id": "msg_\(id)", "response_id": "resp_\(id)", "next_response_ids": [],
         "created_at": 1_760_500_000 + i, "status": "completed", "model": "test-model",
         "previous_response_id": "resp_outside_\(id)", "role": "user",
         "content": [["type": "input_text", "text": "synthetic import line \(i)"]]]
    }

    /// One chat's items (the per-chat export).
    private func singleChatExport(_ id: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [item(id, 0)])
    }

    /// The full export: `chats` conversations of one message each.
    private func fullExport(chats: Int) -> Data {
        let conversations: [[String: Any]] = (0..<chats).map { i in
            ["id": "conv_\(i)", "created_at": 1_760_500_000 + i, "metadata": ["title": "synthetic \(i)"],
             "data": [item("b\(i)", i)]]
        }
        return try! JSONSerialization.data(withJSONObject: conversations)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screen = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screen)
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
        // `TEST_RUNNER_IMPORT_LAYOUT_SHOTS=<host dir>` on xcodebuild also writes each step's PNG there.
        if let dir = ProcessInfo.processInfo.environment["IMPORT_LAYOUT_SHOTS"] {
            try? screen.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// Bottom gap and side insets of `element` against the window, in points; asserted equal to Safari's (±1 pt).
    private func assertWhereSafarisButtonIs(_ element: XCUIElement, in app: XCUIApplication, step: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame, f = element.frame
        let gap = window.maxY - f.maxY, left = f.minX - window.minX, right = window.maxX - f.maxX
        let note = "\(step): frame \(f) in window \(window) → bottom gap \(gap), left \(left), right \(right)"
        print("IMPORT-BUTTON-FRAME \(note)")
        let report = XCTAttachment(string: note)
        report.name = "\(step)-frame"; report.lifetime = .keepAlways; add(report)
        XCTAssertEqual(gap, safariBottomGap, accuracy: 1, "bottom gap — \(note)", file: file, line: line)
        XCTAssertEqual(left, safariSideInset, accuracy: 1, "left inset — \(note)", file: file, line: line)
        XCTAssertEqual(right, safariSideInset, accuracy: 1, "right inset — \(note)", file: file, line: line)
    }

    /// Start, file chosen, importing, finished and nothing new: the bottom button (or the progress in its place) is
    /// where Safari's is. A screenshot of each step is attached.
    func testTheBottomButtonSitsWhereSafarisDoesOnEveryStep() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = dir.appendingPathComponent("synthetic-export.json")
        let large = dir.appendingPathComponent("synthetic-export-large.json")
        try singleChatExport("a").write(to: small)
        try fullExport(chats: 20_000).write(to: large)

        let app = ProductE2E.launchLocal(server: server)
        let confirm = app.buttons["import.confirm"].firstMatch
        let done = app.buttons["import.done"].firstMatch

        // Start: from Settings › chats, the disabled import button.
        ProductE2E.openSettings(app)
        app.buttons["chats"].firstMatch.tap()
        let row = app.descendants(matching: .any)["chats.import"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no import row in chats settings")
        row.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the start step shows no bottom button")
        sleep(1)
        capture(app, "1-start")
        assertWhereSafarisButtonIs(confirm, in: app, step: "start")
        app.buttons["import.cancel"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the import sheet did not close")
        ProductE2E.dismissSettings(app)

        // File chosen, then finished.
        XCUIDevice.shared.system.open(small)
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "the opened file did not reach the confirm step")
        sleep(1)
        capture(app, "2-confirm")
        assertWhereSafarisButtonIs(confirm, in: app, step: "confirm")
        ProductE2E.tapUntilGone(confirm)
        XCTAssertTrue(done.waitForExistence(timeout: 15), "the import did not finish")
        sleep(1)
        capture(app, "4-finished")
        assertWhereSafarisButtonIs(done, in: app, step: "finished")
        done.tap()
        let offer = app.alerts["delete the export file?"]
        if offer.waitForExistence(timeout: 3) { offer.buttons["not now"].tap() }

        // Nothing new: the same file again.
        XCUIDevice.shared.system.open(small)
        XCTAssertTrue(done.waitForExistence(timeout: 15), "re-opening the same file did not reach the nothing-new step")
        sleep(1)
        capture(app, "5-nothing-new")
        assertWhereSafarisButtonIs(done, in: app, step: "nothing-new")
        done.tap()
        if offer.waitForExistence(timeout: 3) { offer.buttons["not now"].tap() }

        // Importing: a file large enough that the progress stays up long enough to read its frame.
        XCUIDevice.shared.system.open(large)
        XCTAssertTrue(confirm.waitForExistence(timeout: 30), "the large file did not reach the confirm step")
        sleep(1)
        let slot = confirm.frame
        confirm.tap()
        let progress = app.descendants(matching: .any)["import.progress"].firstMatch
        if progress.waitForExistence(timeout: 5) {
            let f = progress.frame
            capture(app, "3-importing")
            let note = "importing: progress \(f), button \(slot)"
            print("IMPORT-BUTTON-FRAME \(note)")
            let report = XCTAttachment(string: note)
            report.name = "importing-frame"; report.lifetime = .keepAlways; add(report)
            XCTAssertEqual(f.midY, slot.midY, accuracy: 1, "the progress is not centred where the button was — \(note)")
            XCTAssertEqual(f.minX, slot.minX, accuracy: 1, "the progress is not as wide as the button — \(note)")
            XCTAssertEqual(f.maxX, slot.maxX, accuracy: 1, "the progress is not as wide as the button — \(note)")
        } else {
            XCTFail("the import finished before the progress could be read")
        }
        XCTAssertTrue(done.waitForExistence(timeout: 120), "the large import did not finish")
    }
}
