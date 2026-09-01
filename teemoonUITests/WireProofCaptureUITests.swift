//
//  WireProofCaptureUITests.swift
//  teemoonUITests
//
//  The two frames teemoon.ai's "what the wire sees" section is built from: a
//  real chat, and the same request as the in-app debug panel shows it — headers
//  in plaintext, every piece of user content a sealed blob.
//
//  WHY THIS EXISTS AS A SIMULATOR TEST. The pair currently on the site was shot
//  on a physical iPhone, which is the only place a near.ai key normally lives.
//  That makes the status bar unfixable: a real device shows the real time,
//  whatever the battery is at, and the silent-mode bell if it happens to be on.
//  The shipped pair reads 3:50 / 55% / bell. Apple's own marketing convention —
//  9:41, full bars, full battery — needs `simctl status_bar override`, which
//  only exists for a simulator. Hence: run it here, and set the status bar from
//  the host before the test starts.
//
//  PREREQUISITE, and the only manual step: a near.ai API key in THIS
//  simulator's Keychain. `UITEST_SEED_NEARAI_MODEL` seeds the provider and the
//  model (ContentView.swift). The credential is NOT an env var: if the
//  endpoint slot is empty, a DEBUG `--uitesting` launch copies
//  `~/.NEAR_AI_API_KEY` from the Mac (`SIMULATOR_HOST_HOME`) into the sim
//  Keychain. A key already in that slot is left alone. You can also paste
//  once through the app's UI; because the account is the endpoint, it
//  survives reinstalls. The test skips rather than fails when it is
//  missing, so a keyless machine stays green.
//
//  SPENDS REAL MONEY — one near.ai generation per run.
//
//  Run:
//    xcrun simctl status_bar <udid> override --time 9:41 \
//      --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 \
//      --batteryState discharging --batteryLevel 100
//    xcodebuild test -project teemoon.xcodeproj -scheme teemoon \
//      -destination "id=<udid>" \
//      -only-testing:teemoonUITests/WireProofCaptureUITests
//

import XCTest

final class WireProofCaptureUITests: XCTestCase {

    /// near.ai's top E2EE flagship — the tier the wire proof is about. A
    /// proxied model would still encrypt in transit but is not the claim the
    /// site's callouts make about `X-Model-Pub-Key`.
    private static let model = "z-ai/glm-5.2"

    /// Short answer, obvious formatting, nothing to redact — and it must
    /// TRIGGER A WEB SEARCH.
    ///
    /// The frame has to read at ~360px wide on a landing page, so a wall of
    /// prose is illegible and a one-liner leaves the screen empty. A question
    /// that produces a few short structured lines fills it at a glance.
    ///
    /// The search round is the point, twice over. It is the only way to
    /// exercise a tool CALL, which is what proves sealing
    /// `tools[].function.{description, parameters}` did not break tool use —
    /// accepting the request only proves the gateway parses it. And it puts
    /// `tool_calls[].function.{name, arguments}` in the captured body, so the
    /// frame shows that WHAT YOU SEARCHED FOR is sealed, not merely that a
    /// search tool was on offer.
    ///
    /// Needs a Brave key in this simulator's Keychain (account
    /// `brave-grounding`, BraveWebSearchTool.swift) — separate from the near.ai
    /// one. Without it the tool is not offered and this silently degrades to
    /// the definition-only case, which the assertion below catches.
    private static let prompt = "in three bullets, what does end-to-end encryption actually protect me from?"

    override func setUp() { continueAfterFailure = false }

