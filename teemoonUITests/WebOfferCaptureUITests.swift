//
//  WebOfferCaptureUITests.swift
//  teemoonUITests
//
//  Drives the web-answers offer against a REAL model on the device, because the
//  only open question about it cannot be answered by a preview: does the model
//  actually emit a `web_search` call when the tool is attached with no key?
//
//  Runs against ai.teemoon.dev with gemma 4 e2b equipped and NO brave key. Three
//  prompts, two of which should raise the card and one of which must not — a
//  card on the control means the model calls web_search indiscriminately, which
//  would make the feature noise on every turn. That negative case is the point
//  of the run, not an afterthought.
//
//  Generous waits throughout: on-device decode is slow, and a timeout here reads
//  as "no card" — exactly the failure this test exists to distinguish from.
//

import XCTest

final class WebOfferCaptureUITests: XCTestCase {

    /// THE DEV INSTALL, BY NAME. These drive a real model and SEND MESSAGES, so
    /// pointing them at `ai.teemoon.app` would write test conversations into
    /// the developer's actual chat history.
    ///
    /// Naming the bundle here rather than gating on an environment variable is
    /// deliberate, and the second attempt. The first used
    /// `XCTSkipUnless(env["TEEMOON_DEVICE_CAPTURE"] == "1")` with xcodebuild's
    /// TEST_RUNNER_ forwarding — which did not deliver the variable in any of
    /// three forms (on `test`, on `test-without-building`, or baked in at
    /// `build-for-testing`). Three device runs, all skipped, none of them
    /// telling me anything about the app.
    ///
    /// This is better than the guard it replaces anyway: the safety property is
    /// now structural. There is no invocation that points these at the real
    /// app, because they name the one they want. If the dev build is not
    /// installed the launch fails loudly, which is the correct outcome — far
    /// better than a silent skip that looks like a pass.
    private static let devBundleID = "ai.teemoon.dev"
    /// A THIRD install, `ai.teemoon.fresh`, kept permanently empty so first run
    /// can be looked at without destroying the dev app's state — its 2.5 GB
    /// gemma download, four pasted API keys, and dev conversations all live in
    /// `ai.teemoon.dev`'s container, and uninstalling to get a clean slate
    /// takes every one of them.
    static let freshBundleID = "ai.teemoon.fresh"

