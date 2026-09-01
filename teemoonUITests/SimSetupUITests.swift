//
//  SimSetupUITests.swift
//  teemoonUITests
//
//  NOT a test — a setup driver. Populates a simulator's phone and home tiers so
//  the where sheet has something to show under every filter, for teemoon.ai's
//  interactive segment block.
//
//  Deliberately does NOT use UITEST_SEED_*. Those seeds call
//  providerStore.providers.removeAll() before adding their one provider, so
//  seeding is mutually exclusive AND destructive — running one would delete the
//  near.ai key this simulator holds. Everything here goes through the UI a user
//  would use, so it persists.
//

import XCTest

final class SimSetupUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func save(_ shot: XCUIScreenshot, as name: String) {
        let a = XCTAttachment(screenshot: shot); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Downloads the on-device model, so the `phone` filter stops reading
    /// "nothing downloaded".
    func testDownloadOnDeviceModel() throws {
        let app = XCUIApplication()
        app.launch()

        let chip = app.buttons["chat.whereChip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "no where chip")
        chip.tap()
        Thread.sleep(forTimeInterval: 2.0)

        // `all`, not `phone`. Under `phone` the only thing above the fold is the
        // "nothing downloaded" empty state and the get section is off-screen —
        // the row exists in the tree but a tap on it lands nowhere.
        let allSeg = app.buttons["all"].firstMatch
        if allSeg.waitForExistence(timeout: 5) { allSeg.tap(); Thread.sleep(forTimeInterval: 1.4) }

        let row = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "gemma 4 e2b"))
            .firstMatch
        guard row.waitForExistence(timeout: 8) else {
            save(XCUIScreen.main.screenshot(), as: "90-no-gemma-row")
            throw XCTSkip("no gemma row under `all` — see attachment")
        }

        // Tap the ROW. `downloadRow` is a WhereRow carrying an .onTapGesture
        // (WhereSheetView.swift:1830) — the trailing arrow.down.circle is a
        // glyph inside it, not a button, so there is no separate control to
        // aim at and a trailing-edge coordinate hits nothing.
        row.tap()
        Thread.sleep(forTimeInterval: 3.0)
        save(XCUIScreen.main.screenshot(), as: "91-after-download-tap")

