//
//  ComposerThumbnailIDsTests.swift
//  teemoonTests
//
//  the maintainer 2026-11-12: x-ing out a composer image snapped instead of animating away. Thumbnails were identified by
//  position, so removing one renamed every one after it and SwiftUI had nothing to animate.
//

import Foundation
import Testing
@testable import teemoon

@MainActor
@Suite("Composer thumbnails — identity")
struct ComposerThumbnailIDsTests {

    @Test func removingOneLeavesTheOthersTheirIdentity() {
        let images = (1...3).map { ComposerImageTests.kept($0) }
        let before = ComposerThumbnailIDs.ids(images)
        #expect(Set(before).count == 3)
        let after = ComposerThumbnailIDs.ids([images[0], images[2]])
        #expect(after == [before[0], before[2]], "the third image was renamed when the second left")
    }

    @Test func theSameImageTwiceIsTwoThumbnails() {
        let a = ComposerImageTests.kept(1)
        #expect(Set(ComposerThumbnailIDs.ids([a, a])).count == 2)
    }
}
