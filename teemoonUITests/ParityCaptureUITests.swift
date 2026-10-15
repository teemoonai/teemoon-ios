//
//  ParityCaptureUITests.swift
//  teemoonUITests
//
//  Captures every screen the Android port stands in for, under the same names the
//  Android driver uses, so the two can be laid side by side. Writes to
//  /tmp/teemoon-parity/ios/<name>.png. Not part of any gate; run on purpose:
//
//    xcodebuild test -scheme teemoon -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//      -only-testing:teemoonUITests/ParityCaptureUITests
//
import XCTest

final class ParityCaptureUITests: XCTestCase {

    private let outputDir = URL(fileURLWithPath: "/tmp/teemoon-parity/ios")

    override func setUpWithError() throws {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        Thread.sleep(forTimeInterval: 0.8)
        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(to: outputDir.appendingPathComponent("\(name).png"))
        let tree = app.debugDescription
        try? tree.write(to: outputDir.appendingPathComponent("\(name).tree.txt"), atomically: true, encoding: .utf8)
    }

    /// Tap the first element that exists among identifier, label, or partial label — screens name things differently.
    @discardableResult
    private func tapFirst(_ app: XCUIApplication, _ candidates: [String], timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for c in candidates {
                let byId = app.descendants(matching: .any).matching(identifier: c).firstMatch
                if byId.exists && byId.isHittable { byId.tap(); return true }
                // Labels: exact and case-sensitive, buttons and segments only — "settings" must not match the gear's "Settings".
                for q in [app.buttons, app.segmentedControls.buttons, app.cells] {
                    let byLabel = q.matching(NSPredicate(format: "label == %@", c)).firstMatch
                    if byLabel.exists && byLabel.isHittable { byLabel.tap(); return true }
                }
                let contains = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", c)).firstMatch
                if contains.exists && contains.isHittable { contains.tap(); return true }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    private func launch(env: [String: String], extraArgs: [String] = []) -> XCUIApplication {
        // The tint is forced to the product default so a stale simulator preference can't colour the captures.
        return ProductE2E.launch(arguments: ["--uitesting", "-appTintColor", "orange"] + extraArgs, environment: env)
    }

    /// The NO-KEY state. `ProductE2E.launch` stages every host key file it finds and the app reads the Brave
    /// grounding key straight from that directory, so a plain launch is never unkeyed. Point every host-home
    /// lookup at an empty directory instead. The simulator must also be erased before this run — keys live in
    /// the keychain, keyed by endpoint, and survive reinstalls (2026-09-04: "browse grok" opened the browser
    /// and web search showed a key from a run days earlier).
    private func launchUnkeyed(env: [String: String], extraArgs: [String] = []) -> XCUIApplication {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("teemoon-parity-nokeys", isDirectory: true)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        var e = env
        e["TEEMOON_STAGED_KEYS"] = empty.path; e["TEEMOON_HOST_HOME"] = empty.path; e["SIMULATOR_HOST_HOME"] = empty.path
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-appTintColor", "orange"] + extraArgs
        app.launchEnvironment = e
        app.launch()
        dismissFirstBootOverlays(app)
        return app
    }

    /// An erased simulator greets the first launch with a keyboard tip ("Speed up your typing…") and a system
    /// banner; both photobombed the first capture of the no-key run (2026-09-05). Wait them out.
    private func dismissFirstBootOverlays(_ app: XCUIApplication) {
        // the keyboard tip is drawn in the app's own process; the banner is springboard's
        let cont = app.buttons["Continue"]
        if cont.waitForExistence(timeout: 3) { cont.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cont2 = springboard.buttons["Continue"]
        if cont2.waitForExistence(timeout: 1) { cont2.tap() }
        Thread.sleep(forTimeInterval: 6)   // the banner leaves on its own
    }

    private func closeSheet(_ app: XCUIApplication) {
        if !tapFirst(app, ["settings.close", "attestation.close", "close", "xmark", "done", "cancel"], timeout: 3) {
            app.swipeDown()
        }
        Thread.sleep(forTimeInterval: 0.8)
    }

    // MARK: run 1 — a home server that is down

    /// State A — a home server and NO cloud keys: chats_list is empty, where_cloud / places_cloud are unkeyed,
    /// "browse grok" opens the add-key form, web search shows the get-a-key path.
    func test1_localScreens() throws {
        let app = launchUnkeyed(env: ["UITEST_SEED_LOCAL_ENDPOINT": "http://127.0.0.1:9/v1", "UITEST_SEED_LOCAL_MODEL": "fake-model"])
        _ = app.descendants(matching: .any)["chat.composer"].waitForExistence(timeout: 15)
        save("chat_empty", app)

        // chats list
        tapFirst(app, ["list.bullet", "chats"])
        save("chats_list", app); closeSheet(app)

        // where, four segments
        tapFirst(app, ["chat.whereChip"])
        Thread.sleep(forTimeInterval: 1.2); save("where_all", app)
        for seg in ["phone", "home", "cloud"] { tapFirst(app, [seg]); save("where_\(seg)", app) }
        tapFirst(app, ["all"])

        // add key sheet from the browse row, then the custom computer flow
        // near.ai is keyed under the harness (staged host key), so its row opens the browser; grok is unkeyed and opens the add-key sheet.
        if tapFirst(app, ["browse near.ai"]) { Thread.sleep(forTimeInterval: 3); save("model_browser_near", app); closeSheet(app) }
        app.swipeUp(); Thread.sleep(forTimeInterval: 0.6)
        if tapFirst(app, ["browse grok"]) { save("add_key_grok", app); closeSheet(app) }
        if tapFirst(app, ["connect a computer"]) { save("add_computer", app); closeSheet(app) }
        closeSheet(app)

        // settings and its pages
        tapFirst(app, ["chat.settings", "settings"])
        save("settings_root", app)
        if tapFirst(app, ["appearance"]) { save("appearance", app); tapFirst(app, ["settings"]) }
        if tapFirst(app, ["chats"]) { save("chats_settings", app); tapFirst(app, ["settings"]) }
        if tapFirst(app, ["search"]) { save("search_settings", app); tapFirst(app, ["settings"]) }
        if tapFirst(app, ["settings.providers", "places & keys"]) {
            save("places_hub", app)
            if tapFirst(app, ["home machines"]) { save("places_machines", app); tapFirst(app, ["places & keys"]) }
            if tapFirst(app, ["cloud keys"]) { save("places_cloud", app); tapFirst(app, ["places & keys"]) }
            tapFirst(app, ["settings"])
        }
        closeSheet(app)

        // the trust screen for a home server
        if tapFirst(app, ["chat.titleBlock", "chat.trustChip"]) { save("trust_local", app); closeSheet(app) }

        // a turn that fails: the server is down
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        composer.tap(); composer.typeText("what is the capital of france?")
        tapFirst(app, ["chat.send"])
        Thread.sleep(forTimeInterval: 6)
        save("chat_failed_turn", app)
    }

    // MARK: run 2 — near.ai, keyed, live

    func test2_nearAIScreens() throws {
        try ProductE2E.requireHostKey(forPreset: "nearai")
        let app = launch(env: ["UITEST_SEED_NEARAI_MODEL": "z-ai/glm-5.2"])
        _ = app.descendants(matching: .any)["chat.composer"].waitForExistence(timeout: 15)
        _ = ProductE2E.waitUntilVerified(app, timeout: 180)
        save("chat_near_verified", app)

        if tapFirst(app, ["chat.titleBlock", "chat.trustChip"]) {
            save("trust_everyday", app)
            if tapFirst(app, ["expert", "proof", "see the proof", "attestation.showProof"]) { save("trust_proof", app); app.swipeUp(); save("trust_proof_2", app) }
            closeSheet(app)
        }

        tapFirst(app, ["chat.whereChip"]); Thread.sleep(forTimeInterval: 1.2); save("where_all_keyed", app)
        if tapFirst(app, ["browse near.ai"]) { Thread.sleep(forTimeInterval: 4); save("model_browser_near", app); closeSheet(app) }
        closeSheet(app)

        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        composer.tap(); composer.typeText("name three moons of jupiter.")
        tapFirst(app, ["chat.send"])
        if app.alerts.firstMatch.waitForExistence(timeout: 3) { save("send_gate", app) }
        ProductE2E.confirmSendIfAsked(app)
        let stop = app.descendants(matching: .any)["chat.stop"].firstMatch
        _ = stop.waitForExistence(timeout: 20)
        let gone = NSPredicate(format: "exists == false")
        _ = XCTWaiter().wait(for: [expectation(for: gone, evaluatedWith: stop)], timeout: 120)
        Thread.sleep(forTimeInterval: 1.5)
        save("chat_near_reply", app)
        // the sources sheet, when the reply was grounded — paired with Android's sources_sheet
        let sourcesChip = app.descendants(matching: .any)["chat.sourcesChip"].firstMatch
        if sourcesChip.waitForExistence(timeout: 2) { sourcesChip.tap(); Thread.sleep(forTimeInterval: 1.2); save("sources_sheet", app); closeSheet(app) }

        // State B — keyed: the list with a thread in it, the cloud filter and places with the near.ai key,
        // web search with the staged Brave key.
        tapFirst(app, ["list.bullet", "chats"]); save("chats_list_populated", app); closeSheet(app)
        tapFirst(app, ["chat.whereChip"]); Thread.sleep(forTimeInterval: 1.2)
        tapFirst(app, ["cloud"]); save("where_cloud_keyed", app); tapFirst(app, ["all"]); closeSheet(app)
        tapFirst(app, ["chat.settings", "settings"])
        // The Brave key is saved when the field loses focus (`onSubmit`), and the page decides its layout on
        // appear (`showsGetKeyPath = key.isEmpty`) — so type it, submit, leave and come back.
        if tapFirst(app, ["search"]) {
            if let home = ProductE2E.runnerHostHome(),
               let brave = try? String(contentsOfFile: home + "/.BRAVE_API_KEY", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !brave.isEmpty {
                let field = app.textFields["api key"].firstMatch.exists ? app.textFields["api key"].firstMatch : app.secureTextFields["api key"].firstMatch
                if field.waitForExistence(timeout: 4) { field.tap(); field.typeText(brave + "\n") }
                Thread.sleep(forTimeInterval: 2)
                tapFirst(app, ["settings"]); Thread.sleep(forTimeInterval: 0.6); tapFirst(app, ["search"])
            }
            save("search_settings_keyed", app); tapFirst(app, ["settings"])
        }
        if tapFirst(app, ["settings.providers", "places & keys"]) {
            save("places_hub_keyed", app)
            if tapFirst(app, ["cloud keys"]) { save("places_cloud_keyed", app); tapFirst(app, ["places & keys"]) }
            tapFirst(app, ["settings"])
        }
        closeSheet(app)
    }

    /// State B for grok: the preset seeded with the host key, so "browse grok" opens the browser.
    func test2b_grokBrowser() throws {
        try ProductE2E.requireHostKey(forPreset: "grok")
        let app = launch(env: ["UITEST_SEED_PRESET": "grok"])
        _ = app.descendants(matching: .any)["chat.composer"].waitForExistence(timeout: 15)
        tapFirst(app, ["chat.whereChip"]); Thread.sleep(forTimeInterval: 1.2)
        app.swipeUp(); Thread.sleep(forTimeInterval: 0.6)
        if tapFirst(app, ["browse grok"]) { Thread.sleep(forTimeInterval: 4); save("browse_grok", app); closeSheet(app) }
        closeSheet(app)
    }

    // MARK: run 3 — first run, nothing configured

    /// State B for fireworks: the preset seeded with the host key, so "browse fireworks" opens the browser.
    func test2c_fireworksBrowser() throws {
        try ProductE2E.requireHostKey(forPreset: "fireworks")
        let app = launch(env: ["UITEST_SEED_PRESET": "fireworks"])
        _ = app.descendants(matching: .any)["chat.composer"].waitForExistence(timeout: 15)
        tapFirst(app, ["chat.whereChip"]); Thread.sleep(forTimeInterval: 1.2)
        app.swipeUp(); Thread.sleep(forTimeInterval: 0.6)
        if tapFirst(app, ["browse fireworks"]) { Thread.sleep(forTimeInterval: 4); save("browse_fireworks", app); closeSheet(app) }
        closeSheet(app)
    }

    /// State B for Brave Answers: the fixed-answer place seeded with its key — the chat with it equipped, the cloud
    /// filter with every key the keychain now holds (near.ai, grok, fireworks, brave answers — the earlier runs left
    /// theirs), and web search's "search is built in here" state.
    func test2d_braveAnswers() throws {
        try ProductE2E.requireHostKey(forPreset: "brave")
        let app = launch(env: ["UITEST_SEED_PRESET": "braveanswers"])
        _ = app.descendants(matching: .any)["chat.composer"].waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1.5); save("chat_brave", app)
        tapFirst(app, ["chat.whereChip"]); Thread.sleep(forTimeInterval: 1.2)
        tapFirst(app, ["cloud"]); save("where_cloud_allkeys", app); tapFirst(app, ["all"]); closeSheet(app)
        tapFirst(app, ["chat.settings", "settings"])
        if tapFirst(app, ["search"]) { save("search_settings_builtin", app); tapFirst(app, ["settings"]) }
        closeSheet(app)
    }

    /// The send gate: a degraded attestation (UITEST_SEED_ATTESTATION, the DEBUG door) makes the first send ask.
    func test2e_sendGate() throws {
        try ProductE2E.requireHostKey(forPreset: "nearai")
        let app = launch(env: ["UITEST_SEED_NEARAI_MODEL": "z-ai/glm-5.2", "UITEST_SEED_ATTESTATION": "degraded"])
        _ = app.descendants(matching: .any)["chat.composer"].waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 2); save("chat_degraded", app)
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        composer.tap(); composer.typeText("hello")
        tapFirst(app, ["chat.send"])
        if app.alerts.firstMatch.waitForExistence(timeout: 5) { save("send_gate", app); tapFirst(app, ["cancel", "Cancel"]) }
    }

    func test3_firstRun() throws {
        let app = launch(env: [:], extraArgs: ["--uitesting-capture"])
        _ = app.descendants(matching: .any)["chat.composer"].waitForExistence(timeout: 15)
        save("chat_first_run", app)
        tapFirst(app, ["chat.whereChip"]); Thread.sleep(forTimeInterval: 1.2); save("where_first_run", app)
    }

    // MARK: run 4 — the chat itself, with a reply (the embedded fake server), and the populated chats list

    static let parityReply = "## Harbour notes\n\nThe tide turns at **four**, and the pilot boards at the outer buoy.\n\n- first buoy: green, flashing\n- second buoy: red, steady\n\n```\nlet tide = 4\n```\n\nSee [the chart](https://example.org/chart) for the soundings."

    func test4_chatReply() throws {
        let server = try EmbeddedFakeSSEServer(lines: 6, delay: 0.005)
        defer { server.stop() }
        server.replies = [Self.parityReply]
        let app = launchUnkeyed(env: ["UITEST_SEED_LOCAL_ENDPOINT": server.baseURL, "UITEST_SEED_LOCAL_MODEL": "fake-model", "UITEST_SEED_THREADS": "1"])
        ProductE2E.sendAndWait(app, "what are the harbour notes?")
        _ = ProductE2E.waitUntilSettled(app, timeout: 20)
        app.tap()   // the keyboard down, as the Android capture has it
        save("chat_reply", app)
        _ = tapFirst(app, ["chat.threads", "chats", "List"])
        Thread.sleep(forTimeInterval: 1)
        save("chats_populated", app)
    }
}
