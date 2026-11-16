//
//  DeviceCheckGuardUITests.swift
//  teemoonUITests
//
//  The 2026-11-12 incident, as a test: the device check pasted the maintainer's own clipboard photo because the runner's
//  pasteboard write failed. The guard must refuse when the pasteboard holds anything but the test image.
//

import UIKit
import UniformTypeIdentifiers
import XCTest

final class DeviceCheckGuardUITests: XCTestCase {

    func testAPersonsOwnClipboardPhotoIsNeverTakenForTheTestImage() {
        let fixture = DeviceCheckUITests.photo(.systemRed)
        let theirs = DeviceCheckUITests.photo(.systemTeal, .square)
        let board = UIPasteboard.withUniqueName()
        board.setItems([[UTType.png.identifier: theirs]])
        XCTAssertFalse(DeviceCheckUITests.pasteboardHolds(fixture, board: board), "a non-fixture image passed the guard")
        board.items = []
        XCTAssertFalse(DeviceCheckUITests.pasteboardHolds(fixture, board: board), "an empty pasteboard passed the guard")
        board.setItems([[UTType.png.identifier: fixture]])
        XCTAssertTrue(DeviceCheckUITests.pasteboardHolds(fixture, board: board))
    }
}
