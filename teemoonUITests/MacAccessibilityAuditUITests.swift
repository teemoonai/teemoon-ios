//
//  MacAccessibilityAuditUITests.swift
//  teemoonUITests
//
//  WHAT VOICEOVER WOULD SAY, CHECKED MECHANICALLY.
//
//  `accessibilityLabel` appears in a dozen view files, added wherever somebody
//  happened to need it, and VoiceOver has never actually been driven over this
//  app. That is not a state anyone can eyeball: an unlabelled button looks
//  perfect and announces as "button".
//
//  So this walks the real accessibility tree — the same one VoiceOver reads —
//  and fails on controls it would announce with nothing useful. It is the same
//  discipline as the rest of the Mac suites: assert the EFFECT (what a screen
//  reader receives), not the presence of a modifier in source.
//
//      xcodebuild test -destination 'platform=macOS,arch=arm64' \
//        -only-testing:teemoonUITests/MacAccessibilityAuditUITests
//

#if os(macOS)

import XCTest

final class MacAccessibilityAuditUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_THREADS"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "no window")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    /// How a control would be announced: label, then title, then value, then
    /// placeholder.
    ///
    /// PLACEHOLDER IS IN THE LIST BECAUSE VOICEOVER READS IT. A first version of
    /// this helper left it out and duly reported that the composer "announces as
    /// nothing" — which was the test being wrong, not the app. An empty
    /// `TextField("message", …)` announces as "message" on macOS. Worth stating
    /// because the correction went the other way from the one this file exists
    /// to make: not every finding an audit produces is a defect.
    ///
    /// An identifier is NOT in the list — `chat.send` is a test handle, not
    /// something a person should hear.
    private func spokenName(_ element: XCUIElement) -> String {
        let candidates = [
            element.label,
            element.title,
            element.value as? String ?? "",
            element.placeholderValue ?? "",
        ]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// A name that is present but useless to hear — a raw identifier, an SF
    /// Symbol name, or a bare glyph.
    private func isUnhelpful(_ name: String) -> Bool {
        if name.contains(".") && !name.contains(" ") { return true }   // chat.send, moonphase.waning.gibbous
        if name.count <= 1 { return true }                             // a lone glyph
        return false
    }

    /// Every button in the main window must announce as something a person can
    /// act on.
    func testEveryButtonHasAnAnnouncableName() throws {
        XCTAssertTrue(app.textFields["chat.composer"].waitForExistence(timeout: 10))

        var offenders: [String] = []
        let buttons = app.windows.firstMatch.buttons
        for index in 0..<buttons.count {
            let button = buttons.element(boundBy: index)
            guard button.exists, button.isHittable else { continue }
            // Window furniture is AppKit's, announced by the system.
            let identifier = button.identifier
            if identifier.hasPrefix("_XCUI:") { continue }

            let name = spokenName(button)
            if name.isEmpty {
                offenders.append("unlabelled button at \(button.frame.origin) [id: \(identifier.isEmpty ? "none" : identifier)]")
            } else if isUnhelpful(name) {
                offenders.append("button announces as '\(name)', which is an identifier or glyph, not a phrase")
            }
        }

        let report = XCTAttachment(string: offenders.isEmpty ? "clean" : offenders.joined(separator: "\n"))
        report.name = "unlabelled buttons"
        report.lifetime = .keepAlways
        add(report)

        XCTAssertTrue(offenders.isEmpty,
                      "VoiceOver would announce these as nothing useful:\n" + offenders.joined(separator: "\n"))
    }

    /// Images that carry meaning need a label; images that are decoration should
    /// not be in the tree at all. Either way, an image announcing its SF Symbol
    /// name is wrong — "moonphase.waning.gibbous" is not a sentence.
    func testNoImageAnnouncesItsSymbolName() throws {
        XCTAssertTrue(app.textFields["chat.composer"].waitForExistence(timeout: 10))

        var offenders: [String] = []
        let images = app.windows.firstMatch.images
        for index in 0..<images.count {
            let image = images.element(boundBy: index)
            guard image.exists else { continue }
            let name = spokenName(image)
            if !name.isEmpty && isUnhelpful(name) {
                offenders.append("image announces as '\(name)'")
            }
        }

        let report = XCTAttachment(string: offenders.isEmpty ? "clean" : offenders.joined(separator: "\n"))
        report.name = "images announcing symbol names"
        report.lifetime = .keepAlways
        add(report)

        XCTAssertTrue(offenders.isEmpty, offenders.joined(separator: "\n"))
    }

    /// The composer is the app's primary control. It must announce as something,
    /// and its placeholder alone is thin but acceptable.
    func testComposerIsAnnouncable() throws {
        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertFalse(spokenName(composer).isEmpty,
                       "the message field announces as nothing")
    }
}

#endif
