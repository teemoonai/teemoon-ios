//
//  FirstRunCaptureUITests.swift
//  teemoonUITests
//
//  Drives first run and writes PNGs to the app container, so the flow can be
//  LOOKED AT without a human holding the phone and describing it.
//
//  Why not `simctl io screenshot` from the host: it can capture, but it cannot
//  tap, and the states worth seeing are all one tap deep. Why not AppleScript
//  against the Simulator window: it needs Accessibility permission this machine
//  has not granted to osascript.
//
//  Screenshots land in the app's Documents directory. Pull them with:
//      xcrun simctl get_app_container <sim> ai.teemoon.app data
//
//  Runs against a CLEAN install — uninstall first, or the provider list from a
//  previous run makes `showsFirstRun` false and the capture is of the wrong
//  screen entirely.
//

import XCTest

final class FirstRunCaptureUITests: XCTestCase {

    /// Writes into the APP's container rather than the test runner's, so one
    /// `get_app_container` call finds everything.
    private func save(_ shot: XCUIScreenshot, as name: String, app: XCUIApplication) {
        // The attachment is what shows up in the .xcresult; the file is what a
        // human (or a model) can actually open without xcresulttool.
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// iOS shows one-time swipe-typing education over the keyboard. On an
    /// erased sim it photobombs whichever capture happens to focus a field
    /// first, and the `DidShowContinuousPathIntroduction` defaults keys that
    /// claim to pre-dismiss it did not. So dismiss it the honest way: when the
    /// overlay is on screen, tap its own Continue.
    private func dismissKeyboardIntro(_ app: XCUIApplication) {
        let intro = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "sliding your finger"))
            .firstMatch
        let cont = app.buttons["Continue"].firstMatch
        if intro.exists && cont.exists {
            cont.tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    func test1FirstRunFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-capture"]
        app.launch()

        // 1 — the chat surface with nothing configured.
        save(XCUIScreen.main.screenshot(), as: "01-first-run-chat", app: app)

        // The chip is the only affordance on this screen. If this fails, the
        // capture is worthless and the reason is worth knowing immediately.
        // `.firstMatch`, not the bare query. The chip resolves to a nested
        // pair — Button(chat.whereChip) → Button → Button(chat.whereChip) —
        // because the identifier is applied to a control XCTest reads as a
        // PopUpButton ("automation type mismatch: computed Button from legacy
        // attributes vs PopUpButton from modern attribute"). `waitForExistence`
        // tolerates two matches, so the failure surfaces later and elsewhere,
        // as `tap()` raising "multiple matching elements found".
        let chip = app.buttons["chat.whereChip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "the where chip is missing — first run has no other control")

        // No mid-settle / settled chip pair anymore: the fill lands before the
        // first screenshot can, so both frames photographed the same screen —
        // and duplicated test3's opening frame on top. One state, one frame.
        Thread.sleep(forTimeInterval: 1.2)

        // 2 — open the sheet, but don't save it here: this is the same screen
        // test3 captures as 21-onboarding-2-start-here, and it shot as a
        // byte-identical duplicate. One state, one owner — the sequence owns it.
        chip.tap()
        Thread.sleep(forTimeInterval: 1.4)

        // 3 — scrolled, to see whether anything is below the fold at this detent.
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.8)
        save(XCUIScreen.main.screenshot(), as: "05-where-sheet-scrolled", app: app)
    }

    /// THE EDGE CASE: type and send with nothing configured.
    ///
    /// Deleting the first-run wall means the composer is live from the first
    /// second, so this is now a path a real user takes — and it is the one place
    /// the app still has to say "you cannot do that yet" rather than just
    /// working. Worth seeing what it actually says.
    func test2SendWithNothingConfigured() throws {
        let app = XCUIApplication()
        app.launch()

        let field = app.textViews.firstMatch.exists
            ? app.textViews.firstMatch
            : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no composer to type into")

        field.tap()
        dismissKeyboardIntro(app)
        field.typeText("what is the capital of france?")
        Thread.sleep(forTimeInterval: 0.5)
        save(XCUIScreen.main.screenshot(), as: "10-typed-nothing-configured", app: app)

        app.buttons["chat.send"].tap()
        Thread.sleep(forTimeInterval: 1.2)
        save(XCUIScreen.main.screenshot(), as: "11-send-blocked", app: app)

        // Follow the alert's own recommendation and see where it lands. This is
        // the path that forces `filter = .cloud`, which would skip the
        // first-run screen entirely — the thing worth checking.
        let addProvider = app.buttons["add a provider"]
        if addProvider.waitForExistence(timeout: 3) {
            addProvider.tap()
            Thread.sleep(forTimeInterval: 1.4)
            // No screenshot: the alert lands on the plain first-run Where
            // sheet — byte-identical to 21-onboarding-2-start-here. Assert the
            // landing instead of duplicating the frame.
            XCTAssertTrue(app.staticTexts["where"].waitForExistence(timeout: 5),
                          "add-a-provider did not land on the Where sheet")
        }
    }

