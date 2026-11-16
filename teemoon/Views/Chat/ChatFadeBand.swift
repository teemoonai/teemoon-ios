//
//  ChatFadeBand.swift
//  teemoon
//
//  The shape of the mask that dissolves the transcript into the chat's bottom
//  chrome. Split out of the view because this edge has been got wrong three
//  separate ways, each time in a manner no preview and no unit test could see —
//  so the arithmetic now lives somewhere `ChatFadeBandTests` can assert on it.
//

import CoreGraphics

/// Where the SwiftUI transcript's mask (`chatBottomScrollFade`) fades inside the chat's bottom inset. The UIKit
/// transcript's glass bars are `ChatGlassFade` below, which shows the transcript softly under the panel instead.
///
/// All offsets are measured DOWN FROM THE TOP OF THE INSET, which is the space
/// the geometry reader in `ChatView` reports in.
///
/// The inset holds two floating capsules with a gap between them:
///
///     ─────────────────────  0            inset top
///        (padding)
///     ┌───────────────────┐  chipTop      ← nothing above here may fade
///     │   Where chip      │
///     └───────────────────┘  chipBottom
///        (gap)                            ← text bled through HERE
///     ┌───────────────────┐
///     │   composer        │
///     └───────────────────┘
///        (padding)
///     ─────────────────────  insetHeight
///
/// The mask is therefore three regions, not two:
///
/// * **opaque** above `chipTop` — the transcript is untouched until it reaches
///   something to hide behind. A band that starts higher dissolves text into
///   empty background.
/// * **ramp** across the chip — a gradient, so the dissolve reads as depth
///   rather than as a hard edge slicing glyphs.
/// * **hidden** from `chipBottom` down — fully masked, *including the gap*.
///
/// The third region is the whole point. A single ramp spanning the inset leaves
/// the gap between the capsules around 78% opaque, which is exactly legible: the
/// recurring "text bleeds through between the chip and the composer". Nothing
/// below the chip is ever partially visible, because everything below the chip
/// is either a capsule, a gap between capsules, or padding under them — and the
/// transcript has no business showing in any of those.
struct ChatFadeBand: Equatable {
    /// Top edge of the Where chip, from the top of the inset.
    let chipTop: CGFloat
    /// Bottom edge of the Where chip, from the top of the inset.
    let chipBottom: CGFloat
    /// Full height of the inset (note + chip + composer + padding).
    let insetHeight: CGFloat

    /// The panel's left edge and width in the inset (= overlay) width; nil width: the 16 pt gutters.
    let chipMinX: CGFloat
    let chipWidth: CGFloat?

    init(chipTop: CGFloat, chipBottom: CGFloat, insetHeight: CGFloat, chipMinX: CGFloat = 16, chipWidth: CGFloat? = nil) {
        self.chipTop = max(chipTop, 0)
        self.chipBottom = max(chipBottom, self.chipTop)
        self.insetHeight = max(insetHeight, self.chipBottom)
        self.chipMinX = chipMinX
        self.chipWidth = chipWidth.flatMap { $0 > 1 ? $0 : nil }
    }

    /// Height of the gradient — the chip's own height.
    var ramp: CGFloat { chipBottom - chipTop }

    /// Height of the fully-masked region below the ramp: the gap, the composer,
    /// and the padding under it.
    var hidden: CGFloat { insetHeight - chipBottom }

    /// Total height the mask must reserve at the bottom of its container.
    ///
    /// Load-bearing: the mask stacks this beneath a flexible spacer, so if it
    /// ever exceeds the container the spacer collapses to zero and the whole
    /// stack overflows and centres — which drew the band ~160pt too high with
    /// the keyboard up. `ChatFadeBandTests` pins it to the chrome's real span.
    var total: CGFloat { ramp + hidden }

