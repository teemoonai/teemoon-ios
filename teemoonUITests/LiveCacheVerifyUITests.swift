//
//  LiveCacheVerifyUITests.swift
//  teemoonUITests
//
//  The cache gate, driven through the app: one Fireworks GLM 5.3 Flash chat, three
//  sends, and the "cache N%" the developer card prints for each. Sends 2 and 3 must
//  show a figure above 0. Run it through the verify-teemoon skill, which builds a
//  clean export on the teemoon-ci simulator and prints the figures.
//
//  Simulator only: `--uitesting` replaces the provider setup and keychain slot, so
//  it must never run on a phone that holds real keys. Spends three short completions.
//

import XCTest

final class LiveCacheVerifyUITests: XCTestCase {

    private static let model = "accounts/fireworks/models/glm-5p3-flash"
    private static let prompts = [
        "verify-teemoon one: name a fruit in one word.",
        "verify-teemoon two: name a colour in one word.",
        "verify-teemoon three: name an animal in one word.",
    ]

    override func setUp() { continueAfterFailure = false }

    func testCacheOnSendsTwoAndThree() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("simulator only: --uitesting rewrites the device's provider setup")
        #else
        try ProductE2E.requireHostKey(forPreset: "fireworks")
        let app = ProductE2E.launchPreset("fireworks", model: Self.model, developerMode: true)
        XCTAssertTrue(ProductE2E.composer(app).waitForExistence(timeout: 20), "composer missing")
        try ProductE2E.skipIfUnauthorized(app)

        var figures: [String] = []
        for (index, prompt) in Self.prompts.enumerated() {
            ProductE2E.sendAndWait(app, prompt, timeout: 120)
            XCTAssertTrue(ProductE2E.waitForDebugCardOnScreen(app), "no developer card after send \(index + 1)")
            ProductE2E.attachScreenshot(app, name: "verify-send-\(index + 1)", to: self)
            let copied = try Self.copiedCardText(app)
            let card = XCTAttachment(string: copied)
            card.name = "verify-card-\(index + 1)"
            card.lifetime = .keepAlways
            add(card)
            let figure = Self.cacheFigure(in: copied) ?? "none"
            figures.append(figure)
            print("[verify-teemoon] send \(index + 1): cache \(figure) | \(copied.split(separator: "\n").prefix(3).joined(separator: " / "))")
        }
        print("[verify-teemoon] RESULT model=\(Self.model) send1=\(figures[0]) send2=\(figures[1]) send3=\(figures[2])")
        for send in [1, 2] {
            let percent = Int(figures[send].dropLast()) ?? 0
            XCTAssertGreaterThan(percent, 0, "send \(send + 1) cached \(figures[send])")
        }
        #endif
    }

    /// The card's own "copy debug info", pasted into the composer and read back there, then cleared.
    /// XCUI sees the card as one element, so its rows can't be read directly, and the runner
    /// reading UIPasteboard raises the paste prompt.
    private static func copiedCardText(_ app: XCUIApplication) throws -> String {
        ProductE2E.debugCard(app).press(forDuration: 1.0)
        let copy = app.buttons["copy debug info"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the card offered no copy debug info")
        copy.tap()
        let composer = ProductE2E.composer(app)
        composer.tap()
        composer.press(forDuration: 1.2)
        let paste = app.menuItems.matching(NSPredicate(format: "label ==[c] %@", "paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the composer offered no paste")
        paste.tap()
        let text = composer.value as? String ?? ""
        // The caret sits after the paste: delete exactly that much. The UIKit composer's long-press menu over pasted
        // text has no Select All.
        // A long burst of deletes can drop keys, so delete what is left until the field is empty.
        var left = text
        var passes: [Int] = []
        for _ in 0..<6 where !(left.isEmpty || left == composer.placeholderValue) {
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: left.count))
            left = composer.value as? String ?? ""
            passes.append(left.count)
        }
        XCTAssertTrue(left.isEmpty || left == composer.placeholderValue,
                      "the composer kept the pasted card (\(text.count) chars, left after each pass \(passes)): \(left.prefix(40))")
        return text
    }

    /// "cache 92%" → "92%".
    static func cacheFigure(in line: String) -> String? {
        guard let range = line.range(of: #"cache \d+%"#, options: .regularExpression) else { return nil }
        return String(line[range].dropFirst("cache ".count))
    }
}