        // 2.4 GB. The transfer only advances while the app is alive, so the
        // wait has to happen in-test.
        func pending() -> Bool {
            app.staticTexts.matching(NSPredicate(format:
                "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "downloading", "not downloaded"))
                .firstMatch.exists
        }
        var started = false
        let startBy = Date().addingTimeInterval(45)
        while Date() < startBy { if pending() { started = true; break }; Thread.sleep(forTimeInterval: 1) }
        if !started {
            save(XCUIScreen.main.screenshot(), as: "92-never-started")
            XCTFail("download never visibly started — see attachment")
            return
        }
        let deadline = Date().addingTimeInterval(1200)
        while Date() < deadline { if !pending() { break }; Thread.sleep(forTimeInterval: 5) }
        save(XCUIScreen.main.screenshot(), as: "93-download-settled")
    }

    /// Adds a self-hosted provider, so the `home` filter stops reading
    /// "no computers connected".
    ///
    /// Through the UI on purpose. Writing teemoon-config.json directly would be
    /// faster and deterministic, but it would prove nothing about the flow a
    /// user actually walks, and a field guessed wrong is silently dropped.
    ///
    /// AddEditProviderView carries NO accessibility identifiers, so everything
    /// here matches on label and screenshots itself when a step misses.
    func testAddHomeServer() throws {
        let endpoint = ProcessInfo.processInfo.environment["SETUP_LOCAL_ENDPOINT"]
            ?? "https://ringzero.tailnet-name.ts.net:11434/v1"

        let app = XCUIApplication()
        app.launch()

        let chip = app.buttons["chat.whereChip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "no where chip")
        chip.tap()
        Thread.sleep(forTimeInterval: 2.0)

        let connect = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "connect a computer"))
            .firstMatch
        guard connect.waitForExistence(timeout: 8) else {
            save(XCUIScreen.main.screenshot(), as: "80-no-connect-row")
            throw XCTSkip("no 'connect a computer' row — see attachment")
        }
        connect.tap()
        Thread.sleep(forTimeInterval: 2.5)
        save(XCUIScreen.main.screenshot(), as: "81-connect-screen")

        // Match by PLACEHOLDER, not firstMatch. The sheet is presented over the
        // chat, so `chat.composer` is still in the hierarchy and sorts first —
        // the previous attempt typed the endpoint into the message box.
        let host = app.textFields
            .matching(NSPredicate(format: "placeholderValue == %@", "api.example.com/v1"))
            .firstMatch
        guard host.waitForExistence(timeout: 8) else {
            save(XCUIScreen.main.screenshot(), as: "82-no-field")
            XCTFail("no endpoint field on the connect screen — see attachment")
            return
        }

        // Host FIRST, scheme second. Flipping the scheme opens a menu that
        // covers the field, and if the menu item match misses, the popover
        // stays up and the field reports "not hittable" — which is what
        // happened. Typing while nothing is over it removes the ordering
        // dependency entirely.
        let hostOnly = endpoint
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        host.tap()
        Thread.sleep(forTimeInterval: 0.6)
        host.typeText(hostOnly)
        Thread.sleep(forTimeInterval: 0.6)

        // Now the scheme. It defaults to `http://` and the screen warns that
        // http is unencrypted; tailscale serves https, and iOS ATS would block
        // cleartext regardless.
        let scheme = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "http://"))
            .firstMatch
        if scheme.waitForExistence(timeout: 4) {
            scheme.tap()
            Thread.sleep(forTimeInterval: 1.0)
            // CONTAINS, not BEGINSWITH — the menu item reads "switch back to
            // https", so anchoring at the start never matched and the run
            // silently continued on http, which iOS then blocked.
            let https = app.buttons
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "https"))
                .firstMatch
            if https.waitForExistence(timeout: 4) {
                https.tap()
            } else {
                // Leave nothing modal on screen for the save tap.
                save(XCUIScreen.main.screenshot(), as: "85-scheme-menu")
                app.tap()
            }
            Thread.sleep(forTimeInterval: 0.8)
        }
        Thread.sleep(forTimeInterval: 1.0)
        save(XCUIScreen.main.screenshot(), as: "83-endpoint-typed")

        // `save` stays disabled until a model is chosen, so fetch the list off
        // the box and take the first one.
        let fetch = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "fetch models"))
            .firstMatch
        if fetch.waitForExistence(timeout: 5) {
            fetch.tap()
            Thread.sleep(forTimeInterval: 6.0)
            save(XCUIScreen.main.screenshot(), as: "86-after-fetch")
            // The box serves gemma4:e4b; pick whatever came back.
            let model = app.buttons
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "gemma"))
                .firstMatch
            if model.waitForExistence(timeout: 5) { model.tap(); Thread.sleep(forTimeInterval: 1.2) }
        }

        let save_ = app.buttons["save"].firstMatch
        XCTAssertTrue(save_.waitForExistence(timeout: 5), "no save button")
        XCTAssertTrue(save_.isEnabled, "save is still disabled — endpoint or model incomplete")
        save_.tap()
        Thread.sleep(forTimeInterval: 8.0)
        save(XCUIScreen.main.screenshot(), as: "84-after-save")

        // PROVE it landed. The previous run reported success while saving
        // nothing, because tapping a disabled button is not an error.
        // Assert on the SHEET TITLE, not the phrase. "connect a computer" is
        // also a row label in the where sheet's `get` section, so matching it
        // anywhere reported failure on a run that had in fact succeeded.
        let saved = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "ringzero"))
            .firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10),
                      "no row naming the home server — the provider was not saved")
    }
}
