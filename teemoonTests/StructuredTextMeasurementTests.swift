//
//  StructuredTextMeasurementTests.swift
//  teemoonTests
//
//  THE FIRST SIZE A RENDERED REPLY REPORTS MUST BE ITS REAL ONE.
//
//  Reported as "scrolling is janky because of Textual resizing". The mechanism:
//  upstream `StructuredText` parsed its markdown into `@State` from
//  `.onChange(initial: true)` — which runs when the view APPEARS, after the
//  layout system has already asked how big it is. Every row therefore measured
//  an empty document first and its real height a frame later, so a scroll
//  through a thread was a stream of self-sizing corrections, each one moving
//  `contentSize` under the drag. (The same hole is why the hand-off needed a
//  re-measure: a 3,801pt reply came back as 83pt.)
//
//  Both halves are pinned here: the parse happens before the first measurement
//  (the vendored patch), and it happens ONCE per distinct string however many
//  times the row is rebuilt (`CachedMarkdownParser`).
//

#if os(iOS)

import XCTest
import SwiftUI
import Textual
@testable import teemoon

@MainActor
final class StructuredTextMeasurementTests: XCTestCase {

    private let width: CGFloat = 360

    /// Block-level content, so the structured renderer is what measures it.
    private let reply = """
        ## What the attestation proves

        The quote binds three things, and the binding is the whole point:

        - the measurement of the code that booted
        - the public key the enclave will sign with
        - a nonce your device chose, so the answer cannot be replayed

        ```swift
        let quote = try TDXQuote(parsing: report)
        guard quote.reportData == expected else { throw Err.mismatch }
        ```

        | Layer | Attested by |
        | --- | --- |
        | gateway | its own TEE |
        | model host | the GPU node |

        > None of it means anything if the transport ends somewhere else.

        \(String(repeating: "A paragraph of ordinary prose that wraps across several lines on a phone. ", count: 12))
        """

    private func firstMeasuredHeight(of view: some View) -> CGFloat {
        let host = UIHostingController(rootView: AnyView(view.frame(width: width)))
        // Measured WITHOUT a window and without a runloop turn: nothing has
        // appeared, so anything deferred to `onAppear`/`onChange` has not run.
        return host.sizeThatFits(in: CGSize(width: width,
                                            height: UIView.layoutFittingExpandedSize.height)).height
    }

    private func settledHeight(of view: some View) -> CGFloat {
        let host = UIHostingController(rootView: AnyView(view.frame(width: width)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<4 { window.layoutIfNeeded(); RunLoop.main.run(until: Date()) }
        return host.sizeThatFits(in: CGSize(width: width,
                                            height: UIView.layoutFittingExpandedSize.height)).height
    }

    func testTheFirstMeasurementIsTheRealHeightNotAnEmptyDocument() {
        let height = firstMeasuredHeight(of: StructuredText.cached(reply))
        // The fixture is a page and a half of blocks at 360pt wide. Before the
        // patch this measured an empty document — tens of points, not hundreds.
        XCTAssertGreaterThan(height, 600,
                             "StructuredText measured before its markdown was parsed")
    }

    /// The measurement must also be CLOSE TO FINAL: a row that measures
    /// correctly and then changes its mind still moves the content under a
    /// drag. Not exact, and the tolerance is not a fudge — a hosted view
    /// measures a little taller once it is in a window (a plain SwiftUI `Text`
    /// shows the same delta), and Textual still resolves table columns a
    /// pass late when Overflow's container width is nil. Those are worth
    /// points; the bug this pins was worth the whole reply.
    func testTheFirstMeasurementIsWithinAFractionOfTheSettledOne() {
        // A hosted view measures taller once it is in a window whatever it
        // contains, so a plain `Text` is the control that separates the
        // harness's delta from Textual's.
        let control = Text(String(repeating: "wrapping prose line. ", count: 200))
        let harness = settledHeight(of: control) - firstMeasuredHeight(of: control)

        let first = firstMeasuredHeight(of: StructuredText.cached(reply))
        let settled = settledHeight(of: StructuredText.cached(reply)) - harness
        XCTAssertEqual(first / settled, 1, accuracy: 0.08,
                       "first measurement \(first) is not close to the settled \(settled)")
    }

    func testTheSameReplyIsParsedOnceHoweverManyTimesItIsRendered() throws {
        // Unique per run so a warm cache from another test cannot mask a miss.
        let markdown = "## \(UUID().uuidString)\n\n- one\n- two\n\n```\ncode\n```\n"
        let before = CachedMarkdownParser.parseCount
        for _ in 0..<8 {
            _ = firstMeasuredHeight(of: StructuredText.cached(markdown))
        }
        XCTAssertEqual(CachedMarkdownParser.parseCount - before, 1,
                       "the transcript re-parsed markdown it had already parsed")
    }

    /// Closing `[label](url` into a real link used to shrink the row: the
    /// raw syntax is longer than the label, often by a wrapped line. The
    /// streaming tail must already be showing the label, so adding `)` is
    /// not a vertical resize.
    func testClosingAStreamedLinkDoesNotShrinkTheView() {
        let prefix = "See the "
        let link = "[documentation](https://example.com/very/long/path/that/wraps)"
        var previous: CGFloat = 0
        for end in 1...link.count {
            let markdown = prefix + String(link.prefix(end))
            let height = firstMeasuredHeight(of: StreamingMarkdownView(content: markdown))
            XCTAssertGreaterThanOrEqual(
                height, previous - 8,
                "stream shrank from \(previous) to \(height) at prefix \(end): \(markdown)")
            previous = max(previous, height)
        }
    }

    /// A GFM header without a delimiter row is a wrapping paragraph; with
    /// one it is a one-row table. The tail stabilizer injects the delimiter
    /// so those two states measure the same.
    func testStreamingTableHeaderDoesNotCollapseWhenDelimiterArrives() {
        let header = "| Layer | Attested by | Bound to |\n"
        let withDelimiter = header + "| --- | --- | --- |\n"
        let before = firstMeasuredHeight(of: StreamingMarkdownView(content: header))
        let after = firstMeasuredHeight(of: StreamingMarkdownView(content: withDelimiter))
        XCTAssertEqual(before, after, accuracy: 8,
                       "table header \(before) collapsed to \(after) when the delimiter arrived")
    }
}

#endif
