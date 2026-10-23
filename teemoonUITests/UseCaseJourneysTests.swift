//
//  UseCaseJourneysTests.swift
//  teemoonUITests
//
//  Use cases from the Android port's use-case list that iOS had no end-to-end
//  test for, ported from the Android journeys that walk them. Offline: the
//  embedded fake SSE server, seeded attestation, no keys.
//

import XCTest

final class UseCaseJourneysTests: XCTestCase {

    private var server: EmbeddedFakeSSEServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try EmbeddedFakeSSEServer(lines: 6, delay: 0.005)
        server.replies = ["use-case-reply-alpha"]
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    private func element(_ app: XCUIApplication, _ fragment: String) -> XCUIElement {
        ProductE2E.elementContaining(app, fragment)
    }

    /// B2: stop mid-stream leaves what streamed, shows no error, and the next send works.
    func testStopMidStreamShowsNoErrorAndTheNextSendWorks() throws {
        server.stop()
        server = try EmbeddedFakeSSEServer(lines: 60, delay: 0.05)
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.typeIntoComposer(app, "stop-me")
        ProductE2E.send(app)
        let stop = app.buttons["chat.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the turn never started streaming")
        sleep(1)
        stop.tap()
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 10), "stop did not end the turn")
        XCTAssertFalse(app.descendants(matching: .any)["chat.error"].firstMatch.exists, "a stop showed an error card")
        // the next send works: a second completion leaves and streams
        let before = server.requestBodies.count
        ProductE2E.typeIntoComposer(app, "and-again")
        ProductE2E.send(app)
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the send after a stop never started")
        XCTAssertTrue(server.requestBodies.contains { $0.contains("and-again") } && server.requestBodies.count > before,
                      "the send after a stop did not reach the wire")
        stop.tap()
    }

    /// B8: the system prompt set in settings → chats is what the next turn sends, `{{datetime}}` filled in.
    func testTheSystemPromptFromSettingsReachesTheWire() {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.openSettings(app)
        app.buttons["chats"].firstMatch.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the system prompt editor is missing")
        editor.tap()
        editor.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        editor.typeText("speak like a lighthouse keeper. now: {{datetime}}")
        app.navigationBars.buttons.firstMatch.tap()
        ProductE2E.dismissSettings(app)
        ProductE2E.sendAndWait(app, "hello keeper")
        let body = server.requestBodies.last ?? ""
        XCTAssertTrue(body.contains("speak like a lighthouse keeper"), "the system prompt did not reach the wire: \(body.prefix(300))")
        XCTAssertFalse(body.contains("{{datetime}}"), "{{datetime}} went out unexpanded")
    }

    /// F1: a turn persists — new chat clears it away, the chats list brings it back with its reply.
    func testAChatPersistsAndTheListBringsItBack() {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "remember-this-one")
        XCTAssertTrue(element(app, "use-case-reply-alpha").waitForExistence(timeout: 10), "no reply")
        ProductE2E.openChats(app)
        // "+" also asks for an App Store review once enough visits have accrued (requestReviewIfAppropriate) — late in
        // a long run the system's prompt rises over the app; it is not this journey's subject, so it is dismissed
        app.buttons["plus"].firstMatch.tap()   // new chat (testNewChatClearsTheComposer's way in)
        let notNow = app.buttons["Not Now"].firstMatch   // StoreKit's sheet, in its own process but in the app's tree
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 8), "composer missing after new chat")
        XCTAssertFalse(element(app, "use-case-reply-alpha").waitForExistence(timeout: 2), "the new chat is not empty")
        // the list animates away after "+": wait for it to be gone before asking for it again
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.navigationBars["chats"]); waitForExpectations(timeout: 5)
        ProductE2E.openChats(app)
        element(app, "remember-this-one").tap()
        XCTAssertTrue(element(app, "use-case-reply-alpha").waitForExistence(timeout: 10), "the reopened chat lost its reply")
    }

    /// F3: search the chats for a word from a question → the hit opens its thread; a word nowhere says "no results".
    func testSearchingTheChatsOpensTheThreadWithTheHit() {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "where is the lighthouse")
        ProductE2E.openChats(app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the chats list has no search field")
        field.tap(); field.typeText("zzqxnowhere")
        XCTAssertTrue(element(app, "no results").waitForExistence(timeout: 5), "a word nowhere did not say no results")
        field.buttons.firstMatch.tap()   // clear
        field.typeText("lighthouse")
        let hit = element(app, "where is the lighthouse")
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "the search found no hit")
        hit.tap()
        XCTAssertTrue(element(app, "use-case-reply-alpha").waitForExistence(timeout: 10), "the hit did not open its thread")
    }

    /// F4: settings → chats → delete all chats, confirmed: the list is empty and the open chat starts fresh.
    func testDeletingAllChatsEmptiesTheListAndTheOpenChat() {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "one-to-delete")
        ProductE2E.openSettings(app)
        app.buttons["chats"].firstMatch.tap()
        let deleteAll = element(app, "delete all chats")
        XCTAssertTrue(deleteAll.waitForExistence(timeout: 5), "delete all chats is missing")
        deleteAll.tap()
        XCTAssertTrue(app.alerts["are you sure?"].waitForExistence(timeout: 5), "delete all did not ask")
        app.alerts["are you sure?"].buttons["delete"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        ProductE2E.dismissSettings(app)
        XCTAssertFalse(element(app, "use-case-reply-alpha").waitForExistence(timeout: 2), "the deleted chat is still drawn")
        ProductE2E.openChats(app)
        XCTAssertTrue(element(app, "no chats yet").waitForExistence(timeout: 5), "the chats list is not empty after delete all")
    }

    /// E1: degraded — the first send asks; cancel keeps the draft; the bypass sends.
    func testTheDegradedGateCancelKeepsTheDraftAndTheBypassSends() {
        let app = ProductE2E.launch(environment: [
            "UITEST_SEED_NEARAI_MODEL": "z-ai/glm-5.3-flash",
            "UITEST_SEED_ATTESTATION": "degraded",
        ])
        XCTAssertTrue(ProductE2E.titleBlock(app).waitForExistence(timeout: 15), "title block missing")
        ProductE2E.typeIntoComposer(app, "hello-anyway")
        app.buttons["chat.send"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "a degraded send did not ask")
        alert.buttons["cancel"].tap()
        XCTAssertTrue((ProductE2E.composer(app).value as? String ?? "").contains("hello-anyway"), "cancel lost the draft")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the second send did not ask")
        let bypass = alert.buttons.allElementsBoundByIndex.first { $0.label.contains("send") }
        XCTAssertNotNil(bypass, "a soft degrade offered no way to send: \(alert.buttons.allElementsBoundByIndex.map(\.label))")
        bypass?.tap()
        XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 15)
                      || app.descendants(matching: .any)["chat.error"].firstMatch.waitForExistence(timeout: 15),
                      "the bypass did not send")
    }

    // MARK: - batch 2

    /** Opens where → "connect a computer" and types [host] into the endpoint field (the probe runs on its own). */
    private func connectAComputer(_ app: XCUIApplication, host: String) {
        let chip = ProductE2E.whereChip(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "where chip missing")
        chip.tap()
        let connect = element(app, "connect a computer")
        XCTAssertTrue(connect.waitForExistence(timeout: 10), "where offers no connect a computer")
        connect.tap()
        let label = app.textFields["label"].firstMatch
        if label.waitForExistence(timeout: 5) { label.tap(); label.typeText("box") }
        let endpoint = app.textFields["api.example.com/v1"].firstMatch
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5), "the endpoint field is missing")
        endpoint.tap(); endpoint.typeText(host)
        app.staticTexts["model"].firstMatch.tap()   // put the keyboard away
        let fetch = app.buttons["fetch models"].firstMatch
        if fetch.waitForExistence(timeout: 4) { fetch.tap() }
    }

    /// A2: connect a computer from where: host → its models → pick → save; the chip names it and the next message goes there.
    func testConnectingAComputerFromWhereAndChattingOnIt() {
        let app = ProductE2E.launch(environment: [:])
        connectAComputer(app, host: server.baseURL.replacingOccurrences(of: "http://", with: ""))
        let model = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "fake-model")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 30), "the server's model never appeared")
        model.tap()
        app.buttons["save"].firstMatch.tap()
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 10), "save did not end in the chat")
        XCTAssertTrue(element(app, "fake-model").waitForExistence(timeout: 10), "the chip does not name the new place's model")
        ProductE2E.sendAndWait(app, "hello box")
        XCTAssertTrue(element(app, "use-case-reply-alpha").waitForExistence(timeout: 10), "the message did not go to the new place")
    }

    /// A3: connect a computer, failure paths — nothing listening, and http to a public host refused.
    func testConnectingAComputerSaysWhyItFailed() {
        var app = ProductE2E.launch(environment: [:])
        connectAComputer(app, host: "127.0.0.1:9/v1")
        XCTAssertTrue(element(app, "nothing listening there").waitForExistence(timeout: 20), "a dead port did not say nothing is listening")
        app.terminate()
        // a server that answers but serves nothing
        server.modelIDs = []
        app = ProductE2E.launch(environment: [:])
        connectAComputer(app, host: server.baseURL.replacingOccurrences(of: "http://", with: ""))
        XCTAssertTrue(element(app, "no models were returned").waitForExistence(timeout: 20), "an empty model list was not said")
        XCTAssertFalse(app.buttons["save"].firstMatch.isEnabled && element(app, "fake-model").exists, "an empty server offered a model")
        app.terminate()
        app = ProductE2E.launch(environment: [:])
        connectAComputer(app, host: "example.com/v1")
        XCTAssertTrue(element(app, "blocked http").waitForExistence(timeout: 20), "http to a public host was not refused")
    }

    /// C3: each where filter shows exactly its locality's ready rows.
    func testTheWhereFiltersShowExactlyTheirLocality() {
        let app = ProductE2E.launch(environment: [
            "UITEST_SEED_NEARAI_MODEL": "z-ai/glm-5.3-flash",
            "UITEST_SEED_ALSO_LOCAL_ENDPOINT": server.baseURL,
            "UITEST_SEED_LOCAL_MODEL": "fake-model",
        ])
        ProductE2E.whereChip(app).tap()
        XCTAssertTrue(element(app, "fake-model").waitForExistence(timeout: 10), "all is missing the home machine")
        app.buttons["home"].firstMatch.tap(); sleep(1)
        XCTAssertTrue(element(app, "fake-model").exists, "home lost its machine")
        // the sheet's ROWS only — the chat's own title behind the sheet says "end-to-end encrypted" too
        XCTAssertFalse(app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", "glm-5.3")).firstMatch.exists, "home shows the cloud place")
        app.buttons["cloud"].firstMatch.tap(); sleep(1)
        XCTAssertTrue(app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", "glm-5.3")).firstMatch.waitForExistence(timeout: 5)
                      || app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "glm-5.3")).firstMatch.exists, "cloud lost near.ai")
        XCTAssertFalse(app.cells.matching(NSPredicate(format: "label CONTAINS %@", "fake-model")).firstMatch.exists, "cloud shows the home machine")
    }

    /// I5: rotating mid-stream — the stream continues to its end, one request, no error.
    func testRotatingMidStreamKeepsTheStream() throws {
        server.stop()
        server = try EmbeddedFakeSSEServer(lines: 40, delay: 0.03)
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.typeIntoComposer(app, "turn-me-around")
        ProductE2E.send(app)
        XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 10), "the turn never started")
