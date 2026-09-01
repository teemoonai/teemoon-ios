import Foundation
import Testing
@testable import teemoon

/// Pins the trailing activity chip's visibility rule.
///
/// The rule was regressed once already, silently: 047e4fc removed
/// `scrollInterrupted` from the decision (hiding a progress indicator from a
/// user who scrolled away to wait is backwards), and 47ef09b re-added it by
/// accident while moving the chip back inline — leaving the doc comment and
/// the code in contradiction for four days. During a second web-search round
/// on a real DeepSeek generation the transcript legitimately sits still for
/// 10+ seconds; the chip is the only thing on screen saying teemoon is still
/// working, and any spurious `scrollInterrupted` latch (or an anxious poke at
/// an apparently frozen screen) removed it exactly then.
///
/// The rule is now a pure function whose signature IS the contract: text on
/// screen plus some form of unshown work. Scroll state is not an input.
@Suite("Trailing activity chip visibility")
struct TrailingChipVisibilityTests {

    /// The three work signals each show the chip on their own, text permitting.
    @Test func eachWorkSignalShowsTheChip() {
        #expect(StreamingMessageView.trailingChipVisible(
            hasText: true, stalled: true, executingTools: false, awaitingModel: false))
        #expect(StreamingMessageView.trailingChipVisible(
            hasText: true, stalled: false, executingTools: true, awaitingModel: false))
        #expect(StreamingMessageView.trailingChipVisible(
            hasText: true, stalled: false, executingTools: false, awaitingModel: true))
    }

    /// No text means the LEADING chip owns the job — the trailing slot stays out.
    @Test func noTextMeansNoTrailingChip() {
        #expect(!StreamingMessageView.trailingChipVisible(
            hasText: false, stalled: true, executingTools: true, awaitingModel: true))
    }

    /// Streaming normally — text flowing, no stall, no tools, no wait — shows
    /// nothing: the growing text is its own progress indicator.
    @Test func steadyStreamingShowsNoChip() {
        #expect(!StreamingMessageView.trailingChipVisible(
            hasText: true, stalled: false, executingTools: false, awaitingModel: false))
    }

    /// THE REGRESSION GUARD. The second tool round of a real generation: text
    /// already on screen, tool executing or follow-up turn in flight. The chip
    /// must be visible — and the function's signature offers no scroll input
    /// with which to hide it. Re-adding one cannot be done without changing
    /// this call site, which is the point.
    @Test func secondToolRoundIsAlwaysCovered() {
        // Tool executing, then awaiting the follow-up turn — the two phases of
        // the measured 13.7s dark window.
        #expect(StreamingMessageView.trailingChipVisible(
            hasText: true, stalled: false, executingTools: true, awaitingModel: false))
        #expect(StreamingMessageView.trailingChipVisible(
            hasText: true, stalled: true, executingTools: false, awaitingModel: true))
    }
}
