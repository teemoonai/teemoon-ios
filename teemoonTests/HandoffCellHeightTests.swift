//
//  HandoffCellHeightTests.swift
//  teemoonTests
//
//  A REPLY'S CELL IS AS TALL AS THE REPLY, AND NO TALLER.
//
//  Reported with a screenshot (2026-08-22): a large empty band between the end
//  of an answer and the next message. `TranscriptHandoffTests` could not see
//  it, and the reason is worth keeping: its rows are `Color.clear`, which
//  EXPANDS to fill whatever minimum it is given, so a floor that is too tall
//  looks like a correctly-sized cell. A real message does not expand — it
//  leaves the difference as empty space.
//
//  So this hosts the REAL `MessageView` through the REAL representable, with
//  the content shape the screenshot showed: a reasoning block (which folds
//  when the persisted row replaces the stream, making the row shorter than the
//  streaming view was) and grounding sources (the chip the gap sat under).
//

#if os(iOS)

import XCTest
import SwiftUI
@testable import teemoon

@MainActor
final class HandoffCellHeightTests: XCTestCase {

    private let width: CGFloat = 393

    private func replyMessage() -> Message {
        Message(role: .assistant, content: """
            <think>
            \(String(repeating: "Reasoning that is folded away once the answer is persisted. ", count: 40))
            </think>
            **The honest takeaway:** \(String(repeating: "A paragraph of the answer itself, which is what the row has to be tall enough for. ", count: 6))
            """,
            generatingTime: 3.2,
            sourcesJSON: GroundingSource.encodedJSON([
                GroundingSource(url: "https://example.com/a", domain: "example.com", title: "A"),
                GroundingSource(url: "https://example.org/b", domain: "example.org", title: "B"),
            ]))
    }

    /// What the row asks for when nothing constrains it.
    private func naturalHeight(of message: Message) -> CGFloat {
        let host = UIHostingController(rootView: AnyView(
            MessageView(message: message, isLLMRunning: false).frame(width: width)))
        return host.sizeThatFits(in: CGSize(width: width,
                                            height: UIView.layoutFittingExpandedSize.height)).height
    }