#if os(iOS)
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(2)
        XCUIDevice.shared.orientation = .portrait
#endif
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 60), "the turn did not finish after a rotation")
        XCTAssertFalse(app.descendants(matching: .any)["chat.error"].firstMatch.exists, "the rotation broke the turn")
        XCTAssertEqual(server.requestBodies.filter { $0.contains("turn-me-around") }.count, 1, "the rotation re-sent the turn")
    }

    /// B7 (part): a long press on the question offers copy, and the question is what lands on the pasteboard.
    func testLongPressingTheQuestionCopiesIt() {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "copy-exactly-this")
        let bubble = app.staticTexts.matching(NSPredicate(format: "label == %@", "copy-exactly-this")).allElementsBoundByIndex.max { $0.frame.minY < $1.frame.minY }
        XCTAssertNotNil(bubble, "the question is not in the transcript")
        bubble?.press(forDuration: 1.0)
        let copy = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "copy")).firstMatch   // the menu says "copy"
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the long press offered no copy")
        copy.tap()
        // read it back INSIDE the app: the runner reading UIPasteboard raises the simulator's paste prompt and hangs
        let composer = ProductE2E.composer(app)
        composer.tap(); composer.press(forDuration: 1.2)
        let paste = app.menuItems.matching(NSPredicate(format: "label ==[c] %@", "paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the composer offered no paste")
        paste.tap()
        XCTAssertTrue((composer.value as? String ?? "").contains("copy-exactly-this"), "what was copied is not the question")
    }

    /// I7: the system accessibility audit finds no unlabelled element on the chat, where, trust, settings, places & keys and
    /// chats screens, and behind each sheet none of the chat's controls can be reached.
    func testTheMainScreensPassTheAccessibilityAudit() throws {
        let app = ProductE2E.launchLocal(server: server)
        var found: [String] = []
        func audit(_ screen: String) throws {
            // the system keyboard's suggestion bar (three unnamed 1/3-width cells) is not the app's to label
            let keyboard = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.insetBy(dx: 0, dy: -60) : .null
            try app.performAccessibilityAudit(for: [.sufficientElementDescription]) { issue in
                if let f = issue.element?.frame, keyboard.contains(f) { return true }
                found.append("\(screen): \(issue.compactDescription) — \(issue.element?.debugDescription.prefix(160) ?? "?")")
                return true   // collect them all, judge at the end
            }
        }
        // behind a sheet the chat is scenery: none of its controls can be reached (UIKit's presentation makes the
        // presenting view modal-inaccessible; the chat's top-bar buttons are the ones a sheet leaves on screen)
        func nothingBehind(_ screen: String) {
            for id in ["chat.settings", "chat.titleBlock"] {
                let el = app.descendants(matching: .any)[id].firstMatch
                if el.exists && el.isHittable { found.append("\(screen): the chat's \(id) is reachable behind the sheet") }
            }
        }
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 15))
        try audit("chat")
        ProductE2E.whereChip(app).tap(); sleep(1)
        try audit("where"); nothingBehind("where")
        app.swipeDown(velocity: .fast); sleep(1)
        ProductE2E.titleBlock(app).tap(); sleep(1)
        try audit("trust"); nothingBehind("trust")
        app.swipeDown(velocity: .fast); sleep(1)
        ProductE2E.openSettings(app)
        try audit("settings"); nothingBehind("settings")
        app.buttons["settings.providers"].firstMatch.tap(); sleep(1)
        try audit("places & keys")
        ProductE2E.dismissSettings(app); sleep(1)
        ProductE2E.openChats(app)
        try audit("chats"); nothingBehind("chats")
        XCTAssertTrue(found.isEmpty, "accessibility audit:\n" + found.joined(separator: "\n"))
    }

    // MARK: - batch 3

    /// A where row by a fragment of its label — the rows are buttons, not table cells.
    private func cells(_ app: XCUIApplication, containing fragment: String) -> XCUIElement {
        // never the chat's own where chip behind the sheet, which names the same model
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND identifier != %@", fragment, "chat.whereChip")).firstMatch
    }

    /// A4: add a near.ai key from where on the cloud filter: the sheet comes back on the cloud filter and the row no
    /// longer says "add key". (Reported on Android 2026-10-04 as "returns to all and still says add key".)
    func testAddingACloudKeyFromWhereLeavesTheRowKeyedAndTheFilterKept() {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.whereChip(app).tap()
        app.buttons["cloud"].firstMatch.tap()
        let near = cells(app, containing: "near.ai")
        XCTAssertTrue(near.waitForExistence(timeout: 10), "the cloud filter has no near.ai row")
        XCTAssertTrue(near.label.contains("add key"), "near.ai should start keyless: \(near.label)")
        near.tap()
        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 10), "the key form did not open")
        key.tap(); key.typeText("uitest-near-key")
        app.buttons["save"].firstMatch.tap()
        XCTAssertTrue(app.buttons["cloud"].firstMatch.waitForExistence(timeout: 10), "save did not return to where")
        XCTAssertTrue(app.buttons["cloud"].firstMatch.isSelected, "the sheet came back off the cloud filter")
        let row = cells(app, containing: "near.ai")
        XCTAssertTrue(row.waitForExistence(timeout: 10) && !row.label.contains("add key"), "near.ai's row still says add key: \(row.label)")
    }

    /// C5: edit a home machine from places & keys — rename it (it sticks), then delete it from its form (asked first).
    func testAPlaceIsRenamedAndDeletedFromPlacesAndKeys() {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.openSettings(app)
        app.buttons["settings.providers"].firstMatch.tap()
        element(app, "home machines").tap()
        XCTAssertTrue(app.navigationBars["home machines"].waitForExistence(timeout: 5), "home machines did not open")
        let edit = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ", edit")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "the machine has no edit row")
        edit.tap()
        let label = app.textFields["label"].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 5), "the edit form has no label field")
        label.tap(); label.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        label.typeText("attic server")
        app.buttons["save"].firstMatch.tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "save did not return to home machines")
        edit.tap()
        XCTAssertEqual(app.textFields["label"].firstMatch.value as? String, "attic server", "the rename did not stick")
        let delete = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "forget this computer")).firstMatch
        if !delete.isHittable { app.swipeUp() }
        delete.tap()
        // an alert or an action sheet, depending on the size class — either way it asks, and "delete provider" confirms
        let confirm = app.buttons["delete provider"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "delete did not ask")
        // cancel first: asking means saying no keeps it. iOS 26 draws the dialog with no Cancel button on a phone —
        // a tap outside it (on the form, not above the sheet) is the cancel
        let cancel = app.buttons["Cancel"].firstMatch
        let outside = app.otherElements["PopoverDismissRegion"].firstMatch
        if cancel.exists { cancel.tap() } else if outside.exists { outside.tap() }
        else { app.textFields["label"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, "the delete dialog did not go away: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.textFields["label"].firstMatch.waitForExistence(timeout: 5), "cancelling the delete left the form")
        if !delete.isHittable { app.swipeUp() }
        delete.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the second delete did not ask")
        confirm.tap()
        XCTAssertTrue(element(app, "no computers connected.").waitForExistence(timeout: 10), "the machine survived its delete")
    }

    /// H1: appearance — a font design and a size chosen in settings survive a relaunch. Put back at the end.
    func testAppearanceChoicesSurviveARelaunch() {
        var app = ProductE2E.launchLocal(server: server)
        func openAppearance() {
            ProductE2E.openSettings(app)
            app.staticTexts["appearance"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["appearance"].waitForExistence(timeout: 5))
        }
        func pick(_ row: String, _ option: String) {
            let r = app.descendants(matching: .any)["appearance.\(row)"].firstMatch
            if r.waitForExistence(timeout: 3) { r.tap() } else {
                // the picker's ROW is the button; its label's text is not hittable on its own
                let b = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", row)).firstMatch
                if !b.isHittable { app.swipeUp() }   // the sheet's medium detent can put the font rows below the fold
                b.tap()
            }
            let o = app.buttons[option].firstMatch.exists ? app.buttons[option].firstMatch : app.staticTexts[option].firstMatch
            XCTAssertTrue(o.waitForExistence(timeout: 5), "\(row) offers no \(option)")
            o.tap()
            if app.navigationBars.buttons.firstMatch.exists && !app.navigationBars["appearance"].exists { app.navigationBars.buttons.firstMatch.tap() }
        }
        openAppearance()
        // design and size, not colour: the launch helper passes -appTintColor, which overlays UserDefaults for the
        // whole process and drops writes (testAppearanceChangeSticksInSession's note)
        pick("design", "serif"); pick("size", "large")
        app.terminate()
        app = ProductE2E.launchLocal(server: server)
        openAppearance()
        XCTAssertTrue(element(app, "serif").waitForExistence(timeout: 5), "the design did not survive a relaunch")
        // the size row carries its choice as the row's VALUE, not as a label
        let size = app.descendants(matching: .any)["appearance.size"].firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 5), "the size row is missing")
        XCTAssertEqual(size.value as? String, "large", "the size did not survive a relaunch")
        pick("design", "standard"); pick("size", "medium")
    }

    /// H4 (part): a credit opens Safari at the host it names.
    func testACreditOpensTheBrowserAtItsHost() {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.openSettings(app)
        let credits = element(app, "credits")
        if !credits.isHittable { app.swipeUp() }
        credits.tap()
        XCTAssertTrue(app.navigationBars["credits"].waitForExistence(timeout: 5), "credits did not open")
        element(app, "LiteRT").tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "the credit did not open the browser")
        let at = safari.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "github.com", "github.com")).firstMatch
        XCTAssertTrue(at.waitForExistence(timeout: 15), "the browser is not at github.com")
        app.activate()
    }

    // MARK: - batch 4

    /// A5 (part): a key the host refuses (401 on /models), offline through connect a computer: the key field appears,
    /// a refused key says "key rejected", and nothing is saved — the chip still has nowhere to send.
    func testARejectedKeyIsSaidAndNothingIsSaved() {
        server.rejectsKey = true
        let app = ProductE2E.launch(environment: [:])
        connectAComputer(app, host: server.baseURL.replacingOccurrences(of: "http://", with: ""))
        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 20), "a 401 did not ask for a key")
        key.tap(); key.typeText("uitest-bad-key")
        let fetch = app.buttons["fetch models"].firstMatch
        if fetch.waitForExistence(timeout: 4) { fetch.tap() }
        XCTAssertTrue(element(app, "key rejected").waitForExistence(timeout: 20), "a refused key was not said")
        app.buttons["cancel"].firstMatch.tap()
        XCTAssertTrue(element(app, "choose where").waitForExistence(timeout: 10), "a refused key left a setup behind")
    }

    /// C4 (part): unequip a cloud model from where — the row's menu offers "unequip", and the row leaves the list.
    func testUnequippingACloudModelTakesItOffTheList() {
        let app = ProductE2E.launch(environment: [
            "UITEST_SEED_NEARAI_MODEL": "z-ai/glm-5.3-flash",
            "UITEST_SEED_ALSO_LOCAL_ENDPOINT": server.baseURL,
            "UITEST_SEED_LOCAL_MODEL": "fake-model",
        ])
        ProductE2E.whereChip(app).tap()
        let row = cells(app, containing: "glm-5.3")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the near.ai model is not in ready now")
        // the long-press menu carries the same one action as the trailing swipe (rowDestructiveActions); a synthetic
        // swipe on the row's button does not reach the list's swipe actions
        row.press(forDuration: 1.2)
        let unequip = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "unequip")).firstMatch
        XCTAssertTrue(unequip.waitForExistence(timeout: 5), "the row offered no unequip")
        unequip.tap()
        XCTAssertTrue(NSPredicate(format: "exists == false").evaluate(with: row) || !row.waitForExistence(timeout: 3), "the unequipped model is still listed")
        // re-equip it from browse: the catalogue still has it, and picking it puts it back in ready now
        app.buttons["cloud"].firstMatch.tap()
        let browse = cells(app, containing: "open models in enclaves")
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "no near.ai preset row to browse from")
        browse.tap()
        let search = app.searchFields["search models"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20), "the model browser did not open")
        search.tap(); search.typeText("glm-5.3-flash")
        let hit = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "glm 5.3 flash")).firstMatch   // the display name, not the id
        XCTAssertTrue(hit.waitForExistence(timeout: 30), "the browser does not offer the unequipped model")
        hit.tap()
        XCTAssertTrue(ProductE2E.whereChip(app).waitForExistence(timeout: 10))
        ProductE2E.whereChip(app).tap()
        let back = app.buttons.matching(NSPredicate(format: "(label CONTAINS[c] %@ OR label CONTAINS[c] %@) AND identifier != %@", "glm-5.3", "glm 5.3", "chat.whereChip")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the re-equipped model is not back in ready now: \(app.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.prefix(30))")
    }

    /// C7 (part): browse near.ai's catalogue from where — a search narrows it, and picking a model makes it the chat's.
    func testBrowsingACloudPicksAModelForTheChat() {
        let app = ProductE2E.launch(environment: ["UITEST_SEED_NEARAI_MODEL": "z-ai/glm-5.3-flash"])
        ProductE2E.whereChip(app).tap()
        app.buttons["cloud"].firstMatch.tap()
        // the get section's near.ai PRESET row — keyed, it browses; the ready row above SELECTS its model instead
        let browse = cells(app, containing: "open models in enclaves")
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "no near.ai preset row on the cloud filter")
        browse.tap()
        let search = app.searchFields["search models"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20), "the model browser did not open")
        search.tap(); search.typeText("qwen")
        let hit = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "qwen")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 30), "the search for qwen found nothing")
        hit.tap()
        XCTAssertTrue(ProductE2E.whereChip(app).waitForExistence(timeout: 10))
        XCTAssertTrue(ProductE2E.whereChip(app).label.lowercased().contains("qwen") || element(app, "qwen").waitForExistence(timeout: 10),
                      "the pick did not become the chat's model: \(ProductE2E.whereChip(app).label)")
    }

    // MARK: - batch 5 (fake Ollama, fake Brave)

    private func openHome(_ app: XCUIApplication) {
        if app.buttons["home"].firstMatch.exists { app.swipeDown(velocity: .fast); sleep(1) }
        ProductE2E.whereChip(app).tap()
        let home = app.buttons["home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 10), "the where sheet did not open")
        home.tap(); sleep(1)
    }

    /// C6 (part): a home server's row reads warm while its model is loaded and cold once it is not (re-read on every
    /// opening); a server that refuses the delete keeps the model.
    func testAHomeServerShowsWarmthAndDeletesAModel() {
        server.ollama = true
        let app = ProductE2E.launchLocal(server: server)
        openHome(app)
        // iOS joins warmth onto the row's caption ("ollama · warm", WhereRow), not its trailing slot
        XCTAssertTrue(element(app, "warm").waitForExistence(timeout: 15), "a loaded model does not read warm; the app asked: \(server.requestLines.suffix(12)); texts: \(app.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0.contains("ollama") || $0.contains("127") })")
        server.ollamaWarmsOnGenerate = false; server.setOllamaWarm([])
        openHome(app)
        XCTAssertTrue(element(app, "cold").waitForExistence(timeout: 15), "an unloaded model does not read cold on the next open")
        server.ollamaDeleteFails = true
        let row = cells(app, containing: "fake-model")
        row.press(forDuration: 1.2)
        let delete = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "delete")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the row offered no delete")
        delete.tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "deleting from the server did not ask")
        confirm.buttons.matching(NSPredicate(format: "label ==[c] %@", "delete")).firstMatch.tap()
        let failed = app.alerts["couldn't delete"].firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 10), "a refused delete did not say so")
        XCTAssertTrue(element(app, "is still on").exists, "the failure does not say the model is still there")
        failed.buttons.firstMatch.tap()
        XCTAssertTrue(server.ollamaModels.contains("fake-model"), "a refused delete removed the model")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "a refused delete left the row gone")
        // and a delete the machine accepts takes it off the machine and off the list
        server.ollamaDeleteFails = false
        row.press(forDuration: 1.2)
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the row offered no delete the second time")
        delete.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the second delete did not ask")
        confirm.buttons.matching(NSPredicate(format: "label ==[c] %@", "delete")).firstMatch.tap()
        let gone = expectation(for: NSPredicate { _, _ in !self.server.ollamaModels.contains("fake-model") }, evaluatedWith: nil)
        wait(for: [gone], timeout: 10)
        let rowGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [rowGone], timeout: 10), .completed, "the deleted model is still listed")
    }

    /// C8 (part): pull a model onto an Ollama machine from where — it lands and is listed; a pull that cannot succeed
    /// says so on its row, and a tap there pulls again.
    func testPullingAModelOntoTheMachineLandsIt() {
        server.ollama = true
        let app = ProductE2E.launchLocal(server: server)
        func startPull(_ ref: String) {
            openHome(app)
            let add = cells(app, containing: "add a model to")
            XCTAssertTrue(add.waitForExistence(timeout: 10), "no add-a-model row")
            add.tap()
            let field = app.textFields["paste the link here"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10), "the pull sheet has no link field")
            field.tap(); field.typeText(ref)
            app.buttons["download"].firstMatch.tap()
        }
        startPull("tinyllama")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !server.ollamaModels.contains("tinyllama") { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        XCTAssertTrue(server.ollamaModels.contains("tinyllama"), "the pull never landed; the app asked: \(server.requestLines.suffix(14))")
        server.ollamaPullFails = true
        app.swipeDown(velocity: .fast); sleep(1)
        startPull("smollm")
        app.swipeDown(velocity: .fast); sleep(1)
        openHome(app)
        let failed = element(app, "tap to retry")   // caption text on iOS, as warmth is — not in the row's label
        XCTAssertTrue(failed.waitForExistence(timeout: 90), "a pull that cannot succeed never said so on its row")
        server.ollamaPullFails = false
        failed.tap()
        let retried = expectation(for: NSPredicate { _, _ in self.server.ollamaModels.contains("smollm") }, evaluatedWith: nil)
        wait(for: [retried], timeout: 30)
    }

    /// D6 (part): search settings checks a pasted key with Brave — a refused key is said so, an accepted one says so.
    func testSearchSettingsChecksTheKeyWithBrave() {
        for rejects in [true, false] {
            server.braveRejects = rejects
            let app = ProductE2E.launch(environment: ["UITEST_SEED_LOCAL_ENDPOINT": server.baseURL, "UITEST_SEED_LOCAL_MODEL": "fake-model",
                                                      "UITEST_BRAVE_ENDPOINT": server.braveEndpoint])
            ProductE2E.openSettings(app)
            let search = app.descendants(matching: .any)["settings.search"].firstMatch
            if search.waitForExistence(timeout: 3) { search.tap() } else { app.staticTexts["search"].firstMatch.tap() }
            let field = app.textFields["api key"].exists ? app.textFields["api key"].firstMatch : app.secureTextFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10), "search settings has no key field")
            field.tap(); field.typeText(rejects ? "uitest-wrong-key\n" : "uitest-brave-key\n")
            let said = element(app, rejects ? "didn't recognise this key" : "brave accepted this key")
            XCTAssertTrue(said.waitForExistence(timeout: 15), rejects ? "a refused key was not said" : "an accepted key was not said")
            app.terminate()
        }
    }

    // MARK: C9 — config problems are surfaced, never read as a first run

    /// C9: an unreadable config is quarantined and the where sheet says so — no first-run hero offering to start over.
    func testAnUnreadableConfigIsKeptAndSurfacedNotReadAsAFirstRun() {
        let app = ProductE2E.launch(environment: ["UITEST_SEED_CONFIG": "corrupt"])
        ProductE2E.whereChip(app).tap()
        XCTAssertTrue(element(app, "couldn't read your setups").waitForExistence(timeout: 10), "an unreadable config was not surfaced")
        XCTAssertTrue(element(app, "kept a copy").exists, "the problem does not say the file was kept")
        XCTAssertFalse(element(app, "start here").exists, "a load failure was presented as a first run")
    }

    /// C9: one connection saved twice is merged at launch and the sheet says what it tidied; "ok" clears it.
    func testADuplicateConnectionIsMergedAndAnnounced() {
        let app = ProductE2E.launch(environment: ["UITEST_SEED_CONFIG": "duplicates"])
        ProductE2E.whereChip(app).tap()
        XCTAssertTrue(element(app, "tidied up").waitForExistence(timeout: 10), "a merged duplicate was not announced")
        XCTAssertTrue(element(app, "saved more than once").exists, "the notice does not say what was merged")
        app.buttons["ok"].firstMatch.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element(app, "tidied up"))
        wait(for: [gone], timeout: 5)
    }

    /// C9: offline, the get section says why nothing can be added rather than offering adds that will fail.
    func testOfflineTheWhereSheetSaysWhyNothingCanBeAdded() {
        let app = ProductE2E.launch(arguments: ["--uitesting", "-simulateOfflinePath"],
                                    environment: ["UITEST_SEED_LOCAL_ENDPOINT": server.baseURL, "UITEST_SEED_LOCAL_MODEL": "fake-model"])
        ProductE2E.whereChip(app).tap()
        let said = element(app, "connect to a network to add cloud keys")
        // the get section sits below the medium detent, and a List renders only what is on screen
        for _ in 0..<4 where !said.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(said.waitForExistence(timeout: 5), "offline, the get section did not say why")
    }

    /// B9: a place that answers one question at a time is sent only the new question, and the rule says "starts fresh".
    func testASingleTurnPlaceStartsFreshEachMessage() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_MAX_MESSAGES": "1"])
        ProductE2E.sendAndWait(app, "first question")
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 20), "the first turn never ended")
        XCTAssertFalse(app.descendants(matching: .any)["chat.freshStartRule"].firstMatch.exists, "the first turn is marked as a fresh start")
        ProductE2E.sendAndWait(app, "second question")
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 20), "the second turn never ended")
        let second = server.requestBodies.last ?? ""
        XCTAssertTrue(second.contains("second question"), "the second request lost its own question")
        XCTAssertFalse(second.contains("first question"), "a single-turn place was sent the thread: \(second.prefix(300))")
        XCTAssertTrue(app.descendants(matching: .any)["chat.freshStartRule"].firstMatch.waitForExistence(timeout: 5), "the second turn does not say it starts fresh")
    }

    /// G5: delete a phone model's weights (asked first) → the row goes back to get and offers the download again.
    func testDeletingAModelsWeightsOffersTheDownloadAgain() {
        let repo = "litert-community/gemma-4-E4B-it-litert-lm"   // not the one the on-device suites keep on disk
        let app = ProductE2E.launch(environment: ["UITEST_SEED_STANDIN_WEIGHTS": repo, "UITEST_SEED_ONDEVICE_MODEL": repo])
        ProductE2E.whereChip(app).tap()
        // the sheet's row, not the chat's where chip behind it, which carries the same name
        let row = app.buttons.matching(identifier: "where.row").matching(NSPredicate(format: "label CONTAINS[c] %@", "gemma 4 e4b")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the stand-in model is not a ready row")
        row.press(forDuration: 1.2)
        let delete = app.buttons["delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the row's menu offers no delete")
        delete.tap()
        let confirm = app.alerts.buttons["delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "deleting weights did not ask first")
        confirm.tap()
        // its own get row — or, when it was the only place, first run, whose download is the recommended model
        let offered = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "download gemma 4 e4b", "download · ")).firstMatch
        XCTAssertTrue(offered.waitForExistence(timeout: 10), "after the delete, no download is offered")
        XCTAssertFalse(row.exists, "the deleted model is still a ready row")
    }

    /// B4: a 401 offers the vendor's key console and a 402 its billing page, named for the vendor.
    func testAKeyOrBillingFailureOffersTheVendorsConsole() {
        for (status, label) in [(401, "manage api key at Fireworks"), (402, "add credits at Fireworks")] {
            server.statusCode = status
            let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_LOCAL_NAME": "Fireworks"])
            ProductE2E.typeIntoComposer(app, "status \(status)")
            ProductE2E.send(app)
            XCTAssertTrue(element(app, label).waitForExistence(timeout: 30), "HTTP \(status) offered no \"\(label)\"")
            app.terminate()
        }
    }

    /// B5: a reasoning model says "thinking..." while it reasons and "thought for Ns" after; the disclosure toggles the reasoning.
    func testAThinkingReplySaysSoAndItsDisclosureToggles() throws {
        // an inline think block, as Android's fake sends it: `reasoning_content` frames are the engine's
        // reasoning-only FALLBACK on iOS, not a disclosure
        server.replies = ["<think>Thinking step 0: weigh the question, pick the plain answer.</think> use-case-reply-alpha"]
        server.startDelay = 3
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.typeIntoComposer(app, "think first")
        ProductE2E.send(app)
        XCTAssertTrue(element(app, "thinking...").waitForExistence(timeout: 15), "no \"thinking...\" while it reasoned")
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 40), "the turn never ended")
        let thought = element(app, "thought for")
        // the label heads the reply, and the transcript ends pinned to its tail: scroll up to it
        for _ in 0..<6 where !thought.waitForExistence(timeout: 1) { app.swipeDown() }
        XCTAssertTrue(thought.waitForExistence(timeout: 5), "no \"thought for\" once it finished")
        let reasoning = element(app, "Thinking step 0")
        let before = reasoning.exists
        let toggle = app.buttons.matching(NSPredicate(format: "label IN %@", ["Forward", "Go Forward", "chevron.right", "Go Down", "chevron.down"])).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the reasoning has no disclosure: \(app.debugDescription.prefix(3000))")
        toggle.tap()
        let flipped = expectation(for: NSPredicate(format: "exists == %@", NSNumber(value: !before)), evaluatedWith: reasoning)
        wait(for: [flipped], timeout: 5)
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Forward", "Go Forward", "chevron.right", "Go Down", "chevron.down"])).firstMatch.tap()
        let back = expectation(for: NSPredicate(format: "exists == %@", NSNumber(value: before)), evaluatedWith: reasoning)
        wait(for: [back], timeout: 5)
    }

    /// C5: a keyed setup's key cannot be emptied from its form — the save is refused, saying why. Revoking is deleting.
    func testAKeyedSetupRefusesToSaveWithItsKeyEmptied() {
        // a placeholder key (the offline trust seed's), never a host key file: nothing here reaches fireworks
        let app = ProductE2E.launch(environment: ["UITEST_SEED_PRESET": "fireworks", "UITEST_NO_HOST_KEYS": "1", "UITEST_SEED_ATTESTATION": "ok"])
        ProductE2E.openSettings(app)
        app.buttons["settings.providers"].firstMatch.tap()
        element(app, "cloud keys").tap()
        XCTAssertTrue(app.navigationBars["cloud keys"].waitForExistence(timeout: 5), "cloud keys did not open")
        let edit = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ", edit")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "fireworks has no edit row")
        edit.tap()
        let key = app.secureTextFields.firstMatch.exists ? app.secureTextFields.firstMatch : app.textFields.matching(NSPredicate(format: "value CONTAINS %@", "uitest")).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5), "the form has no key field")
        key.tap()
        key.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        key.typeText(XCUIKeyboardKey.delete.rawValue)
        app.buttons["save"].firstMatch.tap()
        XCTAssertTrue(element(app, "enter your fireworks api key to save this setup.").waitForExistence(timeout: 5), "the refusal does not say why")
        XCTAssertTrue(app.buttons["save"].firstMatch.exists, "the form closed on a refused save")
    }

    /// D3: no key — the model calls search and the offer card appears; a pasted key Brave accepts re-asks the question,
    /// which searches and answers.
    func testAnOfferedSearchKeyIsCheckedAndTheQuestionIsAskedAgain() {
        server.emitToolRound = true
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_BRAVE_ENDPOINT": server.braveEndpoint])
        ProductE2E.typeIntoComposer(app, "what is the weather in paris")
        ProductE2E.send(app)
        // the card's own identifier is on every element inside it, so the button is found by its label
        let paste = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label ==[c] %@", "chat.webSearchOffer", "paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 30), "a keyless search call offered no key")
