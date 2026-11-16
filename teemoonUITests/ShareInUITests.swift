//
//  ShareInUITests.swift
//  teemoonUITests
//
//  docs/SHARE_IN.md: a share opens teemoon on a new chat whose composer holds the photo and the text, keyboard up,
//  nothing sent. `testSeededShareOpensANewChat` seeds the App Group inbox as the extension would and opens teemoon by
//  its share link; `testShareSheetFromPhotos` drives the real share sheet in Photos.
//

import UIKit
import XCTest

final class ShareInUITests: XCTestCase {

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

    // MARK: the App Group, found from the runner (the simulator does not sandbox the runner from it)

    /// teemoon's App Group folder on this simulator and the bundle id it belongs to.
    private static func appGroup() -> (root: URL, bundleID: String)? {
        let containers = URL(filePath: NSHomeDirectory()).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Shared/AppGroup")
        let fm = FileManager.default
        let found = ((try? fm.contentsOfDirectory(at: containers, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .compactMap { dir -> (URL, String, Date)? in
                let meta = dir.appending(path: ".com.apple.mobile_container_manager.metadata.plist")
                guard let plist = NSDictionary(contentsOf: meta), let id = plist["MCMMetadataIdentifier"] as? String,
                      id.hasPrefix("group.ai.teemoon.app") else { return nil }
                let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (dir, String(id.dropFirst("group.".count)), date ?? .distantPast)
            }
        return found.max { $0.2 < $1.2 }.map { ($0.0, $0.1) }
    }

    private static func png() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48))
        return renderer.pngData { ctx in
            UIColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private var chatRequests: Int { server.requestLines.filter { $0.contains("chat/completions") }.count }

    /// The new chat: the photo in the strip, the text in the composer, the keyboard up, the old chat gone, nothing sent.
    private func assertSharedChat(_ app: XCUIApplication, text: String?, sentBefore: Int) {
        XCTAssertTrue(element(app, "chat.pendingImages").waitForExistence(timeout: 10), "the shared photo is not in the strip")
        if let text {
            let composer = ProductE2E.composer(app)
            let value = (composer.value as? String) ?? composer.label
            XCTAssertEqual(value, text, "the shared text is not in the composer")
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard on the shared chat")
        XCTAssertFalse(app.staticTexts["first-reply-alpha"].exists, "the share did not open a new chat")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(chatRequests, sentBefore, "a share sent something")
        screenshot(app, "shared-chat")
    }

    // MARK: cases

    func testSeededShareOpensANewChat() throws {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "hello")
        XCTAssertTrue(app.staticTexts["first-reply-alpha"].waitForExistence(timeout: 20))
        let sent = chatRequests

        guard let group = Self.appGroup() else {
            return XCTFail("no group.ai.teemoon.app* container: the App Group entitlement did not reach the simulator")
        }
        // As the extension writes it: staged under a dot name, renamed into place.
        let id = UUID()
        let inbox = group.root.appending(path: "Inbox")
        let staging = inbox.appending(path: "." + id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Self.png().write(to: staging.appending(path: "image-00.png"))
        try Data("fact check".utf8).write(to: staging.appending(path: "text.txt"))
        try FileManager.default.moveItem(at: staging, to: inbox.appending(path: id.uuidString))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        XCUIDevice.shared.system.open(URL(string: "\(group.bundleID)://share/\(id.uuidString)")!)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let openButton = springboard.buttons["Open"]
        if openButton.waitForExistence(timeout: 3) { openButton.tap() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "the share link did not open teemoon")

        assertSharedChat(app, text: "fact check", sentBefore: sent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appending(path: id.uuidString).path),
                       "teemoon did not take the entry")
    }

    /// Writes one entry as the extension does: staged under a dot name, renamed into place.
    private func seedEntry(in group: (root: URL, bundleID: String)) throws -> UUID {
        let id = UUID()
        let inbox = group.root.appending(path: "Inbox")
        let staging = inbox.appending(path: "." + id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Self.png().write(to: staging.appending(path: "image-00.png"))
        try FileManager.default.moveItem(at: staging, to: inbox.appending(path: id.uuidString))
        return id
    }

    /// The composer's top while a share opens teemoon, sampled as fast as XCUI answers.
    private func panelTops(_ app: XCUIApplication, opening url: URL, seconds: TimeInterval) -> [CGFloat] {
        XCUIDevice.shared.system.open(url)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Open"].waitForExistence(timeout: 2) { springboard.buttons["Open"].tap() }
        var tops: [CGFloat] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            guard app.state == .runningForeground else { continue }
            let frame = ProductE2E.composer(app).frame
            if frame.height > 1 { tops.append(frame.minY) }
        }
        return tops
    }

    /// the maintainer 2026-11-14, device clip of a share from Photos: the panel rose to mid-screen with no keyboard, dropped to
    /// the bottom, then rose again with the keyboard. It moves once, up, with the keyboard.
    private func assertOnlyRises(_ tops: [CGFloat], _ what: String) {
        XCTAssertGreaterThan(tops.count, 5, "\(what): too few samples")
        for (before, after) in zip(tops, tops.dropFirst()) where after > before + 3 {
            return XCTFail("\(what): the panel moved down from \(Int(before)) to \(Int(after)) (tops \(tops.map { Int($0) }))")
        }
    }

    func testASharedOpenMovesThePanelOnlyUp_warm() throws {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "hello")
        guard let group = Self.appGroup() else { return XCTFail("no App Group container") }
        let id = try seedEntry(in: group)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        let tops = panelTops(app, opening: URL(string: "\(group.bundleID)://share/\(id.uuidString)")!, seconds: 4)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "no keyboard on the shared chat")
        assertOnlyRises(tops, "warm")
    }

