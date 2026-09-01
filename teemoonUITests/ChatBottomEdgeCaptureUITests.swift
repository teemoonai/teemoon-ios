import XCTest

/// Captures the chat's bottom edge over a REAL transcript with the keyboard up —
/// the only state that exercises the fade, and the one that has hidden three
/// separate bugs from previews (which render no keyboard) and from unit tests
/// (which can't see a mask).
///
/// `ChatFadeBandTests` pins the arithmetic; this exists to look at the result.
/// Opt-in: it drives a live model server and takes minutes.
///
///     TEST_RUNNER_TEEMOON_EDGE_CAPTURE_ENDPOINT=https://host.ts.net:11434/v1 \
///     TEST_RUNNER_TEEMOON_EDGE_CAPTURE_MODEL=gemma4:latest \
///     xcodebuild test … -only-testing:teemoonUITests/ChatBottomEdgeCaptureUITests
///
/// The `TEST_RUNNER_` prefix is load-bearing: without it xcodebuild does not
/// forward the variable to the runner, the guard below sees nothing, and the
/// test SKIPS while still reporting `** TEST SUCCEEDED **`.
///
/// It also needs the simulator's SOFTWARE keyboard, which a connected hardware
/// keyboard suppresses — and a capture with no keyboard silently photographs the
/// wrong state rather than failing:
///
///     defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
///
/// (then reboot the simulator; `-bool true` puts it back).
final class ChatBottomEdgeCaptureUITests: XCTestCase {

    func testCaptureBottomEdgeWithKeyboardUp() throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["TEEMOON_EDGE_CAPTURE_ENDPOINT"] else {
            throw XCTSkip("set TEEMOON_EDGE_CAPTURE_ENDPOINT to run the edge capture")
        }
        let model = env["TEEMOON_EDGE_CAPTURE_MODEL"] ?? "gemma4:latest"

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_LOCAL_ENDPOINT"] = endpoint
        app.launchEnvironment["UITEST_SEED_LOCAL_MODEL"] = model
        app.launch()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "composer never appeared")

        // The fade lives on ConversationView, which an empty thread never mounts.
        // A long single-column answer puts text at every height behind the chrome.
        composer.tap()
        composer.typeText("List 25 common vegetables, one per line, no commentary.")
        app.buttons["chat.send"].tap()
        Thread.sleep(forTimeInterval: 90)   // cold model load + generation

        composer.tap()                      // raise the keyboard over the transcript
        Thread.sleep(forTimeInterval: 3)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "chat-bottom-edge-keyboard-up"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
