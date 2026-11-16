import CoreGraphics
import Foundation
import Testing
@testable import teemoon

/// The chat's bottom edge has been got wrong three separate ways, each time in a
/// manner no preview could show (they render without a keyboard) and no test
/// could catch (the arithmetic lived inline in a `mask` builder). These pin all
/// three failures.
///
/// Geometry is the real thing, measured on an iPhone 17 Pro: a 132pt inset,
/// 16pt of padding above a 44pt chip, an 8pt gap, then the 48pt composer.
@Suite("Chat bottom fade band")
struct ChatFadeBandTests {

    private let inset: CGFloat = 132
    private let chipTop: CGFloat = 16
    private let chipBottom: CGFloat = 60      // 16 + 44
    private var band: ChatFadeBand {
        ChatFadeBand(chipTop: chipTop, chipBottom: chipBottom, insetHeight: inset)
    }

    // MARK: - Regression 1: text bleeding through the gap between the capsules

    /// THE recurring bug. The gap sits ~40% along a ramp stretched over the whole
    /// inset, which with a 0.2 plateau leaves it ~78% opaque — plainly readable
    /// between the two capsules.
    @Test func theGapBetweenChipAndComposerIsFullyHidden() {
        for offset in stride(from: chipBottom, through: chipBottom + 8, by: 1.0) {
            #expect(band.alpha(atOffsetFromInsetTop: offset) == 0,
                    "transcript visible \(offset - chipBottom)pt into the chip/composer gap")
        }
    }

    /// Nothing below the chip may show at all — gap, composer, or the padding
    /// under it. Anything partially visible there is text on top of chrome.
    @Test func nothingBelowTheChipIsEverPartiallyVisible() {
        for offset in stride(from: chipBottom, through: inset, by: 0.5) {
            #expect(band.alpha(atOffsetFromInsetTop: offset) == 0,
                    "transcript visible at \(offset)pt, below the chip")
        }
    }

    // MARK: - Regression 2: the dissolve starting above the chip

    /// Sizing the band to the whole inset put its top above the chip, so text
    /// began dissolving into empty background ~40pt before it reached anything.
    @Test func nothingAboveTheChipFades() {
        for offset in stride(from: -200, through: chipTop, by: 1.0) {
            #expect(band.alpha(atOffsetFromInsetTop: offset) == 1,
                    "transcript dimmed at \(offset)pt, above the chip")
        }
    }

    @Test func theDissolveIsGradual_notAHardEdge() {
        // A hard cut slices glyphs; that treatment was tried and reverted. The
        // ramp must actually ramp.
        let quarter = band.alpha(atOffsetFromInsetTop: chipTop + band.ramp * 0.4)
        let half = band.alpha(atOffsetFromInsetTop: chipTop + band.ramp * 0.6)
        let most = band.alpha(atOffsetFromInsetTop: chipTop + band.ramp * 0.9)
        #expect(quarter > half)
        #expect(half > most)
        #expect(most > 0)
    }

    // MARK: - Regression 3: overflowing the mask's container

    /// The mask stacks `total` beneath a FLEXIBLE spacer. If it ever exceeds the
    /// container the spacer collapses to zero, the stack overflows and centres,
    /// and the band is drawn far above the chrome — which is what happened with
    /// the keyboard up, when a keyboard-height spacer was added on top of a
    /// container that had already shrunk by the keyboard.
    @Test func theBandNeverOutgrowsTheChromeItCovers() {
        #expect(band.total == inset - chipTop)
        #expect(band.total <= inset)
    }

    /// The measured keyboard-up case: a 291pt container must still fit the band.
    @Test func theBandFitsTheKeyboardUpContainer() {
        #expect(band.total <= 291)
    }

    // MARK: - Regression 4: the band must land ON the chrome (CURRENTLY FAILING)

    /// **This test fails, and should.** It is the bug that is on the phone.
    ///
    /// RESOLVED, and retired deliberately rather than weakened.
    ///
    /// This asserted that the SCROLL MASK covers the chrome, and failed because
    /// it cannot: the mask is laid out in the scroll view's bounds, measured at
    /// global `[116 … 407]`, while the chrome occupies `[407 … 539]`. The mask
    /// ends exactly where the chrome begins. No arithmetic on the band could
    /// have fixed that — the requirement was aimed at the wrong object.
    ///
    /// Its own note said so, and named the fix: "the container has to change
    /// (an explicit frame spanning the chrome, or A GRADIENT OVERLAY DRAWN FROM
    /// INSIDE THE INSET instead of a mask on the scroll view)". The second
    /// option now ships — `ChatView`'s `safeAreaInset` carries a
    /// `systemBackground` gradient, clear over its top 40% so text dissolves
    /// rather than being sliced by a hard edge, opaque behind the capsules.
    ///
    /// So the chrome is covered, and it is not this type's job. What remains
    /// testable here is the band's own contract, which the tests above already
    /// cover. Verified on device: a photo showed an answer running straight
    /// through both chips, and the same question on the same phone now shows
    /// them on clean background.
    ///
    /// Kept as a comment rather than deleted because the failure it recorded —
    /// a mask that cannot reach what it is asked to hide — is the kind of thing
    /// that gets reintroduced by someone "simplifying" the inset's background
    /// away. That background is load-bearing.

    // MARK: - Degenerate geometry

    @Test func aZeroHeightChipStillHidesEverythingBelowIt() {
        let collapsed = ChatFadeBand(chipTop: 16, chipBottom: 16, insetHeight: 132)
        #expect(collapsed.ramp == 0)
        #expect(collapsed.alpha(atOffsetFromInsetTop: 16) == 0)
        #expect(collapsed.alpha(atOffsetFromInsetTop: 15) == 1)
    }

    @Test func nonsenseOrderingIsClamped_notNegative() {
        // A geometry read can arrive before layout settles.
        let backwards = ChatFadeBand(chipTop: 90, chipBottom: 20, insetHeight: 10)
        #expect(backwards.ramp >= 0)
        #expect(backwards.hidden >= 0)
        #expect(backwards.total >= 0)
    }

    // MARK: - The UIKit transcript's home-indicator shift

    /// The collection view ignores the container's bottom safe area so it can
    /// run behind the composer. That also extends it through the home
    /// indicator. The mask is laid out in those full bounds: if it still
    /// parks `hidden` against the screen bottom, the ramp sits 34pt too low
    /// and text runs through the chips. Passing the indicator as extra
    /// bottom clear puts the ramp back on the chip.
    @Test func theRampLandsOnTheChipWhenTheContainerIncludesTheHomeIndicator() {
        let home: CGFloat = 34
        let screen: CGFloat = 874
        let chromeTop = screen - home - inset
        let expectedRamp = (chromeTop + chipTop)...(chromeTop + chipBottom)
        #expect(band.rampRange(inContainerOfHeight: screen, homeIndicator: home)
                    == expectedRamp)
        #expect(band.hiddenRange(inContainerOfHeight: screen, homeIndicator: home)
                    .lowerBound == chromeTop + chipBottom)
    }

    /// Keyboard up: the collection view has already shrunk and the indicator
    /// is gone. Extra clear would push the ramp up into empty background —
    /// the overflow that ate the last lines above the keyboard.
    @Test func noHomeIndicatorKeepsTheRampOnTheChrome() {
        let container: CGFloat = 291
        // A short container still has to place the ramp at its own bottom,
        // not 34pt above it.
        let range = band.rampRange(inContainerOfHeight: container, homeIndicator: 0)
        #expect(range.upperBound == container - band.hidden)
    }

    @Test func navOverlapIsTheTitleBand_notABandOnTheFirstBodyLine() {
        let chrome = ChatChrome(bottom: band)
        #expect(chrome.navOverlap(safeAreaTop: 96) == 96)
        #expect(chrome.navOverlap(safeAreaTop: 0) == 0)
        let explicit = ChatChrome(topInset: 96, bottom: band)
        #expect(explicit.navOverlap(safeAreaTop: 0) == 96)
    }

    /// One-line test titles and the two-line e2ee header are different
    /// heights. The overlay is the measured title plus the approach
    /// below it, never `statusBar + 48/54/56`.
    @Test func topOverlayIsTheMeasuredTitle_notStatusPlusAConstant() {
        let chrome = ChatChrome(bottom: band)
        #expect(chrome.topChromeHeight(titleMaxYInCanvas: 118) == 118)
        #expect(chrome.topOverlayHeight(titleMaxYInCanvas: 118)
                    == 118 - ChatGlassFade.topLift + ChatGlassFade.topApproach)
        #expect(chrome.topOverlayHeight(titleMaxYInCanvas: 96)
                    == 96 - ChatGlassFade.topLift + ChatGlassFade.topApproach)
        #expect(chrome.topOverlayHeight(titleMaxYInCanvas: 0) == 0)
        #expect(chrome.topOverlayHeight(titleMaxYInCanvas: 0.4) == 0)
    }

    @Test func theTallerOfHostAndMeasuredTitleIsTheOverlay() {
        let chrome = ChatChrome(topInset: 130, bottom: band)
        #expect(chrome.topChromeHeight(titleMaxYInCanvas: 96) == 130)
        #expect(chrome.topOverlayHeight(titleMaxYInCanvas: 140)
                    == 140 - ChatGlassFade.topLift + ChatGlassFade.topApproach)
    }

    /// No grey anywhere around the bars (the maintainer 2026-11-14: "i dont want to see word shapes behind the title bar", "i
    /// dont like the gray"): no material, no tint; behind the status row and title the transcript fades to the page's
    /// own black, at most about 8/255 for white text.
    @Test func theTopFadesToBlack_noBlurNoTint() {
        let stops = ChatGlassFade.topStops(titleHeight: 106)
        let held = (106 - ChatGlassFade.topLift) / (106 - ChatGlassFade.topLift + ChatGlassFade.topApproach)
        #expect(stops.allSatisfy { $0.blur == 0 })
        // Fully black: at 0.97 white text still read on an OLED black (review of the stills, 2026-11-14).
        #expect(stops.filter { $0.location <= held + 0.0001 }.allSatisfy { $0.dim == 1 })
    }

    /// Nothing legible touches the bar (the maintainer 2026-11-14: "the chat text touches the round buttons"), and no wide
    /// empty strip under it (the maintainer 2026-11-14: about 45 pt was too much; then, after 2 + 10 pt, "the space just needs to
    /// be a little smaller"). The run-out starts 6 pt above the bar's measured bottom, under the subtitle and inside the
    /// circles' lower edge, and runs 10 pt.
    @Test func textClearsTheButtons() {
        let title: CGFloat = 106
        let start = title - ChatGlassFade.topLift
        let h = start + ChatGlassFade.topApproach
        let stops = ChatGlassFade.topStops(titleHeight: title)
        #expect(ChatGlassFade.topLift == 6)
        #expect(ChatGlassFade.topApproach == 10)
        #expect(stops.filter { $0.location <= start / h + 0.0001 }.allSatisfy { $0.dim == 1 })
        #expect(stops.contains { abs($0.location - start / h) < 0.001 && $0.dim == 1 })
        #expect(stops.last?.dim == 0 && stops.last?.blur == 0)
        #expect(ChatChrome(topInset: 0, bottom: band).topOverlayHeight(titleMaxYInCanvas: title) == 110)
    }

    /// Text runs at full strength until 14 pt above the panel, then fades into its edge; beside and below the panel
    /// it is the page's own black, no blur and no grey (the maintainer 2026-11-14: "i want black around the composer").
    @Test func textRunsToThePanel_andTheSurroundIsBlack() {
        #expect(ChatGlassFade.bottomApproach == 14)
        let stops = ChatGlassFade.bottomStops(ramp: band.ramp, hidden: band.hidden, home: 34)
        #expect(stops.first?.dim == 0)
        #expect(stops.allSatisfy { $0.blur == 0 })
        #expect(band.overlayHeight() == ChatGlassFade.bottomApproach + band.total)
        let h = ChatGlassFade.bottomApproach + band.ramp + band.hidden + 34
        let fromThePanel = stops.filter { $0.location >= ChatGlassFade.bottomApproach / h - 0.0001 }
        #expect(!fromThePanel.isEmpty)
        #expect(fromThePanel.allSatisfy { $0.dim == 1 })
    }

    /// The panel is a tinted surface over its glass (the maintainer 2026-11-14: "85 is fine"), between Claude's opaque
    /// composer and Grok's clear glass.
    @Test func thePanelFillIs85Percent() {
        #expect(ChatGlassFade.panelFill == 0.85)
    }

    /// Under the glass only, a clear panel-shaped hole: the panel's Liquid Glass alone blurs the transcript to shapes
    /// (the maintainer 2026-11-13). An extra frost there measured as a darkened panel (spread 1.3-2.9 against 4.1-5.8 clear,
    /// sharpness under 1.3 either way; tools/measure_glass_showthrough.py, iPhone 17 Pro sim, 2026-11-14).
    /// The hole is the panel's measured frame: with the keyboard up the panel sat at x 20, width 362, and a fixed 16 pt
    /// inset left 4 pt strips of transcript showing at its edges (review, 2026-11-14).
    @Test func theHoleFollowsTheMeasuredPanel() {
        let up = ChatFadeBand(chipTop: band.chipTop, chipBottom: band.chipBottom, insetHeight: band.insetHeight,
                              chipMinX: 20, chipWidth: 362)
        let hole = ChatGlassFade.panelHole(overlayWidth: 402, band: up, reduceTransparency: false)
        #expect(hole?.minX == 20)
        #expect(hole?.width == 362)
    }

    @Test func thePanelIsAClearHole() {
        let hole = ChatGlassFade.panelHole(overlayWidth: 402, band: band, reduceTransparency: false)
        #expect(hole == CGRect(x: 16, y: ChatGlassFade.bottomApproach, width: 370, height: band.ramp))
        #expect(ChatGlassFade.panelCornerRadius == 30)
    }

    /// At accessibility text sizes the glass's fixed blur leaves glyphs readable (AX5 sim, 2026-11-14: "the loaf"
    /// behind the panel; sharpness 44 at the glyph scale). Then the hole holds the band's full blur; at other sizes
    /// it stays clear.
    @Test func largeTextFrostsThePanel() {
        #expect(ChatGlassFade.panelFrost(accessibilityText: false) == nil)
        let frost = ChatGlassFade.panelFrost(accessibilityText: true)
        #expect(frost?.blur == 1)
        #expect((frost?.dim ?? 1) <= 0.3)
    }

    /// The fade reserves the home indicator only where it lies inside the view. With the keyboard up the view ends
    /// at the keyboard, and reserving 34 pt anyway put the panel's hole 34 pt too high: a full-brightness line of
    /// the transcript sat just above the panel (iPhone 17 Pro sim, keyboard up, 2026-11-14).
    @Test func theHomeIndicatorCountsOnlyInsideTheView() {
        #expect(ChatGlassFade.homeIndicatorInView(safeAreaBottom: 34, gapBelowView: 0) == 34)
        #expect(ChatGlassFade.homeIndicatorInView(safeAreaBottom: 34, gapBelowView: 336) == 0)
        #expect(ChatGlassFade.homeIndicatorInView(safeAreaBottom: 34, gapBelowView: 10) == 24)
        #expect(ChatGlassFade.homeIndicatorInView(safeAreaBottom: 0, gapBelowView: 0) == 0)
    }

    /// Reduce Transparency: the panel is opaque again, so no hole.
    @Test func reduceTransparencyLeavesNoHole() {
        #expect(ChatGlassFade.panelHole(overlayWidth: 402, band: band, reduceTransparency: true) == nil)
    }
}
