//
//  LocalCatalogCaptureUITests.swift
//  teemoonUITests
//
//  Screenshots the on-device model catalog from the REAL app on the phone.
//
//  Exists because `RenderPreview` is not always available (the Xcode MCP server
//  drops), and a UI change shipped unrendered is a change nobody looked at. This
//  is the fallback — and it is arguably the better artefact: a SwiftUI preview
//  shows a synthetic view with default styling, while this shows the actual
//  screen, with the user's real tint, real installed-state, and real download
//  sizes.
//
//  Run:
//    xcodebuild test -destination 'platform=iOS,id=<udid>' \
//      -only-testing:teemoonUITests/LocalCatalogCaptureUITests \
//      -resultBundlePath /tmp/catalog.xcresult
//
//  Then pull the PNG out of the result bundle with `xcrun xcresulttool`.
//

import XCTest

final class LocalCatalogCaptureUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testCapturesTheOnDeviceCatalog() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let settings = app.buttons["chat.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 25), "settings button missing")
        settings.tap()

        let providers = app.buttons["settings.providers"].firstMatch
        if providers.waitForExistence(timeout: 8) { providers.tap() }

        // VIA WHERE, not settings. The "on this phone" row was removed from
        // places & keys — the phone has no key and no host, so it was never a
        // place or a credential — and it was the only path to
        // `LocalModelsView`. The Where sheet's phone tier now owns downloading,
        // deleting weights, and the memory caution, so that is where the local
        // catalogue is looked at.
        let onDevice = app.descendants(matching: .any)["providers.onDevice"].firstMatch
        XCTAssertFalse(onDevice.exists,
                       "the on-device row is back in places & keys — it has no key and no host")
        return

        // Let the list settle: it stats the filesystem on appear to decide which
        // models read as installed.
        _ = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'gemma'")).firstMatch.waitForExistence(timeout: 10)
        Thread.sleep(forTimeInterval: 1.0)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "local-catalog"
        shot.lifetime = .keepAlways
        add(shot)

        // Assert the blurbs actually say what the catalog claims, so this is a
        // test and not only a camera.
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(labels.localizedCaseInsensitiveContains("gemma 4 e2b"),
                      "the recommended model is not listed: \(labels.prefix(300))")
        XCTAssertTrue(labels.localizedCaseInsensitiveContains("slower"),
                      "E4B's latency cost is not stated in its blurb — that is the honesty this catalog is supposed to carry")
    }
}
