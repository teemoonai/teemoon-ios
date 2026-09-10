//
//  DownloadLifecycleUITests.swift
//  teemoonUITests
//
//  Drives a real Gemma 4 E2B download from the Hub through the Where sheet and
//  proves the three things a user reported missing: the transfer keeps going
//  while the app is in the background, it is still there after the app is
//  killed and relaunched, and cancelling then starting again resumes rather than
//  restarts. A second test walks the mobile-data prompt with the path forced
//  expensive; a third points the downloader at a local fake Hub to watch the
//  integrity failure land on the row.
//
//  SIMULATOR ONLY. `--uitesting` puts the provider store in memory and seeds a
//  local provider each launch, which is the fresh-install shape the report
//  described. On a device that seed replaces the real configuration.
//
//  Every state is photographed. `UITEST_SHOT_DIR` in the runner's environment
//  (pass `TEST_RUNNER_UITEST_SHOT_DIR=…` to xcodebuild) is where the PNGs go;
//  they are attached as well.
//
//  The first test pulls a few percent of a 2.4 GB file from the real CDN — at
//  ~1 MB/s that is a couple of minutes — then cancels, leaving resume data in
//  the simulator's Application Support. A later run resumes from it, which is
//  fine: the assertions are about ordering, not absolute percentages.
//

import XCTest

final class DownloadLifecycleUITests: XCTestCase {

    private let e2b = "litert-community/gemma-4-E2B-it-litert-lm"

    override func setUp() { continueAfterFailure = false }

    // MARK: Rig

    private func launch(arguments: [String] = [], environment: [String: String] = [:],
                        clean: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"] + arguments
        app.launchEnvironment["UITEST_SEED_ONDEVICE_MODEL"] = e2b
        // The app's own path/download log (Documents/native.log) — the record
        // to pull with `devicectl device copy from` when a device run misbehaves.
        app.launchEnvironment["TEEMOON_NATIVE_LOG"] = "1"
        // Resume data from an earlier run points at whatever server that run
        // used; a test against the fake Hub must not resume from the real CDN.
        if clean { app.launchEnvironment["UITEST_RESET_LOCAL_MODELS"] = "1" }
        // `TEST_RUNNER_UITEST_HUB_BASE_URL=…` on xcodebuild points every test in
        // this file at a local Hub, so the two-phase relaunch check can be run
        // from the command line against a throttled server.
        if let hub = ProcessInfo.processInfo.environment["UITEST_HUB_BASE_URL"] {
            app.launchEnvironment["UITEST_HUB_BASE_URL"] = hub
        }
        environment.forEach { app.launchEnvironment[$0] = $1 }
        app.launch()
        if clean {
            openWhere(app)
            if app.buttons["cancel download"].firstMatch.exists {
                cancelAnyDownload(app)
                app.launch()
            } else {
                closeWhere(app)
            }
        }
        return app
    }

