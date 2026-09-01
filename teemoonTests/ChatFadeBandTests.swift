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
                    == 118 + ChatGlassFade.topApproach)
        #expect(chrome.topOverlayHeight(titleMaxYInCanvas: 96)
                    == 96 + ChatGlassFade.topApproach)
        #expect(chrome.topOverlayHeight(titleMaxYInCanvas: 0) == 0)
        #expect(chrome.topOverlayHeight(titleMaxYInCanvas: 0.4) == 0)
    }

    @Test func theTallerOfHostAndMeasuredTitleIsTheOverlay() {
        let chrome = ChatChrome(topInset: 130, bottom: band)
        #expect(chrome.topChromeHeight(titleMaxYInCanvas: 96) == 130)
        #expect(chrome.topOverlayHeight(titleMaxYInCanvas: 140)
                    == 140 + ChatGlassFade.topApproach)
    }

    /// The dim RUNS OUT BELOW THE TITLE, it does not stop on its edge.
    ///
    /// This reverses `fc2e18b`'s rule that the first body line under the
    /// header is full brightness. That was fine while whatever sat there
    /// was arbitrary; the anchor now parks the prompt at
    /// `U.minY - topFade`, so there is always body text on that boundary
    /// and it read as the previous reply colliding with the header
    /// (measured 147/255 at the title's edge on the capture fixture).
    ///
    /// The two bounds below are the ones that stay: never an opaque
    /// shelf, never a hard edge. Both were tried on device and reverted.
    @Test func theGlassTopFadeRunsOutBelowTheTitle_notOnItsEdge() {
        // A run-out, not a body-line band: 64pt was rejected for that.
        #expect(ChatGlassFade.topApproach > 16)
        #expect(ChatGlassFade.topApproach < 40)
        let stops = ChatGlassFade.topStops(titleHeight: 118)
        #expect(stops.first?.dim ?? 1 < 0.85)   // never the opaque shelf
        #expect(stops.first?.blur ?? 0 > 0.5)
        #expect(stops.last?.dim == 0)           // never a hard edge
        #expect(stops.last?.blur == 0)
        #expect(stops.allSatisfy { $0.dim < 1 })
        // Still substantially dimmed where the title ends — this is the
        // assertion that changed, and the whole point of the change.
        let titleEnd = stops.first { abs($0.location - 118 / (118 + ChatGlassFade.topApproach)) < 0.02 }
        #expect((titleEnd?.dim ?? 0) > 0.3)
        #expect((titleEnd?.dim ?? 1) < 0.6)
        // The peak sits under the title, and every stop after it falls.
        let dims = stops.map(\.dim)
        #expect(dims.max() == dims[1])
        #expect(dims[1] > dims[2] && dims[2] > dims[3])
        #expect(dims.dropLast().allSatisfy { $0 > 0 })
        let throughTitle = stops.first { $0.location > 0.4 && $0.location < 0.8 }
        #expect((throughTitle?.dim ?? 0) > 0.5)
    }

    /// Fade starts above the chip so the last line dissolves into the
    /// glass. From the chip down, dim is high enough that body text is
    /// not a second sentence on the capsules.
    @Test func theGlassBottomFadeStartsAboveTheChip_andDoesNotEatTheAnswer() {
        #expect(ChatGlassFade.bottomApproach > 0)
        let stops = ChatGlassFade.bottomStops(ramp: band.ramp, hidden: band.hidden, home: 34)
        #expect(stops.first?.dim == 0)
        #expect(stops.first?.blur == 0)
        #expect(stops.last?.dim ?? 0 > 0.9)
        #expect(stops.last?.dim ?? 1 < 1)
        #expect(band.overlayHeight() == ChatGlassFade.bottomApproach + band.total)
        let onChip = stops.first { $0.location > 0.2 && $0.dim > 0.8 }
        #expect(onChip != nil, "dim must jump once the overlay reaches the chip")
    }
}
