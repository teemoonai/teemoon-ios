//
//  MacBaselineCaptureUITests.swift
//  teemoonUITests
//
//  GROUND TRUTH FOR THE MAC.
//
//  The parity loop's direction rule is that the SHIPPED BUILD is the source of
//  truth and Claude Design is a mirror plus a sandbox. That rule needs captures
//  to point at, and the two existing rigs are both iOS: DesignTour flags go
//  through `simctl launch`, and the baseline transcript rig drives the phone.
//  Neither runs on macOS, so the Mac had no baseline at all — every judgement
//  about how it looks was being made from memory.
//
//  This is the Mac equivalent: walk the real app, screenshot each state, and
//  attach `app.debugDescription` alongside. Per that doc the accessibility dump
//  is the lossless copy/structure contract — screenshots carry style, the
//  transcript carries content, and neither is trusted to do the other's job.
//
//      xcodebuild test -destination 'platform=macOS,arch=arm64' \
//        -only-testing:teemoonUITests/MacBaselineCaptureUITests
//
//  Attachments come out with:
//      xcrun xcresulttool export attachments --path <.xcresult> --output-path <dir>
//
//  Captures WINDOWS, never the screen: `XCUIScreenshot` is display-scoped on
//  macOS, so a screen capture would photograph the developer's other windows
//  into a shared artifact. Takes over the display while it runs, same as the
//  other Mac UI suites.
//

#if os(macOS)

import XCTest

