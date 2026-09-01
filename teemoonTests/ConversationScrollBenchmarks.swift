//
//  ConversationScrollBenchmarks.swift
//  teemoonTests
//
//  Closes the "scroll-path not measured" gap from the 2026-07 performance pass.
//
//  The complaint these pin is "scrolling gets laggier the longer the chat
//  gets". A cold-render benchmark cannot see that: it measures opening the
//  thread, not dragging through it. What matters for a drag is how much LIVE
//  UIKit there is behind the scroll view — every view, layer, gesture
//  recogniser and UIInteraction is walked per touch and composited per frame,
//  whether or not it is on screen.
//
//  So the primary measurement here is a CENSUS, not a stopwatch: host the real
//  ConversationView at several thread lengths and count what UIKit is holding.
//  A census is deterministic (no run-to-run variance, no Debug-build inflation)
//  and it answers the actual question — does the cost scale with thread length?
//  The corroborating wall-clock numbers come from `LongThreadScrollUITests`,
//  which flicks the real app; see the note further down for why there is no
//  scroll stopwatch in this file.
//
//  iOS-only: the whole point is the UIKit object graph.
//

#if os(iOS)

import XCTest
import SwiftUI
@testable import teemoon

@MainActor
final class ConversationScrollBenchmarks: XCTestCase {

    // MARK: - Fixture

    /// A thread of realistic mixed content: short user turns, assistant replies
    /// that mostly stay on the inline fast path, and every fifth reply carrying
    /// a fenced code block so `StructuredText` (the expensive renderer) is
    /// represented in the mix at roughly the rate real chats hit it.
    static func fixtureMessages(_ count: Int) -> [Message] {
        (0..<count).map { i in
            if i.isMultiple(of: 2) {
                return Message(role: .user, content: "question \(i): what does this actually prove?")
            }
            if i % 5 == 1 {
                return Message(role: .assistant, content: """
                Here is reply \(i), with a block that needs the structured renderer:

                ```swift
                let quote = try TDXQuote(parsing: report)
                guard quote.mrConfigID == expected else { throw Err.mismatch }
                ```

                \(String(repeating: "Followed by a paragraph of prose that wraps across several lines. ", count: 4))
                """)
            }
            return Message(role: .assistant, content: "reply \(i): "
                + String(repeating: "some **markdown** with `code` and ordinary text. ", count: 10))
        }
    }

    // MARK: - Hosting