#if os(iOS)
        UIPasteboard.general.string = "uitest-brave-key"
#endif
        paste.tap()
        // the system's paste consent, when it asks
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow Paste"].firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(element(app, "brave accepted this key").waitForExistence(timeout: 15), "the pasted key was not checked")
        XCTAssertTrue(element(app, server.toolFollowUpReply).waitForExistence(timeout: 30), "the re-asked question was not answered")
        XCTAssertGreaterThanOrEqual(server.braveRequests, 1, "the key was never checked with brave")
        XCTAssertTrue(server.requestBodies.last?.contains("web_search") == true, "the re-ask went out without the search tool")
    }

    /// D5: with a key the web chip toggles in place, and the next turn does — then does not — search. "Does not" is
    /// Brave never asked: off, the turn still carries the KEYLESS tool (makeGroundingTools), whose call cannot search.
    func testTheWebChipWithAKeyTogglesWhetherTheNextTurnSearches() {
        server.emitToolRound = true
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_GROUNDING": "placeholder",
                                                                    "UITEST_BRAVE_ENDPOINT": server.braveEndpoint])
        let chip = app.buttons["chat.webSearchChip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no web chip")
        XCTAssertEqual(chip.value as? String, "on", "a keyed, enabled search reads off")
        ProductE2E.sendAndWait(app, "first, searching")
        XCTAssertTrue(element(app, server.toolFollowUpReply).waitForExistence(timeout: 30), "the searching turn never answered")
        let searched = server.braveRequests
        XCTAssertGreaterThanOrEqual(searched, 1, "search on, yet brave was never asked")
        chip.tap()
        XCTAssertEqual(chip.value as? String, "off", "the chip did not toggle in place")
        XCTAssertFalse(app.descendants(matching: .any)["settings.search"].firstMatch.exists, "a keyed chip opened settings instead of toggling")
        ProductE2E.sendAndWait(app, "second, not searching")
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 30), "the second turn never ended")
        XCTAssertEqual(server.braveRequests, searched, "search off, yet brave was asked")
    }

    /// C3: "recently used" lists what has ANSWERED — and only that: nothing before the first turn, the model after.
    /// On a persisting store (UITEST_SEED_CONFIG=empty, in a temporary directory): the --uitesting store is in-memory,
    /// and `recordUse` records nothing there.
    func testAModelThatAnsweredIsRecentlyUsed() {
        let app = ProductE2E.launchLocal(server: server, extraEnv: ["UITEST_SEED_CONFIG": "empty"])
        let header = element(app, "recently used")
        ProductE2E.whereChip(app).tap()
        for _ in 0..<3 where !header.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertFalse(header.exists, "recently used before anything answered")
        app.buttons["close"].firstMatch.tap(); sleep(1)
        ProductE2E.sendAndWait(app, "hello a")
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 20))
        ProductE2E.whereChip(app).tap()
        for _ in 0..<4 where !header.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(header.exists, "the model that answered is not recently used")
    }
    /// C7: an id the catalogue does not list can still be used — the browser offers the typed text as the model id.
    /// Fireworks, not near.ai: near.ai's catalogue is fixed (ModelBrowserDoor: no custom id there).
    func testATypedModelIdCanBeUsedFromTheBrowser() {
        let app = ProductE2E.launch(environment: ["UITEST_SEED_PRESET": "fireworks", "UITEST_NO_HOST_KEYS": "1", "UITEST_SEED_ATTESTATION": "ok"])
        ProductE2E.whereChip(app).tap()
        app.buttons["cloud"].firstMatch.tap()
        // the get section's fireworks row (its ready row names the model, "kimi-…, fireworks"), below the fold
        let browse = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "fireworks")).firstMatch
        for _ in 0..<4 where !browse.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "no fireworks row to browse from: \(app.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty })")
        browse.tap()
        let search = app.searchFields["search models"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20), "the model browser did not open")
        search.tap(); search.typeText("acme/uitest-typed-7b")
        let use = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "as model id")).firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 10), "the browser offers no way to use a typed id")
        use.tap()
        XCTAssertTrue(ProductE2E.whereChip(app).waitForExistence(timeout: 10))
        let chip = ProductE2E.whereChip(app)
        XCTAssertTrue(chip.label.lowercased().contains("uitest-typed-7b") || ProductE2E.titleLabel(app).lowercased().contains("uitest-typed-7b"),
                      "the typed id did not become the chat's model: \(chip.label)")
    }
    /// D6: on a provider that searches by itself (Brave Answers), search settings says so instead of asking for a key.
    func testSearchSettingsSaysWhenTheProviderSearchesItself() {
        let app = ProductE2E.launch(environment: ["UITEST_SEED_PRESET": "braveanswers", "UITEST_NO_HOST_KEYS": "1", "UITEST_SEED_ATTESTATION": "ok"])
        ProductE2E.openSettings(app)
        let search = app.descendants(matching: .any)["settings.search"].firstMatch
        if search.waitForExistence(timeout: 3) { search.tap() } else { app.staticTexts["search"].firstMatch.tap() }
        XCTAssertTrue(element(app, "search is built in here").waitForExistence(timeout: 10), "a built-in-search provider's settings do not say so")
        XCTAssertFalse(app.secureTextFields.firstMatch.exists || app.textFields["api key"].exists, "built-in search still asks for a brave key")
    }
    /// B6: a markdown reply renders as structure — heading, list, table, a code block — with none of its
    /// syntax on screen, and its link opens the browser at the link's host.
    func testAMarkdownReplyRendersAndItsLinkOpensTheBrowser() {
        server.replies = ["## Harbour notes\n\n- first buoy\n- second buoy\n\n| ship | berth |\n|---|---|\n| Aurora | 7 |\n\n```\nlet tide = 4\n```\n\nSee [the chart](https://example.org/chart) for more."]
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "show me markdown")
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 30))
        XCTAssertTrue(element(app, "for more").waitForExistence(timeout: 10), "the reply never rendered")
        XCTAssertTrue(element(app, "Harbour notes").exists, "the heading did not render"); XCTAssertFalse(element(app, "## Harbour").exists, "the heading's ## is on screen")
        XCTAssertTrue(element(app, "first buoy").exists && element(app, "second buoy").exists, "the list did not render"); XCTAssertFalse(element(app, "- first buoy").exists, "list syntax on screen")
        XCTAssertTrue(element(app, "Aurora").exists, "the table's cells did not render"); XCTAssertFalse(element(app, "|---|").exists || element(app, "| ship").exists, "table syntax on screen")
        XCTAssertTrue(element(app, "let tide = 4").exists, "the code block did not render"); XCTAssertFalse(element(app, "```").exists, "fence syntax on screen")
        // no copy control: a chat code block is Textual's default style on iOS, and Android matches it
        XCTAssertFalse(element(app, "](https").exists, "link syntax on screen")
        let link = app.links.matching(NSPredicate(format: "label CONTAINS[c] %@", "the chart")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5), "the link is not a link")
        // Textual's link run reports not-hittable (its text view owns the touch); a tap at the run is what a finger does
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "the link did not open the browser")
        let at = safari.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "example.org", "example.org")).firstMatch
        XCTAssertTrue(at.waitForExistence(timeout: 15), "the browser is not at example.org")
        app.activate()
    }
    /// H4: every preset's key form links to where that vendor issues keys — near.ai, xAI, Fireworks, OpenRouter, NVIDIA, Brave.
    func testEveryPresetsKeyLinkOpensTheBrowserAtItsVendor() {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        for (row, host) in [("near.ai", "near.ai"), ("grok", "x.ai"), ("fireworks", "fireworks.ai"), ("openrouter", "openrouter.ai"), ("nvidia", "nvidia.com"), ("brave answers", "brave.com")] {
            let app = ProductE2E.launchLocal(server: server)
            ProductE2E.whereChip(app).tap()
            app.buttons["cloud"].firstMatch.tap()
            let preset = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", row + ",")).firstMatch
            for _ in 0..<4 where !preset.waitForExistence(timeout: 2) { app.swipeUp() }
            XCTAssertTrue(preset.exists, "no \(row) row on the cloud filter")
            preset.tap()
            // the link names the vendor's console ("get xai api key" on grok's form), so it is found, not spelled
            let link = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@ AND label ENDSWITH[c] %@", "get ", "api key")).firstMatch
            for _ in 0..<3 where !link.waitForExistence(timeout: 3) { app.swipeUp() }
            XCTAssertTrue(link.exists, "\(row)'s key form has no get-a-key link")
            link.tap()
            XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "\(row)'s link did not open the browser")
            let at = safari.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", host, host)).firstMatch
            XCTAssertTrue(at.waitForExistence(timeout: 15), "\(row)'s link is not at \(host)")
            safari.terminate()
            app.terminate()
        }
    }

    /// E5: in every trust state the title opens the sheet; where it has rungs, everyday and expert each scroll to their
    /// last line — nothing stranded under the home indicator.
    func testTheTitleOpensTheLadderInEveryStateAndEachRungScrollsToItsEnd() {
        for state in (ProcessInfo.processInfo.environment["E5_STATES"]?.split(separator: ",").map(String.init) ?? ["ok", "verifying", "hardFailure", "mismatch", "none", "e2eeUnavailable"]) {
            let app = ProductE2E.launch(environment: ["UITEST_SEED_NEARAI_MODEL": "z-ai/glm-5.3-flash", "UITEST_SEED_ATTESTATION": state])
            let title = ProductE2E.titleBlock(app)
            XCTAssertTrue(title.waitForExistence(timeout: 15), "\(state): title block missing")
            title.tap()
            let opened = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "who can read this", "end-to-end")).firstMatch
            XCTAssertTrue(opened.waitForExistence(timeout: 8), "\(state): the title opened no sheet")
            let bottomLimit = app.frame.maxY - 30
            // the scroll-to-end check on "ok" only: it carries both rungs and by far the longest content (the live audit
            // findings), and a swipe over that tree costs XCUITest a snapshot each — six states of it ran past 45 minutes
            guard state == "ok" else { app.terminate(); continue }
            let rungs: [String?] = app.buttons["expert"].exists ? ["everyday", "expert"] : [nil]
            for rung in rungs {
                if let rung { app.buttons[rung].firstMatch.tap(); sleep(1) }
                // one snapshot of the tree, not an element walk (21 minutes the slow way): every on-screen StaticText's frame
                let pattern = try! NSRegularExpression(pattern: #"StaticText, 0x[0-9a-f]+, \{\{(-?[\d.]+), (-?[\d.]+)\}, \{([\d.]+), ([\d.]+)\}\}[^\n]*?label: '([^']*)'"#)
                func visibleTexts() -> [(CGFloat, String)] {
                    let tree = app.debugDescription
                    return pattern.matches(in: tree, range: NSRange(tree.startIndex..., in: tree)).compactMap { m -> (CGFloat, String)? in
                        func g(_ i: Int) -> String { String(tree[Range(m.range(at: i), in: tree)!]) }
                        let y = CGFloat(Double(g(2))!), h = CGFloat(Double(g(4))!)
                        return (h > 0 && y < app.frame.maxY) ? (y + h, g(5)) : nil
                    }
                }
                // to the END: the expert rung carries the live audit findings and runs to many screens. Swipes are cheap and a
                // tree snapshot is not (one per swipe took 40 minutes): swipe far, then confirm a few more swipes move nothing.
                func bottom() -> String { visibleTexts().max { $0.0 < $1.0 }.map { "\($0.1)@\($0.0)" } ?? "" }
                for _ in 0..<25 { app.swipeUp(velocity: .fast) }
                var settled = bottom()
                for _ in 0..<3 {
                    for _ in 0..<3 { app.swipeUp(velocity: .fast) }
                    let now = bottom(); if now == settled { break }; settled = now
                }
                sleep(1)
                let frames = visibleTexts()
                let last = frames.max { $0.0 < $1.0 }
                XCTAssertLessThanOrEqual(last?.0 ?? 0, bottomLimit, "\(state)/\(rung ?? "sheet"): \"\(last?.1.prefix(80) ?? "")\" ends at \(last?.0 ?? 0), under the home indicator")
            }
            app.terminate()
        }
    }
    /// C8: a pull shows its progress on its where row while it runs, and the row's cancel ends it — the model never
    /// lands on the machine, and the next reading of the machine drops the row.
    func testAPullShowsProgressAndCancelEndsIt() {
        server.ollama = true
        server.ollamaPullSteps = 150; server.ollamaPullStepDelay = 0.2   // ~30 s: long enough to watch and stop
        let app = ProductE2E.launchLocal(server: server)
        openHome(app)
        let add = cells(app, containing: "add a model to")
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no add-a-model row")
        add.tap()
        let field = app.textFields["paste the link here"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the pull sheet has no link field")
        field.tap(); field.typeText("slowmodel")
        app.buttons["download"].firstMatch.tap()
        sleep(2)
        if !element(app, "downloading").exists { openHome(app) }
        XCTAssertTrue(element(app, "downloading").waitForExistence(timeout: 15), "the running pull shows no progress on its row")
        let cancel = app.buttons["cancel download"].firstMatch   // WhereRow: an xmark in the tick's slot
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the pulling row has no cancel")
        cancel.tap()
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "downloading"))
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 10), .completed, "cancel did not stop the pull")
        sleep(31)   // past where the pull would have ended
        XCTAssertFalse(server.ollamaModels.contains("slowmodel"), "a cancelled pull landed on the machine anyway")
    }

    // MARK: - batch 5 (2026-10-05)

    /// H3: places & keys lists home machines and cloud keys, and a cloud key added from it lands in its list.
    func testPlacesAndKeysAddsACloudKeyToItsList() {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.openSettings(app)
        app.buttons["settings.providers"].firstMatch.tap()
        XCTAssertTrue(element(app, "home machines").waitForExistence(timeout: 5), "the hub does not list home machines")
        XCTAssertTrue(element(app, "cloud keys").exists, "the hub does not list cloud keys")
        element(app, "cloud keys").tap()
        XCTAssertTrue(app.navigationBars["cloud keys"].waitForExistence(timeout: 5), "cloud keys did not open")
        XCTAssertTrue(element(app, "no cloud keys yet.").waitForExistence(timeout: 5), "a fresh store already has cloud keys")
        element(app, "add cloud key").tap()
        let near = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "near.ai")).firstMatch
        XCTAssertTrue(near.waitForExistence(timeout: 10), "the picker offers no near.ai")
        near.tap()
        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 10), "near.ai's key form did not open")
        key.tap(); key.typeText("uitest-near-key")
        app.buttons["save"].firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND label ENDSWITH %@", "near.ai", ", edit")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "near.ai is not in cloud keys after save: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(element(app, "no cloud keys yet.").exists, "cloud keys still says it has none")
    }

    /// B7: part of an answer can be selected and copied — a long press on a word selects it, and copy takes that, not the whole reply.
    func testPartOfAnAnswerCanBeSelectedAndCopied() {
        let answer = "Selectable alpha bravo charlie delta echo foxtrot golf hotel india juliet."
        server.replies = [answer]
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "say-the-alphabet")
        let reply = element(app, "charlie")
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "the answer is not in the transcript")
        // by coordinate: Textual's text reports not-hittable to XCUITest. A tap at the start point puts the answer into
        // selection and a second (XCUITest's double tap) takes the word under it, with the Copy · Share… menu — a part,
        // where a long press copies the whole answer
        let start = reply.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25))
        start.tap(); sleep(1)
        start.doubleTap(); sleep(1)
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@ AND (elementType == %d OR elementType == %d)",
            "copy", XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.menuItem.rawValue)).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "selecting a word offered no copy: \(app.debugDescription.prefix(3000))")
        copy.tap(); sleep(1)
        // read it back INSIDE the app (the runner reading UIPasteboard raises the paste prompt and hangs)
        let composer = ProductE2E.composer(app)
        composer.tap(); composer.press(forDuration: 1.2)
        let paste = app.menuItems.matching(NSPredicate(format: "label ==[c] %@", "paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the composer offered no paste")
        paste.tap(); sleep(1)
        let pasted = (composer.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(pasted.isEmpty, "nothing was copied from the answer")
        XCTAssertTrue(answer.contains(pasted), "the copy \"\(pasted)\" is not from the answer")
        XCTAssertLessThan(pasted.count, answer.count, "the whole answer was copied, not a part of it")
    }
}
