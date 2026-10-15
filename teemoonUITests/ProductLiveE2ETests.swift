//
//  ProductLiveE2ETests.swift
//  teemoonUITests
//
//  Live product E2E — real near.ai endpoints. The key is NEVER an env var:
//  a `--uitesting` near.ai seed copies `~/.NEAR_AI_API_KEY` from the Mac
//  into the sim Keychain when that slot is empty. Skip on 401.
//
//  Completions spend money. Attestation does not.
//
//    xcodebuild test -project teemoon.xcodeproj -scheme teemoon \
//      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//      -only-testing:teemoonUITests/ProductLiveE2ETests
//

import XCTest

final class ProductLiveE2ETests: XCTestCase {

    private static let model = "z-ai/glm-5.3-flash"

    override func setUp() { continueAfterFailure = false }

    /// Attestation endpoints only — no completion. The everyday sheet must
    /// name the seeded model once the live record lands.
    func testLiveAttestationSheetNamesTheModel() throws {
        try ProductE2E.requireHostKey(forPreset: "nearai")
        let app = ProductE2E.launchNearAI(model: Self.model)
        let title = ProductE2E.titleBlock(app)
        XCTAssertTrue(title.waitForExistence(timeout: 15), "title block missing")
        title.tap()
        XCTAssertTrue(app.staticTexts["who can read this?"].waitForExistence(timeout: 8),
                      "everyday sheet did not open")
        // The chip already says glm-5.2. The live record's claim is the seal.
        let sealed = ProductE2E.elementContaining(app, "encrypted to")
        if !sealed.waitForExistence(timeout: 45) {
            ProductE2E.attachScreenshot(app, name: "live-attestation-no-seal", to: self)
            XCTFail("live attestation never reached a sealed hero (title=\(ProductE2E.titleLabel(app)))")
            return
        }
        XCTAssertFalse(ProductE2E.titleLooksMismatched(app),
                       "fresh session already mismatched: \(ProductE2E.titleLabel(app))")
        ProductE2E.attachScreenshot(app, name: "live-attestation-sheet", to: self)
    }

