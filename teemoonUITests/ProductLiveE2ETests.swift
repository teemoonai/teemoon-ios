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

    private static let model = "z-ai/glm-5.2"

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
        let e2ee = app.descendants(matching: .any)["chat.debugCard.e2ee"].firstMatch
        XCTAssertTrue(e2ee.waitForExistence(timeout: 5),
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
}