final class MacBaselineCaptureUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        // Fixture conversations, into an in-memory store. Before this the suite
        // ran against the developer's real chat history, so every capture
        // contained real thread titles and could not be checked in.
        app.launchEnvironment["UITEST_SEED_THREADS"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15),
                      "no window to capture")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private var composer: XCUIElement { app.textFields["chat.composer"] }

    /// Screenshot + element transcript under one name.
    private func capture(_ name: String, element: XCUIElement? = nil) {
        let target = element ?? app.windows.firstMatch
        let shot = XCTAttachment(screenshot: target.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)

        let transcript = XCTAttachment(string: target.debugDescription)
        transcript.name = "\(name) — transcript"
        transcript.lifetime = .keepAlways
        add(transcript)
    }

    /// The state the app opens in, and the one a new user judges it by.
    func testCaptureEmptyChat() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        capture("mac-01-empty-chat")
    }

    /// A thread open, which is where a user spends nearly all their time and
    /// which had never been captured.
    func testCaptureOpenThread() throws {
        // Matched on the first USER MESSAGE, not on `thread.title`. The sidebar
        // renders the opening message and its reply as the row, so a fixture's
        // title never appears there — and the row text is truncated for display,
        // which is why this is a prefix match rather than an equality one.
        let row = app.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH 'if the server'")).firstMatch
        guard row.waitForExistence(timeout: 10) else {
            throw XCTSkip("fixture threads did not seed")
        }
        row.click()
        capture("mac-06-open-thread")
    }

    /// THE WIDE WINDOW, WHICH IS WHERE MAC LAYOUT ACTUALLY GETS TESTED.
    ///
    /// Every other capture here uses the 1000pt default, and at that size the
    /// content pane is ~750pt — narrow enough to hide any measure problem. A Mac
    /// window is resizable by definition and people maximise them, so a layout
    /// that only holds at its default size does not hold.
    func testCaptureWideWindow() throws {
        let row = app.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH 'if the server'")).firstMatch
        guard row.waitForExistence(timeout: 10) else {
            throw XCTSkip("fixture threads did not seed")
        }
        row.click()

        // Dragged, not zoomed. This window has no zoom button — its green
        // traffic light is `_XCUI:FullScreenWindow`, per the element transcript
        // — and full screen changes the chrome enough that it would not be the
        // same capture. Dragging the bottom-right corner is what a person does.
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        corner.press(forDuration: 0.2,
                     thenDragTo: corner.withOffset(CGVector(dx: 480, dy: 0)))

        // Let the zoom animation finish before photographing it.
        let settled = expectation(description: "window zoomed")
        var width = window.frame.width
        for _ in 0..<20 {
            let next = window.frame.width
            if next > 1200, abs(next - width) < 0.5 { settled.fulfill(); break }
            width = next
            usleep(250_000)
        }
        wait(for: [settled], timeout: 1)

        capture("mac-07-wide-window")
    }

    /// Relaunch with a forced attestation state.
    ///
    /// Seven of the ten trust states could not be reached by any fixture, so a
    /// design review could only ever see the happy path. `UITEST_SEED_ATTESTATION`
    /// makes them capturable; this is the harness side of it.
    private func relaunch(attestation: String) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_THREADS"] = "1"
        app.launchEnvironment["UITEST_SEED_ATTESTATION"] = attestation
        app.launch()
        _ = app.windows.firstMatch.waitForExistence(timeout: 15)
    }

    /// THE EXPERT RUNG — the chain, the digests and the verify script.
    ///
    /// The most valuable missing frame: every previous capture of the inspector
    /// showed the EVERYDAY rung, which is the same content as the popover. The
    /// expert rung is what the window exists for and had never been seen.
    func testCaptureExpertRung() throws {
        let chip = app.buttons["chat.trustChip"]
        guard chip.waitForExistence(timeout: 10) else { throw XCTSkip("no trust chip") }
        chip.click()
        guard app.popovers.firstMatch.waitForExistence(timeout: 5) else {
            throw XCTSkip("popover did not open")
        }
        // `show the proof…` now asks for the expert rung specifically.
        app.popovers.firstMatch.buttons["attestation.showProof"].click()
        let inspector = app.windows["who can read this?"]
        guard inspector.waitForExistence(timeout: 8) else { throw XCTSkip("no inspector") }
        usleep(1_200_000)
        capture("mac-10-expert-rung", element: inspector)
    }

    func testCaptureChipVerifying() throws {
        relaunch(attestation: "verifying")
        guard app.buttons["chat.trustChip"].waitForExistence(timeout: 10) else {
            throw XCTSkip("no trust chip")
        }
        capture("mac-11-chip-verifying")
    }

    func testCaptureChipHardFailure() throws {
        relaunch(attestation: "hardFailure")
        guard app.buttons["chat.trustChip"].waitForExistence(timeout: 10) else {
            throw XCTSkip("no trust chip")
        }
        capture("mac-12-chip-hard-failure")
    }

    /// Soft degradation. Must be visibly distinct from the frame above — they
    /// were identical until a design review measured them.
    func testCaptureChipDegraded() throws {
        relaunch(attestation: "degraded")
        guard app.buttons["chat.trustChip"].waitForExistence(timeout: 10) else {
            throw XCTSkip("no trust chip")
        }
        capture("mac-13-chip-degraded")
    }

    /// The chip when the model runs here — the one state `UITEST_SEED_ATTESTATION`
    /// cannot produce, because it is decided by the PROVIDER (`isLocal`) rather
    /// than by an attestation result. Seeded through the on-device door instead.
    func testCaptureChipOnThisMac() throws {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_THREADS"] = "1"
        app.launchEnvironment["UITEST_SEED_ONDEVICE_MODEL"] = "litert-community/gemma-4-E2B-it-litert-lm"
        app.launch()
        guard app.buttons["chat.trustChip"].waitForExistence(timeout: 15) else {
            throw XCTSkip("no trust chip")
        }
        capture("mac-15-chip-on-this-mac")
    }

    func testCaptureChipNotAttestable() throws {
        relaunch(attestation: "none")
        guard app.buttons["chat.trustChip"].waitForExistence(timeout: 10) else {
            throw XCTSkip("no trust chip")
        }
        capture("mac-14-chip-not-attestable")
    }

    /// The trust chip's popover — the everyday rung, which had no Mac surface
    /// at all until now.
    func testCaptureTrustPopover() throws {
        let chip = app.buttons["chat.trustChip"]
        guard chip.waitForExistence(timeout: 10) else { throw XCTSkip("no trust chip") }
        chip.click()
        guard app.popovers.firstMatch.waitForExistence(timeout: 5) else {
            throw XCTSkip("popover did not open")
        }
        usleep(600_000)
        capture("mac-08-trust-popover")
    }

    /// The expert rung in its own window.
    func testCaptureAttestationInspector() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        app.typeKey("i", modifierFlags: .command)
        let inspector = app.windows["who can read this?"]
        guard inspector.waitForExistence(timeout: 8) else {
            throw XCTSkip("inspector did not open")
        }
        usleep(800_000)
        capture("mac-09-attestation-inspector", element: inspector)
    }

    /// A composer with content: send enabled, and whatever the chrome does
    /// when the field grows.
    func testCaptureComposerWithText() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.click()
        composer.typeText("what does an attested model actually prove?")
        capture("mac-02-composer-filled")
    }

    /// The Where sheet — the app's most designed surface.
    func testCaptureWhereSheet() throws {
        let chip = app.buttons["chat.whereChip"]
        guard chip.waitForExistence(timeout: 10) else {
            throw XCTSkip("no Where chip in this state")
        }
        chip.click()
        // Sheet OR popover. On macOS this is now a popover anchored to the
        // chip, which is not an `XCUIElement` of type sheet — the first version
        // of this looked only for `app.sheets` and silently SKIPPED once the
        // container changed, reporting nothing rather than a regression.
        var sheet = app.sheets.firstMatch
        if !sheet.waitForExistence(timeout: 3) {
            sheet = app.popovers.firstMatch
        }
        guard sheet.waitForExistence(timeout: 5) else {
            throw XCTSkip("Where picker did not open as a sheet or a popover")
        }

        // WAIT FOR IT TO STOP MOVING. `waitForExistence` returns the moment the
        // sheet is in the tree, which is the START of its presentation — a
        // capture taken there photographs a half-open sheet and looks exactly
        // like a clipped one. Settle on a stable height before believing
        // anything about what is or isn't visible.
        var lastHeight = sheet.frame.height
        var stableFrames = 0
        for _ in 0..<40 {
            usleep(100_000)
            let height = sheet.frame.height
            stableFrames = abs(height - lastHeight) < 0.5 ? stableFrames + 1 : 0
            lastHeight = height
            if stableFrames >= 5 { break }
        }

        capture("mac-03-where-sheet")
    }

    /// Settings is its own window on macOS, so it is its own capture.
    func testCaptureSettingsWindow() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let before = app.windows.count
        app.typeKey(",", modifierFlags: .command)

        let opened = NSPredicate(format: "count > %d", before)
        expectation(for: opened, evaluatedWith: app.windows, handler: nil)
        waitForExpectations(timeout: 5, handler: nil)

        // FIND IT BY WHAT IT CONTAINS, NOT BY POSITION.
        //
        // This was `windows.element(boundBy: count - 1)`, which returned the
        // CHAT window — and the mistake was invisible in the screenshot, because
        // a window screenshot captures that window's rect from the display and
        // the settings window happened to be sitting inside it. The attached
        // transcript is what gave it away: it described the chat window. Style
        // via screenshots, content via transcripts, and neither trusted to do
        // the other's job.
        var settings: XCUIElement?
        for i in 0..<app.windows.count {
            let candidate = app.windows.element(boundBy: i)
            if candidate.buttons["appearance"].exists { settings = candidate; break }
        }
        let settingsWindow = try XCTUnwrap(settings, "no settings window with tabs")
        capture("mac-04-settings", element: settingsWindow)
        let settings2 = settingsWindow

        // Every tab, not just the one it opens on. The tabs host views written
        // for a pushed iOS list, so each needs looking at in its new container.
        for tab in ["appearance", "chats", "search", "places & keys", "app"] {
            let button = settings2.buttons[tab]
            guard button.exists else { continue }
            button.click()
            capture("mac-04-settings-\(tab.replacingOccurrences(of: " & ", with: "-"))",
                    element: settings2)
        }
    }

    /// The menu bar is Mac-only surface area and reads as a port when thin.
    ///
    /// CAPTURES THE OPENED MENU, NOT THE MENU BAR. The first version photographed
    /// `app.menuBars.firstMatch`, which is the whole system bar — so the checked-in
    /// baseline contained the Apple menu's "Log Out <username>…", the clock, and
    /// whatever menu extras the machine happens to run. None of that is teemoon's
    /// design, and this directory is bound for an open-source repo. Scoping to the
    /// dropdown removes the leak and makes a better reference besides: the thing
    /// under review is the menu's contents.
    func testCaptureMenus() throws {
        for menu in ["teemoon", "File", "Edit", "View", "Window", "Help"] {
            let item = app.menuBars.menuBarItems[menu]
            guard item.exists else { continue }
            item.click()

            let dropdown = item.menus.firstMatch
            guard dropdown.waitForExistence(timeout: 5) else {
                item.typeKey(.escape, modifierFlags: [])
                continue
            }
            capture("mac-05-menu-\(menu.lowercased())", element: dropdown)
            item.typeKey(.escape, modifierFlags: [])
        }
    }
}

#endif
