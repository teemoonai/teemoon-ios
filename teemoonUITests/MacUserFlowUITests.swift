//
//  MacUserFlowUITests.swift
//  teemoonUITests
//
//  DRIVING THE APP, NOT INSPECTING ITS CHROME.
//
//  MacChromeUITests asserts that the Mac furniture exists — menus, a window, the
//  appearance. None of it types a character. This file uses the app the way a
//  person does: put the caret in the composer, type, and use the commands that
//  are supposed to act on what was typed.
//
//      xcodebuild test -destination 'platform=macOS,arch=arm64' \
//        -only-testing:teemoonUITests/MacUserFlowUITests
//
//  Takes over the screen for the same reason MacChromeUITests does.
//

#if os(macOS)

import XCTest

final class MacUserFlowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        // Fixture conversations in an in-memory store, so destructive tests
        // delete threads that never existed outside this process.
        app.launchEnvironment["UITEST_SEED_THREADS"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15),
                      "no window to drive")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private var composer: XCUIElement {
        app.textFields["chat.composer"]
    }

    /// macOS PERSISTS SPLIT-VIEW STATE ACROSS LAUNCHES, so a test that needs the
    /// sidebar cannot assume it is open — whichever test last collapsed it
    /// decides what the next launch looks like. That persistence is correct
    /// behaviour, so tests adapt to it rather than the app giving it up.
    private func ensureSidebarVisible() {
        guard !app.searchFields.firstMatch.exists else { return }
        let viewMenu = app.menuBars.menuBarItems["View"]
        guard viewMenu.exists else { return }
        viewMenu.click()
        let toggle = app.menuBars.menuItems["hide sidebar"]
        if toggle.waitForExistence(timeout: 5) {
            toggle.click()
        } else {
            viewMenu.typeKey(.escape, modifierFlags: [])
        }
        _ = app.searchFields.firstMatch.waitForExistence(timeout: 5)
    }

    /// The most basic thing a person does: click the composer and type.
    func testTypingIntoTheComposerKeepsWhatWasTyped() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")
        composer.click()
        composer.typeText("hello from a mac")

        XCTAssertEqual(composer.value as? String, "hello from a mac",
                       "the composer did not keep what was typed")
    }

    /// ⌘N is advertised in the File menu; this checks it does its job.
    ///
    /// The command posts `.teemoonNewChat`, which clears the current thread and
    /// refocuses the composer — so from a half-written message, ⌘N should leave
    /// the user able to type immediately into an empty composer.
    func testCommandNStartsAFreshComposer() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")
        composer.click()
        composer.typeText("half-written thought")
        XCTAssertEqual(composer.value as? String, "half-written thought")

        app.typeKey("n", modifierFlags: .command)

        // Focus is the point of the command: type without clicking first.
        app.typeText("after new chat")
        XCTAssertEqual(composer.value as? String, "after new chat",
                       "after ⌘N the composer is not empty-and-focused — the user must click before typing")
    }

    /// The sidebar's "+" is documented as having the same effect as ⌘N, so it
    /// has to clear the draft too — it did not, for the same reason.
    func testSidebarNewChatAlsoClearsTheComposer() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")
        composer.click()
        composer.typeText("draft that should not survive")

        let plus = app.buttons["new"]
        guard plus.waitForExistence(timeout: 5) else {
            throw XCTSkip("sidebar 'new' button not reachable in this layout")
        }
        plus.click()

        XCTAssertEqual(composer.value as? String, "",
                       "the sidebar's + started a new chat with the old draft still in the composer")
    }

    // MARK: - Standard Mac text behaviour
    //
    // None of this is teemoon-specific. It is what every Apple app does in a
    // text field, and it is the layer people notice only when it is missing.

    /// ⌘A then delete clears the composer.
    func testSelectAllThenDeleteClearsTheComposer() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")
        composer.click()
        composer.typeText("select all of this")

        app.typeKey("a", modifierFlags: .command)
        composer.typeKey(.delete, modifierFlags: [])

        XCTAssertEqual(composer.value as? String, "",
                       "⌘A then delete did not clear the composer")
    }

    /// ⌘Z undoes typing. Free in AppKit, and absent often enough in SwiftUI
    /// text fields to be worth pinning.
    func testUndoRestoresTypedText() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")
        composer.click()
        composer.typeText("keep this")
        composer.typeText(" and this")

        app.typeKey("z", modifierFlags: .command)

        let value = composer.value as? String ?? ""
        XCTAssertNotEqual(value, "keep this and this",
                          "⌘Z did nothing — the composer has no undo")
    }

    /// Escape must not throw away what the user typed. In a chat app the
    /// composer often holds the only copy of a long message.
    func testEscapeDoesNotDiscardTheDraft() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")
        composer.click()
        composer.typeText("expensive to retype")

        composer.typeKey(.escape, modifierFlags: [])

        XCTAssertEqual(composer.value as? String, "expensive to retype",
                       "escape discarded the draft")
    }

    /// View ▸ hide sidebar exists AND moves the sidebar.
    ///
    /// View used to contain only "Enter Full Screen", which AppKit supplies for
    /// free — the app had contributed nothing to it, while every Mac app with a
    /// sidebar offers this on ⌃⌘S. Asserting the effect and not just the item,
    /// because a menu item that exists and does nothing is the failure mode this
    /// suite already met once.
    ///
    /// ASSERTS THE FLIP, NOT AN ASSUMED STARTING STATE.
    ///
    /// A first version required the sidebar to be open at launch and then
    /// checked it closed. It passed once and then failed on the next run with
    /// "no sidebar search field to begin with" — because macOS persists split
    /// view state, so the run that collapsed the sidebar left it collapsed for
    /// the next launch. That persistence is correct behaviour (Apple apps
    /// restore it too); the test was wrong to assume a direction.
    func testViewMenuTogglesTheSidebar() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "app not up yet")

        // MEASURED GEOMETRICALLY, because element existence lied. Checking
        // `app.searchFields.firstMatch.exists` alternated pass/fail run to run:
        // a collapsed sidebar's search field can still be present in the
        // accessibility tree, just not on screen. Where the composer STARTS is
        // the consequence a person actually sees — the content pane slides left
        // by the sidebar's width — and it cannot be true while invisible.
        let before = composer.frame.minX

        let viewMenu = app.menuBars.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5), "no View menu")
        viewMenu.click()

        let toggle = app.menuBars.menuItems["hide sidebar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "View has no sidebar command — it contains only AppKit's free Enter Full Screen")
        toggle.click()

        // Let the split view settle; the collapse is animated.
        let moved = expectation(description: "content pane moved")
        var after = before
        for _ in 0..<20 {
            after = composer.frame.minX
            if abs(after - before) > 100 { moved.fulfill(); break }
            usleep(250_000)
        }
        wait(for: [moved], timeout: 1)
        XCTAssertNotEqual(after, before, accuracy: 0.5,
                          "the sidebar command did not move the content pane — the sidebar did not toggle")
    }

    /// Instruction copy must not tell a Mac user to tap.
    func testSettingsCopyDoesNotSayTap() throws {
        app.typeKey(",", modifierFlags: .command)

        var settings: XCUIElement?
        for i in 0..<app.windows.count where app.windows.element(boundBy: i).buttons["appearance"].exists {
            settings = app.windows.element(boundBy: i)
        }
        let window = try XCTUnwrap(settings, "no settings window")
        window.buttons["places & keys"].click()

        let dump = window.debugDescription
        XCTAssertFalse(dump.lowercased().contains("tap "),
                       "settings still tells a Mac user to tap something")
    }

    /// A WIDE WINDOW MUST NOT PRODUCE A WIDE LINE OF TEXT.
    ///
    /// The transcript and composer are capped to a readable measure on macOS.
    /// Without it, maximising the window sets line length to the window width —
    /// ~200 characters on a large display, far past the 45-75 that is
    /// comfortable to read. Nothing errors when this regresses; it just becomes
    /// tiring, which is why it needs a test rather than an eye.
    func testTextColumnStaysReadableOnAWideWindow() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")

        let window = app.windows.firstMatch
        let widthBefore = window.frame.width
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        corner.press(forDuration: 0.2,
                     thenDragTo: corner.withOffset(CGVector(dx: 480, dy: 0)))

        let widened = expectation(description: "window widened")
        for _ in 0..<20 {
            if window.frame.width > widthBefore + 200 { widened.fulfill(); break }
            usleep(250_000)
        }
        wait(for: [widened], timeout: 1)

        // The cap is 720pt; padding puts the field a little inside that. The
        // bound is deliberately loose — this guards against "grows with the
        // window", not against a few points of layout drift.
        XCTAssertLessThan(composer.frame.width, 800,
                          "the composer grew with the window — the readable-measure cap is gone")
        XCTAssertGreaterThan(window.frame.width, composer.frame.width + 200,
                             "the window is much wider than the column, so the column should not be tracking it")
    }

    /// Help must not advertise a dead end.
    ///
    /// AppKit adds "<App> Help" whether or not a help book exists. teemoon's
    /// Info.plist has no `CFBundleHelpBookName`, so that item opened Help Viewer
    /// onto "Help isn't available". Asserted by name so the generated item
    /// cannot come back unnoticed. Not clicked — it opens another application,
    /// which is not this suite's business.
    func testHelpMenuPointsSomewhereReal() throws {
        let help = app.menuBars.menuBarItems["Help"]
        XCTAssertTrue(help.waitForExistence(timeout: 10), "no Help menu")
        help.click()

        XCTAssertTrue(app.menuBars.menuItems["teemoon on GitHub"].waitForExistence(timeout: 5),
                      "Help has no real destination")
        XCTAssertFalse(app.menuBars.menuItems["teemoon Help"].exists,
                       "AppKit's generated help item is back, and there is still no help book behind it")
        help.typeKey(.escape, modifierFlags: [])
    }

    /// ⌘F focuses the sidebar search field, as it does in every Mac app with
    /// one. Checks the effect — that typing then lands in search, not the
    /// composer — rather than that a menu item exists.
    func testCommandFFocusesSearch() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")
        ensureSidebarVisible()
        XCTAssertTrue(app.searchFields.firstMatch.exists, "no search field to focus")

        app.typeKey("f", modifierFlags: .command)
        app.typeText("offline")

        let search = app.searchFields.firstMatch
        XCTAssertEqual(search.value as? String, "offline",
                       "⌘F did not put the caret in search — what was typed went elsewhere")
    }

    // MARK: - Destructive actions
    //
    // These run against fixture threads in an in-memory store, so they delete
    // conversations that never existed outside the test process.

    /// ⌫ on a selected chat must ASK, and cancelling must keep the chat.
    ///
    /// Deletion calls `modelContext.delete` — no trash, no undo, no export. A
    /// keyboard shortcut into that without a confirmation is a new way to lose
    /// data, so the two ship together and this pins both halves.
    func testDeleteKeyAsksAndCancelKeepsTheChat() throws {
        let row = app.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH 'does this run offline'")).firstMatch
        guard row.waitForExistence(timeout: 10) else {
            throw XCTSkip("fixture threads did not seed")
        }
        row.click()
        app.typeKey(.delete, modifierFlags: [])

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5),
                      "⌫ deleted a conversation without asking, and it cannot be undone")

        sheet.buttons["cancel"].click()
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "cancelling the confirmation still lost the chat")
    }

    /// ...and confirming actually deletes it.
    func testDeleteKeyConfirmedRemovesTheChat() throws {
        let row = app.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH 'summarise the conf'")).firstMatch
        guard row.waitForExistence(timeout: 10) else {
            throw XCTSkip("fixture threads did not seed")
        }
        row.click()
        app.typeKey(.delete, modifierFlags: [])

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "no confirmation")
        sheet.buttons["delete"].click()

        XCTAssertTrue(row.waitForNonExistence(timeout: 5),
                      "confirming the delete did not remove the chat")
    }

    /// EVERY ROW IN THE WHERE SHEET MUST BE ON SCREEN.
    ///
    /// The sheet shipped at 470x80 because `presentationDetents` is ignored on
    /// macOS. Giving it an explicit 520x560 stopped the collapse — and left the
    /// last row, `add a cloud key`, starting 7pt BELOW the sheet's bottom edge:
    /// zero points visible, reachable only by scrolling a sheet that gives no
    /// sign there is more under it. Fixing the collapse was not fixing the sheet.
    ///
    /// Found by Claude Design reading the capture transcript, not by looking at
    /// the screenshot — the clipped row is invisible in the image by definition.
    func testEveryWhereSheetRowFitsInsideTheSheet() throws {
        let chip = app.buttons["chat.whereChip"]
        guard chip.waitForExistence(timeout: 10) else { throw XCTSkip("no Where chip") }
        chip.click()

        // Sheet or popover — the container changed to a popover on macOS and a
        // selector that knew only about sheets would skip rather than fail.
        var sheet = app.sheets.firstMatch
        if !sheet.waitForExistence(timeout: 3) { sheet = app.popovers.firstMatch }
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the Where picker did not open")

        // Settle: the sheet animates in, and a mid-flight frame proves nothing.
        var lastHeight = sheet.frame.height
        for _ in 0..<20 {
            usleep(150_000)
            let height = sheet.frame.height
            if abs(height - lastHeight) < 0.5 { break }
            lastHeight = height
        }

        let fold = sheet.frame.maxY
        var below: [String] = []
        for descendant in [sheet.staticTexts, sheet.buttons] {
            for index in 0..<descendant.count {
                let element = descendant.element(boundBy: index)
                guard element.exists, element.frame.height > 0 else { continue }
                // maxY, not minY. A first version asked only whether a row
                // STARTED below the fold, which the metrics change fixed while
                // leaving the last row overhanging the bottom edge by 20pt — a
                // row you can see the top of and not read. "Fits" means the
                // whole row is inside.
                if element.frame.maxY > fold {
                    below.append("'\(element.label)' overhangs the bottom edge by \(Int(element.frame.maxY - fold))pt")
                }
            }
        }

        XCTAssertTrue(below.isEmpty,
                      "rows are laid out past the bottom of the sheet:\n" + below.joined(separator: "\n"))
    }

    // MARK: - Window and sheets

    /// The window needs a title: it is what Window menu, Mission Control and
    /// ⌘` show. An untitled window is a tell that a Mac app is a port.
    func testWindowHasATitle() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertFalse(window.title.trimmingCharacters(in: .whitespaces).isEmpty,
                       "the window has no title")
    }

    /// A long first message must not become the window title verbatim.
    ///
    /// The title bar truncates, which hides this — but the same string is the
    /// app's identity in the Window menu, Mission Control, ⌘` and the minimised
    /// Dock tile, none of which forgive a paragraph.
    func testWindowTitleIsShortEvenForALongFirstMessage() throws {
        ensureSidebarVisible()
        let row = app.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH 'when a provider says'")).firstMatch
        guard row.waitForExistence(timeout: 10) else {
            throw XCTSkip("fixture threads did not seed")
        }
        row.click()

        let window = app.windows.firstMatch
        let shortened = expectation(description: "title updated")
        for _ in 0..<20 {
            if window.title.contains("…") { shortened.fulfill(); break }
            usleep(250_000)
        }
        wait(for: [shortened], timeout: 1)

        XCTAssertLessThan(window.title.count, 60,
                          "the window title is the whole first message: \(window.title)")
        XCTAssertFalse(window.title.contains("on faith from the vendor"),
                       "the title ran to the end of the message")
    }

    /// The model chip opens the Where sheet, and escape closes it.
    func testWhereChipOpensAndEscapeCloses() throws {
        let chip = app.buttons["chat.whereChip"]
        guard chip.waitForExistence(timeout: 10) else {
            throw XCTSkip("no Where chip in this state")
        }
        chip.click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5),
                      "the Where chip did not open a sheet")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5),
                      "escape did not close the Where sheet")
    }

    /// The send control must not offer to send nothing.
    func testSendIsNotOfferedForAnEmptyComposer() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")

        let send = app.buttons["chat.send"]
        if send.exists {
            XCTAssertFalse(send.isEnabled,
                           "send is enabled with an empty composer")
        }
    }
}

#endif
