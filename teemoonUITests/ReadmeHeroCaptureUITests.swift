//
//  ReadmeHeroCaptureUITests.swift
//  teemoonUITests
//
//  The two README hero shots — a short-titled grounded chat and the proof
//  sheet — against a LIVE near.ai model, seeded from the host key files.
//  Writes PNGs to /tmp/teemoon-readme-captures. Spends one completion.
//
//    xcodebuild test … -destination 'platform=iOS Simulator,name=readme-capture' \
//      -only-testing:teemoonUITests/ReadmeHeroCaptureUITests
//

import XCTest

final class ReadmeHeroCaptureUITests: XCTestCase {

    /// `TEST_RUNNER_README_CAPTURE_MODEL=…` on xcodebuild picks the model.
    private static var model: String {
        ProcessInfo.processInfo.environment["README_CAPTURE_MODEL"] ?? "z-ai/glm-5.3-flash"
    }
    /// Direct-host fleet members worth a hero, probed by `testProbeFleet`.
    private static let candidates = [
        "zai-org/GLM-5.1-FP8", "zai-org/GLM-5-FP8", "deepseek-ai/DeepSeek-V4-Flash",
        "Qwen/Qwen3.8-27B", "Qwen/Qwen3.5-122B-A10B", "openai/gpt-oss-120b",
    ]
    private static let prompt = "best ramen in hakodate?"
    private let outputDir = URL(fileURLWithPath: "/tmp/teemoon-readme-captures")

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? shot.pngRepresentation.write(to: outputDir.appendingPathComponent("\(name).png"))
    }

    /// Attestation only, no completion: which fleet models reach a green
    /// end-to-end encrypted title right now. Prints one line per model and
    /// saves probe-<slug>.png of each everyday sheet.
    func testProbeFleet() throws {
        try ProductE2E.requireHostKey(forPreset: "nearai")
        var report: [String] = []
        for model in Self.candidates {
            let app = ProductE2E.launchNearAI(model: model)
            let title = ProductE2E.titleBlock(app)
            guard title.waitForExistence(timeout: 15) else { report.append("\(model): no title"); continue }
            let green = ProductE2E.waitUntilVerified(app, timeout: 75)
            let label = ProductE2E.titleLabel(app)
            title.tap()
            _ = app.staticTexts["who can read this?"].waitForExistence(timeout: 8)
            Thread.sleep(forTimeInterval: 2.0)
            let slug = model.split(separator: "/").last.map(String.init) ?? model
            save("probe-\(slug)")
            report.append("\(green ? "GREEN" : "no   ") \(model) — \(label)")
            app.terminate()
        }
        let text = report.joined(separator: "\n")
        try? text.write(to: outputDir.appendingPathComponent("probe-report.txt"), atomically: true, encoding: .utf8)
        print("README-PROBE\n\(text)")
    }


    /// Diagnostic: the header's label every 250 ms for 25 s after launch on the
    /// capture model, so a flash between states is seen with its timing.
    func testTitleTimeline() throws {
        try ProductE2E.requireHostKey(forPreset: "nearai")
        let app = ProductE2E.launchNearAI(model: Self.model)
        var lines: [String] = []
        var last = ""
        let start = Date()
        while Date().timeIntervalSince(start) < 25 {
            let label = ProductE2E.titleLabel(app)
            if label != last {
                lines.append(String(format: "%6.2fs  %@", Date().timeIntervalSince(start), label))
                last = label
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let text = lines.joined(separator: "\n")
        try? text.write(to: outputDir.appendingPathComponent("title-timeline.txt"), atomically: true, encoding: .utf8)
        print("TITLE-TIMELINE\n\(text)")
    }

    /// proof.png — "who can read this?" with a sealed, verified hero.
    func testProofSheet() throws {
        try ProductE2E.requireHostKey(forPreset: "nearai")
        let app = ProductE2E.launchNearAI(model: Self.model)
        let title = ProductE2E.titleBlock(app)
        XCTAssertTrue(title.waitForExistence(timeout: 15), "title block missing")
        XCTAssertTrue(ProductE2E.waitUntilVerified(app, timeout: 90),
                      "session never verified: \(ProductE2E.titleLabel(app))")
        title.tap()
        XCTAssertTrue(app.staticTexts["who can read this?"].waitForExistence(timeout: 8),
                      "everyday sheet did not open")
        let sealed = ProductE2E.elementContaining(app, "only it can read")
        XCTAssertTrue(sealed.waitForExistence(timeout: 60), "no sealed hero")
        // Provenance lands last and can turn a green hero orange (GLM-5.1,
        // 2026-09-10: "one image unpublished" four seconds in). Let it settle.
        Thread.sleep(forTimeInterval: 6)
        XCTAssertTrue(sealed.exists, "hero degraded after settling: \(ProductE2E.titleLabel(app))")
        save("proof")
    }

    /// chat.png — one grounded turn with a title that fits the bar.
    func testGroundedChat() throws {
        try ProductE2E.requireHostKey(forPreset: "nearai")
        try ProductE2E.requireGroundingKey()
        let app = ProductE2E.launchNearAIGrounded(model: Self.model)
        XCTAssertTrue(ProductE2E.titleBlock(app).waitForExistence(timeout: 15))
        XCTAssertTrue(ProductE2E.waitUntilVerified(app, timeout: 90),
                      "session never verified: \(ProductE2E.titleLabel(app))")

        let chip = app.descendants(matching: .any)["chat.webSearchChip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "web search chip missing")
        let value = (chip.value as? String ?? "").lowercased()
        if !value.contains("on") || value.contains("off") {
            chip.tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
        save("chat-0-empty")

        ProductE2E.typeIntoComposer(app, Self.prompt)
        ProductE2E.send(app)
        ProductE2E.confirmSendIfAsked(app)
        XCTAssertTrue(ProductE2E.elementContaining(app, Self.prompt).waitForExistence(timeout: 20),
                      "prompt never landed")
        XCTAssertTrue(ProductE2E.waitUntilSettled(app, timeout: 240), "turn did not settle")
        Thread.sleep(forTimeInterval: 1.5)
        save("chat-1-settled")

        // The hero wants the top of the answer, not its tail: scroll up.
        for _ in 0..<6 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            start.press(forDuration: 0.05, thenDragTo: end)
            Thread.sleep(forTimeInterval: 0.4)
        }
        Thread.sleep(forTimeInterval: 1.0)
        save("chat-2-top")
    }
}
