//
//  TranscriptSpacingTests.swift
//  teemoonTests
//
//  THE COLUMN, MEASURED: every gap between rows, and the space after the last
//  one.
//
//  Asked for directly after two reports of "a large gap" that turned out to be
//  two different defects in two different places. Eyeballing a screenshot
//  identifies WHERE a gap is; it cannot say whether 78pt between two messages
//  is the design or a bug. This prints the whole column and asserts the only
//  two properties that are actually invariants:
//
//    - every message-to-message gap is the SAME (rows carry their own
//      `.padding()`; nothing in the transcript adds per-row spacing, so any
//      variation is a row keeping height it should not have)
//    - the space after the last row is the CHROME the composer needs and no
//      more (the transcript deliberately scrolls under the composer — that
//      inset is `ChatChrome.bottom.insetHeight` plus the home indicator)
//

#if os(iOS)

import XCTest
import SwiftUI
@testable import teemoon

@MainActor
final class TranscriptSpacingTests: XCTestCase {

    private let width: CGFloat = 393
    private let chromeInset: CGFloat = 132

    private func message(_ role: Role, _ text: String,
                         sources: Bool = false) -> Message {
        Message(role: role, content: text,
                generatingTime: role == .assistant ? 2.1 : nil,
                sourcesJSON: sources ? GroundingSource.encodedJSON([
                    GroundingSource(url: "https://example.com", domain: "example.com", title: "A"),
                ]) : nil)
    }

    /// A thread with the shapes the reports came from: plain turns, an answer
    /// carrying sources, and an answer with a folded reasoning block.
    private func thread() -> [Message] {
        [
            message(.user, "what about grind size?"),
            message(.assistant, "**The short answer:** " + String(repeating: "finer for immersion, coarser for pour-over. ", count: 8)),
            message(.user, "and the water?"),
            message(.assistant, String(repeating: "Water matters more than most people think, and here is why. ", count: 10),
                    sources: true),
            message(.user, "what about reddit?"),
            message(.assistant, "<think>\n" + String(repeating: "Folded reasoning. ", count: 40) + "\n</think>\n"
                    + String(repeating: "The consensus there is roughly the same as everywhere else. ", count: 8)),
        ]
    }

    func testTheColumnIsEvenlySpacedAndEndsInChromeOnly() {
        let messages = thread()
        let items = messages.map { TranscriptItem.message($0.id) }

        let view = TranscriptView(
            transcript: items, tail: [], threadID: UUID(),
            isGenerating: false, interrupted: false, volatileItems: [],
            chrome: ChatChrome(bottom: ChatFadeBand(chipTop: 16, chipBottom: 60,
                                                    insetHeight: chromeInset)),
            streamingContent: nil, scrollToEndToken: 0,
            onInterruptionChanged: { _ in },
            rowBuilder: { item in
                guard case .message(let id) = item,
                      let message = messages.first(where: { $0.id == id }) else {
                    return AnyView(EmptyView())
                }
                // The transcript's real row: MessageView under `.padding()`,
                // exactly as `ConversationView.messageRow` builds it.
                return AnyView(MessageView(message: message, isLLMRunning: false).padding())
            })

        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        for _ in 0..<10 { window.layoutIfNeeded(); RunLoop.main.run(until: Date()) }

        guard let collection = Self.firstCollectionView(in: window) else {
            return XCTFail("no collection view")
        }
        let frames = transcriptMessageFrames(in: collection)
        XCTAssertEqual(frames.count, items.count, "not every row was laid out")

        var report = "\n[transcript column]\n"
        var gaps: [CGFloat] = []
        for (index, frame) in frames.enumerated() {
            let gap = index == 0 ? 0 : frame.minY - frames[index - 1].maxY
            if index > 0 { gaps.append(gap) }
            report += String(format: "  row %d  y=%7.1f  h=%7.1f  gap above=%6.1f  (%@)\n",
                             index, frame.minY, frame.height, gap,
                             messages[index].role == .user ? "user" : "assistant")
        }
        let trailing = collection.contentSize.height - (frames.last?.maxY ?? 0)
        report += String(format: "  contentSize=%.1f  last row ends=%.1f  trailing=%.1f  "
                         + "inset.bottom=%.1f\n",
                         collection.contentSize.height, frames.last?.maxY ?? 0, trailing,
                         collection.contentInset.bottom)
        print(report)

        // Rows abut: the spacing a reader sees is each row's own padding, and
        // the layout adds nothing between them.
        for (index, gap) in gaps.enumerated() {
            XCTAssertEqual(gap, 0, accuracy: 1,
                "row \(index + 1) sits \(Int(gap))pt below the row above it — the transcript "
                + "adds no inter-row spacing, so that is height a row is keeping")
        }

        // Nothing hangs off the end of the content itself.
        XCTAssertEqual(trailing, 0, accuracy: 1,
            "\(Int(trailing))pt of content sits after the last row")

        // The only space below the last message is what the composer needs.
        let home = window.safeAreaInsets.bottom
        XCTAssertEqual(collection.contentInset.bottom, chromeInset + home, accuracy: 1,
            "the bottom inset is \(Int(collection.contentInset.bottom))pt, not the "
            + "\(Int(chromeInset + home))pt the composer chrome asks for")
    }