    /// The onboarding flow as a SEQUENCE, for teemoon.ai.
    ///
    /// The site was illustrating "start with no key" with hand-built DOM
    /// mockups, which drifted from the app within one release — the mockup
    /// showed the all/phone/home/cloud picker, which is not what first run
    /// actually presents. These four frames are the real path, in order:
    /// nothing configured → where → download started → downloading.
    ///
    /// Deliberately does NOT wait for the download to finish. 2.4 GB is minutes
    /// of wall clock and the interesting frame is the one with a live
    /// percentage in it, which exists from the first second.
    ///
    /// Run against a CLEAN install, same as test1FirstRunFlow — an installed
    /// model turns the "start here" card into a ready row and there is nothing
    /// left to capture.
    func test3OnboardingFlowCapture() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-capture"]
        app.launch()

        // 1 — the composer, both chips, nothing set up. "choose where" carries
        // the accent fill here; that is the whole call to action on first run.
        Thread.sleep(forTimeInterval: 1.4)
        save(XCUIScreen.main.screenshot(), as: "20-onboarding-1-nothing-configured", app: app)

        // `.firstMatch`, not the bare query. The chip resolves to a nested
        // pair — Button(chat.whereChip) → Button → Button(chat.whereChip) —
        // because the identifier is applied to a control XCTest reads as a
        // PopUpButton ("automation type mismatch: computed Button from legacy
        // attributes vs PopUpButton from modern attribute"). `waitForExistence`
        // tolerates two matches, so the failure surfaces later and elsewhere,
        // as `tap()` raising "multiple matching elements found".
        let chip = app.buttons["chat.whereChip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "the where chip is missing — there is no way into the flow")
        chip.tap()
        Thread.sleep(forTimeInterval: 1.4)

        // 2 — "start here": one download card, then "other places".
        save(XCUIScreen.main.screenshot(), as: "21-onboarding-2-start-here", app: app)

        let download = app.buttons["where.firstRun.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5),
                      "no first-run download button — the sheet is in some other state")
        download.tap()

        // 3 — the moment after the tap, before bytes have moved far.
        Thread.sleep(forTimeInterval: 1.5)
        save(XCUIScreen.main.screenshot(), as: "22-onboarding-3-download-started", app: app)

        // 4 — a live percentage. Ten seconds is enough for a real number on any
        // reasonable connection, and short enough not to slow the suite down.
        Thread.sleep(forTimeInterval: 10)
        save(XCUIScreen.main.screenshot(), as: "23-onboarding-4-downloading", app: app)
    }

    /// The PAYOFF frame: the where sheet once a model is actually installed.
    ///
    /// Separate from test3OnboardingFlowCapture because it has to wait out a
    /// 2.4 GB download, which is minutes, and there is no reason to make the
    /// three cheap frames wait behind it.
    ///
    /// This is the state the site's Where section wants: the sheet is no longer
    /// the first-run "start here" card, it is the populated picker — the model
    /// sits under "ready now", and the other tiers are reachable below it.
    ///
    /// Clean install required, same as the others.
    func test4WhereSheetPopulatedCapture() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-capture"]
        app.launch()

        // `.firstMatch`, not the bare query. The chip resolves to a nested
        // pair — Button(chat.whereChip) → Button → Button(chat.whereChip) —
        // because the identifier is applied to a control XCTest reads as a
        // PopUpButton ("automation type mismatch: computed Button from legacy
        // attributes vs PopUpButton from modern attribute"). `waitForExistence`
        // tolerates two matches, so the failure surfaces later and elsewhere,
        // as `tap()` raising "multiple matching elements found".
        let chip = app.buttons["chat.whereChip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no where chip")
        chip.tap()
        Thread.sleep(forTimeInterval: 1.2)

