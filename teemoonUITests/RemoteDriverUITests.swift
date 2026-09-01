//
//  RemoteDriverUITests.swift
//  teemoonUITests
//
//  An interpreter, not a test: a command loop that lets an agent (or a human
//  with a shell) drive the real app through XCUITest — tap, type, wait, read
//  the hierarchy, screenshot — without writing a rig per flow.
//
//  Why: source-coded rigs can only photograph what they were told to expect.
//  FirstRunCaptureUITests shot a "populated" Where sheet that actually read
//  "not downloaded — tap to resume" under a "ready now" header, because
//  nothing in the rig looked at the frame. A driver in the loop looks.
//
//  Protocol (the simulator shares the host filesystem):
//      /tmp/teemoon-driver/cmd-<n>.json   ← the driver writes, n = 1,2,3…
//      /tmp/teemoon-driver/res-<n>.json   → this loop answers
//      /tmp/teemoon-driver/shot-<n>.png   → screenshots
//      /tmp/teemoon-driver/hier-<n>.txt   → debugDescription dumps
//
//  Start it (a host-side driver wraps all of this):
//      TEST_RUNNER_TEEMOON_DRIVER=1 xcodebuild test … \
//        -only-testing:teemoonUITests/RemoteDriverUITests
//
//  Gated on that env var so a plain full-suite run skips instead of idling.
//

import XCTest

final class RemoteDriverUITests: XCTestCase {

    private let dir = URL(fileURLWithPath: "/tmp/teemoon-driver", isDirectory: true)
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TEEMOON_DRIVER"] == "1",
                          "driver loop runs only when TEST_RUNNER_TEEMOON_DRIVER=1")
        continueAfterFailure = true  // a failed tap is a result, not the end of the session
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func testDrive() throws {
        app = XCUIApplication()
        let idle = Double(ProcessInfo.processInfo.environment["DRIVER_IDLE"] ?? "") ?? 600
        var seq = 0
        var lastActivity = Date()

        while Date().timeIntervalSince(lastActivity) < idle {
            let next = dir.appendingPathComponent("cmd-\(seq + 1).json")
            guard let data = try? Data(contentsOf: next),
                  let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            seq += 1
            lastActivity = Date()
            var res: [String: Any] = ["seq": seq]
            do {
                res["value"] = try perform(cmd)
                res["ok"] = true
            } catch let e {
                res["ok"] = false
                res["error"] = "\(e)"
            }
            let out = try JSONSerialization.data(withJSONObject: res)
            try out.write(to: dir.appendingPathComponent("res-\(seq).json"), options: .atomic)
            if cmd["op"] as? String == "quit" { return }
        }
    }

    // MARK: - ops

    private enum DriverError: Error { case notFound(String), badCommand(String) }

    private func perform(_ cmd: [String: Any]) throws -> String {
        let seqNum = cmd["seq"] as? Int ?? 0
        switch cmd["op"] as? String {

        case "launch":
            app.terminate()
            app.launchArguments = (cmd["args"] as? [String]) ?? []
            if let env = cmd["env"] as? [String: String] { app.launchEnvironment = env }
            app.launch()
            return "launched"

        case "tap":
            let el = try existing(cmd)
            el.tap()
            return "tapped"

        case "tapCoord":
            guard let x = cmd["x"] as? Double, let y = cmd["y"] as? Double else {
                throw DriverError.badCommand("tapCoord needs normalized x,y")
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
            return "tapped \(x),\(y)"

        case "type":
            if cmd["id"] != nil || cmd["label"] != nil { try existing(cmd).tap() }
            guard let text = cmd["text"] as? String else { throw DriverError.badCommand("type needs text") }
            app.typeText(text)
            return "typed"

        case "swipe":
            let target: XCUIElement = (cmd["id"] != nil || cmd["label"] != nil) ? try existing(cmd) : app
            switch cmd["dir"] as? String {
            case "up": target.swipeUp(); case "down": target.swipeDown()
            case "left": target.swipeLeft(); case "right": target.swipeRight()
            default: throw DriverError.badCommand("swipe dir must be up/down/left/right")
            }
            return "swiped"

        case "exists":
            return (try? element(cmd, wait: 0))?.exists == true ? "yes" : "no"

        case "waitFor":
            let t = cmd["timeout"] as? Double ?? 10
            let el = try element(cmd, wait: t)
            guard el.exists else { throw DriverError.notFound("did not appear in \(t)s") }
            return "appeared"

        case "waitGone":
            let t = cmd["timeout"] as? Double ?? 10
            let deadline = Date().addingTimeInterval(t)
            while Date() < deadline {
                if (try? element(cmd, wait: 0))?.exists != true { return "gone" }
                Thread.sleep(forTimeInterval: 0.5)
            }
            throw DriverError.notFound("still present after \(t)s")

        case "label":
            // read an element's current label/value — the cheap poll for
            // download progress without shipping a whole hierarchy
            let el = try existing(cmd)
            return "\(el.label)|\(el.value ?? "")"

        case "hierarchy":
            let path = dir.appendingPathComponent("hier-\(seqNum).txt")
            try app.debugDescription.write(to: path, atomically: true, encoding: .utf8)
            return path.path

        case "screenshot":
            let path = dir.appendingPathComponent("shot-\(seqNum).png")
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: path)
            return path.path

        case "wait":
            Thread.sleep(forTimeInterval: cmd["seconds"] as? Double ?? 1)
            return "waited"

        case "quit":
            return "bye"

        default:
            throw DriverError.badCommand("unknown op \(cmd["op"] ?? "nil")")
        }
    }

    /// Like element(), but a miss is an error RESULT, never a session-ending
    /// exception. Reading .label / tapping a non-existent element raises ObjC —
    /// which killed session one on its eighth command. Guard first.
    private func existing(_ cmd: [String: Any]) throws -> XCUIElement {
        let el = try element(cmd)
        guard el.exists else {
            throw DriverError.notFound("no element for \(cmd["id"] ?? cmd["label"] ?? "?")")
        }
        return el
    }

    /// Resolve by accessibility identifier (`id`) or by label (`label`).
    /// Identifier first — labels are localized and drift; ids are the contract.
    private func element(_ cmd: [String: Any], wait: TimeInterval = 5) throws -> XCUIElement {
        let el: XCUIElement
        if let id = cmd["id"] as? String {
            el = app.descendants(matching: .any).matching(identifier: id).firstMatch
        } else if let label = cmd["label"] as? String {
            el = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch
        } else {
            throw DriverError.badCommand("need id or label")
        }
        if wait > 0 { _ = el.waitForExistence(timeout: wait) }
        return el
    }
}