    /// THE HOME INDICATOR IS RESERVED ONCE, NOT TWICE.
    ///
    /// `contentInsetAdjustmentBehavior` is `.always`, so the scroll view adds
    /// its own `safeAreaInsets` on top of whatever `contentInset` holds. The
    /// transcript also pays the chrome back by hand, and used to pay the home
    /// indicator with it — reserving 34pt of scrollable space that no chrome
    /// occupies, which is where the transcript came to rest: 34pt past its own
    /// content, showing a band between the last row and the composer.
    ///
    /// The window here declares a bottom safe area precisely because the plain
    /// `UIWindow` the other tests use has none — with `home = 0` the double
    /// count is invisible, which is why the offline column looked clean while
    /// the device sat 34pt low.
    func testTheHomeIndicatorIsReservedOnceNotTwice() {
        final class SafeAreaWindow: UIWindow {
            override var safeAreaInsets: UIEdgeInsets {
                UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
            }
        }

        let messages = thread()
        let items = messages.map { TranscriptItem.message($0.id) }
        let view = TranscriptView(
            transcript: items, tail: [], threadID: UUID(),
            isGenerating: false, interrupted: false, volatileItems: [],
            chrome: ChatChrome(bottom: ChatFadeBand(chipTop: 16, chipBottom: 60,
                                                    insetHeight: chromeInset)),
            streamingContent: nil, scrollToEndToken: 0,
            onInterruptionChanged: { _ in },
            rowBuilder: { item in
                guard case .message(let id) = item,
                      let message = messages.first(where: { $0.id == id }) else {
                    return AnyView(EmptyView())
                }
                return AnyView(MessageView(message: message, isLLMRunning: false).padding())
            })

        let controller = UIHostingController(rootView: view)
        let window = SafeAreaWindow(frame: CGRect(x: 0, y: 0, width: width, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        for _ in 0..<10 { window.layoutIfNeeded(); RunLoop.main.run(until: Date()) }

        guard let collection = Self.firstCollectionView(in: window) else {
            return XCTFail("no collection view")
        }
        let home = collection.safeAreaInsets.bottom
        XCTAssertEqual(collection.adjustedContentInset.bottom, chromeInset + home, accuracy: 1,
            "the transcript reserves \(Int(collection.adjustedContentInset.bottom))pt below its "
            + "content, but the chrome is \(Int(chromeInset))pt and the home indicator "
            + "\(Int(home))pt — the difference is scrollable space nothing occupies")
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
