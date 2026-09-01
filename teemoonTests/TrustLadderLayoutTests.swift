//
//  TrustLadderLayoutTests.swift
//  teemoonTests
//
//  Pins the attestation sheet's section stack as EAGER.
//
//  2026-08-25: at the expert rung, scrolling down toward the self-verify
//  script made the offset lurch, and once wedged the main thread for 1,075 s
//  inside a single `flushTransactions` that never converged (533 hang-reporter
//  samples, all in SwiftUI layout, no app frames). Cause: the section stack was
//  a `LazyVStack` (added as a first-render optimisation), which estimates the height of
//  every off-screen section and revises it on realization. These sections vary
//  far too much for that — the last one is a 300 pt window onto a ~600-line
//  script — so the content height moved under the scroll on the way down.
//
//  The invariant below is what a LazyVStack cannot satisfy and an eager stack
//  gets for free: the same document measures the same height regardless of the
//  viewport it is opened into. MEASURED at the expert rung, 393pt wide:
//
//      LazyVStack   240pt viewport -> 1308pt content   852pt -> 2391pt
//      VStack       240pt viewport -> 2391pt content   852pt -> 2391pt
//
//  That 1083pt disagreement is the jump: it is resolved by scrolling, under
//  the reader's finger. Two earlier versions of this test asserted stability
//  across layout passes and across a scroll-to-end instead; BOTH PASSED under
//  the LazyVStack, because a hosted window realizes every row and never
//  estimates. Only varying the viewport reproduces it off-device.
//

// UIKit-hosted (UIWindow/UIHostingController) — no macOS equivalent.
#if canImport(UIKit)

import XCTest
import SwiftUI
@testable import teemoon

@MainActor
final class TrustLadderLayoutTests: XCTestCase {

    /// Depth-first search for the sheet's scroll view.
    private func scrollView(in root: UIView) -> UIScrollView? {
        if let scroll = root as? UIScrollView { return scroll }
        for sub in root.subviews {
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }

    private func settle(_ window: UIWindow) {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date())
        window.layoutIfNeeded()
    }

    /// Host the sheet at an explicit viewport height.
    private func host(rung: TrustRung, height: CGFloat,
                      session: ConfidentialSession, store: ProviderStore) -> UIWindow {
        let host = UIHostingController(
            rootView: NavigationStack { TrustLadderView(initialRung: rung) }
                .environment(session)
                .environment(store))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: height))
        window.rootViewController = host
        window.makeKeyAndVisible()
        settle(window)
        return window
    }

    /// THE VIEWPORT MUST NOT DECIDE THE DOCUMENT. An eager stack measures every
    /// section, so the content height is the same whether the sheet is opened
    /// tall or short. A `LazyVStack` realizes only what a short viewport needs
    /// and estimates the rest, so the two disagree — and that difference is
    /// exactly what moved under the scroll on the way to the script.
    func testContentHeightDoesNotDependOnViewportHeight() throws {
        let (session, store) = PerformanceBenchmarks.offlineVerifiedSession()

        let tall = host(rung: .expert, height: 852, session: session, store: store)
        defer { tall.isHidden = true }
        let tallHeight = try XCTUnwrap(scrollView(in: tall)).contentSize.height

        let (session2, store2) = PerformanceBenchmarks.offlineVerifiedSession()
        let short = host(rung: .expert, height: 240, session: session2, store: store2)
        defer { short.isHidden = true }
        let shortHeight = try XCTUnwrap(scrollView(in: short)).contentSize.height

        XCTAssertGreaterThan(tallHeight, 852, "expert rung should exceed one viewport")
        XCTAssertEqual(shortHeight, tallHeight, accuracy: 1,
                       "content height depends on viewport (\(shortHeight) vs "
                       + "\(tallHeight)) — the section stack is estimating again")
    }
}

#endif