    private func host(_ messages: [Message]) -> (UIWindow, UIScrollView) {
        let llm = ChatGeneration()
        let settings = AppSettings()
        let controller = UIHostingController(
            rootView: ConversationView(messages: messages, threadID: UUID(), generatingThreadID: nil)
                .environment(llm)
                .environment(settings))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date())
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date())
        window.layoutIfNeeded()
        guard let scrollView = Self.firstScrollView(in: window) else {
            XCTFail("no UIScrollView in the hosted ConversationView")
            return (window, UIScrollView())
        }
        return (window, scrollView)
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Census

    struct Census: CustomStringConvertible {
        var views = 0
        var layers = 0
        var gestures = 0
        var interactions = 0
        var contentHeight: CGFloat = 0

        var description: String {
            "views=\(views) layers=\(layers) gestures=\(gestures) "
                + "interactions=\(interactions) contentH=\(Int(contentHeight))"
        }
    }

    private func census(of root: UIView, scrollView: UIScrollView) -> Census {
        var c = Census()
        func walk(_ view: UIView) {
            c.views += 1
            c.gestures += view.gestureRecognizers?.count ?? 0
            c.interactions += view.interactions.count
            func walkLayer(_ layer: CALayer) {
                c.layers += 1
                for sub in layer.sublayers ?? [] { walkLayer(sub) }
            }
            walkLayer(view.layer)
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        c.contentHeight = scrollView.contentSize.height
        return c
    }

    /// The load-bearing test. Live UIKit behind the transcript must not grow
    /// without bound with thread length — a viewport shows a fixed number of
    /// messages, so a fixed-ish object graph is the correct shape.
    ///
    /// Threshold: going from 20 to 200 messages (10x the content) may not cost
    /// more than 3x the views. A lazy stack lands near 1x; the non-lazy VStack
    /// this replaces measured ~10x, i.e. perfectly linear.
    func testLiveUIKitDoesNotScaleWithThreadLength() {
        var results: [(Int, Census)] = []
        for n in [20, 60, 200] {
            let (window, scrollView) = host(Self.fixtureMessages(n))
            let c = census(of: window, scrollView: scrollView)
            results.append((n, c))
            print("[scroll-census] messages=\(n) \(c)")
            window.isHidden = true
        }

        guard let small = results.first(where: { $0.0 == 20 })?.1,
              let large = results.first(where: { $0.0 == 200 })?.1 else {
            return XCTFail("census did not run")
        }

        // Content height MUST scale — that is the transcript being longer.
        XCTAssertGreaterThan(large.contentHeight, small.contentHeight * 3,
                             "fixture is not actually producing a longer transcript")

        let viewGrowth = Double(large.views) / Double(max(small.views, 1))
        print("[scroll-census] view growth 20→200 messages: \(String(format: "%.2f", viewGrowth))x")
        XCTAssertLessThan(viewGrowth, 3.0,
            "live UIKit view count grows ~linearly with thread length "
            + "(\(small.views) → \(large.views) views); the transcript is materialising "
            + "off-screen messages, which is what makes long chats scroll badly")
    }

    /// The regression this change is most likely to cause. A thread must open at
    /// its END — that is the whole contract of a chat transcript, and it is the
    /// thing a LazyVStack breaks if the initial offset is left to a `scrollTo`
    /// that has no realised content to aim at.
    func testLongThreadOpensAtTheBottom() {
        for n in [20, 200] {
            let (window, scrollView) = host(Self.fixtureMessages(n))
            // DISTANCE FROM THE END IS `maxOffset - offset`, and the earlier
            // formula was only right when the bottom inset was zero.
            //
            // It read `contentSize - (offset + bounds + inset)`. At rest
            // against the end, `offset` ALREADY equals
            // `contentSize + inset - bounds`, so adding the inset a second
            // time subtracts it twice: the transcript reserves space for the
            // composer now, and a correct landing reported -264 against a
            // 132pt inset (exactly -2x) rather than 0. The scroll view was
            // right and the ruler was wrong.
            let maxOffset = scrollView.contentSize.height
                + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
            let distanceFromEnd = maxOffset - scrollView.contentOffset.y
            print("[scroll-open] messages=\(n) offset=\(Int(scrollView.contentOffset.y)) "
                + "contentH=\(Int(scrollView.contentSize.height)) fromEnd=\(Int(distanceFromEnd))")
            XCTAssertLessThan(abs(distanceFromEnd), 60,
                "a \(n)-message thread opened \(Int(distanceFromEnd))pt away from the end "
                + "of its transcript; it must open on the newest message")
            window.isHidden = true
        }
    }

    // NO SCROLL BENCHMARK LIVES HERE, AND THAT IS DELIBERATE.
    //
    // The obvious one — step `contentOffset` through the transcript in a
    // `measure {}` and time it — was written, run, and deleted. Setting the
    // offset on a hosted scroll view and calling `layoutIfNeeded` does not
    // drive a lazy stack the way a finger does: over three full up-and-down
    // passes of a 200-message thread the reported content height moved 221pt
    // out of ~33 000, i.e. the rows were never realised and the numbers
    // (1.4ms vs 1.9ms for forty steps) were measuring an empty loop. It also
    // cannot see compositing, which is where a scroll actually spends.
    //
    // A benchmark that reports a number for work it did not do is worse than
    // no benchmark: it will be cited. The scroll path is covered where it can
    // be driven honestly — `LongThreadScrollUITests` flicks the real app and
    // reads CPU, memory and realised-row counts off it.

    // MARK: - Cold open

    /// Opening a long thread. Pinned separately from the 60-message cold render
    /// already in PerformanceBenchmarks so the long-thread case has its own
    /// number rather than being extrapolated.
    func testConversationColdRender_200Messages() {
        let messages = Self.fixtureMessages(200)
        let llm = ChatGeneration()
        let settings = AppSettings()
        measure {
            let controller = UIHostingController(
                rootView: ConversationView(messages: messages, threadID: UUID(), generatingThreadID: nil)
                    .environment(llm)
                    .environment(settings))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date())
            window.layoutIfNeeded()
            window.isHidden = true
        }
    }
}

#endif
