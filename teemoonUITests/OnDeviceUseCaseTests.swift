//
//  OnDeviceUseCaseTests.swift
//  teemoonUITests
//
//  The phone-only use cases of the Android port's use-case list, on a real iPhone with
//  the gemma weights already in the app's container: G8 stop mid-thought, C10 the phone's
//  model reads warm after it has answered, A6 first run offers the model on disk. They skip
//  in the simulator (no weights, no on-device engine worth timing).
//
//  Run them against a SEPARATE install — PRODUCT_BUNDLE_IDENTIFIER=ai.teemoon.app.e2e —
//  never the owner's dev or App Store app: a --uitesting launch clears preset key slots.
//

import XCTest

final class OnDeviceUseCaseTests: XCTestCase {

    private static let model = "litert-community/gemma-4-E2B-it-litert-lm"

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("phone-only: needs gemma's weights and the device's engine")
        #endif
    }

    private func launch(seedModel: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        if seedModel { app.launchEnvironment["UITEST_SEED_ONDEVICE_MODEL"] = Self.model }
        app.launch()
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 30), "composer missing")
        return app
    }

    private func element(_ app: XCUIApplication, _ fragment: String) -> XCUIElement {
        ProductE2E.elementContaining(app, fragment)
    }

    /// G8: stop while gemma is still thinking — the turn ends promptly, and the next turn answers.
    func testStoppingMidThoughtEndsTheTurnAndTheNextOneAnswers() {
        let app = launch()
        ProductE2E.typeIntoComposer(app, "Think very carefully, step by step, about every prime below 200, then tell me how many there are.")
        ProductE2E.send(app)
        let stop = app.buttons["chat.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 120), "the turn never started")
        // mid-turn: thinking if it thinks, else already streaming — gemma does not always open with a thought
        XCTAssertTrue(element(app, "thinking").waitForExistence(timeout: 60) || stop.exists, "the turn was not running")
        sleep(2)
        stop.tap()
        let ended = NSPredicate(format: "exists == false")
        expectation(for: ended, evaluatedWith: stop); waitForExpectations(timeout: 15)
        XCTAssertFalse(app.descendants(matching: .any)["chat.error"].firstMatch.exists, "a stop showed an error")
        ProductE2E.typeIntoComposer(app, "Is 221 a prime number? Answer in one sentence.")
        ProductE2E.send(app)
        XCTAssertTrue(stop.waitForExistence(timeout: 30), "the turn after a stop never started")
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 240), "the turn after a stop never finished")
        XCTAssertTrue(element(app, "221").waitForExistence(timeout: 10), "the engine did not answer after a stop")
    }

    /// C10 (part): once gemma has answered, the phone's row on the where sheet reads warm (on its caption, WhereRow).
    func testThePhonesModelReadsWarmOnceItHasAnswered() {
        let app = launch()
        ProductE2E.typeIntoComposer(app, "Say hello in three words.")
        ProductE2E.send(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 240), "gemma never answered")
        ProductE2E.whereChip(app).tap()
        XCTAssertTrue(element(app, "warm").waitForExistence(timeout: 15), "the phone's model does not read warm after answering")
    }

    /// C10: and cold once the app has been away — iOS's LocalMemoryPressure evicts the engine on did-enter-background,
    /// so the row says what the next turn will cost (a reload), like a home server's cold model.
    func testThePhonesModelReadsColdAfterTheAppWasAway() {
        let app = launch()
        ProductE2E.typeIntoComposer(app, "Say hello in three words.")
        ProductE2E.send(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 240), "gemma never answered")
        XCUIDevice.shared.press(.home)
        sleep(5)
        app.activate()
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 15), "the app did not come back")
        ProductE2E.whereChip(app).tap()
        XCTAssertTrue(element(app, "cold").waitForExistence(timeout: 15), "the phone's model does not read cold after the app was away")
    }

    /// A6: first run on a phone with the model already on disk — "start here" offers to USE it, not to download it.
    func testFirstRunOffersTheModelAlreadyOnThePhone() {
        let app = launch(seedModel: false)
        ProductE2E.whereChip(app).tap()
        XCTAssertTrue(element(app, "start here").waitForExistence(timeout: 15), "first run did not lead with start here")
        XCTAssertTrue(element(app, "already downloaded").waitForExistence(timeout: 10), "start here did not see the weights on disk")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "use ")).firstMatch.exists,
                      "start here offered no use button for the model on disk")
    }
}
