//
//  ProductE2ETests.swift
//  teemoonUITests
//
//  Tier A: offline product E2E. Embedded fake SSE, no API keys, no live near.ai.
//  This is the suite CI runs — not the whole teemoonUITests target.
//

import XCTest

final class ProductE2ETests: XCTestCase {

    private var server: EmbeddedFakeSSEServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try EmbeddedFakeSSEServer(lines: 1, delay: 0.005)
        server.replies = ["first-reply-alpha"]
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    // MARK: - Launch / composer

    func testLaunchShowsComposerAndDisabledSend() {
        let app = ProductE2E.launchLocal(server: server)
        let composer = ProductE2E.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "composer missing")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "send missing")
        XCTAssertFalse(send.isEnabled, "send should be disabled when the composer is empty")
    }

    // MARK: - Chat

    func testSendThenSettleShowsAReply() {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "ping-one")
        XCTAssertTrue(ProductE2E.elementContaining(app, "first-reply-alpha").waitForExistence(timeout: 10),
                      "assistant reply never appeared")
        XCTAssertFalse(app.buttons["chat.stop"].exists, "stop still up after settle")
        // Guard for the fail-closed E2EE work (findings 4.1/4.5): a normal
        // send on a NON-attested provider must stay entirely unaffected — a
        // reply, and no error surface. If a fail-closed guard ever misfires
        // on the ordinary path, this is the assertion that catches it.
        XCTAssertFalse(app.descendants(matching: .any)["chat.error"].firstMatch.exists,
                       "a legitimate send must not raise the error surface")
    }

    func testSecondSendGetsASecondReply() {
        server.replies = ["first-reply-alpha", "second-reply-beta"]
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "turn-one")
        XCTAssertTrue(ProductE2E.elementContaining(app, "first-reply-alpha").waitForExistence(timeout: 10))

        ProductE2E.sendAndWait(app, "turn-two")
        XCTAssertTrue(ProductE2E.elementContaining(app, "second-reply-beta").waitForExistence(timeout: 10),
                      "second reply never appeared")
        XCTAssertFalse(ProductE2E.titleLooksMismatched(app),
                       "local two-turn invented a mismatch: \(ProductE2E.titleLabel(app))")
    }

    func testRetryAfterErrorResends() {
        server.statusCode = 500
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "retry-me")

        let error = app.descendants(matching: .any)["chat.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10) ||
                      ProductE2E.elementContaining(app, "HTTP 500").waitForExistence(timeout: 5),
                      "error surface never appeared after a 500")

        server.statusCode = 200
        server.replies = ["retry-ok-zeta"]

        let retry = app.buttons["chat.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "retry control missing on the failed turn")
        retry.tap()
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 20), "retry did not settle")
        XCTAssertTrue(ProductE2E.elementContaining(app, "retry-ok-zeta").waitForExistence(timeout: 10),
                      "retry never produced a reply")
    }

    /// Native `tool_calls` from the wire, engine executes `web_search`
    /// (keyless — offer card), follow-up reply lands, markup stays off screen.
    func testScriptedToolRoundFollowsUpWithoutLeakingMarkup() {
        server.emitToolRound = true
        server.toolFollowUpReply = "tool-round-ok-zeta"
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "tool-round-please-search", timeout: 40)
        XCTAssertTrue(ProductE2E.elementContaining(app, "tool-round-ok-zeta").waitForExistence(timeout: 10),
                      "follow-up after the tool round never appeared")
        ProductE2E.assertNoToolMarkup(app)
        XCTAssertTrue(ProductE2E.webSearchOffer(app).waitForExistence(timeout: 8),
                      "keyless web_search should raise the offer card")
    }

    // MARK: - Where

    func testWhereChipOpensAndPickingARowChangesThePlace() {
        server.modelIDs = ["alpha-model", "beta-model"]
        let app = ProductE2E.launchLocal(
            server: server,
            model: "alpha-model",
            extraEnv: ["UITEST_SEED_LOCAL_MODEL_B": "beta-model"]
        )
        let chip = ProductE2E.whereChip(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "Where chip missing")
        let before = ProductE2E.folded(chip.label)
        XCTAssertTrue(before.contains("alpha"), "chip should name the seeded model, got: \(chip.label)")

        chip.tap()
        // The home probe copies /v1/models into the equipped set; wait for it.
        let beta = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "beta-model"))
            .firstMatch
        if !beta.waitForExistence(timeout: 12) {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "WHERE-TREE"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("beta-model row missing in Where. labels=\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
            return
        }
        beta.tap()

        XCTAssertTrue(chip.waitForExistence(timeout: 8), "Where chip missing after pick")
        let after = ProductE2E.folded(chip.label)
        XCTAssertTrue(after.contains("beta"),
                      "picking the other row should change the chip, got: \(chip.label)")
        XCTAssertFalse(after.contains("alpha"),
                       "chip still names the old model: \(chip.label)")
    }

    // MARK: - Settings

    func testSettingsRoundTrip() {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.openSettings(app)
        XCTAssertTrue(app.staticTexts["appearance"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["chats"].exists)
        XCTAssertTrue(app.staticTexts["search"].exists)
        XCTAssertTrue(app.staticTexts["places & keys"].waitForExistence(timeout: 3)
                      || app.buttons["settings.providers"].exists,
                      "places & keys missing")
        ProductE2E.dismissSettings(app)
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 8),
                      "composer gone after dismissing settings")
    }

    func testAppearanceChangeSticksInSession() {
        // Font size, not tint: `-appTintColor` as a launch argument overlays
        // UserDefaults for the whole process and silently drops writes.
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.openSettings(app)
        let appearance = app.staticTexts["appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        XCTAssertTrue(app.navigationBars["appearance"].waitForExistence(timeout: 5))

        func openSizeList() {
            let size = app.descendants(matching: .any)["appearance.size"].firstMatch
            if size.waitForExistence(timeout: 3) { size.tap() }
            else { app.staticTexts["size"].firstMatch.tap() }
        }
        func option(_ name: String) -> XCUIElement {
            app.buttons[name].firstMatch.exists ? app.buttons[name].firstMatch : app.staticTexts[name].firstMatch
        }

        openSizeList()
        XCTAssertTrue(option("xlarge").waitForExistence(timeout: 5), "size list did not open")
        let pick = option("xlarge").isSelected ? "xsmall" : "xlarge"
        option(pick).tap()

        if app.navigationBars["appearance"].buttons.firstMatch.exists {
            app.navigationBars["appearance"].buttons.firstMatch.tap()
        }
        ProductE2E.dismissSettings(app)

        ProductE2E.openSettings(app)
        app.staticTexts["appearance"].tap()
        XCTAssertTrue(app.navigationBars["appearance"].waitForExistence(timeout: 5))
        openSizeList()
        let chosen = option(pick)
        XCTAssertTrue(chosen.waitForExistence(timeout: 5), "\(pick) missing after reopen")
        if !chosen.isSelected {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "APPEARANCE-TREE"
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertTrue(chosen.isSelected,
                      "\(pick) should still be selected after dismiss (selected=\(chosen.isSelected) label=\(chosen.label))")
    }

    // MARK: - Threads

    func testNewChatClearsTheComposer() {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.typeIntoComposer(app, "draft-keep-out")
        ProductE2E.openChats(app)
        let plus = app.buttons["plus"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "new-chat plus missing")
        plus.tap()
        let composer = ProductE2E.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "composer missing after new chat")
        let value = (composer.value as? String) ?? ""
        XCTAssertFalse(value.contains("draft-keep-out"),
                       "new chat carried the draft: \(value)")
    }

    func testDeleteThreadFromList() {
        let app = ProductE2E.launch(
            arguments: ["--uitesting"],
            environment: [
                "UITEST_SEED_THREADS": "1",
                "UITEST_SEED_LOCAL_ENDPOINT": server.baseURL,
                "UITEST_SEED_LOCAL_MODEL": "fake-model",
            ]
        )
        ProductE2E.openChats(app)
        let target = "does this run offline?"
        let row = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", target))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded thread missing")
        row.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        if delete.waitForExistence(timeout: 3) { delete.tap() }
        // iPhone delete is delayed 1s inside ChatsListView.
        XCTAssertTrue(row.waitForNonExistence(timeout: 6),
                      "deleted thread is still in the list")
    }

    // MARK: - Offline trust seeds (iOS)

    func testHardFailureBlocksSend() {
        let app = ProductE2E.launch(environment: [
            "UITEST_SEED_NEARAI_MODEL": "z-ai/glm-5.2",
            "UITEST_SEED_ATTESTATION": "hardFailure",
        ])
        XCTAssertTrue(ProductE2E.titleBlock(app).waitForExistence(timeout: 15), "title block missing")
        XCTAssertTrue(ProductE2E.titleLooksBlocked(app),
                      "hardFailure seed should say sending blocked, got: \(ProductE2E.titleLabel(app))")

        ProductE2E.typeIntoComposer(app, "should-not-leave")
        app.buttons["chat.send"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5),
                      "hard-failure send should raise the blocked alert")
        XCTAssertTrue(ProductE2E.folded(alert.label + alert.staticTexts.allElementsBoundByIndex.map(\.label).joined())
                        .contains("sending blocked")
                      || ProductE2E.folded(alert.label).contains("verification failed"),
                      "alert is not the hard-block: \(alert.label)")
        XCTAssertFalse(app.buttons["chat.stop"].exists, "send went out under a hard block")
    }

    /// The no-plaintext-fallback guarantee, end-to-end: an ATTESTED provider whose verdict allows the
    /// send (`sendPolicy == .allow`) but whose E2EE key never arrived must
    /// REFUSE the turn — nothing on the wire — and surface it through the
    /// same error channel as any generation failure, with the one-tap retry
    /// affordance on the failed turn. The `e2eeUnavailable` seed pins the
    /// forcing state offline: seeded `.ok` verdict + live attestation fetch
    /// suppressed, so `currentTEEContext()?.e2eePeer == nil` at send time.
    func testE2EEUnavailableRefusalShowsRetryAffordance() {
        let app = ProductE2E.launch(environment: [
            "UITEST_SEED_NEARAI_MODEL": "z-ai/glm-5.2",
            "UITEST_SEED_ATTESTATION": "e2eeUnavailable",
        ])
        XCTAssertTrue(ProductE2E.titleBlock(app).waitForExistence(timeout: 15), "title block missing")
        XCTAssertFalse(ProductE2E.titleLooksBlocked(app),
                       "the seeded verdict must ALLOW the send — a blocked title means the gate, not the 4.1 guard, is being tested: \(ProductE2E.titleLabel(app))")

        ProductE2E.typeIntoComposer(app, "seal-me-or-refuse")
        app.buttons["chat.send"].tap()

        // The send gate allows, so no confirm/block alert may appear …
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2),
                       "no alert expected — the refusal surfaces as an error, not the send gate")
        // … and the refusal lands on the generation-error surface, naming
        // the fail-closed outcome.
        let error = app.descendants(matching: .any)["chat.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15),
                      "E2EE-unavailable send never raised the chat.error surface")
        XCTAssertTrue(ProductE2E.elementContaining(app, "nothing was sent").waitForExistence(timeout: 5),
                      "the error should say nothing was sent")
        XCTAssertFalse(app.buttons["chat.stop"].exists, "a refused turn must never start generating")

        // CORE: the one-tap retry affordance on the failed turn.
        let retry = app.buttons["chat.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5),
                      "retry affordance missing on the refused turn")

        // Retry re-checks the guard: E2EE is still unavailable, so the tap
        // must NOT bypass into a send — the error + retry return, no
        // generation starts, and no assistant reply appears.
        retry.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 15),
                      "retry should re-refuse while E2EE is still unavailable")
        XCTAssertTrue(retry.waitForExistence(timeout: 5),
                      "retry affordance should return after the re-refusal")
        XCTAssertFalse(app.buttons["chat.stop"].exists, "retry bypassed the guard and started generating")
    }

    func testMismatchCaptionDoesNotBlockSend() {
        server.replies = ["mismatch-still-sendable"]
        let app = ProductE2E.launch(environment: [
            "UITEST_SEED_LOCAL_ENDPOINT": server.baseURL,
            "UITEST_SEED_LOCAL_MODEL": "fake-model",
            "UITEST_SEED_ATTESTATION": "mismatch",
        ])
        XCTAssertTrue(ProductE2E.titleBlock(app).waitForExistence(timeout: 15))
        XCTAssertTrue(ProductE2E.titleLooksMismatched(app),
                      "mismatch seed should caption the title, got: \(ProductE2E.titleLabel(app))")
        ProductE2E.sendAndWait(app, "still-send")
        XCTAssertTrue(ProductE2E.elementContaining(app, "mismatch-still-sendable").waitForExistence(timeout: 10),
                      "mismatch session should still be sendable")
    }

    /// The phone bug, offline. Seeds the reply-signature failure so the
    /// everyday ladder actually shows "one reply didn't check out" — the
    /// surface a live two-turn run only hits when near.ai disagrees.
    func testReplyDidntCheckOutOpensEverydaySheet() {
        let app = ProductE2E.launch(environment: [
            "UITEST_SEED_NEARAI_MODEL": "z-ai/glm-5.2",
            "UITEST_SEED_ATTESTATION": "mismatch",
        ])
        let title = ProductE2E.titleBlock(app)
        XCTAssertTrue(title.waitForExistence(timeout: 15), "title block missing")
        XCTAssertTrue(ProductE2E.titleLooksMismatched(app),
                      "title should say a reply didn't check out, got: \(ProductE2E.titleLabel(app))")
        XCTAssertFalse(ProductE2E.titleLooksBlocked(app),
                       "a reply mismatch must not hard-block sending: \(ProductE2E.titleLabel(app))")
        ProductE2E.attachScreenshot(app, name: "mismatch-title", to: self)

        title.tap()
        XCTAssertTrue(app.staticTexts["who can read this?"].waitForExistence(timeout: 5),
                      "everyday sheet did not open from the mismatch title")
        let hero = ProductE2E.elementContaining(app, "one reply didn't check out")
        XCTAssertTrue(hero.waitForExistence(timeout: 5),
                      "everyday hero never named the failed reply")
        XCTAssertTrue(ProductE2E.elementContaining(app, "still sealed").waitForExistence(timeout: 3)
                      || ProductE2E.elementContaining(app, "couldn't be verified").waitForExistence(timeout: 1),
                      "sheet should say the session is still sealed but a reply failed its check")
        ProductE2E.attachScreenshot(app, name: "mismatch-everyday-sheet", to: self)

        let close = app.buttons["attestation.close"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() }

        // Send stays offered — do not tap it: this seed is near.ai, and a
        // completion would spend. The local test above is the one that sends.
        ProductE2E.typeIntoComposer(app, "still-open")
        XCTAssertTrue(app.buttons["chat.send"].isEnabled,
                      "mismatch must leave send enabled")
    }

    // MARK: - Debug panel (developer mode)

    /// The thinking chip used to centre in the full-width streaming host,
    /// and the debug card used to pop in at full height and yank the
    /// answer up. Both are exercised here with the panel armed.
    func testThinkingChipStaysLeadingAndDebugCardAppears() {
        server.startDelay = 4.0
        let app = ProductE2E.launchLocal(
            server: server,
            extraEnv: ["UITEST_DEVELOPER_MODE": "1"]
        )
        ProductE2E.typeIntoComposer(app, "chip-and-panel")
        ProductE2E.send(app)
        XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 10),
                      "generation never started against the fake SSE server")
        ProductE2E.assertChipIsLeading(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 25),
                      "generation did not settle")
        XCTAssertTrue(ProductE2E.waitForDebugCardOnScreen(app),
                      "developer mode is on but the debug card never landed on screen")
    }

    func testHardFailureBlocksSendWithDebugPanelOn() {
        let app = ProductE2E.launch(environment: [
            "UITEST_SEED_NEARAI_MODEL": "z-ai/glm-5.2",
            "UITEST_SEED_ATTESTATION": "hardFailure",
            "UITEST_DEVELOPER_MODE": "1",
        ])
        XCTAssertTrue(ProductE2E.titleBlock(app).waitForExistence(timeout: 15), "title block missing")
        XCTAssertTrue(ProductE2E.titleLooksBlocked(app),
                      "hardFailure + debug panel should still say sending blocked, got: \(ProductE2E.titleLabel(app))")

        ProductE2E.typeIntoComposer(app, "should-not-leave")
        app.buttons["chat.send"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5),
                      "hard-failure send should raise the blocked alert with the debug panel on")
        XCTAssertFalse(app.buttons["chat.stop"].exists, "send went out under a hard block")
    }

    func testMismatchDoesNotBlockSendWithDebugPanelOn() {
        let app = ProductE2E.launch(environment: [
            "UITEST_SEED_NEARAI_MODEL": "z-ai/glm-5.2",
            "UITEST_SEED_ATTESTATION": "mismatch",
            "UITEST_DEVELOPER_MODE": "1",
        ])
        let title = ProductE2E.titleBlock(app)
        XCTAssertTrue(title.waitForExistence(timeout: 15), "title block missing")
        XCTAssertTrue(ProductE2E.titleLooksMismatched(app),
                      "title should say a reply didn't check out, got: \(ProductE2E.titleLabel(app))")
        XCTAssertFalse(ProductE2E.titleLooksBlocked(app),
                       "a reply mismatch must not hard-block sending: \(ProductE2E.titleLabel(app))")
        title.tap()
        XCTAssertTrue(app.staticTexts["who can read this?"].waitForExistence(timeout: 5),
                      "everyday sheet did not open with the debug panel on")
        let close = app.buttons["attestation.close"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() }
        ProductE2E.typeIntoComposer(app, "still-open")
        XCTAssertTrue(app.buttons["chat.send"].isEnabled,
                      "mismatch must leave send enabled with the debug panel on")
    }

    func testEverydaySheetOpensFromTitleBlock() {
        let app = ProductE2E.launch(environment: [
            "UITEST_SEED_NEARAI_MODEL": "z-ai/glm-5.2",
            "UITEST_SEED_ATTESTATION": "verifying",
        ])
        let title = ProductE2E.titleBlock(app)
        XCTAssertTrue(title.waitForExistence(timeout: 15), "title block missing")
        title.tap()
        XCTAssertTrue(app.staticTexts["who can read this?"].waitForExistence(timeout: 5),
                      "tapping chat.titleBlock did not open the everyday sheet")
        let close = app.buttons["attestation.close"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() }
    }
}
