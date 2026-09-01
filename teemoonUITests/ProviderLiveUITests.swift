//
//  ProviderLiveUITests.swift
//  teemoonUITests
//
//  Simulator UI E2E: one cheap live send per shipped place. Keys are read
//  from ~/.…_API_KEY on the Mac (SIMULATOR_HOST_HOME), never from env.
//
//    xcodebuild test -project teemoon.xcodeproj -scheme teemoon \
//      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//      -only-testing:teemoonUITests/ProviderLiveUITests
//

import XCTest

final class ProviderLiveUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
        print("[uitest-runner] host home=\(ProductE2E.runnerHostHome() ?? "nil")")
    }

    func testNearAIGemma4SendsFromChat() throws {
        try ProductE2E.requireHostKey(forPreset: "nearai")
        let app = ProductE2E.launchPreset("nearai", model: "google/gemma-4-31B-it")
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 15))
        _ = ProductE2E.waitUntilVerified(app, timeout: 25)
        try ProductE2E.sendLive(app, "ui-e2e-nearai-pong", test: self)
    }

    func testFireworksGptOss20BSendsFromChat() throws {
        try ProductE2E.requireHostKey(forPreset: "fireworks")
        let app = ProductE2E.launchPreset("fireworks", model: "accounts/fireworks/models/gpt-oss-20b")
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 15))
        try ProductE2E.sendLive(app, "ui-e2e-fireworks-pong", test: self)
    }

    func testGrokBuildSendsFromChat() throws {
        try ProductE2E.requireHostKey(forPreset: "grok")
        let app = ProductE2E.launchPreset("grok", model: "grok-build-0.1")
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 15))
        try ProductE2E.sendLive(app, "ui-e2e-grok-pong", test: self)
    }

    func testBraveAnswersSendsFromChat() throws {
        try ProductE2E.requireHostKey(forPreset: "brave")
        let app = ProductE2E.launchPreset("brave")
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 15))
        try ProductE2E.sendLive(app, "ui-e2e-brave-sky-color", test: self)
    }

    func testOllamaRingzeroSendsFromChat() throws {
        let app = ProductE2E.launchOllama()
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 15))
        try ProductE2E.sendLive(app, "ui-e2e-ollama-pong", settle: 180, test: self)
    }
}
