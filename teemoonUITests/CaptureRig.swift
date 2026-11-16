//
//  CaptureRig.swift
//  teemoonUITests
//
//  The *CaptureUITests suites take screenshots for docs, the site and design review; they assert nothing about the
//  product. They run only when asked: TEEMOON_CAPTURE=1 (or TEST_RUNNER_TEEMOON_CAPTURE=1 through xcodebuild).
//

import XCTest

enum CaptureRig {
    static var asked: Bool {
        let env = ProcessInfo.processInfo.environment
        return (env["TEEMOON_CAPTURE"] ?? env["TEST_RUNNER_TEEMOON_CAPTURE"]) == "1"
    }

    static func skipUnlessAsked() throws {
        try XCTSkipUnless(asked, "a capture rig: set TEEMOON_CAPTURE=1 to run it")
    }
}