    /// Two real generations. This is the phone bug: the second signed reply
    /// must not stamp "didn't check out" or "sending blocked".
    func testLiveTwoTurnReplySignatureChecksOut() throws {
        try ProductE2E.requireHostKey(forPreset: "nearai")
        let app = ProductE2E.launchNearAI(model: Self.model)
        XCTAssertTrue(ProductE2E.titleBlock(app).waitForExistence(timeout: 15))
        if !ProductE2E.waitUntilVerified(app) {
            ProductE2E.attachScreenshot(app, name: "live-not-verified", to: self)
            XCTFail("session never reached end-to-end encrypted (title=\(ProductE2E.titleLabel(app)))")
            return
        }

        let first = "live-e2e-turn-one"
        ProductE2E.typeIntoComposer(app, first)
        ProductE2E.send(app)

        if app.alerts.firstMatch.waitForExistence(timeout: 3) {
            ProductE2E.attachScreenshot(app, name: "live-send-alert", to: self)
            let retry = app.alerts.firstMatch.buttons["retry verification"]
            if retry.exists {
                retry.tap()
                if !ProductE2E.waitUntilVerified(app, timeout: 45) {
                    XCTFail("retry verification did not reach sealed (title=\(ProductE2E.titleLabel(app)))")
                    return
                }
                ProductE2E.send(app)
            } else {
                XCTFail("send raised an alert instead of going out: \(app.alerts.firstMatch.label)")
                return
            }
        }
        let sent = ProductE2E.elementContaining(app, first)
        if !sent.waitForExistence(timeout: 20) {
            ProductE2E.attachScreenshot(app, name: "live-send-never-landed", to: self)
            XCTFail("first prompt never landed (title=\(ProductE2E.titleLabel(app)))")
            return
        }
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 180),
                      "first turn did not settle")
        ProductE2E.attachScreenshot(app, name: "live-1-first-turn", to: self)
        XCTAssertFalse(ProductE2E.titleLooksMismatched(app),
                       "first reply didn't check out: \(ProductE2E.titleLabel(app))")
        XCTAssertFalse(ProductE2E.titleLooksBlocked(app),
                       "session blocked after first turn: \(ProductE2E.titleLabel(app))")

        ProductE2E.sendAndWait(app, "live-e2e-turn-two", timeout: 180)
        ProductE2E.attachScreenshot(app, name: "live-2-second-turn", to: self)

        let label = ProductE2E.titleLabel(app)
        XCTAssertFalse(ProductE2E.titleLooksMismatched(app),
                       "second reply didn't check out: \(label)")
        XCTAssertFalse(ProductE2E.titleLooksBlocked(app),
                       "session hard-blocked after two live turns: \(label)")
    }

    /// Same two-turn live path with the developer debug panel on. The card
    /// must stamp E2EE (the request went out sealed) and land on screen —
    /// this is the layout that used to jerk when the panel popped in.
    func testLiveTwoTurnWithDebugPanelShowsE2EE() throws {
        try ProductE2E.requireHostKey(forPreset: "nearai")
        let app = ProductE2E.launchNearAI(model: Self.model, developerMode: true)
        XCTAssertTrue(ProductE2E.titleBlock(app).waitForExistence(timeout: 15))
        if !ProductE2E.waitUntilVerified(app) {
            ProductE2E.attachScreenshot(app, name: "live-debug-not-verified", to: self)
            XCTFail("session never reached end-to-end encrypted (title=\(ProductE2E.titleLabel(app)))")
            return
        }

        ProductE2E.typeIntoComposer(app, "live-e2e-debug-one")
        ProductE2E.send(app)
        ProductE2E.confirmSendIfAsked(app)
        if !ProductE2E.elementContaining(app, "live-e2e-debug-one").waitForExistence(timeout: 20) {
            ProductE2E.attachScreenshot(app, name: "live-debug-send-never-landed", to: self)
            XCTFail("prompt never landed")
            return
        }
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 180),
                      "first debug-panel turn did not settle")
        XCTAssertTrue(ProductE2E.waitForDebugCardOnScreen(app),
                      "developer mode is on but the debug card never landed on screen")
        // RequestDebugView stamps the seal on the CARD's value: XCUI sees the card as one element and none of its children
        let sealed = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND value == %@", "chat.debugCard", "E2EE")).firstMatch
        XCTAssertTrue(sealed.waitForExistence(timeout: 5),
                      "sealed live turn should stamp E2EE on the debug card")
        XCTAssertFalse(ProductE2E.titleLooksMismatched(app),
                       "first reply didn't check out: \(ProductE2E.titleLabel(app))")

        ProductE2E.sendAndWait(app, "live-e2e-debug-two", timeout: 180)
        XCTAssertTrue(ProductE2E.waitForDebugCardOnScreen(app),
                      "debug card missing after the second live turn")
        XCTAssertFalse(ProductE2E.titleLooksMismatched(app),
                       "second reply didn't check out with the debug panel on: \(ProductE2E.titleLabel(app))")
        XCTAssertFalse(ProductE2E.titleLooksBlocked(app),
                       "session blocked after two live turns with the debug panel on")
    }

    // MARK: - use cases (the Android port's list), 2026-10-05. Neither spends: attestation and a key probe.

    /// E10: re-verify on the trust sheet refreshes the stamp (a new nonce), and the expert rung's copy puts the
    /// self-verify script on the clipboard.
    func testReverifyRefreshesTheStampAndCopyPutsTheScriptOnTheClipboard() throws {
        try ProductE2E.requireHostKey(forPreset: "nearai")
        let app = ProductE2E.launchNearAI(model: Self.model)
        let title = ProductE2E.titleBlock(app)
        XCTAssertTrue(title.waitForExistence(timeout: 15), "title block missing")
        title.tap()
        let nonce = try NSRegularExpression(pattern: "nonce [0-9a-fA-F]{4}…[0-9a-fA-F]{4}")
        func stamp() -> String? {
            let el = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "nonce ")).firstMatch
            guard el.exists else { return nil }
            let l = el.label
            return nonce.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)).flatMap { Range($0.range, in: l).map { String(l[$0]) } }
        }
        func waitFor(_ seconds: TimeInterval, _ cond: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if cond() { return true }; usleep(500_000) }
            return cond()
        }
        XCTAssertTrue(waitFor(60) { stamp() != nil }, "the sheet never showed a nonce stamp")
        let first = stamp()!
        let reverify = app.buttons.matching(NSPredicate(format: "label ==[c] %@ OR label ==[c] %@", "re-verify", "re-run verification")).firstMatch
        XCTAssertTrue(reverify.waitForExistence(timeout: 10), "the sheet offers no re-verify")
        reverify.tap()
        XCTAssertTrue(waitFor(60) { if let s = stamp() { return s != first }; return false }, "re-verify did not refresh the stamp (still \(first))")
        app.buttons["expert"].firstMatch.tap()
        let heading = app.staticTexts["re-check the live service yourself"].firstMatch
        for _ in 0..<12 where !heading.isHittable { app.swipeUp() }
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "the expert rung has no self-verify section")
        // the script card's pill (its label is the symbol's and the word's, "…, copy"), not a digest's copy icon
        let file = app.staticTexts["teemoon_verify.py"].firstMatch
        for _ in 0..<4 where !file.isHittable { app.swipeUp() }
        guard file.exists else { throw XCTSkip("no script card on this record") }
        // the pill in the card's own header bar: the copy button level with the file name
        let copy = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "copy")).allElementsBoundByIndex
            .filter { abs($0.frame.midY - file.frame.midY) < 20 }.first
        guard let copy else { return XCTFail("the script card has no copy pill beside teemoon_verify.py") }
        copy.tap()
        // the pill says "copied" for 1.6 s; the read-back below is the proof, this only catches a dead button early
        _ = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "copied")).firstMatch.waitForExistence(timeout: 2)
        // read it back INSIDE the app: the runner reading UIPasteboard raises the paste prompt and hangs
        // the sheet's own close (the × at its top left), not swipes: a swipe on the expert rung scrolls it
        let close = app.buttons.matching(NSPredicate(format: "label ==[c] %@ OR label ==[c] %@ OR label ==[c] %@", "close", "done", "xmark")).firstMatch
        if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
        let composer = ProductE2E.composer(app)
        for _ in 0..<3 where !composer.isHittable { sleep(1); if !composer.isHittable { app.swipeDown(velocity: .fast) } }
        composer.tap(); composer.press(forDuration: 1.2)
        let paste = app.menuItems.matching(NSPredicate(format: "label ==[c] %@", "paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the composer offered no paste")
        paste.tap()
        let pasted = composer.value as? String ?? ""
        XCTAssertTrue(pasted.localizedCaseInsensitiveContains("python"), "the clipboard does not hold the verify script: \(pasted.prefix(80))")
    }

    /// A5: a cloud key the provider refuses is said by the add form before save (OpenRouter, a well-formed key that
    /// is not one). NOT asserted: "nothing is saved" — save does not consult the check (AddEditProviderModel.save, on
    /// both platforms); whether it should is an open product question (2026-10-05).
    func testARejectedCloudKeyIsSaidByTheForm() throws {
        let app = ProductE2E.launch(environment: ["UITEST_SEED_LOCAL_ENDPOINT": "http://127.0.0.1:9/v1", "UITEST_SEED_LOCAL_MODEL": "fake-model"])
        ProductE2E.whereChip(app).tap()
        app.buttons["cloud"].firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND identifier != %@", "openrouter", "chat.whereChip")).firstMatch
        // a List renders only its on-screen rows: swipe the sheet's list until openrouter is drawn
        for _ in 0..<8 where !row.exists { app.swipeUp(velocity: .slow); sleep(1) }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the cloud filter has no openrouter row: \(app.debugDescription.prefix(3000))")
        row.tap()
        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 10), "openrouter's key form did not open")
        key.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the key field took no focus")
        key.typeText("sk-or-v1-" + String(repeating: "0", count: 64))
        XCTAssertFalse((key.value as? String ?? "").isEmpty, "the key never reached the field")
        sleep(3)   // editing the key re-probes on its own
        let said = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "rejected")).firstMatch
        if !said.exists {
            let fetch = app.buttons.matching(NSPredicate(format: "label ==[c] %@ OR label ==[c] %@ OR label ==[c] %@", "fetch models", "test connection", "refresh models")).firstMatch
            if fetch.exists { fetch.tap() }
        }
        ProductE2E.attachScreenshot(app, name: "a5-after-key", to: self)
        XCTAssertTrue(said.waitForExistence(timeout: 30), "the form did not say the key is refused: \(app.debugDescription.prefix(3000))")
    }
}
