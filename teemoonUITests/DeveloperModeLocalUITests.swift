//
//  DeveloperModeLocalUITests.swift
//  teemoonUITests
//
//  Developer mode against a LOCAL model: does the debug card render for a
//  keyless self-hosted provider, and does it actually end up ON SCREEN?
//
//  The second question is the interesting one. When generation ends the
//  collection view applies the persisted row first, then inserts the card as
//  its own animated tail. A corrective scroll follows via
//  `scrollToBottomToken`. Whether it lands on screen is a timing question,
//  not a reasoning one, so it is measured here.
//
//  REQUIRES a local engine. Run through the local smoke driver, which brings one
//  up; on its own this skips rather than failing, so a serverless run stays green.
//

import XCTest

final class DeveloperModeLocalUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// Finds whichever engine is up and what it serves, by probing.
    ///
    /// Deliberately NOT read from `LOCAL_SMOKE_ENGINE`: a UI test runs in its own
    /// runner process, which does not receive `TEST_RUNNER_`-prefixed variables
    /// the way the app-hosted unit tests do. Depending on that env silently
    /// skipped this test while reporting success — so it discovers instead, and
    /// the only way to get a false green is for no engine to be running at all.
    private func discoverEngine() -> (endpoint: String, model: String)? {
        for endpoint in ["http://127.0.0.1:11434/v1",   // ollama
                         "http://127.0.0.1:8080/v1",    // llama.cpp
                         "http://127.0.0.1:1234/v1"] {  // lm studio
            guard let url = URL(string: endpoint + "/models") else { continue }
            var req = URLRequest(url: url); req.timeoutInterval = 3
            let sem = DispatchSemaphore(value: 0)
            var model: String?
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                defer { sem.signal() }
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let data else { return }
                // Ollama answers `{"models":[…]}` here, the OpenAI shape is
                // `{"data":[…]}`; both carry a usable id under a different key.
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                let list = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]])
                model = list?.first.flatMap { ($0["id"] as? String) ?? ($0["model"] as? String) ?? ($0["name"] as? String) }
            }.resume()
            _ = sem.wait(timeout: .now() + 5)
            if let model, !model.isEmpty { return (endpoint, model) }
        }
        return nil
    }

    func testDebugCardRendersAndScrollsIntoViewForALocalModel() throws {
        guard let engine = discoverEngine() else {
            throw XCTSkip("no local engine listening on 11434/8080/1234 — start Ollama, llama.cpp, or LM Studio first")
        }
        print("[devmode] engine=\(engine.endpoint) model=\(engine.model)")

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = engine.endpoint
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = engine.model
        app.launch()

        // 1 — turn developer mode on through the UI a user would use.
        app.buttons["chat.settings"].tap()
        let toggle = app.switches["settings.developerMode"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "developer mode toggle not found in settings")
        // A Form row can exist while being off-screen, and a tap on a
        // non-hittable element is silently dropped — which reads as "the toggle
        // didn't work". Bring it into view first, then poll: the switch's value
        // lags the tap by an animation frame.
        if !toggle.isHittable { app.swipeUp() }
        // Tap the TRAILING edge, not the centre. The accessibility element spans
        // the whole Form row (measured 355pt wide), so a centre tap lands on the
        // label and is swallowed — the switch itself sits at the far right. Three
        // centre taps changed nothing and read as "the toggle is broken".
        for _ in 0..<3 where (toggle.value as? String) != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            for _ in 0..<10 where (toggle.value as? String) != "1" { Thread.sleep(forTimeInterval: 0.2) }
        }
        XCTAssertEqual(toggle.value as? String, "1",
                       "developer mode did not turn on (hittable=\(toggle.isHittable), frame=\(toggle.frame))")
        // Dismiss settings via its own close button — a swipe-down is
        // unreliable on a sheet and leaves it up, after which every subsequent
        // "type into the composer" step goes nowhere and the failure surfaces
        // 180 s later as "no debug card".
        let close = app.buttons["settings.close"]
        if close.waitForExistence(timeout: 5) { close.tap() } else { app.swipeDown(velocity: .fast) }
        if app.switches["settings.developerMode"].exists { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(app.descendants(matching: .any)["chat.titleBlock"].waitForExistence(timeout: 10),
                      "settings never dismissed — the chat is not on screen")

        // 2 — send something short. The point is the debug card, not the answer.
        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer not found")
        composer.tap()
        composer.typeText("say hi")
        // Tap send rather than pressing return: the composer is a vertical-axis
        // TextField, so return inserts a newline instead of submitting, and the
        // message silently never goes out.
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "send button not found")
        send.tap()

        // Confirm the send actually happened before waiting on anything derived
        // from it, so a typing failure reports itself instead of masquerading as
        // a rendering bug three minutes later.
        let sent = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'say hi'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 20),
                      "the prompt never appeared in the conversation — it was not sent")

        // 3 — the card appears once generation finishes. Local models are slow;
        // this window is generous on purpose.
        let card = app.descendants(matching: .any)["chat.debugCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 180),
                      "developer mode is on and generation finished, but no debug card rendered")

        // 4 — ON SCREEN, not merely existing. An element below the fold still
        // "exists"; the question was whether the reveal scrolls it into view.
        let window = app.windows.firstMatch
        var visible = false
        for _ in 0..<20 {                       // ~4 s for the corrective scroll to settle
            let f = card.frame
            if f.height > 0, f.minY < window.frame.maxY, f.maxY > window.frame.minY {
                visible = true; break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(visible, """
            the debug card rendered but never scrolled into view — \
            card.frame=\(card.frame) window=\(window.frame). \
            The reveal flips showDebugInfo and scrolls in the same turn, while the \
            card's insertion transition is delayed 0.15s; the corrective \
            scrollToBottomToken scroll is what has to land after layout.
            """)

        // 5 — it is the LOCAL request being described: no Authorization header,
        // and the endpoint we seeded.
        let text = card.label + " " + (card.value as? String ?? "")
        if !text.isEmpty {
            XCTAssertFalse(text.contains("Authorization"),
                           "a keyless local provider must not show an Authorization header")
        }
    }
}
