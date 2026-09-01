//
//  SendHangProbeUITests.swift
//  teemoonUITests
//
//  THROWAWAY (hang bisect): drives one SEND into a seeded long thread and
//  measures where the time goes. The reported failure on main is "composer
//  send button still orange but everything frozen" — a main-thread hang on
//  send. The shell samples the process while this runs; the test itself just
//  drives and prints coarse timings.
//
//      TEST_RUNNER_TEEMOON_FAKE_SSE=http://127.0.0.1:8765/v1 \
//      TEST_RUNNER_TEEMOON_TURNS=200 xcodebuild test … \
//        -only-testing:teemoonUITests/SendHangProbeUITests
//

import XCTest

final class SendHangProbeUITests: XCTestCase {

    func testSendIntoLongThread() throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TEEMOON_FAKE_SSE"] else {
            throw XCTSkip("set TEEMOON_FAKE_SSE to run this")
        }
        let turns = Int(ProcessInfo.processInfo.environment["TEEMOON_TURNS"] ?? "") ?? 200
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_LONG_THREAD"] = String(turns)
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = endpoint
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = "fake-model"
        app.launch()

        var t = Date()
        let chatsButton = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chatsButton.waitForExistence(timeout: 60), "chats button never appeared")
        chatsButton.tap()
        let row = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "question 0:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "long thread row never appeared")
        print("[sendhang] list open took \(Date().timeIntervalSince(t))s")

        t = Date()
        row.tap()
        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 180), "composer never appeared after opening thread")
        print("[sendhang] thread open -> composer visible took \(Date().timeIntervalSince(t))s")

        t = Date()
        composer.tap()
        composer.typeText("go")
        print("[sendhang] focus+type took \(Date().timeIntervalSince(t))s")

        t = Date()
        app.buttons["chat.send"].tap()
        print("[sendhang] send tap returned after \(Date().timeIntervalSince(t))s")

        // Leave the app alone; the shell-side sampler owns the diagnosis.
        Thread.sleep(forTimeInterval: 25)

        // Liveness check: a hung main thread cannot serve this query quickly.
        t = Date()
        let exists = app.buttons["chat.send"].exists
        print("[sendhang] post-send existence query took \(Date().timeIntervalSince(t))s (exists=\(exists))")
    }
}
