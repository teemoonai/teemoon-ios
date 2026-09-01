//
//  ModelSwitchAttestationUITests.swift
//  teemoonUITests
//
//  End-to-end reproduction of the stale-attestation-after-model-switch bug:
//  seed near.ai on GLM-5.2, let attestation load, switch the model to
//  GLM-5.1 through the real Settings flow, and assert the attestation sheet
//  never shows the old model again. Live network (near.ai attestation
//  endpoints, no API key required for attestation fetch).
//

import XCTest

final class ModelSwitchAttestationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSwitchingModelNeverShowsOldAttestation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = "z-ai/glm-5.2"
        app.launch()

        // 1. Open the attestation sheet via the title chip and wait until the
        //    5.2 record actually loads (hero mentions the model, not verifying).
        let chip = ProductE2E.titleBlock(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "title chip not found")
        chip.tap()
        let sheetTitle = app.staticTexts["who can read this?"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), "attestation sheet did not open")
        let heroMentions52 = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "glm-5.2")).firstMatch
        XCTAssertTrue(heroMentions52.waitForExistence(timeout: 25),
                      "attestation for GLM-5.2 never loaded (network?)")
        takeShot(app, name: "1-sheet-52-loaded")
        let closeSheet = app.buttons["attestation.close"].firstMatch
        XCTAssertTrue(closeSheet.waitForExistence(timeout: 5), "close button missing")
        closeSheet.tap()

        // 2. Switch the model to GLM-5.1 through the real Settings flow.
        let gear = app.buttons["chat.settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "settings gear missing")
        gear.tap()
        let providersRow = app.buttons["settings.providers"].exists
            ? app.buttons["settings.providers"].firstMatch
            : app.staticTexts["providers"].firstMatch
        XCTAssertTrue(providersRow.waitForExistence(timeout: 5), "settings: providers row missing")
        providersRow.tap()
        // Rows are labeled by MODEL display name; editing is a leading swipe.
        let nearRow = app.staticTexts["near.ai GLM 5.2"].firstMatch
        XCTAssertTrue(nearRow.waitForExistence(timeout: 5), "providers: near.ai GLM 5.2 row missing")
        nearRow.swipeRight()
        let editButton = app.buttons["edit"].firstMatch
        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "edit swipe action missing")
        editButton.tap()
        let modelField = app.textFields["model"].firstMatch
        XCTAssertTrue(modelField.waitForExistence(timeout: 5), "edit form: model field missing")
        modelField.tap()
        // Clear the field, then type the new id.
        let current = (modelField.value as? String) ?? ""
        modelField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 5))
        modelField.typeText("zai-org/GLM-5.1-FP8")
        takeShot(app, name: "2-model-field-51")
        let save = app.buttons["save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "save button missing")
        save.tap()
        // Discriminating check: the save must actually land in the store —
        // the providers row now reads GLM 5.1. If this fails, the bug is in
        // the edit/save wiring, not in attestation invalidation.
        let nearRow51 = app.staticTexts["near.ai GLM 5.1"].firstMatch
        XCTAssertTrue(nearRow51.waitForExistence(timeout: 5),
                      "SAVE DID NOT LAND: providers row still shows the old model")
        takeShot(app, name: "2b-row-shows-51")
        // Back out of settings to the chat.
        let backOut = app.navigationBars.buttons.firstMatch
        if backOut.exists { backOut.tap() }
        if app.buttons["done"].firstMatch.exists { app.buttons["done"].firstMatch.tap() }
        app.swipeDown(velocity: .fast)   // dismiss settings sheet if still up

        // 3. Reopen the attestation sheet: it must speak about GLM-5.1 and
        //    must NEVER mention GLM-5.2 again — poll for 12 s, because the
        //    reported bug shows the old model immediately or races back in.
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "title chip missing after switch")
        chip.tap()
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), "sheet did not reopen")
        takeShot(app, name: "3-sheet-after-switch")
        let mentions52 = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "glm-5.2"))
        let mentions51 = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "glm-5.1"))
        let deadline = Date().addingTimeInterval(12)
        var sawOldModel = false
        while Date() < deadline {
            if mentions52.firstMatch.exists {
                sawOldModel = true
                takeShot(app, name: "X-STALE-52-VISIBLE")
                break
            }
            _ = mentions51.firstMatch.waitForExistence(timeout: 1)
        }
        XCTAssertFalse(sawOldModel,
            "STALE ATTESTATION: sheet mentioned GLM-5.2 after switching to GLM-5.1")
        XCTAssertTrue(mentions51.firstMatch.exists,
            "sheet never started speaking about GLM-5.1")
        takeShot(app, name: "4-final")
    }

    /// Everyday sheet from the identifier — names the seeded model once the
    /// live record lands. Network, no completion spend.
    func testEverydayLadderOpensAndNamesTheModel() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = "z-ai/glm-5.2"
        app.launch()

        let chip = ProductE2E.titleBlock(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "title chip not found")
        chip.tap()
        XCTAssertTrue(app.staticTexts["who can read this?"].waitForExistence(timeout: 5),
                      "everyday sheet did not open")
        let hero = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "glm-5.2")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 40),
                      "everyday hero never named GLM-5.2 (network?)")
        takeShot(app, name: "everyday-names-52")
    }

    /// Capture harness: drive the REAL attestation flow to the expert
    /// known-code list and dump the full accessibility tree + screenshots, so
    /// we can see exactly which plaintext-tier capsule each image row renders
    /// on live near.ai data (the thing the simulator fixture can't reproduce).
    func testCaptureExpertKnownCodeTiers() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] =
            ProcessInfo.processInfo.environment["TIER_SEED_MODEL"] ?? "zai-org/GLM-5.1-FP8"
        app.launch()

        let chip = ProductE2E.titleBlock(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "title chip not found")
        chip.tap()
        XCTAssertTrue(app.staticTexts["who can read this?"].waitForExistence(timeout: 5),
                      "attestation sheet did not open")
        // Wait for the live attestation record to load (hero names the model).
        let hero = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "glm-5")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 40),
                      "attestation never loaded (network / model id?)")

        // Switch to the expert rung (segmented control button).
        let expert = app.buttons["expert"].firstMatch
        if expert.waitForExistence(timeout: 5) { expert.tap() }
        sleep(3)  // let known-code + capability tags render

        // The whole point: dump every element label so each image row's tier
        // capsule ("can reach enclave processes" / "reads container logs") or
        // its absence is visible without needing to scroll to it.
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "ACCESSIBILITY-TREE"; tree.lifetime = .keepAlways; add(tree)
        let labels = app.staticTexts.allElementsBoundByIndex.map { $0.label }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let lt = XCTAttachment(string: labels)
        lt.name = "STATIC-TEXTS"; lt.lifetime = .keepAlways; add(lt)

        // Screenshots down the sheet so the known-code rows are visible too.
        takeShot(app, name: "tier-0-top")
        for i in 1...6 { app.swipeUp(velocity: .slow); sleep(1); takeShot(app, name: "tier-\(i)") }
    }

    /// Reproduction: selecting DeepSeek V4 Flash must not brand the sheet Qwen
    /// (and vice versa). The near.ai node's compose-manager action log holds
    /// multiple models' compose_up entries; `latestComposeUp` takes the LAST one
    /// regardless of model, so the wrong model-layer YAML → wrong artifact/name.
    func testDeepSeekFlashDoesNotShowQwen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = "deepseek-ai/DeepSeek-V4-Flash"
        app.launch()

        let chip = ProductE2E.titleBlock(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "title chip not found")
        chip.tap()
        XCTAssertTrue(app.staticTexts["who can read this?"].waitForExistence(timeout: 5),
                      "attestation sheet did not open")

        // Poll up to 45s for the record to name a model (deepseek or qwen).
        let deadline = Date().addingTimeInterval(45)
        func dump() -> String {
            app.staticTexts.allElementsBoundByIndex.map { $0.label }
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
        while Date() < deadline {
            let now = dump().lowercased()
            if now.contains("deepseek") || now.contains("qwen") { break }
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 1)
        }
        sleep(3)
        let labels = dump()
        let att = XCTAttachment(string: labels)
        att.name = "STATIC-TEXTS"; att.lifetime = .keepAlways; add(att)
        takeShot(app, name: "deepseek-flash-sheet")

        let lower = labels.lowercased()
        XCTAssertTrue(lower.contains("deepseek"),
                      "sheet never named DeepSeek (labels:\n\(labels))")
        XCTAssertFalse(lower.contains("qwen"),
                       "BUG REPRODUCED: DeepSeek Flash sheet is branded Qwen (labels:\n\(labels))")
    }

    /// Verification for the reused/combined-node scoping fix: Gemma is served by
    /// vLLM on a node it SHARES with DeepSeek/Qwen (SGLang). Before scoping, the
    /// Gemma sheet surfaced the co-located `lmsysorg/sglang` server. The sheet
    /// must now render Gemma's own `vllm/vllm-openai` engine image and NOT sglang.
    func testGemmaShowsVllmImageNotSglang() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = "google/gemma-4-31B-it"
        app.launch()

        let chip = ProductE2E.titleBlock(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "title chip not found")
        chip.tap()
        XCTAssertTrue(app.staticTexts["who can read this?"].waitForExistence(timeout: 5),
                      "attestation sheet did not open")

        // Wait for the live record to load and name Gemma in the hero.
        let hero = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "gemma")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 45),
                      "attestation never loaded / never named Gemma (network / model id?)")

        // Expert rung exposes the per-image known-code rows.
        let expert = app.buttons["expert"].firstMatch
        if expert.waitForExistence(timeout: 5) { expert.tap() }
        sleep(3)

        // Haystack = every rendered label (image rows can be buttons/other, so
        // scan the whole accessibility tree, not just staticTexts).
        func haystack() -> String {
            let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }
            return (texts.joined(separator: "\n") + "\n" + app.debugDescription).lowercased()
        }
        // Scroll the sheet so every image row is realized into the tree.
        var seen = haystack()
        takeShot(app, name: "gemma-0-top")
        for i in 1...8 {
            app.swipeUp(velocity: .slow); sleep(1)
            seen += "\n" + haystack()
            takeShot(app, name: "gemma-\(i)")
        }

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "ACCESSIBILITY-TREE"; tree.lifetime = .keepAlways; add(tree)

        XCTAssertTrue(seen.contains("vllm"),
                      "Gemma sheet never showed a vLLM image row (tree:\n\(seen))")
        XCTAssertFalse(seen.contains("sglang"),
                       "BUG: Gemma sheet still surfaces the co-located SGLang server (tree:\n\(seen))")
    }

    /// Counterpart to the Gemma test: Qwen 3.6-27B is SGLang-served on the SAME
    /// combined node as Gemma (vLLM) and DeepSeek. The sheet must still show the
    /// sglang engine and must NOT surface the co-located Gemma vLLM image.
    func testQwen36ShowsSglangNotVllm() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = "Qwen/Qwen3.6-27B-FP8"
        app.launch()

        let chip = ProductE2E.titleBlock(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "title chip not found")
        chip.tap()
        XCTAssertTrue(app.staticTexts["who can read this?"].waitForExistence(timeout: 5),
                      "attestation sheet did not open")
        let hero = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "qwen")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 45), "attestation never named Qwen")

        let expert = app.buttons["expert"].firstMatch
        if expert.waitForExistence(timeout: 5) { expert.tap() }
        sleep(3)

        func haystack() -> String {
            let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }
            return (texts.joined(separator: "\n") + "\n" + app.debugDescription).lowercased()
        }
        var seen = haystack()
        takeShot(app, name: "qwen-0-top")
        for i in 1...8 {
            app.swipeUp(velocity: .slow); sleep(1)
            seen += "\n" + haystack()
            takeShot(app, name: "qwen-\(i)")
        }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "ACCESSIBILITY-TREE"; tree.lifetime = .keepAlways; add(tree)

        XCTAssertTrue(seen.contains("sglang"),
                      "Qwen sheet never showed an sglang engine row (tree:\n\(seen))")
        XCTAssertFalse(seen.contains("vllm-openai"),
                       "BUG: Qwen sheet surfaced the co-located Gemma vLLM image (tree:\n\(seen))")
    }

    /// Capture-only: GLM-5.1 runs a `:local` in-enclave build patched from a
    /// base sglang image (`FROM lmsysorg/sglang@sha256:…` in the compose). Dump
    /// what the engine row actually renders so we can see whether the base + its
    /// audit surface.
    func testCaptureGLM51EngineRow() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = "zai-org/GLM-5.1-FP8"
        app.launch()
        let chip = ProductE2E.titleBlock(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "title chip not found")
        chip.tap()
        XCTAssertTrue(app.staticTexts["who can read this?"].waitForExistence(timeout: 5),
                      "attestation sheet did not open")
        let hero = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "glm-5")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 45), "attestation never named GLM")
        let expert = app.buttons["expert"].firstMatch
        if expert.waitForExistence(timeout: 5) { expert.tap() }
        sleep(3)
        takeShot(app, name: "glm-0-top")
        for i in 1...8 { app.swipeUp(velocity: .slow); sleep(1); takeShot(app, name: "glm-\(i)") }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "ACCESSIBILITY-TREE"; tree.lifetime = .keepAlways; add(tree)
    }

    private func takeShot(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
