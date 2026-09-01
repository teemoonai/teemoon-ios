//
//  TranscriptHandoffTests.swift
//  teemoonTests
//
//  THE END OF A TURN MUST NOT MOVE A VIEWPORT THE READER PLACED.
//
//  Reported: "if I'm scrolled away from the bottom while it's generating, I'm
//  auto-scrolled to the beginning of the generation when generation finishes."
//
//  The mechanism is geometric, not a stray `scrollTo`. While a turn runs the
//  reply lives in the trailing streaming view, whose height is paid for by
//  `contentInset.bottom`, so the scrollable range includes it. At the hand-off
//  that inset drops and the reply becomes a CELL — which contributes its height
//  only once realised. A reader who scrolled away is not looking at the end, so
//  that cell is off screen and carried at the layout's estimate: the content
//  end jumps up by nearly the whole reply and `UIScrollView` clamps the offset
//  to it. The clamped offset IS the top of the new reply, which is exactly what
//  the report describes.
//
//  These drive the real representable — the same collection view, the same
//  hand-off ordering in `updateUIViewController` — because the bug lives in the
//  interaction between the inset, the estimate and the clamp. Nothing smaller
//  than the real thing can host it.
//

#if os(iOS)

import XCTest
import SwiftUI
@testable import teemoon

@MainActor
final class TranscriptHandoffTests: XCTestCase {

    private let rowHeight: CGFloat = 200
    private let streamingHeight: CGFloat = 3_000

    /// Fixed-height rows, so every number in the assertions is exact.
    private func rows(_ count: Int) -> [TranscriptItem] {
        (0..<count).map { _ in TranscriptItem.message(UUID()) }
    }

    /// The reply's row, once persisted, renders the SAME MARKDOWN the
    /// streaming view was rendering — so in production the two heights differ
    /// only by the reasoning fold, not by an order of magnitude. An early
    /// version of this fixture left the reply at the ordinary 200pt row height
    /// against a 3,000pt streaming view, and that 15x gap is not a hand-off:
    /// it made "hold the distance from the end" look correct and "hold the
    /// offset" look broken, which is the reverse of what the device showed.
    private var replyRowHeight: CGFloat { streamingHeight - 583 }

    private func transcript(items: [TranscriptItem],
                            generating: Bool,
                            interrupted: Bool,
                            streaming: Bool,
                            tallItem: TranscriptItem? = nil) -> TranscriptView {
        TranscriptView(
            transcript: items,
            tail: [],
            threadID: Self.thread,
            isGenerating: generating,
            interrupted: interrupted,
            volatileItems: [],
            chrome: ChatChrome(bottom: ChatFadeBand(chipTop: 16, chipBottom: 60, insetHeight: 0)),
            streamingContent: streaming
                ? AnyView(Color.clear.frame(height: streamingHeight))
                : nil,
            scrollToEndToken: 0,
            onInterruptionChanged: { _ in },
            rowBuilder: { [rowHeight, replyRowHeight] item in
                AnyView(Color.clear.frame(height: item == tallItem ? replyRowHeight : rowHeight))
            })
    }

    private static let thread = UUID()

    private func host(_ view: TranscriptView)
        -> (UIWindow, UIHostingController<TranscriptView>, PinningCollectionView) {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        settle(window)
        guard let collection = Self.firstCollectionView(in: window) as? PinningCollectionView else {
            XCTFail("no PinningCollectionView in the hosted transcript")
            fatalError("unreachable — XCTFail above")
        }
        return (window, controller, collection)
    }

