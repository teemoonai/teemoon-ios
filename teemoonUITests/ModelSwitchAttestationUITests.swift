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
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = "z-ai/glm-5.3-flash"
        app.launch()

        // 1. Open the attestation sheet via the title chip and wait until the
        //    5.2 record actually loads (hero mentions the model, not verifying).
        let chip = ProductE2E.titleBlock(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "title chip not found")
        chip.tap()
        let sheetTitle = app.staticTexts["who can read this?"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), "attestation sheet did not open")
        let heroMentions52 = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "glm-5.3")).firstMatch
        XCTAssertTrue(heroMentions52.waitForExistence(timeout: 25),
                      "attestation for GLM-5.2 never loaded (network?)")
        takeShot(app, name: "1-sheet-52-loaded")
        let closeSheet = app.buttons["attestation.close"].firstMatch
        XCTAssertTrue(closeSheet.waitForExistence(timeout: 5), "close button missing")
        closeSheet.tap()

        // 2. Switch the model through where → cloud → browse near.ai → search → pick (settings has no providers list
        //    to edit since places & keys; the where sheet is the door a user takes)
        ProductE2E.whereChip(app).tap()
        app.buttons["cloud"].firstMatch.tap()
        let browse = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "open models in enclaves")).firstMatch
        for _ in 0..<3 where !browse.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(browse.exists, "no near.ai row to browse from")
        browse.tap()
        let search = app.searchFields["search models"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20), "the model browser did not open")
        search.tap(); search.typeText("qwen 3.6")
        let pick = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "qwen 3.6")).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 30), "the browser offers no Qwen 3.6")
        pick.tap()
        takeShot(app, name: "2-switched")

        // 3. Reopen the attestation sheet: it must speak about DeepSeek V4 Flash and
        //    must NEVER mention GLM-5.2 again — poll for 12 s, because the
        //    reported bug shows the old model immediately or races back in.
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "title chip missing after switch")
        chip.tap()
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), "sheet did not reopen")
        takeShot(app, name: "3-sheet-after-switch")
        let mentions52 = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "glm-5.3"))
        let mentions51 = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "qwen"))
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
            "STALE ATTESTATION: sheet mentioned GLM-5.3 after switching to Qwen 3.6")
        XCTAssertTrue(mentions51.firstMatch.exists,
            "sheet never started speaking about Qwen 3.6")
        takeShot(app, name: "4-final")
    }

    /// Everyday sheet from the identifier — names the seeded model once the
    /// live record lands. Network, no completion spend.
    func testEverydayLadderOpensAndNamesTheModel() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = "z-ai/glm-5.3-flash"
        app.launch()

        let chip = ProductE2E.titleBlock(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "title chip not found")
        chip.tap()
        XCTAssertTrue(app.staticTexts["who can read this?"].waitForExistence(timeout: 5),
                      "everyday sheet did not open")
        let hero = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "glm-5.3")).firstMatch
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
            ProcessInfo.processInfo.environment["TIER_SEED_MODEL"] ?? "z-ai/glm-5.3-flash"
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
    func testGlm53FlashSheetNamesOnlyGlm() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = "z-ai/glm-5.3-flash"   // DeepSeek V4 Flash left near.ai (2026-10)
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
            if now.contains("glm") || now.contains("qwen") { break }
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 1)
        }
        sleep(3)
        let labels = dump()
        let att = XCTAttachment(string: labels)
        att.name = "STATIC-TEXTS"; att.lifetime = .keepAlways; add(att)
        takeShot(app, name: "glm-flash-sheet")

        let lower = labels.lowercased()
        XCTAssertTrue(lower.contains("glm"),
                      "sheet never named GLM (labels:\n\(labels))")
        XCTAssertFalse(lower.contains("qwen"),
                       "the GLM 5.3 Flash sheet names a Qwen (labels:\n\(labels))")
    }

    /// The combined-node scoping fix, on today's fleet: Qwen3.8-27B's expert sheet shows ITS serving engine and none
    /// of the other own-fleet models. (Written for Gemma 4 31B, which near.ai served beside DeepSeek/Qwen until 2026-10.)
    func testQwen38SheetShowsItsOwnImage() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = "Qwen/Qwen3.8-27B"   // Gemma 4 31B left near.ai (2026-10)
        app.launch()

        let chip = ProductE2E.titleBlock(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "title chip not found")
        chip.tap()
        XCTAssertTrue(app.staticTexts["who can read this?"].waitForExistence(timeout: 5),
                      "attestation sheet did not open")

        // Wait for the live record to load and name the model in the hero.
        let hero = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "27b")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 45),
                      "attestation never loaded / never named Qwen3.8-27B (network / model id?)")

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
        takeShot(app, name: "qwen38-0-top")
        for i in 1...8 {
            app.swipeUp(velocity: .slow); sleep(1)
            seen += "\n" + haystack()
            takeShot(app, name: "qwen38-\(i)")
        }

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "ACCESSIBILITY-TREE"; tree.lifetime = .keepAlways; add(tree)

        XCTAssertTrue(seen.contains("vllm") || seen.contains("sglang"),
                      "the Qwen3.8 sheet shows no serving engine (tree:\n\(seen))")
        // ABOVE "the running recipe" only: the recipe section lists every image the signed recipe declares and the
        // audits of them — fleet-wide by design, so other models' services are named there legitimately. The
        // tokens are ones a hex digest cannot contain ("35b" matched a gpu signing address).
        let scoped = seen.components(separatedBy: "the running recipe").first ?? seen
        let other = ["glm", "qwen3.6", "35b-a3b"].first { scoped.contains($0) }
        var context = ""
        if let other, let r = scoped.range(of: other) {
            let lo = scoped.index(r.lowerBound, offsetBy: -160, limitedBy: scoped.startIndex) ?? scoped.startIndex
            let hi = scoped.index(r.upperBound, offsetBy: 160, limitedBy: scoped.endIndex) ?? scoped.endIndex
            context = String(scoped[lo..<hi])
        }
        XCTAssertNil(other, "the Qwen3.8 sheet names another model of the fleet — \(other ?? ""): …\(context)…")
    }

    /// Counterpart to the Qwen3.8 test: Qwen 3.6 is SGLang-served on the SAME
    /// combined node as Gemma (vLLM) and DeepSeek. The sheet must still show the
    /// sglang engine and must NOT surface the co-located Gemma vLLM image.
    func testQwen36ShowsSglangNotVllm() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = "Qwen/Qwen3.6-35B-A3B-FP8"   // the 27B left near.ai (2026-10)
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

        // The name is history: the 27B this was written for ran sglang beside a co-located Gemma vLLM, and the bug was
        // the sheet showing Gemma's engine. Both left near.ai (2026-10); the 35B-A3B that replaced them is served by
        // vLLM itself — the signed recipe's "handles your message" names vllm/vllm-openai as what runs the model — so
        // "vllm" is now the truthful answer, and the check is the one the 3.8 case makes: an engine is named, and
        // nothing above the fleet-wide recipe names another model.
        XCTAssertTrue(seen.contains("vllm") || seen.contains("sglang"),
                      "the Qwen3.6 sheet shows no serving engine (tree:\n\(seen))")
        let scoped = seen.components(separatedBy: "the running recipe").first ?? seen
        let other = ["glm", "qwen3.8", "27b"].first { scoped.contains($0) }
        XCTAssertNil(other, "the Qwen3.6 sheet names another fleet model (\(other ?? "")) above the recipe (tree:\n\(scoped))")
    }

    /// Capture-only: GLM-5.1 runs a `:local` in-enclave build patched from a
    /// base sglang image (`FROM lmsysorg/sglang@sha256:…` in the compose). Dump
    /// what the engine row actually renders so we can see whether the base + its
    /// audit surface.
    func testCaptureGLM51EngineRow() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = "z-ai/glm-5.3-flash"
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
