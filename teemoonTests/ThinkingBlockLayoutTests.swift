//
//  ThinkingBlockLayoutTests.swift
//  teemoonTests
//
//  An open <think> block is as tall as its text. Its left rule is a Capsule, which takes every point it is
//  offered, and the HStack centred the thinking text in that: on the stream rig the block was a tall empty
//  area with the text far below the screen (pm/evidence/1.1-ui/ios/stream/4b-*, 2026-10-25).
//

#if os(iOS)
import XCTest
import SwiftUI
@testable import teemoon

@MainActor
final class ThinkingBlockLayoutTests: XCTestCase {
    private let width: CGFloat = 393

    private func height(_ view: some View, offered: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: AnyView(view.frame(width: width)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<10 { window.layoutIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return host.sizeThatFits(in: CGSize(width: width, height: offered)).height
    }

    func testAnOpenThinkBlockIsAsTallAsItsText() {
        let llm = ChatGeneration()
        llm.output = "<think>The user is asking whether they can walk across to the tidal island tomorrow. "
            + "The causeway floods around high water, so the answer depends on the tide."
        let small = height(StreamingMessageView().environment(llm), offered: 2_000)
        let large = height(StreamingMessageView().environment(llm), offered: 5_000)
        XCTAssertLessThan(small, 400, "the open block took the height it was offered")
        XCTAssertEqual(small, large, accuracy: 1, "the block's height follows the offer, not its text")
    }
}
#endif
