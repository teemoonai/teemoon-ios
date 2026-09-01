//
//  WhereSegmentsCaptureUITests.swift
//  teemoonUITests
//
//  The where sheet at each of its four filters, for an interactive block on
//  teemoon.ai — real buttons on the page swapping between these frames, so a
//  visitor can page the tiers the way the app does.
//
//  Defaults to `cloud` on the site. That is deliberate: cloud is the tier that
//  is populated on any machine with a key, whereas `home` is empty unless a
//  local server happens to be reachable — and an empty state is a poor first
//  impression of a feature that works.
//
//  The segmented control carries no accessibility identifiers, so these match
//  on label. They are short words, so the query is scoped to buttons rather
//  than staticTexts to avoid matching row copy.
//

import XCTest

final class WhereSegmentsCaptureUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func save(_ shot: XCUIScreenshot, as name: String) {
        let a = XCTAttachment(screenshot: shot); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testCaptureEachSegment() throws {
        let app = XCUIApplication()
        // NO SEEDING. UITEST_SEED_* calls providerStore.providers.removeAll()
        // before adding its one provider, which would delete the phone, home
        // and cloud tiers this capture exists to show. The device is configured
        // by SimSetupUITests and left that way.
        app.launch()

        // Clear the attestation flake FIRST, before the sheet goes up.
        //
        // The title block sits above this sheet in every frame, and it
        // intermittently reads "not end-to-end encrypted" in orange even though
        // the session is sealed — which would put a contradiction at the top of
        // all four captures. It settles on a retry, so do what a user does:
        // open the trust sheet and hit re-verify.
        //
        // Only meaningful when the active place is a CLOUD one. On-device and
        // self-hosted have no attestation to run and read "on this device" /
        // "on your own machine", which are correct as-is.
        let title = app.descendants(matching: .any)["chat.titleBlock"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 12), "no title block")
        if title.label.range(of: "not end-to-end", options: .caseInsensitive) != nil {
            for _ in 0..<3 where title.label.range(of: "not end-to-end", options: .caseInsensitive) != nil {
                title.tap()
                let reverify = app.buttons["re-verify"].firstMatch
                if reverify.waitForExistence(timeout: 6) {
                    reverify.tap()
                    for _ in 0..<20 where title.label.range(of: "not end-to-end", options: .caseInsensitive) != nil {
                        Thread.sleep(forTimeInterval: 0.75)
                    }
                }
                let close = app.buttons["attestation.close"].firstMatch
                if close.exists { close.tap() }
                Thread.sleep(forTimeInterval: 1.0)
            }
        }

        let chip = app.buttons["chat.whereChip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no where chip")
        chip.tap()
        Thread.sleep(forTimeInterval: 2.0)

        // FULL DETENT. The sheet presents at a medium detent, which leaves the
        // top ~60% of the frame as empty chat — and on the site these frames
        // are the subject, not context, so most of the picture was nothing.
        // Drag the grabber up rather than swiping the list, which scrolls it.
        //
        // Re-applied per segment, not once: the swipeDown used to reset the
        // list's scroll position also drags the sheet back to medium, so a
        // single expansion at the start only survived the first capture.
        func expand() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.47))
               .press(forDuration: 0.15,
                      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)))
            Thread.sleep(forTimeInterval: 1.4)
        }
        expand()

        for seg in ["all", "phone", "home", "cloud"] {
            let button = app.buttons[seg].firstMatch
            if button.waitForExistence(timeout: 5) {
                button.tap()
                // The list cross-fades and rows reflow; capturing immediately
                // catches the previous filter's rows mid-dissolve.
                Thread.sleep(forTimeInterval: 1.6)
            } else {
                XCTFail("no '\(seg)' segment in the picker")
            }
            // Collapse FIRST, then expand. The drag that expands starts at 47%
            // of the screen — the grabber's position at medium detent, but
            // inside the LIST when the sheet is already full, where it scrolls
            // instead. Without a known starting state, `all` came out scrolled
            // with its picker hidden under the header while the others were
            // fine. Collapsing makes the gesture mean one thing.
            for _ in 0..<3 { app.swipeDown(velocity: .slow); Thread.sleep(forTimeInterval: 0.35) }
            Thread.sleep(forTimeInterval: 0.8)
            expand()
            save(XCUIScreen.main.screenshot(), as: "60-where-\(seg)")

            // Scroll positions, so the site can scroll the list inside the
            // phone instead of showing one frozen screenful. Stitched host-side
            // by matching overlap between consecutive frames, which is why the
            // swipes are SHORT — a long one can jump past the overlap and leave
            // nothing to align on.
            for step in 1...3 {
                app.swipeUp(velocity: .slow)
                Thread.sleep(forTimeInterval: 1.1)
                save(XCUIScreen.main.screenshot(), as: "61-where-\(seg)-scroll\(step)")
            }
            // Back to the top for the next filter. This also collapses the
            // sheet, which is why `expand()` runs again after the next tap.
            for _ in 0..<4 { app.swipeDown(velocity: .slow); Thread.sleep(forTimeInterval: 0.4) }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }
}