    /// SwiftUI applies a `rootView` change on its own schedule; the collection
    /// view then needs layout passes to realise cells and self-size them.
    private func settle(_ window: UIWindow, passes: Int = 6) {
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

    // MARK: - The regression

    /// A reader parked in the HISTORY — above the answer being written —
    /// stays exactly where they were when the turn ends.
    func testATurnEndingWhileReadingHistoryLeavesTheReaderWhereTheyWere() {
        let existing = rows(20)
        let (window, controller, collection) =
            host(transcript(items: existing, generating: true, interrupted: false, streaming: true))

        // Somewhere in the middle of the transcript, well inside drawn
        // content — the "I scrolled up to re-read something" case.
        collection.contentOffset.y = 800
        controller.rootView = transcript(items: existing, generating: true,
                                         interrupted: true, streaming: true)
        settle(window)
        // READ THE BASELINE BACK rather than asserting the number that was
        // written. What is under test is the DELTA across the hand-off; where
        // the fixture's own layout settles beforehand is not the property, and
        // pinning it makes the test fail for reasons that have nothing to do
        // with the reader being moved.
        let reading = collection.contentOffset.y
        XCTAssertLessThan(reading + collection.bounds.height, collection.contentSize.height,
                          "fixture: the reader should be above the answer, inside drawn content")

        let reply = TranscriptItem.message(UUID())
        controller.rootView = transcript(items: existing + [reply], generating: false,
                                         interrupted: true, streaming: false, tallItem: reply)
        settle(window)

        XCTAssertEqual(collection.contentOffset.y, reading, accuracy: 2,
                       "the hand-off moved a reader who had scrolled away")
        assertNothingBlank(collection, "after the hand-off")
    }

    /// A reader parked INSIDE the answer as it streams keeps their place in
    /// it — measured from the newest text, which is the only thing that
    /// survives the hand-off intact.
    ///
    /// Their offset is past `contentSize` — they are looking at the trailing
    /// streaming view, which lives in reserved inset. At the hand-off that
    /// view goes and the reply becomes a cell that contributes its height
    /// only once REALISED — and it cannot realise, because it is carried at
    /// the layout's 120pt estimate and therefore sits outside the region the
    /// viewport is in. Nothing can be drawn where the reader is standing.
    ///
    /// So the transcript takes them to the end of what IS drawn. That is the
    /// old jump, and it is not good — but the alternative, tried and reverted
    /// on 2026-08-22, is to hold them where they were over a reserved band
    /// with nothing in it, which is a blank screen. NEVER BLANK is the
    /// invariant; landing on the answer is the preference.
    ///
    /// The real fix is an anchor-relative hold (the reply's cell begins at the
    /// same y the streaming view did, so the offset INTO the answer is
    /// preserved once that cell can be measured) and it needs the cell's
    /// height to be knowable before realisation — which the compositional
    /// layout's single `.estimated` does not allow. Not attempted here.
    func testAReaderInsideTheAnswerKeepsTheirPlaceInIt() {
        let existing = rows(20)
        let (window, controller, collection) =
            host(transcript(items: existing, generating: true, interrupted: false, streaming: true))

        // Past `contentSize`: inside the streaming view's reserved space.
        controller.rootView = transcript(items: existing, generating: true,
                                         interrupted: true, streaming: true)
        settle(window)
        // Placed AFTER the settle window has run itself out, so the position
        // under test is the one the hand-off sees. Setting it earlier lets the
        // turn-start settle move the reader before the hand-off, which is the
        // fixture's own behaviour and not the property being measured.
        collection.contentOffset.y = collection.maxContentOffsetY - 900
        let reading = collection.contentOffset.y
        XCTAssertGreaterThan(reading + collection.bounds.height, collection.contentSize.height,
                             "fixture: the reader should be inside the streaming view")


        let reply = TranscriptItem.message(UUID())
        controller.rootView = transcript(items: existing + [reply], generating: false,
                                         interrupted: true, streaming: false, tallItem: reply)
        settle(window)

        assertNothingBlank(collection, "after the hand-off from inside the answer")
        // THE SAME CONTENT UNDER THEM, i.e. the absolute offset. The reply's
        // cell begins at exactly the y the streaming view did, so the answer
        // does not move out from under a reader standing on it — only its TAIL
        // shortens, by the fold. A "distance from the newest text" hold was
        // tried here and is wrong for the case that matters: a reader deep in
        // a long answer is thousands of points from the end, and tying them to
        // it feeds every height change below them into their position (device
        // trace, 2026-08-22: it moved the reader 583pt and took the paragraph
        // they were reading off the top of the screen).
        XCTAssertEqual(collection.contentOffset.y, reading, accuracy: 8,
                       "the answer moved out from under a reader standing on it")
    }

    /// THE REPLY'S CELL IS AS TALL AS THE REPLY, AND NO TALLER.
    ///
    /// Reported with a screenshot: a large empty band between the end of an
    /// answer and the next message. The hand-off seeds the persisted row's
    /// height cache with the STREAMING VIEW's height so the first paint is not
    /// the layout's 120pt estimate — but that value becomes a
    /// `UIHostingConfiguration.minSize`, and the persisted row is legitimately
    /// SHORTER than the stream it replaces: the reasoning block folds when
    /// MessageView takes over (~1,800pt measured; 583pt in the device trace of
    /// 2026-08-22). The difference is a floor the content cannot fill.
    func testTheRepliesCellDoesNotKeepTheStreamingViewsHeight() {
        let existing = rows(20)
        let (window, controller, collection) =
            host(transcript(items: existing, generating: true, interrupted: false, streaming: true))
        settle(window)

        let reply = TranscriptItem.message(UUID())
        controller.rootView = transcript(items: existing + [reply], generating: false,
                                         interrupted: false, streaming: false, tallItem: reply)
        settle(window)

        guard let last = transcriptLastMessageIndexPath(in: collection) else {
            return XCTFail("the reply's cell has no index path")
        }
        guard let attributes = collection.layoutAttributesForItem(at: last) else {
            return XCTFail("the reply's cell has no layout attributes")
        }
        XCTAssertEqual(attributes.size.height, replyRowHeight, accuracy: 2,
            "the reply's cell is \(Int(attributes.size.height - replyRowHeight))pt taller than "
            + "the reply — that is empty space under the last message")
    }

    /// THE OTHER HALF OF "DON'T MOVE THEM": THERE HAS TO BE SOMETHING THERE.
    ///
    /// Holding an offset is only a fix if content is drawn under it. The
    /// first version of the hold reserved `contentInset.bottom` to stop the
    /// content end moving up — but the streaming view that used to occupy
    /// that space is gone by then, so it reserved a band with NOTHING IN IT
    /// and pinned the reader inside it: a blank screen for the length of the
    /// hold, reported as "the screen blanks after generation if I'm scrolled
    /// up". The test above passed throughout, because it only asked where the
    /// viewport was and never whether anything was under it.
    ///
    /// This is the transcript's own overscroll metric — the one the
    /// out-of-band trace analyzer counts and the UIKit transcript's
    /// target is zero of.
    /// The trailing streaming view's height, or 0 when it is not mounted.
    /// Read off the scroll view's own subviews so the test does not need the
    /// controller — the host is a plain subview by design.
    private func controllerStreamingHeight(_ collection: PinningCollectionView) -> CGFloat {
        collection.subviews
            .filter { !($0 is UICollectionViewCell) && $0.frame.height > 1 }
            .map(\.frame.height).max() ?? 0
    }

    private func assertNothingBlank(_ collection: PinningCollectionView,
                                    _ when: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        // AGAINST `contentSize`, NOT against the inset. The bottom inset is
        // exactly where a reserved-but-empty band would hide, so measuring the
        // content end as `contentSize + inset` is a tautology — the first
        // version of this assertion did that and passed against a screen that
        // was demonstrably blank. The fixture draws no chrome, so the real end
        // of drawn content IS `contentSize.height` here.
        // The streaming host, while mounted, is REAL CONTENT living in the
        // space `contentInset.bottom` reserves — the same split
        // `recordGeometry` makes for the trace. Chrome is not content, but
        // the transcript legitimately scrolls under it.
        let viewportBottom = collection.contentOffset.y + collection.bounds.height
        let chrome = collection.window?.safeAreaInsets.bottom ?? 0
        let drawnEnd = collection.contentSize.height
            + (controllerStreamingHeight(collection)) + chrome
        XCTAssertLessThanOrEqual(viewportBottom, drawnEnd + 1,
            "\(when): the viewport is \(Int(viewportBottom - drawnEnd))pt past the last "
            + "drawn content — that band is blank",
            file: file, line: line)
    }

    /// The first touch outranks the hold. Whatever the transcript was holding,
    /// a reader who starts scrolling owns the offset from then on.
    func testATouchDuringTheHoldGivesTheOffsetBackToTheReader() {
        let existing = rows(20)
        let (window, controller, collection) =
            host(transcript(items: existing, generating: true, interrupted: false, streaming: true))
        collection.contentOffset.y = collection.maxContentOffsetY - 900
        controller.rootView = transcript(items: existing, generating: true,
                                         interrupted: true, streaming: true)
        settle(window)

        let reply = TranscriptItem.message(UUID())
        controller.rootView = transcript(items: existing + [reply], generating: false,
                                         interrupted: true, streaming: false, tallItem: reply)
        settle(window)

        // A drag begins, and lands somewhere else entirely.
        collection.delegate?.scrollViewWillBeginDragging?(collection)
        let chosen = collection.contentOffset.y - 600
        collection.contentOffset.y = chosen
        settle(window)

        XCTAssertEqual(collection.contentOffset.y, chosen, accuracy: 2,
                       "the hold dragged the reader back after they scrolled")
    }

    /// The other half of the rule, and the reason the hold is conditional: a
    /// reader still at the end when the answer lands should be taken to the
    /// answer, not frozen mid-transcript.
    func testATurnEndingWhileFollowingStillLandsOnTheAnswer() {
        let existing = rows(20)
        let (window, controller, collection) =
            host(transcript(items: existing, generating: true, interrupted: false, streaming: true))
        collection.contentOffset.y = collection.maxContentOffsetY
        settle(window)

        let reply = TranscriptItem.message(UUID())
        controller.rootView = transcript(items: existing + [reply], generating: false,
                                         interrupted: false, streaming: false, tallItem: reply)
        settle(window)

        XCTAssertEqual(collection.contentOffset.y, collection.maxContentOffsetY, accuracy: 2,
                       "a following reader should end the turn at the end of the content")
    }
}

#endif