    private func devApp() -> XCUIApplication {
        XCUIApplication(bundleIdentifier: Self.devBundleID)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func save(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Types into the composer and sends. Returns false if the composer can't be
    /// found, so the caller can fail with a useful reason instead of a timeout.
    @discardableResult
    private func send(_ prompt: String, in app: XCUIApplication) -> Bool {
        // The real identifiers, read off ChatView — not guessed by element type.
        let field = app.descendants(matching: .any)["chat.composer"]
        guard field.waitForExistence(timeout: 15) else { return false }
        field.tap()
        field.typeText(prompt)
        Thread.sleep(forTimeInterval: 0.6)

        // The send button is disabled until the composer has text, so it only
        // becomes hittable after typing.
        let send = app.buttons["chat.send"]
        guard send.waitForExistence(timeout: 5) else { return false }
        send.tap()
        return true
    }

    /// Waits for the offer card, polling rather than sleeping a fixed span, so a
    /// fast answer doesn't cost the full budget and a slow one still gets seen.
    private func waitForOffer(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let card = app.descendants(matching: .any)["chat.webSearchOffer"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if card.exists { return true }
            Thread.sleep(forTimeInterval: 1.0)
        }
        return false
    }

    func testOfferAppearsForTimeSensitiveQuestion() throws {
        let app = devApp()
        app.launch()
        save("01-launch")

        XCTAssertTrue(send("what's the weather in tokyo right now?", in: app),
                      "composer not found — nothing else in this test can run")
        save("02-sent")

        // Long: on-device prefill plus decode, and the card only lands after the
        // turn finishes.
        let appeared = waitForOffer(in: app, timeout: 180)
        Thread.sleep(forTimeInterval: 1.5)
        save(appeared ? "03-offer-shown" : "03-no-offer")

        // Recorded, not asserted. A missing card here is a real finding about
        // gemma e2b's tool-calling, and failing the run would hide the
        // screenshot that shows what it did instead.
        if !appeared {
            print("NO OFFER: model did not emit web_search for a weather question")
        }
    }

    /// THE REPORTED REPRO: ask the same time-sensitive question twice, declining in
    /// between. The card appeared the first time and not the second.
    ///
    /// The suspect is not the view. On turn two the thread already contains the
    /// model's own refusal AND the tool result saying search is unconfigured, so
    /// a small model can simply repeat itself without calling `web_search`
    /// again — and no call means no card, correctly. If that is what happens,
    /// the bug is that teemoon forgets a turn WANTED the web the moment the
    /// model stops asking twice.
    func testOfferOnSecondAskAfterDeclining() throws {
        let app = devApp()
        app.launch()

        XCTAssertTrue(send("what's the weather in tokyo right now?", in: app),
                      "composer not found")
        let first = waitForOffer(in: app, timeout: 180)
        Thread.sleep(forTimeInterval: 1.0)
        save(first ? "20-first-ask-offer" : "20-first-ask-NO-offer")
        XCTAssertTrue(first, "the first ask did not raise the card — repro invalid")

        // Decline, exactly as he did.
        // BY LABEL, not identifier. The card sets `chat.webSearchOffer` on its
        // container and SwiftUI propagates that down, so child buttons report
        // the container's identifier and the ones set on the buttons never
        // survive. Verified from the failure's element dump.
        //
        // "dismiss" since the "not now" button became an X in the corner —
        // declining is leaving, not a second choice of equal weight.
        let notNow = app.buttons.matching(
            NSPredicate(format: "label == %@", "dismiss")).firstMatch
        XCTAssertTrue(notNow.waitForExistence(timeout: 5), "dismiss button missing")
        notNow.tap()
        Thread.sleep(forTimeInterval: 1.0)
        save("21-after-declining")

        // Same question again, same thread.
        XCTAssertTrue(send("what's the weather in tokyo right now?", in: app),
                      "composer not found on second ask")
        let second = waitForOffer(in: app, timeout: 180)
        Thread.sleep(forTimeInterval: 1.5)
        save(second ? "22-second-ask-offer" : "22-second-ask-NO-offer")

        // Recorded, not asserted — the screenshot is the finding either way, and
        // failing here would bury what the model actually did on turn two.
        print("SECOND ASK OFFER: \(second)")
    }

    /// FIX 2 ON THE DEVICE. Three properties, in the order a user meets them:
    /// the card appears; a LATER message does not erase it (the reported bug);
    /// declining removes it and stops the thread offering again.
    func testOfferSurvivesLaterTurnsThenDeclines() throws {
        let app = devApp()
        app.launch()
        let card = app.descendants(matching: .any)["chat.webSearchOffer"]

        XCTAssertTrue(send("what's the weather in tokyo right now?", in: app),
                      "composer not found")
        XCTAssertTrue(waitForOffer(in: app, timeout: 180), "no card on the first ask")
        Thread.sleep(forTimeInterval: 1.0)
        save("30-offer-shown")

        // THE BUG. Previously this next message wiped the card.
        XCTAssertTrue(send("write me a haiku about rain", in: app),
                      "composer not found on the second send")
        // Wait for the haiku to finish rather than for the card, which is
        // already on screen — polling `exists` would return instantly and
        // prove nothing.
        Thread.sleep(forTimeInterval: 45)
        save("31-after-an-unrelated-turn")
        XCTAssertTrue(card.exists,
                      "the card was erased by a later message — fix 2 regressed")
        // And exactly ONE: a second card here would be the nagging version.
        //
        // Counted by the "set it up" BUTTON, not by the card's identifier.
        // SwiftUI propagates `chat.webSearchOffer` to the card's children, so
        // both buttons also report it and one card counts as three. Cost a run
        // to rediscover, having already hit it on `not now`.
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label == %@", "get a key")).count, 1,
                       "more than one card — the offer is following the conversation down")

        let notNow = app.buttons.matching(
            NSPredicate(format: "label == %@", "dismiss")).firstMatch
        XCTAssertTrue(notNow.waitForExistence(timeout: 10), "not now button missing")
        notNow.tap()
        Thread.sleep(forTimeInterval: 1.5)
        save("32-after-declining")
        XCTAssertFalse(card.exists, "declining did not remove the card")

        // Declined: the thread should neither offer again nor attach the tool.
        XCTAssertTrue(send("what's the weather in tokyo right now?", in: app),
                      "composer not found on the third send")
        let cameBack = waitForOffer(in: app, timeout: 90)
        Thread.sleep(forTimeInterval: 1.0)
        save(cameBack ? "33-RETURNED-after-decline" : "33-stays-declined")
        XCTAssertFalse(cameBack, "the card came back after being declined")
    }

    /// TEST 1: the card's primary action actually arrives somewhere.
    ///
    /// `set it up` and the composer chip must reach the SAME screen — two entry
    /// points to one destination. If they ever diverge, the card teaches a
    /// route the chip does not take.
    /// The deep link PUSHES onto the settings stack, so the search screen shows
    /// a back button and `settings.close` exists only at the root. Getting out
    /// is therefore two taps, not one.
    private func dismissSettings(in app: XCUIApplication) {
        let back = app.buttons["BackButton"]
        if back.waitForExistence(timeout: 3) { back.tap() }
        let close = app.buttons["settings.close"]
        if close.waitForExistence(timeout: 5) { close.tap() }
        Thread.sleep(forTimeInterval: 1.2)
    }

    func testSetItUpReachesSearchSettings() throws {
        let app = devApp()
        app.launch()
        let searchScreen = app.descendants(matching: .any)["settings.search"]

        // A. from the CHIP, which is reachable without generating anything.
        let chip = app.buttons["chat.webSearchChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "web chip missing")
        chip.tap()
        XCTAssertTrue(searchScreen.waitForExistence(timeout: 10),
                      "the chip did not reach search settings")
        save("40-chip-to-search")

        dismissSettings(in: app)

        // NO CARD LEG ANY MORE. The offer card used to route here via "set it
        // up"; under design C setup happens IN the card, so the chip is the
        // only entrance to this screen and the card is not a second one.
        // Removing this rather than rewriting it: a test that reached settings
        // from the card would be asserting behaviour that was deliberately
        // deleted.
    }

    func testOfferAboveARealAnswer() throws {
        let app = devApp()
        app.launch()

        XCTAssertTrue(send("what's the most distant galaxy ever confirmed?", in: app),
                      "composer not found")
        let appeared = waitForOffer(in: app, timeout: 180)
        Thread.sleep(forTimeInterval: 2.0)
        save(appeared ? "50-answerable-offer" : "50-answerable-NO-offer")

        // Recorded, not asserted, on both counts: whether the model chose to
        // search an answerable question is a finding about the model, and the
        // screenshot carries whether the answer above it is real.
        print("ANSWERABLE QUESTION OFFER: \(appeared)")
    }

    /// LOOK, DO NOT TOUCH. Launches and captures one frame.
    ///
    /// Exists because the obvious way to check whether search is enabled — tap
    /// the chip — TOGGLES it once a key is configured. Reading the state must
    /// not change it.
    /// Opens the Where sheet on the empty install, where `get` shows the browse
    /// rows — the only place the e2ee tag appears.
    func testCaptureWhereGet() throws {
        let app = XCUIApplication(bundleIdentifier: Self.freshBundleID)
        app.launch()
        let chip = app.buttons["chat.whereChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "where chip missing")
        chip.tap()
        Thread.sleep(forTimeInterval: 2.5)
        save("90-where-get")
    }

    func testCaptureFreshInstall() throws {
        let app = XCUIApplication(bundleIdentifier: Self.freshBundleID)
        app.launch()
        Thread.sleep(forTimeInterval: 3.0)
        save("80-fresh-first-run")
        let chip = app.buttons["chat.whereChip"]
        print("WHERE CHIP: \(chip.waitForExistence(timeout: 10) ? chip.label : "not found")")
        let web = app.buttons["chat.webSearchChip"]
        print("WEB CHIP: \(web.exists ? web.label + " / " + web.value.debugDescription : "not found")")
    }

    func testCaptureCurrentState() throws {
        let app = devApp()
        app.launch()
        Thread.sleep(forTimeInterval: 2.5)
        save("70-current-state")

        // The chip's accessibility label carries the state in words, which
        // survives into the log even if nobody opens the screenshot.
        let chip = app.buttons["chat.webSearchChip"]
        if chip.waitForExistence(timeout: 10) {
            print("WEB CHIP LABEL: \(chip.label)")
        } else {
            print("WEB CHIP: not found")
        }
    }

    func testControlPromptRaisesNoOffer() throws {
        let app = devApp()
        app.launch()

        XCTAssertTrue(send("write me a haiku about rain", in: app),
                      "composer not found")

        // Shorter budget: this asserts ABSENCE, so the wait only has to outlast
        // a normal answer, not a worst-case one.
        let appeared = waitForOffer(in: app, timeout: 90)
        Thread.sleep(forTimeInterval: 1.5)
        save(appeared ? "10-control-FALSE-POSITIVE" : "10-control-clean")

        XCTAssertFalse(appeared,
                       "the model called web_search for a haiku — it is calling it "
                       + "indiscriminately, which makes the card noise on every turn")
    }
}