    /// Mask alpha at `offset` points below the top of the inset: 1 shows the
    /// transcript, 0 hides it.
    ///
    /// Negative offsets are above the inset entirely (the live transcript).
    func alpha(atOffsetFromInsetTop offset: CGFloat) -> Double {
        // Hiding is checked FIRST so it wins any tie. With a degenerate
        // (zero-height) chip the two boundaries coincide, and the safe reading
        // of "is this point behind chrome?" is yes — leaking text over the
        // composer is the failure that keeps getting reported, not over-hiding.
        if offset >= chipBottom { return 0 }
        if offset <= chipTop { return 1 }
        guard ramp > 0 else { return 0 }
        let travelled = Double((offset - chipTop) / ramp)
        // Full opacity through the first fifth so the dissolve starts at the
        // chip rather than just before it, then linear to nothing.
        guard travelled > Self.plateau else { return 1 }
        return 1 - (travelled - Self.plateau) / (1 - Self.plateau)
    }

    /// Fraction of the ramp held at full opacity before the gradient starts.
    static let plateau = 0.2

    // MARK: - Where the regions actually land

    /// The mask stacks `[flexible spacer][ramp][hidden]`, so both bands sit at
    /// the BOTTOM of whatever container the mask is laid out in. These project
    /// them into that container's coordinate space.
    ///
    /// This is the half that the alpha arithmetic above cannot check, and it is
    /// where every shipped failure has actually been: the numbers were right and
    /// the box was wrong. A band is only correct if these ranges land on the
    /// chrome, so the tests assert against a MEASURED container and chip frame
    /// rather than against the band in isolation.
    func rampRange(inContainerOfHeight height: CGFloat, homeIndicator: CGFloat = 0) -> ClosedRange<CGFloat> {
        let bottom = height - hidden - homeIndicator
        return (bottom - ramp)...bottom
    }

    func hiddenRange(inContainerOfHeight height: CGFloat, homeIndicator: CGFloat = 0) -> ClosedRange<CGFloat> {
        let top = height - hidden - homeIndicator
        return top...(height - homeIndicator)
    }

    /// Viewport overlay height, including the approach above the chip.
    /// The SwiftUI mask still uses `total` (chrome-aligned). The UIKit
    /// glass overlay is taller so the last line dissolves into the glass
    /// the way Claude's composer does, instead of staying crisp until it
    /// hits the capsule.
    func overlayHeight(homeIndicator: CGFloat = 0) -> CGFloat {
        ChatGlassFade.bottomApproach + total + homeIndicator
    }

}

/// The UIKit transcript's bars: a dim to the page's black, fully black behind the bar and around the panel (0.97 still
/// read on OLED black), and blur only for the panel's frost at accessibility sizes. Values are the maintainer's 2026-11-14 picks, tabled in docs/COMPOSER_PANEL.md.
enum ChatGlassFade {
    struct Stop: Equatable {
        var location: CGFloat
        /// Blur-mask alpha. 1 is full frost, 0 is no blur.
        var blur: CGFloat
        /// Dim alpha of `systemBackground`. Must stay below 1 — 1 is
        /// the opaque band that was tried and rejected.
        var dim: CGFloat
    }

    /// Extra height above the chip where the bottom dissolve starts.
    static let bottomApproach: CGFloat = 14

    /// The run-out starts `topLift` above the bar's measured bottom (below the subtitle, inside the circles' lower edge)
    /// and runs `topApproach`. More lift reaches the subtitle's text; less leaves an empty strip under the buttons.
    static let topLift: CGFloat = 6
    static let topApproach: CGFloat = 10

    /// Behind the status row and title the transcript fades to the page's own black: no material and no tint, so no
    /// grey (the maintainer 2026-11-14), and no word shapes. `t = 0` is the top of the screen, `t = 1` the run-out's end.
    static func topStops(titleHeight: CGFloat) -> [Stop] {
        let start = max(titleHeight - topLift, 0)
        let h = max(start + topApproach, 1)
        let held = min(max(start / h, 0), 1)
        return [
            .init(location: 0,    blur: 0, dim: 1),
            .init(location: held, blur: 0, dim: 1),
            .init(location: 1,    blur: 0, dim: 0),
        ]
    }