        // The transfer only advances while the app is alive: when the runner
        // exits, the app is torn down and the download stops wherever it got to.
        // So the wait has to happen HERE, in-test, rather than out of process.
        //
        // Two separate waits, and collapsing them into one is the bug this
        // comment exists to prevent. Polling only for "has it finished?" is true
        // on the very first tick — the row has not repainted into its
        // downloading state yet — so the test sails past, captures three seconds
        // after the tap, and produces a screenshot of a model that never
        // downloaded. Wait for it to START, then wait for it to FINISH.
        //
        // Do NOT poll the where chip either. Its accessibility label reads
        // "gemma 4 e2b, on this device" both when the model is installed and
        // when it is sitting at "not downloaded — tap to resume". Visible sheet
        // text is the only honest signal.
        /// Any visible text meaning "this model is not usable yet".
        ///
        /// Predicate query, NOT allElementsBoundByIndex: the percentage
        /// repaints every few hundred ms, so enumerating the snapshot and
        /// then reading `.label` off each element throws
        /// "No matches found for Element at index N" the moment a row is
        /// replaced mid-iteration. `.firstMatch.exists` re-resolves instead.
        func stillPending() -> Bool {
            let p = NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                "downloading", "not downloaded")
            return app.staticTexts.matching(p).firstMatch.exists
        }

        let download = app.buttons["where.firstRun.download"]
        let resume = app.buttons["where.row.resume"].firstMatch
        if download.waitForExistence(timeout: 5) {
            download.tap()

            // Wait for the download to visibly START before waiting for it to
            // finish. Polling only "has it finished?" is true on the very first
            // tick — the row has not repainted into its downloading state yet.
            var started = false
            let startBy = Date().addingTimeInterval(60)
            while Date() < startBy {
                if stillPending() { started = true; break }
                Thread.sleep(forTimeInterval: 1)
            }
            XCTAssertTrue(started, "download never visibly started after the tap")
        } else if resume.waitForExistence(timeout: 3) {
            // Interrupted earlier run — test3OnboardingFlowCapture starts the
            // download and then exits, which tears the app down and stops the
            // transfer wherever it got to. The row now reads "not downloaded —
            // tap to resume", and that is a designed one-click affordance, not
            // an error state: USE it. This branch used to only assert, which
            // is how three wrong-state captures shipped on 2026-08-05.
            //
            // By ID, never by matched text: the label query resolved to an
            // occluded twin of the caption and the tap opened "connect a
            // computer" one row below. Ids are the contract.
            resume.tap()
            Thread.sleep(forTimeInterval: 2)
        }

        // Fail fast if a tap above navigated somewhere unexpected. The settle
        // loop below polls `exists`, which is hierarchy membership, not
        // visibility — a form covering the sheet leaves "not downloaded" in the
        // hierarchy and the loop grinds its full 15 minutes staring at the
        // wrong screen. Observed, not hypothetical.
        XCTAssertFalse(app.staticTexts["connect a computer"].exists,
                       "a tap opened the connect-a-computer form — wrong element hit")
        guard !app.staticTexts["connect a computer"].exists else { return }

        // Either branch (or neither, if a prior run finished) may leave a
        // download in flight — wait it out before capturing. This is the wait
        // whose absence produced a "populated" sheet reading "not downloaded".
        if stillPending() {
            let deadline = Date().addingTimeInterval(900)
            var settled = false
            while Date() < deadline {
                if !stillPending() { settled = true; break }
                Thread.sleep(forTimeInterval: 5)
            }
            XCTAssertTrue(settled,
                          "model still shows downloading/not-downloaded after 15 minutes — "
                          + "capturing now would ship a stalled-download screenshot")
            guard settled else { return }  // a stalled capture is worse than none
        }

        // Back to the chat, so both branches start the capture from one place.
        //
        // Conditional: when a first-run download completes, the app equips the
        // model and dismisses the sheet itself, so there is no close button left
        // to press. Only the already-installed branch still needs the tap.
        let close = app.buttons["xmark"].firstMatch
        if close.exists {
            close.tap()
            Thread.sleep(forTimeInterval: 1.2)
        }

        Thread.sleep(forTimeInterval: 2)
        dismissKeyboardIntro(app)
        save(XCUIScreen.main.screenshot(), as: "30-model-ready-chat", app: app)

        // The populated sheet — this is the frame the site needs.
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no where chip to reopen the sheet")
        chip.tap()
        Thread.sleep(forTimeInterval: 1.6)
        save(XCUIScreen.main.screenshot(), as: "31-where-sheet-populated", app: app)

        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.9)
        save(XCUIScreen.main.screenshot(), as: "32-where-sheet-populated-scrolled", app: app)
    }
}
