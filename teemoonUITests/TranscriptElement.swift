//
//  TranscriptElement.swift
//  teemoonUITests
//
//  HOW A UI TEST FINDS THE TRANSCRIPT.
//
//  Every suite in here used to write `app.scrollViews.firstMatch`, and that was
//  wrong before the UIKit transcript existed — it just failed quietly. Textual
//  renders a markdown table inside a horizontal `Overflow` scroll view, so on
//  any run where a reply with a table is on screen, `firstMatch` returns THAT:
//  the test then swipes a table sideways, reads its frame, and reports on the
//  transcript. `testRaisingTheKeyboardMidAnswerKeepsTheFollow` already carries a
//  comment about a sibling case (the composer's field editor winning the query
//  and costing 60s of searching for a reply that was on screen the whole time).
//
//  The UIKit transcript turned the intermittent miss into a total one — a
//  `UICollectionView` is not a ScrollView to XCUI — which is how it got found.
//  The fix is not to swap one type query for another: it is to ADDRESS THE
//  TRANSCRIPT BY NAME, which cannot resolve to a table, a field editor, or
//  whatever the next nested scroll view turns out to be.
//
//  `chat.transcript` is set on the collection view (iOS) and on the ScrollView
//  (macOS), so this reads the same on both.
//

import XCTest

extension XCUIApplication {
    /// The chat transcript's scroll container, whatever it is implemented with.
    /// Deliberately type-agnostic: the identifier is the contract.
    var transcript: XCUIElement {
        descendants(matching: .any).matching(identifier: "chat.transcript").firstMatch
    }
}
