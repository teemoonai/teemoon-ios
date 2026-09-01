//
//  LocalProviderUITests.swift
//  teemoonUITests
//
//  The visual half of the local-model smoke: the claims a user reads rather than
//  the plumbing `LocalEngineSmokeTests` exercises.
//
//  These need NO server running. They seed a local provider by endpoint and
//  assert what the chrome says about it — the model name, "on your own machine",
//  and a trust sheet that replaces the ladder instead of warning about a missing
//  enclave. All of that is derived from `Provider.isSelfHosted`, which is a
//  function of the host, so no inference is required to check it.
//
//  That matters: it keeps the slow, engine-dependent suite separate from the
//  fast, deterministic one.
//

import XCTest

final class LocalProviderUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// A tailnet-shaped host, so `isSelfHosted` classifies it the way a real
    /// local endpoint would (CGNAT / `.ts.net` / loopback all qualify).
    private func launchSeeded(model: String = "gemma4:e2b-it-qat",
                              endpoint: String = "http://127.0.0.1:11434/v1") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = endpoint
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = model
        app.launch()
        return app
    }

    private func titleBlock(_ app: XCUIApplication) -> XCUIElement {
        // The block collapses to a single accessibility element; its label
        // carries every line's text.
        app.descendants(matching: .any)["chat.titleBlock"].firstMatch
    }

    // MARK: The nav bar

    func testTitleBarNamesTheModelAndSaysItIsLocal() {
        let app = launchSeeded()
        let block = titleBlock(app)
        XCTAssertTrue(block.waitForExistence(timeout: 20), "title block never appeared")

        let label = block.label
        // compactName strips the build words: gemma4:e2b-it-qat → gemma4:e2b.
        XCTAssertTrue(label.contains("gemma4:e2b"),
                      "expected the compacted model in the title block, got: \(label)")
        XCTAssertFalse(label.contains("-it-qat"),
                       "build words should be peeled off for display, got: \(label)")
        XCTAssertTrue(label.contains("on your own machine"),
                      "a local provider should say so, got: \(label)")
        // The warning written for a third-party provider with no enclave must
        // never be applied to the user's own machine.
        XCTAssertFalse(label.contains("not end-to-end encrypted"),
                       "local must not borrow the no-enclave warning, got: \(label)")
    }

    /// A raw GGUF path is what llama.cpp reports as its model id. The bar must
    /// show a name, not a filesystem path.
    func testAGgufPathIsShownAsAName() {
        let app = launchSeeded(model: "/Users/x/.cache/models/Qwen2.5-7B-Instruct-Q4_K_M.gguf",
                              endpoint: "http://127.0.0.1:8080/v1")
        let block = titleBlock(app)
        XCTAssertTrue(block.waitForExistence(timeout: 20))
        let label = block.label
        XCTAssertFalse(label.contains("/Users/"), "a path leaked into the title bar: \(label)")
        XCTAssertFalse(label.contains(".gguf"), "a file extension leaked into the title bar: \(label)")
        XCTAssertTrue(label.lowercased().contains("qwen2.5-7b"),
                      "expected the model name, got: \(label)")
    }

    // MARK: The trust sheet

    func testTrustSheetShowsTheSelfHostedViewAndNoRungPicker() {
        let app = launchSeeded()
        let block = titleBlock(app)
        XCTAssertTrue(block.waitForExistence(timeout: 20))
        block.tap()

        let hero = app.descendants(matching: .any)["attestation.selfHosted.hero"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 10),
                      "the self-hosted sheet should lead with its own hero, not the ladder")

        // No proof to go deeper into, so no depth control.
        let rungs = app.descendants(matching: .any)["attestation.rungPicker"].firstMatch
        XCTAssertFalse(rungs.exists, "the self-hosted sheet should have no rung picker")

        // The machine's name is personal and this screen gets screenshotted.
        // Scope to the sheet: the Where chip behind it names the host on purpose.
        XCTAssertFalse(hero.label.contains("127.0.0.1"),
                       "the sheet must not print the host, got: \(hero.label)")
    }
}