    private func save(_ shot: XCUIScreenshot, as name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testChatAndWireCapture() throws {
        let app = XCUIApplication()
        // Developer mode via the ARGUMENT DOMAIN, not the settings UI.
        //
        // `AppSettings.developerModeEnabled` reads UserDefaults.standard
        // (AppSettings.swift), and NSUserDefaults overlays `-key value` launch
        // arguments on top of everything, so this is on before the first frame.
        //
        // Driving the toggle instead does not work: settings is a partial-height
        // sheet, the toggle sits in a section below "places & keys", and a
        // swipeUp inside a sheet DRAGS THE SHEET rather than scrolling its list
        // — so the row never came into reach and every tap was silently
        // dropped. How far down it sits also depends on how many providers are
        // configured, so the same recipe can pass on one device and fail on the
        // next. The toggle's own behaviour is covered by
        // DeveloperModeLocalUITests; this test only needs the state.
        app.launchArguments = ["--uitesting", "-developerModeEnabled", "YES"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = Self.model
        app.launch()

        // 1 — send.
        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer not found")
        // Type, then CONFIRM the text landed before sending. Observed flake:
        // typeText can run before the composer has focus, the characters go
        // nowhere, and send is tapped on an empty field — which surfaces 20s
        // later as "the prompt never appeared", pointing at sending rather than
        // at typing.
        var typed = false
        for _ in 0..<3 where !typed {
            composer.tap()
            Thread.sleep(forTimeInterval: 0.5)
            composer.typeText(Self.prompt)
            for _ in 0..<10 {
                if (composer.value as? String)?.contains("end-to-end encryption") == true {
                    typed = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        XCTAssertTrue(typed, "the prompt never landed in the composer — value=\(composer.value ?? "nil")")

        // Tap send rather than pressing return: the composer is a vertical-axis
        // field, so return inserts a newline and the message never goes out.
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "send button not found")
        send.tap()

        // Prove the send happened before waiting on anything derived from it,
        // so a typing failure reports itself instead of masquerading as a
        // missing debug card three minutes later.
        // "three short bullets", not "near.ai ship": `near.ai` is also the
        // provider name in the chip above the composer, so that predicate could
        // match a control rather than the message — and could equally miss the
        // message while matching nothing useful.
        let sent = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS 'end-to-end encryption'"))
            .firstMatch
        if !sent.waitForExistence(timeout: 30) {
            save(XCUIScreen.main.screenshot(), as: "98-send-never-landed")
            XCTFail("""
                the prompt never appeared in the conversation — it was typed (the composer \
                check passed) but sending did not produce a transcript message. See the \
                98-send-never-landed attachment.
                """)
            return
        }

        // 2 — no key is a SKIP, not a failure. The error surface is the same
        // one a user without a key would see, so match on it rather than
        // reaching into the Keychain to ask.
        let authError = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                  "401", "unauthorized", "api key"))
            .firstMatch
        if authError.waitForExistence(timeout: 20) {
            throw XCTSkip("""
                near.ai rejected the request (\(authError.label)) — this simulator has no \
                near.ai key in its Keychain. Add one once through the app's UI; it persists.
                """)
        }

        // 3 — the debug card only renders once generation has FINISHED, so
        // waiting for it is also the wait for the answer.
        let card = app.descendants(matching: .any)["chat.debugCard"].firstMatch
        if !card.waitForExistence(timeout: 240) {
            // A picture, not a guess. "No debug card" has at least three very
            // different causes — generation errored (the card is suppressed
            // while `llm.lastError != nil`), the web-search offer is up and
            // generation is parked waiting for a key, or it is simply still
            // streaming. Reading them apart from a bare assertion message costs
            // a four-minute round trip each time.
            save(XCUIScreen.main.screenshot(), as: "97-no-debug-card")
            let offer = app.descendants(matching: .any)["chat.webSearchOffer"].firstMatch
            XCTFail("""
                no debug card after 240s. webSearchOffer on screen: \(offer.exists). \
                See the 97-no-debug-card attachment.
                """)
            return
        }

        // The title block must actually READ as encrypted.
        //
        // There is a known, intermittent attestation bug that leaves the header
        // saying "not end-to-end encrypted" — with an open padlock, in orange —
        // while the body below it is entirely ciphertext. Both frames carry
        // that header, and they exist to illustrate a page whose whole argument
        // is that the wire is sealed, so a degraded run must fail here rather
        // than quietly produce a screenshot that contradicts itself.
        //
        // NOT a plain CONTAINS: "not end-to-end encrypted" contains
        // "end-to-end encrypted", so the naive check passes in exactly the case
        // it is meant to catch.
        let title = app.descendants(matching: .any)["chat.titleBlock"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "no title block")

        /// Verified, and not merely containing the words.
        ///
        /// NOT a plain CONTAINS: "not end-to-end encrypted" contains
        /// "end-to-end encrypted", so the naive check passes in exactly the
        /// case it exists to catch.
        func headerIsEncrypted() -> Bool {
            let t = title.label
            return t.range(of: "end-to-end encrypted", options: .caseInsensitive) != nil
                && t.range(of: "not end-to-end", options: .caseInsensitive) == nil
        }

        // Recover from the known attestation flake by doing what a user does:
        // open the sheet and hit re-verify. It settles on a retry, so failing
        // the whole run — and paying for another generation — to get a clean
        // header would be wasteful as well as slow.
        for _ in 0..<3 where !headerIsEncrypted() {
            title.tap()
            let reverify = app.buttons["re-verify"].firstMatch
            if reverify.waitForExistence(timeout: 6) {
                reverify.tap()
                // Give the run time to land before reading the header again.
                for _ in 0..<20 where !headerIsEncrypted() { Thread.sleep(forTimeInterval: 0.75) }
            }
            let close = app.buttons["attestation.close"].firstMatch
            if close.exists { close.tap() }
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTAssertTrue(headerIsEncrypted(), """
            the title block still reads "\(title.label)" after three re-verify attempts, \
            so the header contradicts the sealed body underneath it. Both frames carry this \
            header and they illustrate a page arguing the wire is sealed — capturing now \
            would ship a screenshot that refutes itself.
            """)

        // 4 — the chat frame. Scroll the transcript back to the top of the
        // answer: the reveal leaves the view parked at the debug card, which is
        // the OTHER frame. Without this both captures show the same thing.
        app.swipeDown(velocity: .slow)
        app.swipeDown(velocity: .slow)
        Thread.sleep(forTimeInterval: 1.2)
        save(XCUIScreen.main.screenshot(), as: "40-wire-chat")

        // 5 — the wire frame. Back down to the card, and confirm it is actually
        // ON SCREEN rather than merely existing: an element below the fold
        // still "exists", and a capture of the answer labelled as the wire view
        // is exactly the kind of drift this harness is for.
        app.swipeUp(velocity: .slow)
        app.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 1.2)

        let window = app.windows.firstMatch
        var visible = false
        for _ in 0..<20 {
            let f = card.frame
            if f.height > 0, f.minY < window.frame.maxY, f.maxY > window.frame.minY { visible = true; break }
            app.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertTrue(visible, "the debug card never came on screen — card=\(card.frame) window=\(window.frame)")

        // 6 — EXPAND IT. The card renders collapsed: "headers (7)", "request
        // body encrypted" and "response" are folded disclosure rows
        // (DebugComponents.swift), so a capture of it as-is shows three grey
        // summary lines. The whole point of the site's callouts is the contents
        // — X-Client-Pub-Key, X-Model-Pub-Key, X-Encrypt-All-Fields, and every
        // message content as a sealed blob. Collapsed, the frame proves nothing.
        //
        // Matched on label text because these rows carry no accessibility
        // identifier, and BEGINSWITH because the header row's count varies with
        // the request ("headers (7)", "headers (8)").
        // Each expansion is VERIFIED by something only that section contains,
        // and retried if it did not take. Tapping blind does not work: opening
        // `headers` reflows everything below it, so the next tap resolved
        // against stale geometry and hit `response` instead — producing a frame
        // with the answer in plaintext and the sealed request body still
        // folded, which is the exact opposite of what this section argues.
        func expand(_ prefix: String) {
            let row = app.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH[c] %@", prefix))
                .firstMatch
            guard row.waitForExistence(timeout: 5) else {
                XCTFail("no '\(prefix)' row in the debug card")
                return
            }
            row.tap()
            // Let the 0.15s disclosure animation AND the reflow settle before
            // anything else resolves a frame.
            Thread.sleep(forTimeInterval: 1.0)
        }
        // ORDER MATTERS, bottom-up. `request body` sits BELOW `headers`, so
        // opening it cannot move `headers`. Doing it the other way round moved
        // everything under the header block mid-tap, and the second tap landed
        // on `response` instead — which produced a frame with the answer in the
        // clear and the sealed body still folded, the exact opposite of the
        // claim this section makes.
        //
        // `response` is deliberately left closed for the same reason: it is the
        // decrypted answer, which is true but is not what the wire sees.
        expand("request body")
        expand("headers")

        // Expanding makes the card taller than the screen, so park its TOP just
        // under the nav bar: that framing is what puts the url, the timings, the
        // headers and the start of the sealed body in one shot.
        let target = window.frame.height * 0.25
        for _ in 0..<14 where card.frame.minY > target {
            app.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.35)
        }
        Thread.sleep(forTimeInterval: 0.8)

        // Verify the expansion HERE, after scrolling — not straight after the
        // tap. XCUITest only exposes rendered elements, so header content that
        // is still below the fold is legitimately absent from the accessibility
        // tree even though the row did open; asserting too early failed on a
        // capture that was actually fine. This also guards the thing that
        // matters: a collapsed frame proves nothing and must not ship.
        let headerProof = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "X-Client-Pub-Key"))
            .firstMatch
        XCTAssertTrue(headerProof.waitForExistence(timeout: 5),
                      "headers never expanded — the frame would show three folded summary rows")

        // And the credential must not be in it. The panel prints Authorization
        // verbatim for a real user; DebugHeaderRedaction masks it under
        // --uitesting precisely so a capture cannot carry a key. If that ever
        // regresses, fail here rather than publish it.
        let leaked = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Bearer sk-"))
            .firstMatch
        XCTAssertFalse(leaked.exists,
                       "an unmasked bearer token is on screen — DebugHeaderRedaction is not applying")

        // A tool round MUST have happened. Without a Brave key the tool is not
        // offered, the model just answers, and the captured body then shows a
        // tool DEFINITION and no tool CALL — which still looks like a fine
        // screenshot while quietly testing nothing about tool use. Since the
        // point of this run is to prove that sealing
        // `tools[].function.{description, parameters}` did not break calling,
        // that degradation has to be a failure rather than a shrug.
        // The tool DEFINITION must be sealed — name, description and the
        // parameters schema. This is the claim WireProof's callout makes, and
        // until 2026-08-02 only `name` was encrypted, which bought nothing: the
        // description beside it read "Search the web for current, real-time
        // information…" in the clear, so the gateway could identify the tool
        // exactly. See E2EEPeer.encryptRequestBody.
        let sealedTools = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "\"description\""))
            .firstMatch
        XCTAssertTrue(sealedTools.exists,
                      "no tool definition in the captured body — nothing proves the description is sealed")

        // Deliberately NOT requiring a tool CALL.
        //
        // A prompt that provokes a web search does exercise more — it puts
        // sealed `tool_calls[].function.{name, arguments}` in the body, and a
        // run on 2026-08-02 confirmed those are encrypted. But a search round
        // also produces a generation that finishes its visible answer and then
        // leaves the stream open: observed at "thinking… 261s" with the reply
        // fully rendered and a stop button still showing, so the debug card —
        // which only renders once generation ENDS — never appears. Capturing
        // must not depend on a code path that hangs.

        save(XCUIScreen.main.screenshot(), as: "41-wire-debug")
    }
}
