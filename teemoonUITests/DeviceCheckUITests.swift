//
//  DeviceCheckUITests.swift
//  teemoonUITests
//
//  the maintainer's 1.1.0 device check, driven on his iPhone against the installed "teemoon dev" (ai.teemoon.app.dev). Runs
//  only when asked (TEEMOON_DEVICE_CHECK=1 in the .xctestrun) and only on a device. Never --uitesting, never
//  ProductE2E.launch: those stage keys and once wiped the dev app's (2026-10-21). Photos go in through the pasteboard,
//  never the Photos library. Every chat it makes starts "zz check" and is deleted at the end; the model and developer
//  mode it changes are put back.
//

import UIKit
import UniformTypeIdentifiers
import XCTest

final class DeviceCheckUITests: XCTestCase {

    static let marker = "devcheck"
    static let bundleID = "ai.teemoon.app.dev"

    override func setUpWithError() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("device only")
        #else
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless((env["TEEMOON_DEVICE_CHECK"] ?? env["TEST_RUNNER_TEEMOON_DEVICE_CHECK"]) == "1",
                          "device check: set TEEMOON_DEVICE_CHECK=1")
        continueAfterFailure = true
        #endif
    }

    // MARK: - Helpers

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.bundleID)
        app.launchArguments = extra
        app.launch()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 30), "the dev app did not open on a chat")
        let chip = app.descendants(matching: .any)["chat.whereChip"].firstMatch
        if Self.chipAtStart == nil, chip.waitForExistence(timeout: 10) {
            // An earlier run that stopped early left its model; the person's own choice can be named instead.
            let env = ProcessInfo.processInfo.environment
            Self.chipAtStart = env["TEEMOON_DEVICE_CHECK_RESTORE"] ?? env["TEST_RUNNER_TEEMOON_DEVICE_CHECK_RESTORE"] ?? chip.label
            note("model at start: \(chip.label)")
        }
        return app
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["chat.composer"].firstMatch }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func note(_ text: String) {
        let a = XCTAttachment(string: text)
        a.name = "note"; a.lifetime = .keepAlways; add(a)
        print("DEVICECHECK \(text)")
    }

    enum Shape { case circle, square, triangle }
    static let colours: [(UIColor, String)] = [(.systemRed, "red"), (.systemBlue, "blue"), (.systemGreen, "green"),
                                              (.systemYellow, "yellow"), (.systemPurple, "purple"), (.systemOrange, "orange"),
                                              (.black, "black"), (.systemPink, "pink"), (.brown, "brown"), (.systemGray, "gray")]

    static let tenFixtures = ["red-circle", "blue-square", "green-triangle", "yellow-circle", "purple-circle",
                              "orange-circle", "black-circle", "pink-circle", "brown-circle", "gray-circle"]

    static func photo(_ color: UIColor, _ shape: Shape = .circle) -> Data {
        let size = CGSize(width: 512, height: 512)
        return UIGraphicsImageRenderer(size: size).pngData { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            color.setFill()
            let box = CGRect(x: 96, y: 96, width: 320, height: 320)
            switch shape {
            case .circle: UIBezierPath(ovalIn: box).fill()
            case .square: UIBezierPath(rect: box).fill()
            case .triangle:
                let p = UIBezierPath()
                p.move(to: CGPoint(x: box.midX, y: box.minY)); p.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
                p.addLine(to: CGPoint(x: box.minX, y: box.maxY)); p.close(); p.fill()
            }
        }
    }

    /// Whether the system pasteboard holds exactly `png` now. On a device the runner can neither write nor read the
    /// general pasteboard (PBErrorDomain 10/11, 2026-11-12), so this is false there and nothing is pasted: the app
    /// would otherwise paste whatever the person last copied. The incident: the maintainer's own photo went into test chats.
    static func pasteboardHolds(_ png: Data, board: UIPasteboard = .general) -> Bool {
        guard let held = board.data(forPasteboardType: UTType.png.identifier) else { return false }
        return held == png
    }

    static let helperID = "ai.teemoon.devcheck"
    /// The guard's proof run: the helper writes nothing, so the run must stop before any send.
    static var helperWriteDisabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return (env["TEEMOON_DEVICE_CHECK_NOWRITE"] ?? env["TEST_RUNNER_TEEMOON_DEVICE_CHECK_NOWRITE"]) == "1"
    }

    /// The devcheck helper puts the fixture on the pasteboard in the foreground and reports its hash; teemoon pastes
    /// only when that hash is the fixture's. Nothing runs between the helper's write and the paste.
    private func paste(_ app: XCUIApplication, _ fixture: String) {
        guard !Self.aborted else { XCTFail("aborted: no paste after an unproven one"); return }
        guard let expected = DeviceCheckFixtures.sha256[fixture] else { XCTFail("no fixture \(fixture)"); Self.aborted = true; return }
        let helper = XCUIApplication(bundleIdentifier: Self.helperID)
        helper.launchArguments = ["-fixture", fixture] + (Self.helperWriteDisabled ? ["-noWrite"] : [])
        helper.launch()
        let status = helper.staticTexts["devcheck.status"]
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !status.exists || status.label == "working" { Thread.sleep(forTimeInterval: 0.2) }
        guard status.exists, status.label == "ready \(expected)" else {
            note("helper said \(status.exists ? status.label : "nothing") for \(fixture); the run stops before any send")
            XCTFail("the pasteboard does not hold the fixture; nothing pasted, the run stops")
            Self.aborted = true
            return
        }
        app.activate()
        let before = app.descendants(matching: .any).matching(identifier: "chat.pendingImage").count
        let field = composer(app)
        _ = field.waitForExistence(timeout: 10)
        // Back from another app the first long press can land before the field takes focus: tap, then try twice.
        field.tap()
        Thread.sleep(forTimeInterval: 0.8)
        let item = app.descendants(matching: .any)["Paste"].firstMatch
        var offered = false
        for _ in 0..<2 where !offered {
            field.press(forDuration: 1.2)
            offered = item.waitForExistence(timeout: 4)
        }
        if offered { item.tap() } else { XCTFail("the edit menu offers no Paste"); Self.aborted = true; return }
        let attached = app.descendants(matching: .any).matching(identifier: "chat.pendingImage")
        let grew = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > %d", before), object: attached)
        if XCTWaiter().wait(for: [grew], timeout: 6) != .completed {
            XCTFail("the paste attached no image"); Self.aborted = true
        }
    }

    private func type(_ app: XCUIApplication, _ text: String) {
        let field = composer(app)
        field.tap()
        field.typeText(text)
    }

    /// Sends and returns seconds from the tap to the first streamed word (nil if none came).
    @discardableResult
    private func send(_ app: XCUIApplication, timeout: TimeInterval = 240) -> Double? {
        guard !Self.aborted else { XCTFail("aborted: no send after an unproven paste"); return nil }
        let start = Date()
        app.buttons["chat.send"].firstMatch.tap()
        let streaming = app.descendants(matching: .any)["chat.streamingText"].firstMatch
        var first: Double?
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if first == nil, streaming.exists, !(streaming.label.isEmpty) { first = Date().timeIntervalSince(start) }
            if !app.buttons["chat.stop"].exists, Date().timeIntervalSince(start) > 3 { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(app.buttons["chat.stop"].exists, "the reply did not finish in \(Int(timeout)) s")
        return first
    }

    private func contains(_ app: XCUIApplication, _ word: String) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", word)).firstMatch.exists
    }

    /// Set when a paste could not be proven to carry the test image; every later step refuses to send.
    static var aborted = false

    /// The where chip's label before the run, to put the model back (tests run in name order in one process).
    static var chipAtStart: String?

    private func openWhere(_ app: XCUIApplication) -> Bool {
        let chip = app.descendants(matching: .any)["chat.whereChip"].firstMatch
        guard chip.waitForExistence(timeout: 10) else { XCTFail("no where chip"); return false }
        chip.tap()
        return app.buttons["where.showOnly"].waitForExistence(timeout: 8)
    }

    /// Turns "show only" off and goes back to the all tab, so the next pick sees every row.
    private func clearWhereFilter(_ app: XCUIApplication) {
        if !app.buttons["where.showOnly"].exists { guard openWhere(app) else { return } }
        let showOnly = app.buttons["where.showOnly"]
        if showOnly.label.contains("reads images") {
            showOnly.tap()
            let on = app.buttons["reads images"].firstMatch
            if on.waitForExistence(timeout: 3) { on.tap() }
        }
        let all = app.buttons["all"].firstMatch
        if all.exists { all.tap() }
        app.swipeDown(velocity: .fast)
    }

    /// Picks the first where-sheet row whose label contains `fragment`; false (and a note) when none is there.
    @discardableResult
    private func pick(_ app: XCUIApplication, _ fragment: String) -> Bool {
        guard openWhere(app) else { return false }
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
        guard row.waitForExistence(timeout: 6) else {
            note("no where row contains \"\(fragment)\""); shot(app, "where-no-\(fragment)")
            app.swipeDown(velocity: .fast); return false
        }
        row.tap()
        _ = composer(app).waitForExistence(timeout: 10)
        return true
    }

    private func setDeveloperMode(_ app: XCUIApplication, on: Bool) -> Bool? {
        app.buttons["chat.settings"].firstMatch.tap()
        let toggle = app.switches["settings.developerMode"].firstMatch
        var scrolls = 0
        while !toggle.exists, scrolls < 8 { app.swipeUp(); scrolls += 1 }
        guard toggle.exists else { XCTFail("no developer mode toggle"); return nil }
        let was = (toggle.value as? String) == "1"
        if was != on { toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap() }
        let close = app.buttons["settings.close"]
        if close.waitForExistence(timeout: 3) { close.tap() } else { app.swipeDown(velocity: .fast) }
        return was
    }

    // MARK: - 1. E2B reads phone photos

    func test1_E2BOneAndTenPhotos() {
        let app = launch()
        guard pick(app, "e2b") else { return }
        paste(app, "red-circle")
        type(app, "\(Self.marker) 1: what colour is the shape? one word.")
        let one = send(app)
        note("step 1 one photo: first word after \(one.map { String(format: "%.1f s", $0) } ?? "none")")
        XCTAssertTrue(contains(app, "red"), "one photo: no \"red\"")
        shot(app, "1-e2b-one-photo")

        _ = launch()
        for name in Self.tenFixtures { paste(app, name) }
        type(app, "\(Self.marker) 10: name the colour in each of these 10 pictures, numbered 1 to 10.")
        let ten = send(app)
        note("step 1 ten photos: first word after \(ten.map { String(format: "%.1f s", $0) } ?? "none")")
        let named = Self.colours.filter { contains(app, $0.1) }.map(\.1)
        note("step 1 ten photos named: \(named)")
        XCTAssertGreaterThanOrEqual(named.count, 7, "ten photos: only \(named) named")
        shot(app, "1-e2b-ten-photos")
    }

    // MARK: - 2. Earlier photos go back

    func test2_HistoryPhotosReachTheModel() {
        let app = launch()
        guard pick(app, "e2b") else { return }
        let devWas = setDeveloperMode(app, on: true)
        paste(app, "red-circle")
        type(app, "\(Self.marker) history: here is photo one. reply ok.")
        send(app)
        paste(app, "blue-square")
        type(app, "here is photo two. reply ok.")
        send(app)
        type(app, "compare the two photos: what shape and colour is each?")
        send(app)
        shot(app, "2-history-answer")
        let card = app.descendants(matching: .any)["chat.debugCard"].firstMatch
        if card.waitForExistence(timeout: 10) {
            card.swipeUp()
            let body = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "request body")).firstMatch
            if body.waitForExistence(timeout: 5) { body.tap() }
            let parts = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "image · ")).allElementsBoundByIndex
                .map(\.label).joined(separator: "\n")
            let count = parts.components(separatedBy: "image · ").count - 1
            note("step 2 image parts in the last request: \(count)")
            XCTAssertEqual(count, 2, "the last request should carry both earlier photos")
            shot(app, "2-history-card")
        } else {
            XCTFail("no last-request card")
        }
        XCTAssertTrue(contains(app, "red") && contains(app, "blue"), "the answer did not see both photos")
        if let devWas, !devWas { _ = setDeveloperMode(app, on: false) }
    }

    // MARK: - 3. A model that can't see images

    func test3_BlindModelRefusalAndWhereSheet() {
        let app = launch()
        guard pick(app, "glm") else { return }
        paste(app, "green-triangle")
        type(app, "\(Self.marker) blind: what is this?")
        guard !Self.aborted else { XCTFail("aborted: no send after an unproven paste"); return }
        app.buttons["chat.send"].firstMatch.tap()   // refused before the wire: this model can't see images
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "no refusal")
        note("step 3 alert: \(alert.label) | \(alert.staticTexts.allElementsBoundByIndex.map(\.label)) | \(alert.buttons.allElementsBoundByIndex.map(\.label))")
        shot(app, "3-alert")
        alert.buttons["choose model"].tap()
        var keyboardFrames = 0, samples = 0
        let filter = app.buttons["where.showOnly"]
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            samples += 1
            if app.keyboards.firstMatch.exists { keyboardFrames += 1 }
        }
        note("step 3 keyboard seen in \(keyboardFrames) of \(samples) samples over the rise")
        XCTAssertTrue(filter.exists && filter.label.contains("reads images"), "the where sheet is not filtered")
        XCTAssertEqual(keyboardFrames, 0, "the keyboard came back on the way")
        shot(app, "3-where-filtered")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.descendants(matching: .any)["chat.pendingImage"].firstMatch.waitForExistence(timeout: 5),
                      "the photo was not kept")
        XCTAssertTrue((composer(app).value as? String ?? "").contains("blind"), "the text was not kept")
        // Never send a photo off the phone: the alert again, then cancel, and the draft is cleared by hand.
        app.buttons["chat.send"].firstMatch.tap()
        if alert.waitForExistence(timeout: 8) {
            XCTAssertTrue(alert.buttons["cancel"].exists, "no cancel")
            alert.buttons["cancel"].tap()
        }
        let removes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "remove"))
        while removes.count > 0 { removes.firstMatch.tap(); Thread.sleep(forTimeInterval: 0.6) }
        shot(app, "3-cancelled")
    }

    // MARK: - 4. E4B under reads images

    func test4_E4BUnderReadsImages() {
        let app = launch()
        guard openWhere(app) else { return }
        let showOnly = app.buttons["where.showOnly"]
        showOnly.tap()
        let reads = app.buttons["reads images"].firstMatch
        if reads.waitForExistence(timeout: 4) { reads.tap() }
        let phone = app.buttons["phone"].firstMatch
        if phone.exists { phone.tap() }
        shot(app, "4-reads-images-phone")
        let e4b = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "e4b")).firstMatch
        note("step 4 e4b row: \(e4b.exists ? e4b.label : "absent")")
        XCTAssertTrue(e4b.exists, "E4B is not listed under reads images")
        if e4b.exists {
            e4b.tap()
            Thread.sleep(forTimeInterval: 2)
            shot(app, "4-e4b-tapped")
            note("step 4 after tap: \(app.descendants(matching: .any)["chat.whereChip"].firstMatch.label)")
        }
        clearWhereFilter(app)
    }

    // MARK: - 5. The + outside the field

    func test5_PlusOutsideTheField() {
        for (name, args) in [("default", [String]()),
                             ("ax5", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])] {
            let app = launch(args)
            let field = composer(app)
            field.tap()
            field.typeText("one\ntwo\nthree")
            let plus = app.buttons["chat.attach"].firstMatch
            // The card's accessibility frame lags on a device (it reported one line while three showed), so the field's
            // edges come from the send arrow, 12 pt inside its bottom-right corner.
            let send = app.buttons["chat.send"].firstMatch
            let fieldBottom = send.frame.maxY + 12
            note("step 5 \(name): + \(plus.frame), send \(send.frame), keyboard \(app.keyboards.firstMatch.exists)")
            XCTAssertLessThan(plus.frame.maxX, field.frame.minX, "\(name): the + is inside the field")
            XCTAssertEqual(plus.frame.maxY, fieldBottom, accuracy: 4, "\(name): the + left the last line")
            shot(app, "5-plus-\(name)")
            field.press(forDuration: 1.0)
            if app.descendants(matching: .any)["Select All"].firstMatch.waitForExistence(timeout: 3) {
                app.descendants(matching: .any)["Select All"].firstMatch.tap()
                app.keys["delete"].firstMatch.tap()
            }
        }
    }

    // MARK: - 6. Removing photos

    func test6_TwoQuickRemovals() {
        let app = launch()
        for name in Self.tenFixtures.prefix(4) { paste(app, name) }
        let thumbs = app.descendants(matching: .any).matching(identifier: "chat.pendingImage")
        XCTAssertEqual(thumbs.count, 4, "four photos did not attach")
        shot(app, "6-four")
        let removes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "remove"))
        if removes.count >= 3 {
            removes.element(boundBy: 1).tap()
            removes.element(boundBy: 1).tap()
        }
        Thread.sleep(forTimeInterval: 1)
        note("step 6 after two quick x taps on the second: \(thumbs.count) left")
        XCTAssertEqual(thumbs.count, 2)
        shot(app, "6-two-left")
        while removes.count > 0 { removes.firstMatch.tap(); Thread.sleep(forTimeInterval: 0.6) }
    }

    // MARK: - 7. Search

    func test7_SearchBoldMatchesRegularTitles() {
        let app = launch()
        app.buttons["list.bullet"].firstMatch.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8), "no search field")
        search.tap()
        search.typeText("colour")
        Thread.sleep(forTimeInterval: 2)
        shot(app, "7-search")
        note("step 7 results: \(app.cells.count)")
    }

    // MARK: - Cleanup (runs last by name)

    func testZ_DeleteCheckChatsAndRestore() {
        let app = launch()
        app.buttons["list.bullet"].firstMatch.tap()
        let search = app.searchFields.firstMatch
        guard search.waitForExistence(timeout: 8) else { XCTFail("no search field"); return }
        search.tap()
        search.typeText(Self.marker)
        Thread.sleep(forTimeInterval: 2)
        var deleted = 0
        while deleted < 20 {
            let cell = app.cells.firstMatch
            guard cell.waitForExistence(timeout: 3) else { break }
            cell.swipeLeft()
            let del = app.buttons["delete"].firstMatch
            guard del.waitForExistence(timeout: 3) else { break }
            del.tap()
            let confirm = app.alerts.buttons["delete"].firstMatch
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
            let sheet = app.sheets.buttons["delete"].firstMatch
            if sheet.waitForExistence(timeout: 1) { sheet.tap() }
            deleted += 1
            Thread.sleep(forTimeInterval: 1)
        }
        note("cleanup: deleted \(deleted) zz check chats")
        shot(app, "z-cleanup")
        // The model it started on: the first words of the chip's label name it.
        let back = launch()
        clearWhereFilter(back)
        if let start = Self.chipAtStart, let name = start.components(separatedBy: ",").first, !name.isEmpty {
            let chip = back.descendants(matching: .any)["chat.whereChip"].firstMatch
            if !chip.label.hasPrefix(name), pick(back, name) {
                note("restored the model: \(chip.label)")
            }
            XCTAssertTrue(chip.label.hasPrefix(name), "the model was not put back: \(chip.label) vs \(start)")
        }
    }
}