    /// As on the phone: teemoon left with the keyboard up, then a share from another app.
    func testASharedOpenMovesThePanelOnlyUp_keyboardWasUp() throws {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "hello")
        ProductE2E.composer(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        guard let group = Self.appGroup() else { return XCTFail("no App Group container") }
        let id = try seedEntry(in: group)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        let tops = panelTops(app, opening: URL(string: "\(group.bundleID)://share/\(id.uuidString)")!, seconds: 4)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "no keyboard on the shared chat")
        assertOnlyRises(tops, "keyboard was up")
    }

    func testASharedOpenMovesThePanelOnlyUp_cold() throws {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "hello")
        guard let group = Self.appGroup() else { return XCTFail("no App Group container") }
        let id = try seedEntry(in: group)
        app.terminate()
        let tops = panelTops(app, opening: URL(string: "\(group.bundleID)://share/\(id.uuidString)")!, seconds: 6)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "no keyboard on the shared chat")
        assertOnlyRises(tops, "cold")
    }

    func testShareSheetFromPhotos() throws {
        let app = ProductE2E.launchLocal(server: server)
        ProductE2E.sendAndWait(app, "hello")
        let sent = chatRequests

        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        for label in ["Continue", "Not Now", "OK"] where photos.buttons[label].waitForExistence(timeout: 2) {
            photos.buttons[label].tap()
        }
        let photo = photos.images.firstMatch.exists ? photos.images.firstMatch : photos.cells.firstMatch
        guard photo.waitForExistence(timeout: 10) else {
            screenshot(photos, "photos-no-photo")
            throw XCTSkip("Photos shows no photo to share on this simulator")
        }
        photo.tap()
        let share = photos.buttons["Share"].firstMatch
        guard share.waitForExistence(timeout: 5) else {
            screenshot(photos, "photos-no-share")
            throw XCTSkip("Photos shows no Share button XCUI can reach")
        }
        share.tap()
        let target = photos.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'teemoon'")).firstMatch
        guard target.waitForExistence(timeout: 8) else {
            screenshot(photos, "share-sheet-no-teemoon")
            return XCTFail("teemoon is not in the share sheet")
        }
        target.tap()
        if !app.wait(for: .runningForeground, timeout: 10) {
            screenshot(photos, "after-pick")
            let line = photos.descendants(matching: .any)["share.line"].firstMatch
            return XCTFail("teemoon did not open; the extension says: \(line.exists ? line.label : "nothing")")
        }
        assertSharedChat(app, text: nil, sentBefore: sent)
    }
}
