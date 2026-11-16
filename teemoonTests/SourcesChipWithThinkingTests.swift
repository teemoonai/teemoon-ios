//
//  SourcesChipWithThinkingTests.swift
//  teemoonTests
//
//  A saved reply that kept an inline <think> block (a model that writes it into its
//  answer) hid its sources chip although the sources were stored: the chip was gated
//  on `thinking == nil`. Every message with sources shows the chip (pm sources-ui,
//  The maintainer 2026-10-16). Measured by height, because the chip is the only thing sources add.
//

#if os(iOS)

import XCTest
import SwiftUI
@testable import teemoon

@MainActor
final class SourcesChipWithThinkingTests: XCTestCase {

    private let width: CGFloat = 393

    private func height(of message: Message) -> CGFloat {
        let host = UIHostingController(rootView: AnyView(
            MessageView(message: message, isLLMRunning: false).frame(width: width)))
        return host.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)).height
    }

    private func reply(thinking: Bool, sources: Bool) -> Message {
        let body = (thinking ? "<think>\nChecking the opening hours.\n</think>\n" : "") + "It opens at ten."
        let json = sources ? GroundingSource.encodedJSON([
            GroundingSource(url: "https://example.com/a", domain: "example.com", title: "A"),
        ]) : nil
        return Message(role: .assistant, content: body, generatingTime: 1.0, sourcesJSON: json)
    }

    func testAReplyWithThinkingShowsItsSourcesChip() {
        let bare = height(of: reply(thinking: true, sources: false))
        let withSources = height(of: reply(thinking: true, sources: true))
        XCTAssertGreaterThan(withSources, bare + 20, "the sources chip is missing under a reply with a thinking block")
    }

    func testAReplyWithoutThinkingStillShowsIt() {
        XCTAssertGreaterThan(height(of: reply(thinking: false, sources: true)),
                             height(of: reply(thinking: false, sources: false)) + 20)
    }
}

#endif