    /// The reply lands in the transcript the way a real turn ends: the
    /// streaming view — deliberately much taller, as an expanded reasoning
    /// block makes it — is replaced by the persisted row in one apply.
    func testTheReplysCellIsNotFlooredByTheStreamingViewsHeight() {
        let message = replyMessage()
        let natural = naturalHeight(of: message)
        XCTAssertGreaterThan(natural, 100, "fixture: the reply should have real height")

        let history = (0..<8).map { _ in TranscriptItem.message(UUID()) }
        let reply = TranscriptItem.message(message.id)
        func view(generating: Bool) -> TranscriptView {
            TranscriptView(
                transcript: generating ? history : history + [reply],
                tail: [], threadID: Self.thread,
                isGenerating: generating, interrupted: false, volatileItems: [],
                chrome: ChatChrome(bottom: ChatFadeBand(chipTop: 16, chipBottom: 60, insetHeight: 0)),
                streamingContent: generating
                    ? AnyView(Color.clear.frame(height: natural + 600))
                    : nil,
                scrollToEndToken: 0,
                onInterruptionChanged: { _ in },
                rowBuilder: { item in
                    item == reply
                        ? AnyView(MessageView(message: message, isLLMRunning: false))
                        : AnyView(Color.clear.frame(height: 120))
                })
        }

        let controller = UIHostingController(rootView: view(generating: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        settle(window)

        controller.rootView = view(generating: false)
        settle(window)

        guard let collection = Self.firstCollectionView(in: window) else {
            return XCTFail("no collection view")
        }
        guard let last = transcriptLastMessageIndexPath(in: collection) else {
            return XCTFail("the reply's cell has no index path")
        }
        guard let attributes = collection.layoutAttributesForItem(at: last) else {
            return XCTFail("the reply's cell has no layout attributes")
        }
        XCTAssertEqual(attributes.size.height, natural, accuracy: 3,
            "the reply's cell is \(Int(attributes.size.height - natural))pt taller than the "
            + "reply it holds — that is the empty band under the last message")
    }

    /// A ROW THAT SHRINKS MUST SHRINK ITS CELL.
    ///
    /// The remembered height is applied as `UIHostingConfiguration.minSize` on
    /// every dequeue, not only the first — so a row whose content GOES AWAY
    /// (the web-search offer card, once its search has been accepted and the
    /// sources chip has taken over) leaves a cell still holding the height it
    /// had when it was full. That is a band of empty space sitting between the
    /// answer and the next message, which is where the reported one was.
    func testARowThatLosesItsContentLosesItsHeight() {
        let item = TranscriptItem.offer(UUID())
        let history = (0..<6).map { _ in TranscriptItem.message(UUID()) }

        func view(showingCard: Bool) -> TranscriptView {
            TranscriptView(
                transcript: history + [item],
                tail: [], threadID: Self.thread,
                isGenerating: false, interrupted: false,
                // The offer is volatile by nature: its row's INPUTS change
                // while its identity does not, which is what `volatileItems`
                // exists to reconfigure.
                volatileItems: showingCard ? [] : [item],
                chrome: ChatChrome(bottom: ChatFadeBand(chipTop: 16, chipBottom: 60, insetHeight: 0)),
                streamingContent: nil, scrollToEndToken: 0,
                onInterruptionChanged: { _ in },
                rowBuilder: { built in
                    guard built == item else { return AnyView(Color.clear.frame(height: 100)) }
                    return showingCard
                        ? AnyView(Color.clear.frame(height: 300))
                        : AnyView(EmptyView())
                })
        }

        let controller = UIHostingController(rootView: view(showingCard: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        settle(window)

        controller.rootView = view(showingCard: false)
        settle(window)

        guard let collection = Self.firstCollectionView(in: window) else {
            return XCTFail("no collection view")
        }
        guard let last = transcriptLastMessageIndexPath(in: collection) else {
            return XCTFail("no index path for the offer row")
        }
        guard let attributes = collection.layoutAttributesForItem(at: last) else {
            return XCTFail("no layout attributes for the offer row")
        }
        // A row rendering nothing collapses to the layout's hairline minimum,
        // not to exactly zero — 300pt of band is the defect, 10pt is not.
        XCTAssertLessThan(attributes.size.height, 20,
            "the row renders nothing but its cell is still \(Int(attributes.size.height))pt tall "
            + "— that is an empty band in the middle of the transcript")
    }

    /// A DEBUG CARD IS NOT FLOORED BY THE PREVIOUS TURN'S CARD.
    ///
    /// Reported twice with screenshots: large empty bands above and below the
    /// developer debug card. Its height is driven by what the turn DID — two
    /// web-search rounds with long queries make a tall card, a plain
    /// completion a short one — and the height cache used to carry the last
    /// card's measurement onto the next card's identity as a `minSize`. A tall
    /// turn followed by a plain one therefore floored the plain card at a
    /// height its content could not fill, and no amount of scrolling cleared
    /// it. Measured on the simulator before the fix: cell 206pt, content 174pt.
    func testADebugCardIsNotFlooredByThePreviousTurnsCard() {
        func info(rounds: Int) -> LastRequestDebugInfo {
            LastRequestDebugInfo(
                providerName: "near.ai", url: URL(string: "https://cloud-api.near.ai/v1"),
                requestHeaders: ["authorization": "Bearer …"],
                requestBodyJSON: "{\"encrypted\": true}",
                responseBody: String(repeating: "response body. ", count: 4),
                toolCalls: (0..<rounds).map { round in
                    ToolCallRecord(name: "web_search",
                                   arguments: "{\"q\": \"\(String(repeating: "a long query ", count: 6))\(round)\"}",
                                   result: "n:10 -> 10")
                },
                threadID: Self.thread, totalDuration: 38.3, timeToFirstToken: 12.1,
                outputTokens: 929, isE2EEActive: true,
                teeVerification: .unverified(.signatureUnavailable))
        }

        func height(of debugInfo: LastRequestDebugInfo, turn: Int) -> CGFloat {
            let item = TranscriptItem.debugInfo(turn: turn)
            func view(showingCard: Bool) -> TranscriptView {
                makeView(item: item, debugInfo: debugInfo, showingCard: showingCard)
            }
            // THE APP REVEALS THE CARD IN TWO STEPS, and the second is where a
            // first-paint floor is dropped: the hand-off applies without it,
            // then a beat later it arrives as a tail-only insert, which
            // `apply` recognises (`TranscriptApplyPolicy.isDebugCardReveal`)
            // and follows with a reconfigure. A single apply never reaches
            // that path and measures the floor instead of the card.
            let controller = UIHostingController(rootView: view(showingCard: false))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 852))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            settle(window)
            controller.rootView = view(showingCard: true)
            settle(window)
            guard let collection = Self.firstCollectionView(in: window) else { return -1 }
            let tail = TranscriptSection.tail.rawValue
            guard collection.numberOfItems(inSection: tail) > 0 else { return -1 }
            let height = collection.layoutAttributesForItem(
                at: IndexPath(item: 0, section: tail))?.frame.height ?? -1
            window.isHidden = true
            return height
        }

        func makeView(item: TranscriptItem, debugInfo: LastRequestDebugInfo,
                      showingCard: Bool) -> TranscriptView {
            TranscriptView(
                transcript: [Self.stableRow], tail: showingCard ? [item] : [],
                threadID: Self.thread, isGenerating: false, interrupted: false,
                volatileItems: [], chrome: ChatChrome(bottom: ChatFadeBand(
                    chipTop: 16, chipBottom: 60, insetHeight: 0)),
                streamingContent: nil, scrollToEndToken: 0,
                onInterruptionChanged: { _ in },
                rowBuilder: { built in
                    built == item
                        ? AnyView(RequestDebugView(info: debugInfo).padding())
                        : AnyView(Color.clear.frame(height: 120))
                })
        }

        // A tall turn: two tool rounds with long queries, exactly the shape in
        // the screenshots.
        let tall = height(of: info(rounds: 2), turn: 1)
        XCTAssertGreaterThan(tall, 240, "fixture: a two-round card should be tall")

        // Then a plain one. Its cell must be ITS size.
        let plain = info(rounds: 0)
        let short = height(of: plain, turn: 2)

        // What the plain card wants, measured with nothing floored.
        let natural = UIHostingController(rootView: AnyView(
            RequestDebugView(info: plain).padding().frame(width: width)))
            .sizeThatFits(in: CGSize(width: width,
                                     height: UIView.layoutFittingExpandedSize.height)).height

        XCTAssertEqual(short, natural, accuracy: 3,
            "the plain turn's card is \(Int(short))pt in a cell for \(Int(natural))pt of "
            + "content — the previous turn's taller card is still flooring it")
    }

    private static let thread = UUID()
    private static let stableRow = TranscriptItem.message(UUID())

    private func settle(_ window: UIWindow, passes: Int = 8) {
        for _ in 0..<passes {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date())
        }
    }

    private static func firstCollectionView(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView { return collection }
        for sub in view.subviews {
            if let found = firstCollectionView(in: sub) { return found }
        }
        return nil
    }
}

#endif
