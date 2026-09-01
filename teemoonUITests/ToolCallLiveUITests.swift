//
//  ToolCallLiveUITests.swift
//  teemoonUITests
//
//  Live UI E2E for the tool loop: the model must call `web_search`, Brave
//  must run, sources must land on the transcript, and tool markup must not.
//  Keys from ~/.NEAR_AI_API_KEY / ~/.FIREWORKS_API_KEY / ~/.XAI_API_KEY
//  plus ~/.BRAVE_API_KEY (staged, never env). Brave Answers is not here:
//  it grounds natively and never gets the web_search tool.
//
//    xcodebuild test -project teemoon.xcodeproj -scheme teemoon \
//      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//      -only-testing:teemoonUITests/ToolCallLiveUITests
//

import XCTest

final class ToolCallLiveUITests: XCTestCase {

    /// Current + explicit: models that have the tool still skip "nice" prompts.
    private static let prompt =
        "Search the web for today's top Reuters headline. Reply in one short sentence and cite the source."

    override func setUp() { continueAfterFailure = false }

    func testNearAIGLM52CallsWebSearchAndShowsSources() throws {
        try ProductE2E.requireHostKey(forPreset: "nearai")
        try ProductE2E.requireGroundingKey()
        let app = ProductE2E.launchNearAIGrounded(model: "z-ai/glm-5.2")
        try assertLiveToolRound(app, name: "nearai")
    }

    func testGrokBuildCallsWebSearchAndShowsSources() throws {
        try ProductE2E.requireHostKey(forPreset: "grok")
        try ProductE2E.requireGroundingKey()
        let app = ProductE2E.launchPreset("grok", model: "grok-build-0.1", grounding: true)
        try assertLiveToolRound(app, name: "grok")
    }

    func testFireworksGptOss20BCallsWebSearchAndShowsSources() throws {
        try ProductE2E.requireHostKey(forPreset: "fireworks")
        try ProductE2E.requireGroundingKey()
        let app = ProductE2E.launchPreset(
            "fireworks", model: "accounts/fireworks/models/gpt-oss-20b", grounding: true)
        try assertLiveToolRound(app, name: "fireworks")
    }

    func testOllamaGemma4CallsWebSearchAndShowsSources() throws {
        try ProductE2E.requireGroundingKey()
        let app = ProductE2E.launchOllama(grounding: true)
        try assertLiveToolRound(app, name: "ollama", settle: 180)
    }

    private func assertLiveToolRound(
        _ app: XCUIApplication, name: String, settle: TimeInterval = 180
    ) throws {
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 15))
        _ = ProductE2E.waitUntilNotVerifying(app)
        let web = app.descendants(matching: .any)["chat.webSearchChip"].firstMatch
        if web.waitForExistence(timeout: 5) {
            XCTAssertEqual(web.value as? String, "on",
                           "web chip should be on after grounding seed (value=\(web.value ?? "nil"))")
        }

        try ProductE2E.sendLive(app, Self.prompt, settle: settle, test: self)
        ProductE2E.attachScreenshot(app, name: "tool-\(name)-settled", to: self)
        ProductE2E.assertNoToolMarkup(app)

        if ProductE2E.webSearchOffer(app).exists {
            XCTFail("\(name) raised the keyless offer card — grounding key did not take")
            return
        }
        XCTAssertTrue(ProductE2E.sourcesAppeared(app),
                      "\(name) never showed sources after a search prompt — tool round did not complete")

        let chip = ProductE2E.sourcesChip(app)
        if chip.exists {
            chip.tap()
            let sheet = app.navigationBars["sources"].firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 6),
                          "sources chip did not open the sources sheet")
            ProductE2E.attachScreenshot(app, name: "tool-\(name)-sources", to: self)
        }
    }
}
