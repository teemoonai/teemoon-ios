//
//  ProviderCaptureUITests.swift
//  teemoonUITests
//
//  Captures the CURRENT add/edit provider screen as ground-truth screenshots to
//  feed Claude Design (which had only the web-landing-page design system to work
//  from). Grabs: the empty add screen, the preset dropdown open (all presets),
//  and a filled LOCAL-provider config — the actual use case.
//
//  Extract the images after a run:
//    xcrun xcresulttool export attachments --path <run>.xcresult --output-path out
//

import XCTest

final class ProviderCaptureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot())
        s.name = name; s.lifetime = .keepAlways; add(s)
    }
    private func tree(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testCaptureProviderScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        // 1. open settings
        let settings = app.buttons["chat.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 25), "settings button missing")
        settings.tap()

        // 2. providers
        let providers = app.buttons["settings.providers"].firstMatch
        if providers.waitForExistence(timeout: 8) {
            providers.tap()
        } else {
            tree(app, "TREE-settings")   // deep-linked or different label — capture for debug
        }

        // 3. add provider
        let add = app.buttons["add provider"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 8), "add-provider button missing")
        add.tap()

        // 4. empty add screen
        _ = app.navigationBars["add provider"].waitForExistence(timeout: 8)
        tree(app, "TREE-add-provider")
        snap(app, "SHOT-1-add-empty")

        // 5. preset dropdown open — shows ALL presets
        let preset = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'preset'")).firstMatch
        if preset.waitForExistence(timeout: 4) {
            preset.tap()
            Thread.sleep(forTimeInterval: 0.9)
            snap(app, "SHOT-2-preset-menu")
            // close the menu without changing state: pick "none" if present, else tap the title
            let none = app.buttons["none"].firstMatch
            if none.waitForExistence(timeout: 2) {
                none.tap()
            } else {
                app.navigationBars["add provider"].firstMatch.tap()
            }
            Thread.sleep(forTimeInterval: 0.4)
        }

        // 6. fill a real LOCAL config
        func fill(_ placeholder: String, _ text: String) {
            let f = app.textFields[placeholder].firstMatch
            if f.waitForExistence(timeout: 3) { f.tap(); f.typeText(text) }
        }
        fill("label", "local qwen")
        fill("api.example.com/v1", "127.0.0.1:8080/v1")
        fill("model", "qwen2.5-7b")
        // dismiss keyboard for a clean shot — tap the plain footer text
        let footer = app.staticTexts["tap and hold the lock to switch to http for local servers"].firstMatch
        if footer.exists { footer.tap() }
        else { app.staticTexts["select a preset to fill in the fields below"].firstMatch.tap() }
        Thread.sleep(forTimeInterval: 0.5)
        snap(app, "SHOT-3-filled-local")
        tree(app, "TREE-final")
    }

    /// Walks the whole add-provider → connect → model-list → download flow against
    /// the live local Ollama (127.0.0.1:11434, reachable from the sim), capturing a
    /// full-chrome screenshot at each step to feed Claude Design. Skips gracefully
    /// if Ollama isn't up.
    func testCaptureOllamaFlow() throws {
        // Reach the Mac's Ollama over Tailscale (the sim reaches the tailnet
        // reliably; sim→host loopback on :11434 did not hold).
        let ollamaHost = "ringzero.tailnet-name.ts.net"
        var up = false
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: URL(string: "https://\(ollamaHost)/api/version")!)
        req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            up = (resp as? HTTPURLResponse)?.statusCode == 200; sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 7)
        try XCTSkipUnless(up, "Ollama not reachable via tailnet — skipping flow capture")

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        // 1. Settings → Providers → Add
        app.buttons["chat.settings"].firstMatch.tap()
        let providers = app.buttons["settings.providers"].firstMatch
        if providers.waitForExistence(timeout: 8) { providers.tap() }
        let add = app.buttons["add provider"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 8), "add-provider button missing")
        add.tap()
        _ = app.navigationBars["add provider"].waitForExistence(timeout: 8)
        snap(app, "FLOW-1-empty")

        // 2. Enter the local Ollama endpoint (http:// strips → scheme becomes http)
        let endpoint = app.textFields["api.example.com/v1"].firstMatch
        XCTAssertTrue(endpoint.waitForExistence(timeout: 4), "endpoint field missing")
        endpoint.tap(); endpoint.typeText("\(ollamaHost)/v1")   // https default, no scheme prefix
        app.staticTexts["model"].firstMatch.tap()   // dismiss keyboard via section header
        snap(app, "FLOW-2-endpoint")

        // 3. Auto-probe connects → model rows appear (with ctx·quant + warm)
        let aModel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'qwen' OR label CONTAINS[c] 'gemma'")).firstMatch
        if aModel.waitForExistence(timeout: 30) {
            Thread.sleep(forTimeInterval: 1.0)   // let warm/caps settle
            snap(app, "FLOW-3-connected")
        } else {
            tree(app, "FLOW-TREE-noconnect")
            snap(app, "FLOW-3-connect-failed")
        }

        // 4. Open the paste-first download sheet
        let dl = app.buttons["download a model"].firstMatch
        if dl.waitForExistence(timeout: 4) {
            dl.tap()
            _ = app.navigationBars["download a model"].waitForExistence(timeout: 5)
            snap(app, "FLOW-4-download-sheet")
        }
    }

    /// End-to-end verify-first flow against a live local server on :8080.
    /// Fills a local http endpoint, taps "fetch models", and asserts the model
    /// picker populates with the served model. Skips if the server isn't up.
    func testFetchModelsFlowE2E() throws {
        // Use the real Tailscale HTTPS endpoint: no scheme prefix to strip, and it
        // exercises the self-hosted-over-https path. Skip if the sim can't reach it.
        let endpointHost = "ringzero.tailnet-name.ts.net/v1"
        let modelID = "qwen2.5-7b"
        var up = false
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: URL(string: "https://\(endpointHost)/models")!)
        req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            up = (resp as? HTTPURLResponse)?.statusCode == 200; sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 7)
        try XCTSkipUnless(up, "tailnet endpoint unreachable from sim — skipping e2e fetch flow")

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        app.buttons["chat.settings"].firstMatch.tap()
        let providers = app.buttons["settings.providers"].firstMatch
        if providers.waitForExistence(timeout: 8) { providers.tap() }
        let add = app.buttons["add provider"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 8), "add-provider button missing")
        add.tap()
        _ = app.navigationBars["add provider"].waitForExistence(timeout: 8)

        let name = app.textFields["label"].firstMatch
        if name.waitForExistence(timeout: 3) { name.tap(); name.typeText("local qwen") }
        // Bare host (https default) — no scheme prefix, so onChange never re-writes
        // the field mid-typing.
        let endpoint = app.textFields["api.example.com/v1"].firstMatch
        if endpoint.waitForExistence(timeout: 3) { endpoint.tap(); endpoint.typeText(endpointHost) }
        app.staticTexts["model"].firstMatch.tap()   // dismiss keyboard via section header
        Thread.sleep(forTimeInterval: 0.4)
        snap(app, "E2E-1-selfhosted-filled")

        let fetch = app.buttons["fetch models"].firstMatch
        XCTAssertTrue(fetch.waitForExistence(timeout: 4), "fetch-models button missing")
        fetch.tap()

        // The model row shows the display name (last path component); match either a
        // button or static text carrying it.
        let served = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", modelID)).firstMatch
        let appeared = served.waitForExistence(timeout: 30)
        tree(app, "E2E-TREE-after-fetch")
        snap(app, "E2E-2-connected")
        XCTAssertTrue(appeared, "model picker did not populate with \(modelID) after fetch")
    }
}
