//
//  HomeImagesLiveUITests.swift
//  teemoonUITests
//
//  Photos to a real home model: the Mac's Ollama at localhost:11434 with gemma4:e4b (vision), through the app on the
//  simulator. Live, so it runs only when asked: TEEMOON_LIVE_OLLAMA=1 (TEST_RUNNER_TEEMOON_LIVE_OLLAMA=1 through
//  xcodebuild). No pulls; the model must already be there.
//

import UIKit
import UniformTypeIdentifiers
import XCTest

final class HomeImagesLiveUITests: XCTestCase {

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless((env["TEEMOON_LIVE_OLLAMA"] ?? env["TEST_RUNNER_TEEMOON_LIVE_OLLAMA"]) == "1",
                          "live: set TEEMOON_LIVE_OLLAMA=1 with Ollama serving gemma4:e4b on localhost:11434")
        continueAfterFailure = true
    }

    /// A fresh setup that never opened the where sheet (the maintainer 2026-11-12): the app must ask the machine before it
    /// refuses a photo, not only when the where sheet opens.
    private func launch() -> XCUIApplication {
        ProductE2E.launch(environment: ["UITEST_SEED_LOCAL_ENDPOINT": "http://localhost:11434/v1",
                                        "UITEST_SEED_LOCAL_MODEL": "gemma4:e4b"])
    }

    enum Shape { case circle, square, triangle }

    static func photo(_ color: UIColor, _ shape: Shape) -> Data {
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

    private func paste(_ app: XCUIApplication, _ png: Data) {
        UIPasteboard.general.setItems([[UTType.png.identifier: png]])
        let composer = ProductE2E.composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "composer missing")
        composer.tap()
        composer.press(forDuration: 1.2)
        let item = app.descendants(matching: .any)["Paste"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 6), "the edit menu offers no Paste")
        item.tap()
    }

    private func ask(_ app: XCUIApplication, _ text: String) {
        ProductE2E.typeIntoComposer(app, text)
        ProductE2E.send(app)
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 240), "the home model did not finish")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func answered(_ app: XCUIApplication, _ words: [String], _ what: String) {
        for w in words {
            // A cold Ollama load can outlast "settled" (the chip still says thinking), so the words get their own wait.
            XCTAssertTrue(ProductE2E.elementContaining(app, w).waitForExistence(timeout: 180), "\(what): no \"\(w)\" in the answer")
        }
    }

    func testOnePhoto() {
        let app = launch()
        paste(app, Self.photo(.systemRed, .circle))
        ask(app, "What shape is in this picture, and what colour is it? Answer in a few words.")
        shot(app, "home-1-photo")
        answered(app, ["red", "circle"], "one photo")
    }

    func testFourPhotos() {
        let app = launch()
        for (color, shape) in [(UIColor.systemRed, Shape.circle), (.systemBlue, .square),
                               (.systemGreen, .triangle), (.systemYellow, .circle)] {
            paste(app, Self.photo(color, shape))
        }
        ask(app, "Name the colour of the shape in each of these 4 pictures, numbered 1 to 4.")
        shot(app, "home-4-photos")
        answered(app, ["red", "blue", "green", "yellow"], "four photos")
    }

    func testTextThenPhoto() {
        let app = launch()
        ask(app, "Say hello in five words.")
        paste(app, Self.photo(.systemBlue, .triangle))
        ask(app, "What shape is in this picture, and what colour is it? Answer in a few words.")
        shot(app, "home-text-then-photo")
        answered(app, ["blue", "triangle"], "text then a photo")
    }
}
