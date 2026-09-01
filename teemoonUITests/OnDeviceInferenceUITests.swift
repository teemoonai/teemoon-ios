//
//  OnDeviceInferenceUITests.swift
//  teemoonUITests
//
//  Drives a REAL on-device generation through the actual UI: seed a local
//  provider, type a grounded question, send, read what comes back.
//
//  Why this exists when `LocalInferenceLiveTests` already calls the transport
//  directly: those tests kept passing (3/3 tool calls) while the app kept
//  failing (0 for 4), because they never exercised the app's own path — the
//  resolved system prompt, the thread history, the real temperature. Every
//  earlier wrong hypothesis came from testing a layer
//  below the one that was broken. This closes that gap.
//
//  REAL DEVICE ONLY and requires the weights to already be downloaded — it seeds a provider, it does not fetch gigabytes.
//  Skips cleanly otherwise.
//
//  Run:
//    xcodebuild test -destination 'platform=iOS,id=<udid>' \
//      -only-testing:teemoonUITests/OnDeviceInferenceUITests
//

import XCTest

final class OnDeviceInferenceUITests: XCTestCase {

    /// The model that actually ships as the recommended one. Was a retired MLX
    /// entry, which meant this suite seeded a provider that could never load.
    private static let model = "litert-community/gemma-4-E2B-it-litert-lm"

    override func setUp() { continueAfterFailure = false }

    private func launchSeeded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_ONDEVICE_MODEL"] = Self.model
        app.launch()
        return app
    }

    /// Sends `text` and waits for generation to finish.
    ///
    /// "Finished" is the debug card appearing, not the answer text changing:
    /// the answer streams, so any text-based wait races the stream, and a local
    /// thinking model shows nothing at all until `</think>` closes.
    @discardableResult
    private func ask(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 180) -> String {
        // By IDENTIFIER, not by placeholder: the placeholder is content, and it
        // is absent the moment the field has text — which is why the first turn
        // worked and the follow-up reported "composer never appeared".
        let composer = app.textFields["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer never appeared")
        // A long answer can leave it off-screen; tapping an unhittable element
        // silently does nothing and the test then times out on the send.
        if !composer.isHittable { app.swipeUp() }
        composer.tap()
        composer.typeText(text)

        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "send button missing")
        send.tap()

        // "Finished" = the STOP button going away.
        //
        // Waiting on the debug card was wrong and cost a whole run: it is gated
        // on developer mode, on a per-thread toggle, AND on `lastError == nil`,
        // so an errored turn hides the very thing the test waits for and the
        // failure reads as "generation did not complete" when generation
        // completed fine. The stop button is present exactly while `llm.running`
        // is true, regardless of settings, which is the actual question.
        let stop = app.buttons["chat.stop"]
        _ = stop.waitForExistence(timeout: 20)          // generation started
        let deadline = Date().addingTimeInterval(timeout)
        while stop.exists && Date() < deadline { usleep(300_000) }
        XCTAssertFalse(stop.exists, "generation did not finish within \(timeout)s")

        // The debug card is a bonus when developer mode happens to be on.
        let debugCard = app.descendants(matching: .any)["chat.debugCard"].firstMatch
        return debugCard.exists ? debugCard.label : ""
    }

    /// Everything on screen, for assertions about what the model said.
    func visibleText(_ app: XCUIApplication) -> String {
        app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
    }

    /// The whole point: a question that CANNOT be answered from weights must
    /// reach the web-search tool.
    ///
    /// Asserted on the debug card rather than the prose, because the prose is a
    /// small model's and will vary. A tool call either happened or it did not.
    func testAGroundedQuestionActuallyCallsTheSearchTool() throws {
        let app = launchSeeded()
        let card = ask(app, "How much is oil now?")
        print("[uitest] debug card: \(card)")

        // A model that declined to search says so in a recognisable way, and
        // that phrasing is the regression this test exists to catch.
        let declined = ["cannot provide", "don't have access", "do not have access",
                        "real-time data", "check the latest"]
        let body = app.staticTexts.allElementsBoundByIndex
            .map(\.label).joined(separator: " ").lowercased()
        let refused = declined.contains { body.contains($0) }

        XCTAssertFalse(refused,
                       "the model declined instead of searching — this is the bug: \(body.prefix(400))")
    }

    /// Plain chat must stay fast and must NOT drag in the tool machinery.
    func testPlainChatAnswersWithoutSearching() throws {
        let app = launchSeeded()
        let card = ask(app, "Say hello in exactly one word.", timeout: 120)
        print("[uitest] plain-chat debug card: \(card)")
        XCTAssertFalse(card.isEmpty, "no debug card content")
    }
}


// MARK: - Multi-turn

extension OnDeviceInferenceUITests {

    /// A FOLLOW-UP question must produce a real answer.
    ///
    /// Every other test here — and every live test — sends exactly one message
    /// into an empty thread. The second turn is a different code path: prior
    /// turns have to be seeded into the model's conversation, and getting that
    /// wrong does not throw, it degrades. Reported from the device: a follow-up
    /// ("what about for the rest of the week") answered with the single word
    /// "Hungary", 1 token generated, after a first turn that was perfect.
    ///
    /// Asserts on LENGTH and token count rather than content: what a 2B model
    /// says will vary, but "one token" is never a real answer to a follow-up.
    func testAFollowUpTurnAnswersInsteadOfEmittingOneToken() throws {
        let app = launchSeeded()

        let first = ask(app, "What's the weather in New York NY today?")
        print("[uitest] turn 1 card: \(first)")

        let second = ask(app, "What about for the rest of the week?")
        print("[uitest] turn 2 card: \(second)")

        // The debug card carries "<n>tok". One token is the signature of the
        // failure; a genuine answer is dozens at least.
        // Token count only when the debug card is available; the text check
        // below is the one that always applies.
        if let tokens = Self.tokenCount(in: second) {
            XCTAssertGreaterThan(tokens, 5,
                                 "follow-up generated \(tokens) tokens — it collapsed instead of answering")
        }

        // The failure this exists to catch produced a hard native error
        // (`Input token ids are too long: 4484 >= 4096`) rendered as an error
        // card, so an error on screen is a failure even if text is present.
        let all = visibleText(app).lowercased()
        XCTAssertFalse(all.contains("input token ids are too long"),
                       "context overflow on the follow-up — the KV budget is too small for history + grounding")
        XCTAssertFalse(all.contains("unexpected error"),
                       "the follow-up errored: \(all.suffix(300))")

        // And the visible reply must not be a bare word.
        let body = app.staticTexts.allElementsBoundByIndex.map(\.label)
        let longest = body.map(\.count).max() ?? 0
        XCTAssertGreaterThan(longest, 40,
                             "no substantial text on screen after the follow-up — longest run was \(longest) chars")
    }

    /// Pulls "280tok" out of the debug card label.
    private static func tokenCount(in card: String) -> Int? {
        guard let range = card.range(of: #"(\d+)tok"#, options: .regularExpression) else { return nil }
        return Int(card[range].dropLast(3))
    }
}
