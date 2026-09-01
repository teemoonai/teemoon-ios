//
//  ProductE2ESupport.swift
//  teemoonUITests
//
//  Shared driver for the product E2E suite. Title chip is `chat.titleBlock`,
//  never the VoiceOver hint. Typing retries until the composer actually holds
//  the text (WireProof's focus flake).
//

import XCTest

enum ProductE2E {

    /// Mac home as this test process sees it. Not a secret.
    static func runnerHostHome() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let home = env["SIMULATOR_HOST_HOME"], !home.isEmpty { return home }
        if let home = env["HOME"], home.hasPrefix("/Users/"), !home.contains("Containers") {
            return home
        }
        return nil
    }

    /// Filenames under the Mac home, matching `UITestHostSecrets`.
    static func hostKeyFileNames(forPreset raw: String) -> [String] {
        switch raw.lowercased() {
        case "nearai", "near.ai", "near": return [".NEAR_AI_API_KEY", ".nearai_api_key"]
        case "grok", "xai":               return [".XAI_API_KEY", ".xai_api_key"]
        case "fireworks":                 return [".FIREWORKS_API_KEY", ".fireworks_api_key"]
        case "brave", "braveanswers":     return [".BRAVE_ANSWERS_API_KEY"]
        case "grounding", "bravesearch":  return [".BRAVE_API_KEY", ".brave_api_key"]
        default:                          return []
        }
    }

    static func hostKeyFileExists(forPreset preset: String) -> Bool {
        guard let home = runnerHostHome() else { return false }
        return hostKeyFileNames(forPreset: preset).contains {
            FileManager.default.isReadableFile(atPath: (home as NSString).appendingPathComponent($0))
        }
    }

    /// Skip only when this Mac has no host-file key for the preset.
    static func requireHostKey(forPreset preset: String) throws {
        guard hostKeyFileExists(forPreset: preset) else {
            throw XCTSkip("no ~/.…_API_KEY for \(preset) on this Mac")
        }
    }

    /// Simulator-wide tmp the UI-test runner (iOS) can write with FileManager.
    /// Not the app sandbox — `Process`/`simctl` are unavailable in this target.
    static func stagedKeysDirectory() -> URL? {
        guard let home = runnerHostHome() else { return nil }
        let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["TARGET_DEVICE_IDENTIFIER"]
        guard let udid, !udid.isEmpty else { return nil }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/data/tmp/teemoon-uitest-keys",
                                    isDirectory: true)
    }

    /// Copy `~/.…_API_KEY` files into simulator tmp so the sandboxed app can
    /// read them. Path only — never the key in env/`ps`.
    @discardableResult
    static func stageHostKeys() -> URL? {
        guard let home = runnerHostHome(), let dest = stagedKeysDirectory() else {
            print("[uitest-runner] no host home / UDID — cannot stage keys")
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            print("[uitest-runner] could not create staged-keys dir: \(error)")
            return nil
        }
        var staged = 0
        let names = [
            ".NEAR_AI_API_KEY", ".nearai_api_key",
            ".XAI_API_KEY", ".xai_api_key",
            ".FIREWORKS_API_KEY", ".fireworks_api_key",
            ".BRAVE_ANSWERS_API_KEY",
            ".BRAVE_API_KEY", ".brave_api_key",
        ]
        for name in names {
            let src = URL(fileURLWithPath: home).appendingPathComponent(name)
            guard FileManager.default.isReadableFile(atPath: src.path) else { continue }
            let dst = dest.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dst)
            do {
                try FileManager.default.copyItem(at: src, to: dst)
                staged += 1
            } catch {
                print("[uitest-runner] could not stage \(name): \(error)")
            }
        }
        print("[uitest-runner] staged \(staged) host-key file(s) at \(dest.path)")
        return staged > 0 ? dest : nil
    }

    static func launch(
        arguments: [String] = ["--uitesting"],
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        var env = environment
        // Path only — never the key. `SIMULATOR_*` can be stripped from
        // launchEnvironment; `TEEMOON_HOST_HOME` is ours.
        if let home = runnerHostHome() {
            if env["SIMULATOR_HOST_HOME"] == nil { env["SIMULATOR_HOST_HOME"] = home }
            if env["TEEMOON_HOST_HOME"] == nil { env["TEEMOON_HOST_HOME"] = home }
        }
        if let staged = stageHostKeys() {
            env["TEEMOON_STAGED_KEYS"] = staged.path
        }
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment = env
        app.launch()
        return app
    }

    static func launchNearAI(model: String = "z-ai/glm-5.2",
                             developerMode: Bool = false) -> XCUIApplication {
        var env = ["UITEST_SEED_NEARAI_MODEL": model]
        if developerMode { env["UITEST_DEVELOPER_MODE"] = "1" }
        return launch(environment: env)
    }

    /// near.ai plus the Brave Search key, so `web_search` actually runs.
    static func launchNearAIGrounded(model: String = "z-ai/glm-5.2") -> XCUIApplication {
        launch(environment: [
            "UITEST_SEED_NEARAI_MODEL": model,
            "UITEST_SEED_GROUNDING": "1",
        ])
    }

    static func launchPreset(_ preset: String, model: String? = nil, grounding: Bool = false) -> XCUIApplication {
        var env = ["UITEST_SEED_PRESET": preset]
        if let model { env["UITEST_SEED_MODEL"] = model }
        if grounding { env["UITEST_SEED_GROUNDING"] = "1" }
        return launch(environment: env)
    }

    static func launchOllama(
        endpoint: String = "https://ringzero.tailnet-name.ts.net:11434/v1",
        model: String = "gemma4:e4b",
        grounding: Bool = false
    ) -> XCUIApplication {
        var env = [
            "UITEST_SEED_LOCAL_ENDPOINT": endpoint,
            "UITEST_SEED_LOCAL_MODEL": model,
        ]
        if grounding { env["UITEST_SEED_GROUNDING"] = "1" }
        return launch(environment: env)
    }

    /// Soft-degrade send gate: tap through so a live completion still goes out.
    static func confirmSendIfAsked(_ app: XCUIApplication) {
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return }
        for title in ["send unencrypted", "send anyway (still encrypted)", "send anyway"] {
            let button = alert.buttons[title]
            if button.exists { button.tap(); return }
        }
    }

    static func sendLive(_ app: XCUIApplication, _ text: String, settle: TimeInterval = 120,
                         test: XCTestCase,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        typeIntoComposer(app, text, file: file, line: line)
        send(app, file: file, line: line)
        confirmSendIfAsked(app)
        let sent = elementContaining(app, text)
        if !sent.waitForExistence(timeout: 20) {
            attachScreenshot(app, name: "live-send-never-landed", to: test)
            XCTFail("prompt never landed: \(text)", file: file, line: line)
            return
        }
        XCTAssertTrue(waitUntilSettled(app, timeout: settle),
                      "live turn did not settle", file: file, line: line)
        let error = app.descendants(matching: .any)["chat.error"].firstMatch
        if error.exists {
            let hay = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ").lowercased()
            if hay.contains("http ") || hay.contains("401") || hay.contains("unauthorized")
                || hay.contains("422") || hay.contains("field required") {
                XCTFail("live turn ended on the error card: \(hay)", file: file, line: line)
            }
        }
    }

    /// 401 / missing key — skip, don't fail. The host-file inject should have
    /// filled an empty Keychain slot; this is the remaining honest miss.
    /// Wait until the title is no longer "verifying" so a live send is not
    /// racing the first attestation fetch.
    static func waitUntilNotVerifying(_ app: XCUIApplication, timeout: TimeInterval = 40) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let label = folded(titleLabel(app))
            if !label.contains("verifying") { return }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    /// Live send must go out sealed. Wait for the verified caption.
    @discardableResult
    static func waitUntilVerified(_ app: XCUIApplication, timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if titleLooksVerified(app) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return titleLooksVerified(app)
    }

    static func skipIfUnauthorized(_ app: XCUIApplication, timeout: TimeInterval = 8) throws {
        let auth = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                  "401", "unauthorized", "api key"))
            .firstMatch
        if auth.waitForExistence(timeout: timeout) {
            throw XCTSkip("provider rejected the request (\(auth.label)) — no usable key in this simulator")
        }
    }

    /// Local provider pointed at the in-process fake SSE server.
    static func launchLocal(
        server: EmbeddedFakeSSEServer,
        model: String = "fake-model",
        extraEnv: [String: String] = [:]
    ) -> XCUIApplication {
        var env: [String: String] = [
            "UITEST_SEED_LOCAL_ENDPOINT": server.baseURL,
            "UITEST_SEED_LOCAL_MODEL": model,
        ]
        extraEnv.forEach { env[$0] = $1 }
        return launch(environment: env)
    }

    static func composer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat.composer"].firstMatch
    }

    static func titleBlock(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat.titleBlock"].firstMatch
    }

    static func titleLabel(_ app: XCUIApplication) -> String {
        let block = titleBlock(app)
        guard block.waitForExistence(timeout: 10) else { return "" }
        return block.label
    }

    /// Type into the composer and confirm the characters landed (focus flake).
    static func typeIntoComposer(_ app: XCUIApplication, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 15), "composer not found", file: file, line: line)
        var typed = false
        for _ in 0..<3 where !typed {
            field.tap()
            Thread.sleep(forTimeInterval: 0.3)
            field.typeText(text)
            for _ in 0..<10 {
                let value = (field.value as? String) ?? field.label
                if value.contains(text) { typed = true; break }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        XCTAssertTrue(typed, "prompt never landed in the composer (value=\(field.value ?? "nil"))", file: file, line: line)
    }

    static func send(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["chat.send"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "send button not found", file: file, line: line)
        XCTAssertTrue(button.isEnabled, "send is disabled", file: file, line: line)
        button.tap()
    }

    /// Wait until generation has finished (`chat.stop` is gone).
    @discardableResult
    static func waitUntilSettled(_ app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        app.buttons["chat.stop"].waitForNonExistence(timeout: timeout)
    }

    static func sendAndWait(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        typeIntoComposer(app, text, file: file, line: line)
        send(app, file: file, line: line)
        let sent = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 15),
                      "prompt never appeared in the transcript: \(text)", file: file, line: line)
        XCTAssertTrue(waitUntilSettled(app, timeout: timeout),
                      "generation did not settle", file: file, line: line)
    }

    static func elementContaining(_ app: XCUIApplication, _ fragment: String) -> XCUIElement {
        // `matching` on the element's own label. `containing` matches ancestors
        // (including the application), so firstMatch would exist before the reply.
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
            .firstMatch
    }

    static func whereChip(_ app: XCUIApplication) -> XCUIElement {
        // SwiftUI duplicates the identifier on a parent and a child; only
        // the inner one carries the spoken label.
        let matches = app.descendants(matching: .any).matching(identifier: "chat.whereChip")
        let n = matches.count
        for i in 0..<n {
            let el = matches.element(boundBy: i)
            if !el.label.isEmpty { return el }
        }
        return matches.firstMatch
    }

    static func titleLooksMismatched(_ app: XCUIApplication) -> Bool {
        folded(titleLabel(app)).contains("didnt check out")
    }

    static func titleLooksBlocked(_ app: XCUIApplication) -> Bool {
        folded(titleLabel(app)).contains("sending blocked")
    }

    /// "not end-to-end encrypted" contains "end-to-end encrypted".
    static func titleLooksVerified(_ app: XCUIApplication) -> Bool {
        let label = folded(titleLabel(app))
        return label.contains("endtoend encrypted") && !label.contains("not endtoend encrypted")
    }

    /// Strip punctuation so "didn't" / "didn’t" / em-dash variants compare.
    static func folded(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    }

    static func attachScreenshot(_ app: XCUIApplication, name: String, to test: XCTestCase) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        test.add(shot)
    }

    static func openSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let gear = app.buttons["chat.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "settings gear missing", file: file, line: line)
        gear.tap()
        XCTAssertTrue(app.navigationBars["settings"].waitForExistence(timeout: 5),
                      "settings did not open", file: file, line: line)
    }

    static func dismissSettings(_ app: XCUIApplication) {
        let close = app.buttons["settings.close"]
        if close.waitForExistence(timeout: 3) {
            close.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
    }

    static func openChats(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let chats = app.buttons["list.bullet"].firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 10), "chats button missing", file: file, line: line)
        chats.tap()
        XCTAssertTrue(app.navigationBars["chats"].waitForExistence(timeout: 5),
                      "chats list did not open", file: file, line: line)
    }

    static func requireGroundingKey() throws {
        try requireHostKey(forPreset: "grounding")
    }

    /// Visible transcript must not leak tool markup the user is not meant to see.
    static func assertNoToolMarkup(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let hay = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        for leak in ["<tool_call>", "</tool_call>", "```tool_code", "tool_call_id",
                     "<｜DSML｜tool_calls>", "functions.web_search"] {
            XCTAssertFalse(hay.contains(leak), "tool markup leaked into the transcript: \(leak)",
                           file: file, line: line)
        }
    }

    static func sourcesChip(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat.sourcesChip"].firstMatch
    }

    static func webSearchOffer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat.webSearchOffer"].firstMatch
    }

    /// A completed grounded turn: the stacked sources chip, or a "N sources" label.
    static func sourcesAppeared(_ app: XCUIApplication, timeout: TimeInterval = 8) -> Bool {
        if sourcesChip(app).waitForExistence(timeout: timeout) { return true }
        return elementContaining(app, "source").waitForExistence(timeout: 2)
    }

    static func activityChip(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat.activityChip"].firstMatch
    }

    static func debugCard(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat.debugCard"].firstMatch
    }

    /// The thinking chip must sit on the leading edge, not in the middle of
    /// the full-width streaming host.
    static func assertChipIsLeading(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let chip = activityChip(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 8),
                      "thinking chip never appeared", file: file, line: line)
        let window = app.windows.firstMatch
        XCTAssertLessThan(chip.frame.midX, window.frame.midX * 0.55,
                          "thinking chip should sit on the leading edge, frame=\(chip.frame)",
                          file: file, line: line)
        XCTAssertLessThan(chip.frame.minX, 48,
                          "thinking chip leading edge should be near the left, minX=\(chip.frame.minX)",
                          file: file, line: line)
    }

    @discardableResult
    static func waitForDebugCardOnScreen(_ app: XCUIApplication, timeout: TimeInterval = 12) -> Bool {
        let card = debugCard(app)
        guard card.waitForExistence(timeout: timeout) else { return false }
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let f = card.frame
            if f.height > 0, f.minY < window.frame.maxY, f.maxY > window.frame.minY {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
}