    /// How much of the home indicator lies inside the view: none when the view ends above it (the keyboard is up).
    static func homeIndicatorInView(safeAreaBottom: CGFloat, gapBelowView: CGFloat) -> CGFloat {
        max(safeAreaBottom - max(gapBelowView, 0), 0)
    }

    /// The composer panel's tint over its glass (the maintainer 2026-11-14: "85 is fine"); nothing reads through it.
    static let panelFill: Double = 0.85

    /// The composer panel's corner radius (docs/COMPOSER_PANEL.md spacing table).
    static let panelCornerRadius: CGFloat = 30

    /// Inside the hole, at accessibility text sizes only: the glass's own blur has a fixed radius and leaves glyphs that
    /// big readable. Nil: the hole stays clear.
    static func panelFrost(accessibilityText: Bool) -> Stop? {
        accessibilityText ? Stop(location: 0, blur: 1, dim: 0.2) : nil
    }

    /// Where the band opens for the glass: the panel's own rectangle (16 pt in from the sides, from its top edge, its
    /// height), in the overlay's coordinates. Reduce Transparency: none, the panel is opaque.
    static func panelHole(overlayWidth: CGFloat, band: ChatFadeBand, reduceTransparency: Bool) -> CGRect? {
        guard !reduceTransparency else { return nil }
        return CGRect(x: band.chipMinX, y: bottomApproach, width: band.chipWidth ?? max(overlayWidth - 32, 0), height: band.ramp)
    }

    /// Stops for a measured bottom overlay (the "chip" band is the composer panel on iOS). Text is full strength until
    /// `bottomApproach` above the panel, then fades into the page's black beside and below it: no material, no grey
    /// (the maintainer 2026-11-14, "i want black around the composer"). The panel is a clear hole under its own tinted glass.
    static func bottomStops(ramp: CGFloat, hidden: CGFloat, home: CGFloat) -> [Stop] {
        let h = max(bottomApproach + ramp + hidden + home, 1)
        let chipTop = bottomApproach / h
        let chipBottom = (bottomApproach + ramp) / h
        return [
            .init(location: 0,          blur: 0, dim: 0),
            .init(location: chipTop,    blur: 0, dim: 1),
            .init(location: chipBottom, blur: 0, dim: 1),
            .init(location: 1,          blur: 0, dim: 1),
        ]
    }
}

/// Chrome heights are inputs. The list does not guess them from
/// safe-area constants that change with Dynamic Island, a one-line
/// title, or the two-line e2ee header.
///
/// `topInset` is an optional measured title bottom from the host.
/// When it is 0 the collection view measures `chat.titleBlock` in
/// its own coordinates. `bottom` is the measured composer + chip
/// band from `ChatView`.
struct ChatChrome: Equatable {
    var topInset: CGFloat = 0
    var bottom: ChatFadeBand

    func navOverlap(safeAreaTop: CGFloat) -> CGFloat {
        topInset > 0 ? topInset : max(safeAreaTop, 0)
    }

    /// Title bottom in the canvas. Zero when the title sits above the
    /// canvas or has not been measured.
    func topChromeHeight(titleMaxYInCanvas y: CGFloat) -> CGFloat {
        let measured = max(topInset, y)
        return measured > 1 ? measured : 0
    }

    /// Overlay height is the measured title plus a short soft edge.
    /// Never a `statusBar + N` guess.
    func topOverlayHeight(titleMaxYInCanvas y: CGFloat) -> CGFloat {
        let chrome = topChromeHeight(titleMaxYInCanvas: y)
        return chrome > 1 ? max(chrome - ChatGlassFade.topLift, 0) + ChatGlassFade.topApproach : 0
    }
}