    private func openWhere(_ app: XCUIApplication) {
        // A sheet or alert may still be animating out from the previous step;
        // tapping through that fails the tap's interruption check.
        Thread.sleep(forTimeInterval: 1.2)
        let deadline = Date().addingTimeInterval(5)
        while app.alerts.firstMatch.exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        let chip = app.buttons["chat.whereChip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 30), "the Where chip never appeared")
        // A coordinate tap skips the interrupting-element check, which has failed
        // its own alert query mid-dismissal ("no matches found for Alert"). It
        // can also miss when the keyboard is sliding the chip upward on first
        // launch, so it is retried.
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'where.row'")).firstMatch
        var opened = false
        for _ in 0..<3 where !opened {
            chip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            opened = rows.waitForExistence(timeout: 6)
        }
        XCTAssertTrue(opened, "no rows in the Where sheet")
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func closeWhere(_ app: XCUIApplication) {
        // The sheet's close control, then a fallback swipe if the chrome differs.
        let close = app.buttons["close"].firstMatch
        if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// The daemon keeps transfers across test runs, simulator reboots included —
    /// which is the feature, and also why a run can open on a row that is already
    /// downloading. Cancel it so every test starts from "not downloaded".
    private func cancelAnyDownload(_ app: XCUIApplication) {
        let cancel = app.buttons["cancel download"].firstMatch
        if cancel.waitForExistence(timeout: 3) {
            cancel.tap()
            Thread.sleep(forTimeInterval: 1.5)
            // Cancelling drops the seeded provider; relaunch to seed it again.
            app.terminate()
        }
    }

    private func readyRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["where.row"].firstMatch
    }

    private func resumeRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["where.row.resume"].firstMatch
    }

    /// "downloading 3%" → 3. nil when the row is not showing progress.
    private func percent(in label: String) -> Int? {
        guard let range = label.range(of: #"downloading (\d+)%"#, options: .regularExpression) else { return nil }
        let digits = label[range].filter(\.isNumber)
        return Int(digits)
    }

    /// Waits until the ready row reports at least `minimum` percent.
    @discardableResult
    private func waitForProgress(_ app: XCUIApplication, atLeast minimum: Int, timeout: TimeInterval,
                                 file: StaticString = #filePath, line: UInt = #line) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var last = -1
        while Date() < deadline {
            let row = readyRow(app)
            if row.exists, let p = percent(in: row.label) {
                last = p
                if p >= minimum { return p }
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTFail("progress never reached \(minimum)% (last seen \(last))", file: file, line: line)
        return last
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["UITEST_SHOT_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url)
        }
    }

    // MARK: Tests

    /// Background, kill, relaunch, cancel, resume — against the real CDN.
    func testDownloadSurvivesBackgroundKillAndResumes() throws {
        var app = launch(clean: true)
        openWhere(app)

        // Fresh install: the seeded model has no weights, so the row offers to
        // download (the seed makes it read as "resume").
        let start = resumeRow(app)
        XCTAssertTrue(start.waitForExistence(timeout: 10), "no download/resume row for E2B")
        shot("01-fresh-not-downloaded")
        start.tap()                                   // wi-fi in the simulator: starts, no prompt

        // The sheet dismisses on start; reopen and watch the bar.
        openWhere(app)
        let before = waitForProgress(app, atLeast: 1, timeout: 240)
        shot("02-downloading-\(before)pct")

        // 1. Background for a while. A foreground session would have been frozen.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 20)
        app.activate()
        XCTAssertTrue(readyRow(app).waitForExistence(timeout: 10))
        let afterBackground = waitForProgress(app, atLeast: before, timeout: 30)
        shot("03-after-background-\(afterBackground)pct")
        XCTAssertGreaterThanOrEqual(afterBackground, before)

        // 2. Kill the app. The daemon keeps the transfer; relaunch re-attaches.
        app.terminate()
        Thread.sleep(forTimeInterval: 3)
        app = launch()
        openWhere(app)
        XCTAssertTrue(readyRow(app).waitForExistence(timeout: 15), "no ready row after relaunch")
        let afterRelaunch = waitForProgress(app, atLeast: afterBackground, timeout: 60)
        shot("04-after-relaunch-\(afterRelaunch)pct")
        XCTAssertGreaterThanOrEqual(afterRelaunch, afterBackground, "relaunch lost the download")

        // 3. Cancel — which removes the seeded provider and sends E2B back to
        //    `get` — then tap it again: the second start must resume, not restart.
        let cancel = app.buttons["cancel download"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "no cancel control on the row")
        cancel.tap()
        Thread.sleep(forTimeInterval: 1.5)
        shot("05-cancelled")

        // Cancelling removed the only provider, so the sheet is back to its
        // first-run shape with one big download button; with other providers
        // configured E2B would sit in `get` instead. Either way, tap it.
        let firstRun = app.descendants(matching: .any)["where.firstRun.download"].firstMatch
        let getRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'download Gemma 4 E2B'")).firstMatch
        if firstRun.waitForExistence(timeout: 10) {
            firstRun.tap()
        } else {
            XCTAssertTrue(getRow.waitForExistence(timeout: 5), "E2B did not return to `get` after cancel")
            getRow.tap()
        }

        openWhere(app)
        // Resumed downloads pick up their offset within a couple of seconds; a
        // restart would sit at 0% for the ~25 s it takes to fetch 1% again.
        let resumed = waitForProgress(app, atLeast: afterRelaunch, timeout: 15)
        shot("06-resumed-\(resumed)pct")
        XCTAssertGreaterThanOrEqual(resumed, afterRelaunch, "the restart began from zero")

        // Stop pulling gigabytes over the CDN.
        app.buttons["cancel download"].firstMatch.tap()
    }

    /// The path is forced expensive: the tap asks, "wait for wi-fi" parks the
    /// download with a visible reason, tapping again offers mobile data.
    func testMobileDataPromptAndWaitingForWifi() throws {
        let app = launch(arguments: ["-simulateExpensivePath"], clean: true)
        openWhere(app)

        let start = resumeRow(app)
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no mobile-data prompt on an expensive path")
        XCTAssertTrue(alert.staticTexts["download over mobile data?"].exists)
        shot("10-mobile-data-prompt")

        alert.buttons["wait for wi-fi"].tap()
        openWhere(app)
        let row = readyRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("waiting for wi-fi"), "row reads: \(row.label)")
        shot("11-waiting-for-wifi")

        // Change of mind: the parked row re-asks, and "download now" moves it
        // onto mobile data.
        row.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "parked row did not re-ask")
        Thread.sleep(forTimeInterval: 1.0)   // a tap during the present animation is swallowed
        alert.buttons["download now"].tap()
        openWhere(app)
        let moving = readyRow(app)
        XCTAssertTrue(moving.waitForExistence(timeout: 10))
        XCTAssertTrue(moving.label.contains("downloading"), "row reads: \(moving.label)")
        shot("12-downloading-on-mobile-data")

        app.buttons["cancel download"].firstMatch.tap()
    }

    // MARK: Device: wi-fi off and on, through Control Center

    /// The check that found three bugs by hand on 2026-09-05: with a wi-fi-only
    /// download running, switch wi-fi off and the row must say "waiting for
    /// wi-fi" with the percentage frozen; switch it on and it must move again.
    ///
    /// DEVICE OVER USB ONLY. Toggling wi-fi drops the network link to the Mac,
    /// so a network-paired run dies mid-test, and a simulator has no wi-fi tile
    /// at all (skipped there). Run it by name; `TEST_RUNNER_` environment does
    /// not reach a device runner, so there is no env gate. The teardown turns
    /// wi-fi back on if the test left it off. The Control Center wi-fi tile is
    /// what a user reaches for, and it produces the same cellular-only path.
    func testWifiOffParksAndWifiOnResumes() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("needs a real phone on USB: the simulator has no wi-fi tile")
        #endif
        // A previous run may have died with wi-fi off; start from a known state.
        setWifi(on: true)
        let app = launch(clean: true)
        openWhere(app)
        let start = resumeRow(app)
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()                                   // on wi-fi: starts wi-fi-only, no prompt
        openWhere(app)
        let moving = waitForProgress(app, atLeast: 1, timeout: 300)
        shot("40-downloading-\(moving)pct-on-wifi")

        var wifiIsOff = false
        addTeardownBlock { [self] in
            if wifiIsOff { setWifi(on: true); wifiIsOff = false }
        }

        // 1. Wi-fi off. The daemon holds the bytes at once; the app parks after
        //    its blip-debounce and only then changes the label.
        setWifi(on: false)
        wifiIsOff = true
        app.activate()
        let row = readyRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let parkDeadline = Date().addingTimeInterval(20)
        while !row.label.contains("waiting for wi-fi"), Date() < parkDeadline {
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(row.label.contains("waiting for wi-fi"), "row reads: \(row.label)")
        shot("41-wifi-off-waiting")

        // Frozen: nothing may move over cellular. Fifteen seconds is more than
        // a percent's worth at any speed this phone has shown.
        let frozenAt = percent(in: row.label) ?? moving
        Thread.sleep(forTimeInterval: 15)
        let later = percent(in: readyRow(app).label) ?? frozenAt
        XCTAssertEqual(later, frozenAt, "progress moved while on mobile data")
        XCTAssertTrue(readyRow(app).label.contains("waiting for wi-fi"), "label flipped back while still on cellular")

        // 2. Wi-fi on. Resumes from the same number, label back to downloading.
        setWifi(on: true)
        wifiIsOff = false
        app.activate()
        let resumed = waitForProgress(app, atLeast: frozenAt, timeout: 60)
        XCTAssertFalse(readyRow(app).label.contains("waiting for wi-fi"), "still parked after wi-fi returned")
        shot("42-wifi-on-resumed-\(resumed)pct")
        let advanced = waitForProgress(app, atLeast: frozenAt + 1, timeout: 120)
        XCTAssertGreaterThan(advanced, frozenAt, "did not move again after wi-fi returned")

        app.buttons["cancel download"].firstMatch.tap()
    }

    /// Flips the Control Center wi-fi tile. Opens Control Center with a drag
    /// from the top-right corner, reads the tile's value so it only taps when
    /// the state actually differs, then closes it.
    private func setWifi(on wanted: Bool) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.01))
        let pulled = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.55))
        top.press(forDuration: 0.1, thenDragTo: pulled)
        Thread.sleep(forTimeInterval: 1.0)
        shot("cc-open-before-\(wanted ? "on" : "off")")

        // iOS 26 exposes the tile as the "wifi-button" Button. Its `value` is
        // the NETWORK NAME while on ("Starbucks WiFi"), "Off" when off, and
        // `isSelected` is never set — reading either of those wrongly flipped
        // wi-fi the opposite way on 2026-09-06, twice.
        let tile = springboard.buttons["wifi-button"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "no wi-fi tile in Control Center")
        func tileIsOn() -> Bool {
            let state = ((tile.value as? String) ?? "").lowercased()
            return !(state.isEmpty || state == "off" || state == "not connected")
        }
        let isOn = tileIsOn()
        XCTContext.runActivity(named: "wi-fi tile: value='\((tile.value as? String) ?? "")' → on=\(isOn), wanted=\(wanted)") { _ in }
        if isOn != wanted {
            // The round icon in the tile's top-left corner is the toggle; a tap
            // on the label area opens the network picker instead (iOS 26).
            tile.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.22)).tap()
            Thread.sleep(forTimeInterval: 1.5)
            shot("cc-after-tap-\(wanted ? "on" : "off")")
            XCTAssertEqual(tileIsOn(), wanted, "wi-fi tile did not change state (value now '\((tile.value as? String) ?? "")')")
        }
        // Close Control Center: a tap on the empty area at the bottom.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        Thread.sleep(forTimeInterval: wanted ? 4.0 : 2.0)   // wi-fi re-association takes a moment
    }

    /// Phase one of the relaunch-to-deliver check, for a DEVICE: start the real
    /// download, then kill the app and walk away. iOS should wake the app when
    /// the bytes land so it can verify and install them; `testCaptureCurrentState`
    /// is how you look, later, without disturbing anything.
    func testStartDownloadAndKill() throws {
        let app = launch(clean: true)
        openWhere(app)
        let start = resumeRow(app)
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        openWhere(app)
        let pct = waitForProgress(app, atLeast: 1, timeout: 300)
        shot("30-started-\(pct)pct-before-kill")
        app.terminate()
    }

    /// Read-only: seed, open Where, photograph. No reset, no cancel.
    func testCaptureCurrentState() throws {
        let app = launch()
        openWhere(app)
        Thread.sleep(forTimeInterval: 1.0)
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'where.row'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        shot("31-current-state")
        // Print, so the runner log carries the answer without opening the shot.
        print("[dl-state] row: \(row.label)")
    }

    /// A local fake Hub serves the wrong bytes: the download lands, fails its
    /// checksum, and the row says so.
    func testIntegrityFailureIsShownOnTheRow() throws {
        let hub = ProcessInfo.processInfo.environment["UITEST_FAKE_HUB"] ?? "http://127.0.0.1:8765"
        let app = launch(environment: ["UITEST_HUB_BASE_URL": hub], clean: true)
        openWhere(app)

        let start = resumeRow(app)
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        openWhere(app)

        // 30 MB from localhost: seconds. The row flips back to the resume shape
        // with the failure as its caption.
        let failed = resumeRow(app)
        XCTAssertTrue(failed.waitForExistence(timeout: 60), "the failed download never came back as a row")
        Thread.sleep(forTimeInterval: 0.5)
        shot("20-integrity-failure")
        let integrity = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'integrity'")).firstMatch
        XCTAssertTrue(integrity.waitForExistence(timeout: 5), "no integrity-failure caption on the row")
    }
}
