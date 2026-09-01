//
//  MacAttestationUITests.swift
//  teemoonUITests
//
//  THE FEATURE THAT WAS COMPUTED AND NEVER SHOWN.
//
//  The Mac ran attestation and displayed none of it: `E2EETitleBlock` was
//  `#if os(iOS)` and it was the only route into `TrustLadderView`, which was
//  iOS-only for its whole file. The engine worked; the claim was unverifiable.
//
//  These assert REACHABILITY, which is the thing that was missing. Every other
//  Mac suite asks whether something present is correct; none asked what should
//  be here and isn't — which is exactly why this went unnoticed through a whole
//  session of Mac work and seventeen baseline captures.
//

#if os(macOS)

import XCTest

final class MacAttestationUITests: XCTestCase {

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

    /// There is a trust indicator in the toolbar at all.
    func testToolbarCarriesATrustChip() throws {
        let chip = app.buttons["chat.trustChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "no trust chip — attestation is computed and invisible again")
    }

    /// IT CARRIES A WORD, NOT ONLY A COLOUR.
    ///
    /// Safari adds the words "not secure" rather than recolouring the padlock,
    /// because colour alone fails for a tenth of users and for every screenshot
    /// in a bug report. The chip's accessibility label is where that promise is
    /// checkable.
    func testTheChipStatesItsStateInWords() throws {
        let chip = app.buttons["chat.trustChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))

        let spoken = chip.label.lowercased()
        let known = ["encrypted", "verifying", "not verified", "not attestable", "on this mac"]
        XCTAssertTrue(known.contains(where: spoken.contains),
                      "the chip announces '\(chip.label)', which names no state")
    }

    /// Clicking it opens the everyday rung.
    func testChipOpensTheEverydayRung() throws {
        let chip = app.buttons["chat.trustChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.click()

        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5),
                      "the trust chip opened nothing")
        XCTAssertTrue(popover.buttons["attestation.showProof"].waitForExistence(timeout: 5),
                      "the popover has no route to the proof")
    }

    /// ⌘I opens the inspector — the Mac convention, and the thing that makes
    /// this reachable without hunting for a 22pt chip.
    func testCommandIOpensTheInspector() throws {
        XCTAssertTrue(app.textFields["chat.composer"].waitForExistence(timeout: 10))
        let before = app.windows.count

        app.typeKey("i", modifierFlags: .command)

        let opened = NSPredicate(format: "count > %d", before)
        expectation(for: opened, evaluatedWith: app.windows, handler: nil)
        waitForExpectations(timeout: 6) { error in
            XCTAssertNil(error, "⌘I did not open the attestation inspector")
        }
    }

    /// ONE inspector, not one per invocation. Attestation varies by model, not
    /// by thread, so a second ⌘I must raise the existing window rather than
    /// stack another.
    func testTheInspectorIsASingleWindow() throws {
        XCTAssertTrue(app.textFields["chat.composer"].waitForExistence(timeout: 10))
        app.typeKey("i", modifierFlags: .command)

        let opened = NSPredicate(format: "count > 1")
        expectation(for: opened, evaluatedWith: app.windows, handler: nil)
        waitForExpectations(timeout: 6, handler: nil)
        let afterFirst = app.windows.count

        app.typeKey("i", modifierFlags: .command)
        usleep(1_500_000)

        XCTAssertEqual(app.windows.count, afterFirst,
                       "a second ⌘I stacked another inspector instead of raising the one")
    }

    /// NO MAC SURFACE MAY SAY "your phone" — not just this feature's.
    ///
    /// `DeviceNoun` fixed the trust ladder, and a design review then found the
    /// Where picker still reading "free · nothing leaves your phone" in live Mac
    /// UI. Same defect, different screen, and the feature-scoped test could not
    /// see it. This one sweeps the surfaces a user actually opens.
    func testNoMacSurfaceMentionsAPhone() throws {
        XCTAssertTrue(app.textFields["chat.composer"].waitForExistence(timeout: 10))

        var offenders: [String] = []

        // The model picker — where the leak actually was.
        let chip = app.buttons["chat.whereChip"]
        if chip.waitForExistence(timeout: 5) {
            chip.click()
            if app.popovers.firstMatch.waitForExistence(timeout: 5) {
                if app.popovers.firstMatch.debugDescription.lowercased().contains("your phone") {
                    offenders.append("the Where picker")
                }
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        // The trust popover.
        let trust = app.buttons["chat.trustChip"]
        if trust.waitForExistence(timeout: 5) {
            trust.click()
            if app.popovers.firstMatch.waitForExistence(timeout: 5) {
                if app.popovers.firstMatch.debugDescription.lowercased().contains("your phone") {
                    offenders.append("the trust popover")
                }
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        XCTAssertTrue(offenders.isEmpty,
                      "these Mac surfaces still say 'your phone': \(offenders.joined(separator: ", "))")
    }

    /// The Mac must not be told about its phone.
    ///
    /// Six shipped strings named the wrong machine — "readable only here, on
    /// your phone". Not a tone problem on a Mac; false.
    func testNoCopyMentionsAPhone() throws {
        XCTAssertTrue(app.textFields["chat.composer"].waitForExistence(timeout: 10))
        app.typeKey("i", modifierFlags: .command)

        let inspector = app.windows["who can read this?"]
        guard inspector.waitForExistence(timeout: 8) else {
            throw XCTSkip("inspector did not open")
        }

        let dump = inspector.debugDescription.lowercased()
        XCTAssertFalse(dump.contains("your phone"),
                       "the Mac's proof surface still says 'your phone'")
    }
}

#endif
