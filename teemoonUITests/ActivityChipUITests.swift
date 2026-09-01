//
//  ActivityChipUITests.swift
//  teemoonUITests
//
//  Measures the BLIND WINDOW: how long the app can be working on a reply with
//  nothing on screen saying so.
//
//  The activity chip is meant to cover exactly that. It used to be driven by a
//  3-second stall timer, which has a hole the width of a follow-up round trip
//  plus prefill — but only for a model that writes something BEFORE calling its
//  tool, because that is what empties the leading chip's `pacer.text.isEmpty`
//  condition. DeepSeek V4 Flash does (a 63-character preamble, first text at
//  0.6s); GLM-5.1 does not. Off the wire that window measured 3.0s per tool
//  round on DeepSeek and 0.6s on GLM.
//
//  Off-wire timing could not prove the FIX, because the fix is a UI condition:
//  it needs the real chip, in the real transcript, during a real generation.
//  That is this file.
//
//  REAL DEVICE, and it spends real money — one near.ai generation plus however
//  many Brave searches the model asks for. Uses whatever near.ai and Brave keys
//  are already on the device; skips cleanly if generation never starts.
//
//  Run:
//    xcodebuild test -destination 'platform=iOS,id=<udid>' \
//      -only-testing:teemoonUITests/ActivityChipUITests
//

import XCTest

final class ActivityChipUITests: XCTestCase {

    /// The model the bug was reported on. Its preamble-before-tool-call is the
    /// whole precondition — seeding GLM here would pass without testing anything.
    private static let model = "deepseek-ai/DeepSeek-V4-Flash"

    /// The on-device model that actually ships as the recommended one.
    private static let onDeviceModel = "litert-community/gemma-4-E2B-it-litert-lm"

    /// A question that reliably drives at least one web_search round; the gap
    /// only exists on the turn AFTER a tool round.
    private static let prompt = "what were the biggest AI announcements this week?"

    /// Chip absent while the transcript is also frozen. Under the old stall
    /// timer this reached 3.0s by construction — the timer's own delay.
    private static let tolerableBlindWindow: TimeInterval = 2.0

    override func setUp() { continueAfterFailure = false }

    /// One sample of "what could the user see".
    private struct Sample {
        let at: TimeInterval
        let chipVisible: Bool
        /// Signature of the tail of the transcript — changes as text streams.
        let textSignature: String
    }

    /// near.ai, the model the bug was reported on.
    func testTheChipCoversTheGapAfterAToolRound() throws {
        try measureBlindWindow(seed: ("UITEST_SEED_NEARAI_MODEL", Self.model))
    }

    /// ON DEVICE, where the same engine runs against a different transport.
    ///
    /// Not redundant with the hosted case — it is the one most likely to break
    /// differently. `LiteRTTransport` streams RAW text (`<think>` tags and all)
    /// so the engine's "first visible character" clear fires on the first
    /// THINKING token, not the first answer token. Whether that leaves a blind
    /// window depends on the on-device prefill, which is seconds, and on the
    /// partial suppression while a tool call is being typed.
    ///
    /// Skips unless the weights are already on the device — it seeds a
    /// provider, it does not fetch gigabytes.
    func testTheChipCoversTheGapOnDeviceToo() throws {
        try measureBlindWindow(seed: ("UITEST_SEED_ONDEVICE_MODEL", Self.onDeviceModel),
                               timeout: 300)
    }

    private func measureBlindWindow(seed: (key: String, value: String),
                                    timeout: TimeInterval = 180) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment[seed.key] = seed.value
        app.launch()

        let composer = app.textFields["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer never appeared")
        if !composer.isHittable { app.swipeUp() }
        composer.tap()
        composer.typeText(Self.prompt)

        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "send button missing")
        send.tap()

        // Generation is running while the STOP button is up. That is the only
        // signal that doesn't depend on developer mode being enabled.
        let stop = app.buttons["chat.stop"]
        guard stop.waitForExistence(timeout: 60) else {
            throw XCTSkip("generation never started — missing key, or on-device weights absent")
        }

        // `.descendants(matching: .any)`, NOT `otherElements`. A combined
        // accessibility element surfaces as a staticText here, so an
        // otherElements query silently never matched and every sample recorded
        // "chip absent" — which made the whole measurement vacuous while the
        // test still passed. Caught by a sample reading `chip=no` with
        // "searching..." in the transcript signature at the same instant.
        let chip = app.descendants(matching: .any)
            .matching(identifier: "chat.activityChip").firstMatch
        let start = Date()
        var samples: [Sample] = []

        while stop.exists, Date().timeIntervalSince(start) < timeout {
            // "Did anything change on screen" is a PIXEL question, so ask it in
            // pixels. Three accessibility proxies were tried first and each one
            // lied in a different way, all while the test stayed green or
            // failed for the wrong reason:
            //
            //   enumerating staticTexts  — raced the stream, died on a stale index
            //   the text element's label — resolved to StructuredText's FIRST
            //                              block, frozen once a 2nd paragraph came
            //   the container's height   — saturates when content exceeds the
            //                              viewport (clipped frame), froze at 87pt
            //
            // A screenshot cannot freeze while the screen is moving. It costs
            // ~100-200ms, which sets the sampling cadence; the windows being
            // measured are seconds, so that is affordable.
            let visible = chip.exists
            let shot = app.screenshot().pngRepresentation
            samples.append(Sample(at: Date().timeIntervalSince(start),
                                  chipVisible: visible,
                                  textSignature: "\(shot.count):\(shot.hashValue)"))
        }

        try XCTSkipIf(samples.count < 5, "too few samples to judge (generation too fast?)")

        // Longest run of consecutive samples where the chip was absent AND the
        // transcript did not change. Measured between real timestamps rather
        // than assumed from a sampling cadence — a tree query on device is not
        // free and its cost varies.
        var worst: TimeInterval = 0
        var worstRange: (TimeInterval, TimeInterval) = (0, 0)
        var runStart: TimeInterval?
        for (prev, cur) in zip(samples, samples.dropFirst()) {
            let frozen = !cur.chipVisible && cur.textSignature == prev.textSignature
            if frozen {
                if runStart == nil { runStart = prev.at }
                let span = cur.at - runStart!
                if span > worst { worst = span; worstRange = (runStart!, cur.at) }
            } else {
                runStart = nil
            }
        }

        let timeline = samples.map {
            String(format: "%6.2fs chip=%@ %@", $0.at, $0.chipVisible ? "YES" : " no ",
                   String($0.textSignature.suffix(48)))
        }.joined(separator: "\n")
        let attachment = XCTAttachment(string: """
            seed: \(seed.key)=\(seed.value)
            samples: \(samples.count) over \(String(format: "%.1f", samples.last?.at ?? 0))s
            worst blind window: \(String(format: "%.2f", worst))s \
            at \(String(format: "%.2f", worstRange.0))–\(String(format: "%.2f", worstRange.1))s

            \(timeline)
            """)
        attachment.name = "chip-timeline"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertLessThan(
            worst, Self.tolerableBlindWindow,
            "the app was working with nothing on screen for \(String(format: "%.2f", worst))s "
            + "(\(String(format: "%.2f", worstRange.0))–\(String(format: "%.2f", worstRange.1))s) "
            + "— see the chip-timeline attachment"
        )
    }
}
