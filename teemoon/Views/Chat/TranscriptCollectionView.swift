//
//  TranscriptCollectionView.swift
//  teemoon
//
//  THE TRANSCRIPT IS A UICOLLECTIONVIEW, AND THE REASON IS OFFSET OWNERSHIP.
//
//  Every rule in this file was paid for with a device freeze, a blank screen,
//  or rows painted over each other, and each is pinned: the follow contract by
//  `LongThreadStreamingUITests`, the hand-off hold by `TranscriptHandoffTests`,
//  first-measure resolution by `StructuredTextMeasurementTests`, and the
//  overscroll metric by the scroll-trace gates. Change behavior only with the
//  pinning test in front of you.
//
//  The one-paragraph version. `LazyVStack` ESTIMATES the height of rows it has
//  not built and revises those estimates as they realise. Under this app's
//  content variance — 30-character questions beside 7,150-character
//  table-and-link replies — the estimate swings by 10,000+ points in a single
//  step, and every mechanism built on top inherited the instability: the
//  `.sizeChanges` anchor died under it, the explicit follow chased it, the
//  row-size cache livelocked against it, and the viewport got stranded past a
//  deflating content end (597 overscrolled samples in one traced generation —
//  the blank screen). A collection view does not have this class of problem,
//  because it OWNS `contentOffset` and adjusts it in the same layout pass that
//  resolves a cell's real size. That is not a better estimate; it is the
//  absence of an estimate that anyone downstream has to trust.
//
//  macOS is deliberately NOT on this path — there is no UIKit there, it has
//  none of the reported symptoms, and `ConversationView` keeps its SwiftUI
//  ScrollView for the Mac.
//

#if os(iOS) || os(visionOS)

import SwiftUI
import UIKit

// MARK: - Sections and items

/// Two sections, and the split is load-bearing.
///
/// `.transcript` holds the persisted conversation. `.tail` holds the small
/// transient cards — the pending chip, the debug card, the error card — so a
/// tail change never diffs the message list.
///
/// THE STREAMING VIEW IS IN NEITHER, and that is the contract's rule, learned
/// the expensive way. It first lived here as a `.tail` item, on the reading
/// that a separate section counted as "outside the list". It does not: a
/// section is still the list, and a SELF-SIZING CELL invalidates
/// collection-view layout on every pacer tick. O(1) diffing is not O(1)
/// layout. Measured on `testATapMidAnswerDoesNotStopTheFollow`, the streaming
/// view in a cell kept the app non-quiescent for 34.1s of a 26s generation
/// (main: 6.1s) — and since every XCUI query waits for idle first, the suite
/// could no longer see the app at all. See `TranscriptViewController`'s
/// trailing-view mount for where it lives now.
enum TranscriptSection: Int, Hashable, CaseIterable {
    case transcript
    /// The newest message, alone, so its `.estimated` can be the hand-off
    /// seed without changing history's 120pt guess. Off-screen items keep
    /// the estimate; that is how contentH survives the first layout when
    /// the cell is not dequeued (device 2026-08-24).
    case latest
    case tail
}

func transcriptLastMessageIndexPath(in collection: UICollectionView) -> IndexPath? {
    let latest = TranscriptSection.latest.rawValue
    if collection.numberOfSections > latest, collection.numberOfItems(inSection: latest) > 0 {
        return IndexPath(item: collection.numberOfItems(inSection: latest) - 1, section: latest)
    }
    let history = TranscriptSection.transcript.rawValue
    guard collection.numberOfSections > history else { return nil }
    let count = collection.numberOfItems(inSection: history)
    guard count > 0 else { return nil }
    return IndexPath(item: count - 1, section: history)
}

func transcriptMessageFrames(in collection: UICollectionView) -> [CGRect] {
    var frames: [CGRect] = []
    for section in [TranscriptSection.transcript, .latest] {
        let index = section.rawValue
        guard collection.numberOfSections > index else { continue }
        for item in 0..<collection.numberOfItems(inSection: index) {
            if let frame = collection.layoutAttributesForItem(at: IndexPath(item: item, section: index))?.frame {
                frames.append(frame)
            }
        }
    }
    return frames
}

/// Identity for the diffable data source. Deliberately VALUE identity (ids,
/// not `Message` objects): a SwiftData `@Model` is a reference whose contents
/// change under you, and hashing one would make the diff depend on mutation
/// timing. A message's id is stable for its whole life, which is exactly what
/// a snapshot identifier is supposed to be.
enum TranscriptItem: Hashable {
    /// The "the provider never saw the turns above this" rule, drawn before
    /// the message it precedes. Keyed by that message so inserting a turn
    /// higher up moves the rule instead of recreating every one below it.
    case freshStart(before: UUID)
    case message(UUID)
    case offer(UUID)
    case pending
    /// Keyed by the turn ordinal, so the card for a new turn is a NEW item and
    /// gets a freshly built cell. A dequeued cell holds the SwiftUI view it was
    /// configured with; an identity that ignored the turn would leave the
    /// previous request's numbers on screen.
    case debugInfo(turn: Int)
    /// Keyed by the error's description for the same reason: a different
    /// failure has to redraw, and it is not worth a reconfigure path when
    /// identity already says it.
    case error(String)

    var isDebugInfo: Bool {
        if case .debugInfo = self { return true }
        return false
    }
}

// MARK: - The pinning collection view

/// A collection view that can hold itself at the end of its content, or at
/// the prompt (see `TranscriptViewport`).
///
/// THE FOLLOW LIVES IN `layoutSubviews`, AFTER `super`. Anything that writes
/// `contentOffset` outside the layout pass scrolls to a position the content
/// has not been measured into yet — the near-end flash, seen on a Release
/// build. After `super` returns, the offset lands in the same CATransaction
/// as the layout that produced it.
///
/// Keep the 40ms floor (constraint 3). Pinning on every pass moves the offset
/// on every frame, and a scroll view that never settles is one XCUI never
/// calls idle — the suite stops being able to see the app at all. The floor
/// only decides how OFTEN the pin runs, so it does not weaken the rule above.
final class PinningCollectionView: UICollectionView {

    /// How a pin-to-end should fire. Phase B only — while a reply still fits
    /// the viewport the follow anchors the prompt instead and never reaches
    /// here. See TranscriptViewport.
    enum PinMode: Equatable {
        /// Not following; leave the offset alone.
        case off
        /// A turn is streaming: hold the end, but no more than once per
        /// `minimumPinInterval` so the runloop gets to idle in between.
        case throttled
        /// A settle window (thread open, hand-off). Content is not growing, so
        /// the pin converges within a few passes and then stops on its own —
        /// throttling here would just make the landing slow, and would stall
        /// entirely under a synchronous `layoutIfNeeded` loop with no runloop
        /// to deliver a deferred retry (`ConversationScrollBenchmarks`).
        case immediate
    }

    /// Asked once per layout pass. Hold outranks pin; see TranscriptViewport.
    var viewport: (() -> TranscriptViewport)?

    /// Called after a pin actually moved the offset, so the trace can record
    /// the geometry the user is looking at rather than the one before it.
    var didPin: (() -> Void)?

    private var lastBoundsHeight: CGFloat = 0
    private var resized = false
    private var resizedLastPass = false
    private var isPinning = false
    private var lastPinTime: CFTimeInterval = 0
    private var deferredPinScheduled = false
    /// A linear follow-glide is in flight. layoutSubviews must not snap
    /// over it — that would turn every wrap back into a 22pt teleport.
    private var isGliding = false
    private var glide: FollowGlide?
    private var glideLink: CADisplayLink?

    /// The floor from constraint 3, in seconds. Worst case ~25 pins/s —
    /// invisible behind a stream, impossible to storm, and it leaves the
    /// runloop real gaps to go idle in.
    private static let minimumPinInterval: CFTimeInterval = 0.040

    /// How long a wrap-sized pin is spread across. Matches a2725d5.
    /// `UIView.animate` of `contentOffset` from `layoutSubviews` does not
    /// interpolate — the model offset jumps on the first frame — so the
    /// glide is a display link writing the lerp, then stopping.
    static let followGlideDuration: CFTimeInterval = 0.12

    /// How long a resize-driven pin takes. UIKit's keyboard animation is
    /// 0.25s; matching it by constant rather than by reading the
    /// notification keeps this to a condition on the glide that already
    /// exists, with no observer and no second animation path.
    static let resizeGlideDuration: CFTimeInterval = 0.25

    /// The offset at which the last line of content sits on the bottom edge of
    /// the viewport. Insets included: the composer is a `safeAreaInset`, so the
    /// real end of the scroll is `contentSize + bottom inset - bounds`.
    var maxContentOffsetY: CGFloat {
        let bottom = contentSize.height + adjustedContentInset.bottom - bounds.height
        return max(-adjustedContentInset.top, bottom)
    }

    /// How far the viewport is from the end, in points. Positive means there is
    /// content below the fold.
    var distanceFromEnd: CGFloat { maxContentOffsetY - contentOffset.y }

    /// Positions the trailing streaming view and sizes the space reserved for
    /// it. Runs after `super` (so `contentSize` is final) and before the pin
    /// (so the pin's target already includes it).
    var layoutTrailingView: (() -> Void)?

    /// The streaming host is a subview, not a cell, so the collection view's
    /// default accessibility container does not list it. Without this, XCUI
    /// and VoiceOver cannot see the thinking chip (or the streaming text)
    /// while a turn is in flight.
    var supplementalAccessibilityViews: [UIView] = []

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let existing = super.accessibilityElements {
                elements.append(contentsOf: existing)
            } else {
                elements.append(contentsOf: visibleCells)
            }
            for view in supplementalAccessibilityViews where view.superview != nil {
                elements.append(view)
            }
            return elements
        }
        set { super.accessibilityElements = newValue }
    }

    #if DEBUG
    /// Offset at the end of every layout pass, with whether THIS pass wrote
    /// it. `didPin` alone is blind to the offset moving without us — the
    /// scroll view's own compensation when a cell above resolves, or an
    /// inset rewrite — which is the class "it stutters while I am scrolled
    /// up" lives in.
    var didLayoutPass: ((_ offset: CGFloat, _ pinned: Bool) -> Void)?
    /// Set by EVERY write of ours, cleared when reported — deliberately NOT
    /// reset at the start of a pass. The glide writes from a display link
    /// and the deferred pin from a dispatch, both BETWEEN passes; a per-pass
    /// flag calls those "unpinned" and the instrument answers its own
    /// question wrong.
    private var wroteOffsetSinceReport = false
    #endif

    override func layoutSubviews() {
        // THE VIEWPORT RESIZED, so this pass's pin is the keyboard's, not the
        // content's. Bounds do not change while a reply streams — only the
        // keyboard, rotation and split view move them — so this cannot fire
        // on a normal follow.
        // `lastBoundsHeight > 0` excludes the FIRST layout, where the height
        // goes 0 -> full: that is a thread opening, and a thread-open snaps.
        resizedLastPass = resized
        resized = lastBoundsHeight > 0 && abs(bounds.height - lastBoundsHeight) > 0.5
        lastBoundsHeight = bounds.height
        // A run of resizes is somebody else's animation; abandon our own.
        if resized, resizedLastPass, isGliding { abandonGlide() }
        #if DEBUG
        defer {
            didLayoutPass?(contentOffset.y, wroteOffsetSinceReport)
            wroteOffsetSinceReport = false
        }
        #endif
        super.layoutSubviews()
        layoutTrailingView?()

        guard !isPinning else { return }
        switch viewport?() ?? .free {
        case .free:
            return
        case .hold(let held):
            // A HAND-OFF MUST NOT MOVE A VIEWPORT THE USER PLACED. Re-assert
            // the held offset before considering the pin: `layoutTrailingView`
            // has just resized the space the streaming view was occupying, and
            // any residual clamp lands in this pass.
            guard !isTracking, !isDragging, !isDecelerating else { return }
            let target = min(max(held, -adjustedContentInset.top), maxContentOffsetY)
            if abs(contentOffset.y - target) > 0.5 {
                isPinning = true
                UIView.performWithoutAnimation { writeOffset(target) }
                isPinning = false
                didPin?()
            }
            return
        case .pinToEnd(let mode):
            guard mode != .off else { return }
            applyPin(mode: mode)
        }
    }

    private func applyPin(mode: PinMode) {
        // A PIN DURING A TOUCH IS A CANCELLED GESTURE. The 50pt interruption
        // rule needs a drag to travel 50pt before it latches; pinning under
        // the finger would fight — and win — the first 50pt of every
        // scroll-away, and the user would never be able to leave the bottom.
        guard !isTracking, !isDragging, !isDecelerating else { return }

        let target = maxContentOffsetY
        // Half a point is below anything that can be seen or that a subsequent
        // layout pass would preserve; without an epsilon the pin would rewrite
        // the offset forever on sub-pixel rounding.
        guard abs(contentOffset.y - target) > 0.5 else { return }

        if mode == .throttled {
            let waited = CACurrentMediaTime() - lastPinTime
            guard waited >= Self.minimumPinInterval else {
                // Come back when the floor has elapsed. The DELAY is the point:
                // it hands the runloop back, which is what lets the app go idle
                // between pins. Re-arming synchronously here instead is a
                // busy-wait that spins until the wall clock advances — that was
                // the first thing tried, and it changed the measured idle wait
                // not at all, precisely because it never yielded.
                scheduleDeferredPin(after: Self.minimumPinInterval - waited)
                return
            }
        }

        lastPinTime = CACurrentMediaTime()
        let delta = target - contentOffset.y

        // A wrap grows height ~22pt. Snapping there is the "one line at a
        // time" generation scroll. Glide only on `.throttled` (a live
        // stream); settle / thread-open still snaps.
        if isGliding {
            // A GLIDE PAST ITS OWN DURATION IS NOT A GLIDE. The link owns the
            // offset while one runs, and this branch returns — so a glide that
            // never steps swallows every later pin, permanently. That happens
            // wherever `CADisplayLink` does not fire: a test runloop is the
            // reachable case (`TranscriptHandoffTests` wedged at 129pt against
            // an expected 4,082), and it is latent for any off-window view.
            // The glide knows when it is over; ask it rather than the link.
            if glide?.isFinished(at: CACurrentMediaTime()) != false {
                stopGlideLink()
            }
        }
        if isGliding {
            // A RESIZE GLIDE FOLLOWS ITS TARGET, because the target moves.
            // The end of the content shifts a little while the safe area
            // settles under the keyboard, so a glide aimed at where the end
            // WAS finishes short and the next pin yanks the difference. In
            // the recording that is the tail of the ride: a clean S-curve of
            // -1,-9,-16,-22,-26,-30,-32,-33,-33,-32,-30,-26 and then -11,
            // -25, +15 — an overshoot and a snap back. Moving `to` keeps the
            // curve and its clock, where restarting the glide would not.
            if glide?.eased == true, let inFlight = glide, abs(inFlight.to - target) > 1 {
                glide?.to = target
            } else if mode == .throttled, FollowGlide.shouldRetarget(delta: delta) {
                // The link owns the offset. Retarget only if we have fallen
                // more than a line behind (a burst of wraps during the glide).
                startGlide(to: target)
            }
            return
        }
        // A RESIZE IS THE ONE PIN THAT MAY GLIDE ON `.immediate`.
        //
        // The comment on `contentInsetAdjustmentBehavior` promised the follow
        // would RIDE the keyboard, on the reasoning that the inset change is a
        // bounds change and the pin runs at the end of every layout pass.
        // Measured on the simulator: SwiftUI delivers that bounds change in
        // ONE pass, 874 -> 539, and the pin moved the offset 335pt in 14ms
        // against a keyboard that takes ~250ms. There is nothing to ride.
        //
        // So the ride is made explicit, with the mechanism that already exists
        // for spreading an offset change over time. Not the settle's own
        // landing and not a thread-open — those still snap, because `resized`
        // is only true on the pass where the viewport itself changed size.
        //
        // ONLY A RESIZE THAT JUMPS. On dismissal SwiftUI animates the bounds
        // itself, in steps (device: 539 -> 615 -> 649 -> 874), and starting a
        // fresh 0.25s glide on each one retargets the last: the ride took
        // 890-917ms against a ~250ms keyboard. When the previous pass also
        // resized we are already riding a real animation, so snap and let it
        // carry us.
        if resized, !resizedLastPass, abs(delta) > FollowGlide.startThreshold {
            startGlide(to: target, duration: Self.resizeGlideDuration, eased: true)
            return
        }
        if FollowGlide.shouldStart(delta: delta, mode: mode) {
            startGlide(to: target)
            return
        }

        isPinning = true
        // EXPLICITLY UNANIMATED, not merely "assigned rather than animated".
        //
        // `contentOffset = ` is documented as equivalent to
        // `setContentOffset(_:animated: false)`, but that is only true when no
        // implicit action is in scope. This runs inside a layout pass that can
        // be nested in a transaction SwiftUI opened — the streaming view alone
        // carries two `.animation(.spring…)` modifiers and the hand-off runs a
        // `withAnimation` — and an inherited action would turn every pin into a
        // 0.3s spring. That is the pre-anchor chase all over again: interrupted
        // springs restarting on every token are exactly what made the follow
        // ride unevenly.
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            #if DEBUG
            wroteOffsetSinceReport = true
            #endif
            contentOffset.y = target
            CATransaction.commit()
        }
        isPinning = false
        didPin?()
    }

    /// Stops a glide WITHOUT writing its position.
    ///
    /// Every glide is aimed at the end of the content, so for a reader who has
    /// left the end there is nothing there worth landing on — and `cancelGlide`
    /// would write that aim into `contentOffset`, which is the follow moving
    /// someone who asked not to be followed. (In a test runloop, where the
    /// display link never ran, that write is the glide's ORIGINAL target: a
    /// position thousands of points stale.)
    func abandonGlide() {
        stopGlideLink()
    }

    /// A finger on the transcript outranks the glide. Called from
    /// `scrollViewWillBeginDragging` so the animation cannot fight the drag.
    func cancelGlide() {
        guard isGliding else { return }
        if let y = glide?.offset(at: CACurrentMediaTime()) {
            writeOffset(y)
        }
        stopGlideLink()
    }

    private func startGlide(to target: CGFloat,
                           duration: CFTimeInterval = followGlideDuration,
                           eased: Bool = false) {
        let from = glide?.offset(at: CACurrentMediaTime()) ?? contentOffset.y
        glide = FollowGlide(from: from, to: target,
                            start: CACurrentMediaTime(),
                            duration: duration, eased: eased)
        isGliding = true
        if glideLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(stepGlide(_:)))
            // THE SAME OPT-IN `DisplayLinkPacer` MAKES, for the same reason.
            // Without it iOS clamps the link to 60 on a ProMotion phone, so
            // the glide steps every OTHER frame of a 120Hz keyboard
            // animation and the ride reads as judder. `Info.plist` already
            // carries `CADisableMinimumFrameDurationOnPhone`.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120,
                                                            preferred: 120)
            link.add(to: .main, forMode: .common)
            glideLink = link
        }
    }

    @objc private func stepGlide(_ link: CADisplayLink) {
        guard let glide else {
            stopGlideLink()
            return
        }
        let now = CACurrentMediaTime()
        writeOffset(glide.offset(at: now))
        didPin?()
        if glide.isFinished(at: now) {
            stopGlideLink()
            setNeedsLayout()
        }
    }

    private func writeOffset(_ y: CGFloat) {
        #if DEBUG
        wroteOffsetSinceReport = true
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentOffset.y = y
        CATransaction.commit()
    }

    private func stopGlideLink() {
        glideLink?.invalidate()
        glideLink = nil
        glide = nil
        isGliding = false
    }

    deinit {
        glideLink?.invalidate()
    }

    /// One outstanding retry at a time — a queue of them would be the storm
    /// this exists to prevent.
    private func scheduleDeferredPin(after delay: CFTimeInterval) {
        guard !deferredPinScheduled else { return }
        deferredPinScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.deferredPinScheduled = false
            self.setNeedsLayout()
        }
    }
}

// MARK: - The controller

/// Hosts the collection view and owns the follow state machine.
@MainActor
final class TranscriptViewController: UIViewController {

    // MARK: State pushed in from SwiftUI

    var rowBuilder: (TranscriptItem) -> AnyView = { _ in AnyView(EmptyView()) }
    private(set) var isGenerating = false
    private(set) var threadID = UUID()

    /// Raised when the follow's interruption state changes because of something
    /// the user did. The host writes it back into `ChatGeneration` — which is
    /// still the source of truth across components, so the streaming view and
    /// the tests keep reading the flag they always read.
    var onInterruptionChanged: ((Bool) -> Void)?

    // MARK: Follow state

    /// Whether the user has scrolled away from the end FOR THIS TURN. Mirrors
    /// `llm.scrollInterrupted`; the mirror exists so the scroll callbacks can
    /// read it without a SwiftUI round trip.
    private var interrupted = false
    /// Where the current drag started. The interruption rule measures DRAG
    /// DISPLACEMENT from here, not distance from the bottom, and the
    /// difference is the entire lesson of `1f415ca`: while a finger is down
    /// the pin is off, so content growth alone drags the end away from the
    /// viewport at whatever rate the model is writing. A distance rule reads
    /// that as "the user scrolled away" — the false interruption that killed
    /// the follow mid-answer. Displacement from the anchor can only be caused
    /// by the finger.
    private var dragAnchorY: CGFloat = 0
    private var isUserDriving = false
    /// A drag has to travel this far before it counts as leaving the end.
    /// Pinned from both sides: `testASmallDragUnderTheThresholdDoesNotStop-
    /// TheFollow` (~30pt, must not latch) and
    /// `testScrollingAwayMidAnswerStopsTheFollow` (a full page, must latch).
    private static let interruptionThreshold: CGFloat = 50

    /// A window during which the transcript holds the end of its content even
    /// though nothing is generating. Two uses, both of them "the layout is
    /// still resolving and the user has not asked for anything else yet":
    /// opening a thread, and the hand-off at the end of a turn.
    private var settleDeadline: CFTimeInterval = 0

    /// The settle's mirror image, for a turn the reader walked away from:
    /// the hand-off moves the end of the scrollable content, and the clamp
    /// that follows lands on the top of the new reply. `hold` re-asserts
    /// their place through it, expiring on its own; the first touch wins.
    ///
    /// It holds an OFFSET AND NOTHING ELSE. Propping the scrollable end up
    /// with reserved inset instead reserves a band with nothing drawn in it
    /// — constraint 9, and `TranscriptHandoffTests`.
    private var hold: CGFloat?
    private var holdDeadline: CFTimeInterval = 0

    // MARK: Views

    private lazy var collectionView: PinningCollectionView = {
        let view = PinningCollectionView(frame: .zero, collectionViewLayout: makeLayout())
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        // NAMED, because `app.scrollViews.firstMatch` is not a way to find a
        // transcript. It never was: a reply containing a table puts Textual's
        // horizontal `Overflow` scroll view in the tree, and on the runs where
        // one is on screen that is what `firstMatch` returns — a UI test then
        // swipes a table sideways and reports on the transcript. The UIKit
        // transcript makes the miss total rather than intermittent (a
        // collection view is not a ScrollView to XCUI at all), which is how
        // the latent bug surfaced. See `XCUIApplication.transcript`.
        view.accessibilityIdentifier = "chat.transcript"
        // Both edges are viewport-fixed overlays (`ChatChrome`). The system
        // top effect does not attach to the streaming host, so generation
        // would paint through the title while idle cells looked fine.
        if #available(iOS 26.0, *) {
            view.topEdgeEffect.isHidden = true
            view.bottomEdgeEffect.isHidden = true
        }
        // The composer is a `safeAreaInset` and the keyboard raises it. Letting
        // the scroll view adjust for the safe area is what makes constraint 7
        // free: the inset change is a bounds change, a bounds change is a
        // layout pass, and the pin runs at the end of every layout pass — so
        // the follow RIDES the keyboard instead of fighting it.
        view.contentInsetAdjustmentBehavior = .always
        view.keyboardDismissMode = .interactive
        view.delegate = self
        view.viewport = { [weak self] in self?.viewportIntent ?? .free }
        view.layoutTrailingView = { [weak self] in self?.layoutStreamingView() }
        #if DEBUG
        view.didPin = { [weak self] in self?.recordGeometry() }
        view.didLayoutPass = { [weak self] offset, pinned in
            self?.recordUnpinnedMotion(offset: offset, pinned: pinned)
        }
        #endif
        return view
    }()

    /// Viewport-fixed liquid-glass fades. Siblings of the collection view,
    /// not a `layer.mask` on it — a mask on the scroll layer follows
    /// `contentOffset` and blanks the app. These sit on the canvas and
    /// cover cells and the streaming host the same way.
    private let topFadeView = GlassEdgeFadeView(edge: .top)
    private let bottomFadeView = GlassEdgeFadeView(edge: .bottom)
    var chrome = ChatChrome(bottom: ChatFadeBand(chipTop: 16, chipBottom: 60, insetHeight: 132)) {
        didSet {
            bottomChromeInset = chrome.bottom.insetHeight
            updateFadeOverlays()
        }
    }

    private var dataSource: UICollectionViewDiffableDataSource<TranscriptSection, TranscriptItem>!

    /// Plain cells over a list configuration, on purpose. A
    /// `UICollectionViewListCell` brings separators, accessories and a
    /// background configuration this transcript draws none of, and
    /// `ConversationScrollBenchmarks` counts exactly that — layers and gesture
    /// recognisers behind the scroll view. `UIHostingConfiguration` works on
    /// any cell, so the list appearance buys nothing here and costs a census.
    ///
    /// `.latest` uses the cached seed as its estimate so an off-screen reply
    /// still contributes its height. History stays `.estimated(120)` and
    /// self-sizes; cache-absolute frames froze every cell at 120pt.
    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
            let height: NSCollectionLayoutDimension
            if sectionIndex == TranscriptSection.latest.rawValue {
                let estimate = max(self?.latestEstimate ?? 120, 1)
                // Absolute only while we have a real seed. `.estimated(6483)`
                // was replaced by an unfitted ~400pt self-size (device:
                // 14674→8524 with latestEst already 6483). History and a
                // default last row stay estimated so they can shrink.
                height = estimate > 120 ? .absolute(estimate) : .estimated(120)
            } else {
                height = .estimated(120)
            }
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: height)
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            return NSCollectionLayoutSection(group: group)
        }
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let registration = UICollectionView.CellRegistration<UICollectionViewCell, TranscriptItem> {
            [weak self] cell, _, item in
            guard let self else { return }
            // Last self-sized height for this identity, if we have one.
            // minSize only: the cell can still grow. Not a correction loop —
            // we never compare and invalidate. Stops a just-finished reply
            // from appearing at the 120pt estimate, painting its prose over
            // the next row, then jumping when Textual reports its real height.
            var hosting = UIHostingConfiguration {
                self.rowBuilder(item)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if height > 1 { TranscriptRowHeightCache.store(height, for: item) }
                        let isLatest = self.dataSource.snapshot()
                            .itemIdentifiers(inSection: .latest).first == item
                        guard isLatest else { return }
                        if let relax = self.handoffItemToRelax, relax == item {
                            // Ignore unfitted first measures while the seed
                            // is holding contentH.
                            if height >= self.latestEstimate * 0.5 {
                                self.handoffItemToRelax = nil
                                self.latestEstimate = height
                                self.refreshLatestSection()
                            }
                        } else if self.handoffItemToRelax == nil,
                                  abs(self.latestEstimate - height) > 40 {
                            self.latestEstimate = max(height, 1)
                            // ONLY WHEN THE SECTION'S DIMENSION CAN ACTUALLY
                            // MOVE. Below the 120pt threshold `makeLayout`
                            // returns `.estimated(120)` either way, so a
                            // refresh would re-apply the snapshot for no
                            // change — and mid-turn `.latest` is the user's
                            // question row, which is exactly that case. A
                            // steady-state apply during a turn is what
                            // `apply`'s own guard exists to prevent.
                            if max(self.latestEstimate, height) > 120 {
                                self.refreshLatestSection()
                            }
                        }
                    }
            }
            .margins(.all, 0)
            if let remembered = TranscriptRowHeightCache.height(for: item) {
                hosting = hosting.minSize(width: 0, height: remembered)
            }
            cell.contentConfiguration = hosting
            cell.backgroundConfiguration = .clear()
            // Hosting views do not clip. A 120pt estimate with a 2,000pt
            // body would otherwise draw through the cells below it.
            cell.clipsToBounds = true
            cell.contentView.clipsToBounds = true
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration,
                                                         for: indexPath, item: item)
        }

        installTextSelectionDismissal()
        installFadeOverlays()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateFadeOverlays()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The title block is a toolbar item; it can mount after the
        // first layout. Re-measure so the top overlay is not left at 0.
        cachedTitleBlock = nil
        updateFadeOverlays()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFadeOverlays()
    }

    /// Top and bottom dissolves. Both are siblings of the collection view.
    private func installFadeOverlays() {
        view.addSubview(topFadeView)
        view.addSubview(bottomFadeView)
    }

    /// Everything `updateFadeOverlays` reads. Unchanged inputs, no work.
    private struct FadeOverlayInputs: Equatable {
        var bounds: CGRect
        var titleMaxY: CGFloat
        var chrome: ChatChrome
        var home: CGFloat
    }
    private var lastFadeInputs: FadeOverlayInputs?

    private func updateFadeOverlays() {
        // The system edge effect is the right *look* on cells, but it
        // does not sample the streaming UIHostingController — generation
        // would paint through the title while idle cells looked like
        // Claude. These overlays are that look, applied to everything.
        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.isHidden = true
            collectionView.bottomEdgeEffect.isHidden = true
        }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        // THIS RUNS ON EVERY LAYOUT PASS, AND ALMOST NEVER HAS WORK TO DO.
        // Rebuilding two `CAGradientLayer` colour arrays and re-masking a
        // `UIVisualEffectView` is not free at 120Hz: a keyboard glide is ~31
        // passes, and the recording of one shows the render falling behind
        // the offset (frames moving 32px, then 4, then 32). The inputs are a
        // measured title, the bounds and the chrome — none of which change
        // while an offset animates.
        let measuredTitle = measuredTitleMaxY()
        let inputs = FadeOverlayInputs(bounds: bounds, titleMaxY: measuredTitle,
                                       chrome: chrome, home: windowBottomInset)
        guard inputs != lastFadeInputs else { return }
        lastFadeInputs = inputs
        let titleH = chrome.topChromeHeight(titleMaxYInCanvas: measuredTitle)
        let topH = chrome.topOverlayHeight(titleMaxYInCanvas: measuredTitle)
        if topH > 1 {
            topFadeView.isHidden = false
            topFadeView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: topH)
            topFadeView.setStops(ChatGlassFade.topStops(titleHeight: titleH))
        } else {
            topFadeView.isHidden = true
        }
        let home = inputs.home
        let band = chrome.bottom
        let bottomH = band.overlayHeight(homeIndicator: home)
        bottomFadeView.frame = CGRect(x: 0, y: bounds.height - bottomH,
                                      width: bounds.width, height: bottomH)
        bottomFadeView.setStops(ChatGlassFade.bottomStops(
            ramp: band.ramp, hidden: band.hidden, home: home))
    }

    // MARK: Snapshot

    private var lastApplied: (transcript: [TranscriptItem], tail: [TranscriptItem])?

    /// Applies the transcript. Unanimated except for the debug-card reveal
    /// (see `TranscriptApplyPolicy`). Never during a turn's steady state —
    /// the only snapshots a generating thread applies are the tail's own
    /// state changes (pending → streaming → the finished message).
    func apply(transcript: [TranscriptItem], tail: [TranscriptItem], threadChanged: Bool) {
        // O(1) LIST WORK PER TICK, MADE EXPLICIT.
        //
        // A diffable apply with an unchanged snapshot is still a diff over
        // every identifier — 200+ of them on a real thread — and
        // `updateUIViewController` runs on any SwiftUI update the host happens
        // to take. The host is careful not to read `llm.output` while a turn is
        // running (that is what `&&`'s short-circuit in `isPendingGeneration`
        // is doing), so this should rarely fire mid-stream; the guard is here
        // so the invariant is a property of this file rather than a property of
        // somebody remembering that.
        if !threadChanged, let last = lastApplied,
           last.transcript == transcript, last.tail == tail { return }

        let revealingDebug = !threadChanged && (lastApplied.map {
            TranscriptApplyPolicy.isDebugCardReveal(
                previousTranscript: $0.transcript,
                previousTail: $0.tail,
                transcript: transcript,
                tail: tail)
        } ?? false)

        lastApplied = (transcript, tail)

        var snapshot = NSDiffableDataSourceSnapshot<TranscriptSection, TranscriptItem>()
        snapshot.appendSections([.transcript, .latest, .tail])
        if let last = transcript.last {
            snapshot.appendItems(Array(transcript.dropLast()), toSection: .transcript)
            snapshot.appendItems([last], toSection: .latest)
        }
        snapshot.appendItems(tail, toSection: .tail)

        // ANIMATION IS OFF FOR THE HAND-OFF. At the end of a turn the
        // streaming item leaves and the persisted message joins in the SAME
        // snapshot. Applied atomically and unanimated, the content never
        // passes through a state where the reply is absent.
        //
        // THE DEBUG CARD IS THE EXCEPTION. It is a ~400pt tail insert that
        // arrives after the hand-off. Animated, and with the settle pin
        // cancelled, the panel slides the answer up. Unanimated under an
        // armed settle it pops in and the pin yanks the viewport in one frame.
        if revealingDebug {
            settleDeadline = 0
            dataSource.apply(snapshot, animatingDifferences: true)
            // Second SwiftUI layout, same as the persisted-row hand-off:
            // the first hosting measure is short even with a minSize floor.
            if let debug = tail.first(where: { $0.isDebugInfo }) {
                DispatchQueue.main.async { [weak self] in
                    self?.reconfigure([debug])
                    self?.collectionView.setNeedsLayout()
                }
            }
            return
        }

        // Floor the persisted row BEFORE the apply, so the first dequeue is
        // not the 120pt estimate; `reconfigure` drops it once the row has
        // answered for itself. Do not add an `invalidateLayout()` here
        // (constraint 11). Do not force a dequeue with scrollToItem(.bottom)
        // — it parked the viewport at offset 1943 with 12kpt below the fold.
        // Do not use cache-absolute frames — cells stick at 120pt.
        if needsHandoffReconfigure, let last = transcript.last {
            let seed = max(streamingHeight, pendingHandoffSeed, lastKnownStreamingHeight)
            var floor = seed
            let width = collectionView.bounds.width
            if width > 1 {
                let fitted = UIHostingController(rootView: rowBuilder(last))
                    .sizeThatFits(in: CGSize(width: width,
                                             height: UIView.layoutFittingExpandedSize.height)).height
                floor = TranscriptHandoffSizing.floor(seed: seed, fitted: fitted)
            }
            if floor > 1 {
                TranscriptRowHeightCache.store(floor, for: last)
                latestEstimate = floor
            }
            handoffItemToRelax = last
            pendingHandoffSeed = 0
            #if DEBUG
            StreamTrace.event("[handoff-seed] seed=\(Int(seed)) floor=\(Int(floor)) "
                + "lastKnown=\(Int(lastKnownStreamingHeight)) live=\(Int(streamingHeight)) "
                + "latestEst=\(Int(latestEstimate))")
            #endif
        }

        dataSource.apply(snapshot, animatingDifferences: false)

        if needsHandoffReconfigure {
            needsHandoffReconfigure = false
            handoffReconfigure(lastItem: transcript.last)
        }

        if threadChanged {
            // A DIFFERENT THREAD IS A DIFFERENT SCROLL POSITION. Land on the
            // end and hold it while the cells that were only estimates resolve
            // into real heights.
            armSettle(seconds: 1.5)
        }
    }

    /// Rebuilds a row that is already on screen without diffing the list —
    /// used when a row's INPUTS change but its identity does not (the last
    /// message learning that generation has started, say).
    func reconfigure(_ items: [TranscriptItem], droppingFloor: Bool = true) {
        guard !items.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        let known = Set(snapshot.itemIdentifiers)
        let present = items.filter(known.contains)
        guard !present.isEmpty else { return }
        // See `TranscriptRowHeightCache.forget`. A reconfigure means these
        // rows are being rebuilt from changed inputs; their old heights are
        // not a floor for their new content. The hand-off's second measure
        // keeps the seed until the cell is on screen (`handoffItemToRelax`).
        if droppingFloor {
            present.forEach(TranscriptRowHeightCache.forget)
            let latestIDs = snapshot.itemIdentifiers(inSection: .latest)
            // No `invalidateLayout()` here: the `apply` below already
            // re-asks the section provider, and a bare invalidation would
            // throw away every history row's resolved self-size with it
            // (see `refreshLatestSection`).
            if present.contains(where: latestIDs.contains) {
                latestEstimate = 120
            }
        }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private var needsHandoffReconfigure = false
    /// Streaming height captured at turn end, before `setStreaming(nil)`
    /// can zero the live value. The first-paint seed reads this.
    private var pendingHandoffSeed: CGFloat = 0
    /// Drop this item's seed floor once it is on screen, so the reasoning
    /// fold can shrink the cell. Forgetting earlier returns the 120pt estimate
    /// while the cell is still off-screen.
    private var handoffItemToRelax: TranscriptItem?
    /// `.latest` section's `.estimated` — a property, not a cache lookup
    /// during `apply`, which can run before the snapshot is visible to the
    /// layout. Change it through `refreshLatestSection`, never by
    /// invalidating the layout (constraint 11).
    private var latestEstimate: CGFloat = 120

    private var latestSectionRefreshScheduled = false

    /// Re-ask the layout for `.latest`'s dimension. Never
    /// `invalidateLayout()` — it discards every row's resolved self-size and
    /// history collapses to its estimate (constraint 11; the gate's
    /// history-collapse check). A scoped invalidation context does not help
    /// either. Deferred: applying from inside a geometry callback is the
    /// nested apply the deadlock comment forbids.
    private func refreshLatestSection() {
        guard !latestSectionRefreshScheduled else { return }
        latestSectionRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latestSectionRefreshScheduled = false
            guard let item = self.dataSource.snapshot()
                .itemIdentifiers(inSection: .latest).first else { return }
            // Keeps the floor: this is a re-measure, not changed inputs.
            self.reconfigure([item], droppingFloor: false)
        }
    }


    /// Re-measure the reply's cell ONCE, on the turn that creates it: it is
    /// inserted and measured before Textual has resolved the body, and the
    /// layout keeps that first answer (a 3,801pt reply came back as 83pt).
    ///
    /// Deliberately one, deliberately scoped to the item that just appeared.
    /// A general "re-measure when it looks wrong" rule is the correction loop
    /// the row-size cache livelocked in (1e7438b..7d577f8) — this one cannot
    /// compare heights and cannot re-arm itself. `HandoffCellHeightTests`.
    private func handoffReconfigure(lastItem: TranscriptItem?) {
        guard let lastItem else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Keep the seed: forgetting here returns the 120pt estimate
            // while the cell is still off-screen (device 2026-08-24).
            self.reconfigure([lastItem], droppingFloor: false)
            self.collectionView.setNeedsLayout()
            #if DEBUG
            // Past the reconfigure, the re-measure and the settle window: the
            // column as the reader is left with it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.collectionView.layoutIfNeeded()
                self?.dumpColumn("turn-end")
            }
            #endif
        }
    }

    // MARK: The trailing streaming view

    // NOT A CELL, AND THAT IS THE WHOLE POINT. The streaming view changes
    // size every pacer tick; in a self-sizing cell that is a layout
    // invalidation per tick, and the app stops going idle (34.1s of idle wait
    // on a 26s generation — see `TranscriptSection`). As a plain subview,
    // per-tick growth costs one frame assignment and one scalar inset.
    //
    // `layoutTrailingView` runs after `super.layoutSubviews`, so it is sized
    // before the pin can move the viewport onto it.

    /// THE TRANSCRIPT RUNS BEHIND THE COMPOSER, AND IT HAS TO BE TOLD TO.
    ///
    /// SwiftUI's `.safeAreaInset` does not treat a representable the way it
    /// treats a `ScrollView`. A ScrollView keeps its full-height frame and
    /// receives the inset as `contentInset`, so the transcript runs underneath
    /// the glass capsules and `ChatFadeBand` dissolves it as it passes them —
    /// which is the whole design of that edge. A representable is given a
    /// SMALLER FRAME instead: measured, the collection view came out
    /// `{0, 116, 402, 570}`, ending at y=686 with the composer at y≈788. The
    /// transcript then stopped above the chrome, and the fade band — which is
    /// laid out in the scroll view's own bounds — masked its bottom 132pt of
    /// REAL CONTENT rather than the composer's area. That is the reply's last
    /// lines being invisible while `contentOffset` was provably at the end.
    ///
    /// So the view ignores the container's bottom safe area (regaining the
    /// full height) and pays the inset back here as `contentInset.bottom`,
    /// which is where a scroll view wanted it in the first place. The keyboard
    /// is deliberately NOT ignored — it arrives as a safe-area change and
    /// `.always` folds it in, which is what keeps constraint 7 free.
    var bottomChromeInset: CGFloat = 0 {
        didSet { if bottomChromeInset != oldValue { collectionView.setNeedsLayout() } }
    }

    private var streamingHost: UIHostingController<AnyView>?
    private var streamingHeight: CGFloat = 0
    /// Survives `setStreaming(nil)` zeroing `streamingHeight`. The hand-off
    /// apply can run after that zero; without this the seed is an unfitted
    /// ~400pt first measure and contentH drops by the whole reply
    /// (device 2026-08-24: 14674→8524).
    private var lastKnownStreamingHeight: CGFloat = 0

    /// The home indicator. NOT part of `contentInset` — see
    /// `layoutStreamingView`, where adding it double-counted against
    /// `contentInsetAdjustmentBehavior = .always`. It is still what the bottom
    /// fade has to cover, because that overlay is drawn in the view's own
    /// bounds, which do extend under the indicator.
    private var windowBottomInset: CGFloat {
        collectionView.window?.safeAreaInsets.bottom ?? 0
    }

    /// Bottom of the nav title in this view's coordinates.
    ///
    /// `safeAreaInsets.top` is often just the status bar: iOS 26's glass
    /// title sits *below* that, which is how body text showed through
    /// the title while the clock stayed clean. The title block (and the
    /// bar that hosts it) is the overlap — never `statusBar + N`.
    private weak var cachedTitleBlock: UIView?

    private func measuredTitleMaxY() -> CGFloat {
        if let title = resolvedTitleBlock() {
            let titleBottom = title.convert(title.bounds, to: view).maxY
            if let bar = Self.enclosingNavigationBar(of: title) {
                return max(titleBottom, bar.convert(bar.bounds, to: view).maxY)
            }
            return titleBottom
        }
        if let bar = Self.enclosingNavigationBar(of: view) ?? windowNavigationBar() {
            return bar.convert(bar.bounds, to: view).maxY
        }
        return 0
    }

    private func resolvedTitleBlock() -> UIView? {
        if let cached = cachedTitleBlock,
           cached.window != nil,
           cached.accessibilityIdentifier == "chat.titleBlock" {
            return cached
        }
        guard let root = view.window else { return nil }
        let found = Self.firstView(withAccessibilityIdentifier: "chat.titleBlock", in: root)
        cachedTitleBlock = found
        return found
    }

    private func windowNavigationBar() -> UINavigationBar? {
        guard let root = view.window else { return nil }
        return Self.firstNavigationBar(in: root)
    }

    private static func firstView(withAccessibilityIdentifier id: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == id { return root }
        for child in root.subviews {
            if let hit = firstView(withAccessibilityIdentifier: id, in: child) { return hit }
        }
        return nil
    }

    private static func firstNavigationBar(in root: UIView) -> UINavigationBar? {
        if let bar = root as? UINavigationBar { return bar }
        for child in root.subviews {
            if let hit = firstNavigationBar(in: child) { return hit }
        }
        return nil
    }

    private static func enclosingNavigationBar(of start: UIView) -> UINavigationBar? {
        var current: UIView? = start
        while let node = current {
            if let bar = node as? UINavigationBar { return bar }
            current = node.superview
        }
        return nil
    }

    var isStreamingMounted: Bool { streamingHost != nil }

    func setStreaming(_ content: AnyView?) {
        guard let content else {
            guard let host = streamingHost else { return }
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            streamingHost = nil
            streamingHeight = 0
            collectionView.supplementalAccessibilityViews = []
            // Do NOT zero `contentInset.bottom`. That inset is also the
            // composer chrome; dropping it to 0 for a frame is the flash
            // between the overlay leaving and the persisted row taking over.
            // `layoutStreamingView` will write chrome-only on the next pass.
            collectionView.setNeedsLayout()
            return
        }
        // Mounted ONCE per turn. Reassigning `rootView` on every SwiftUI update
        // would hand `StreamingMessageView` a fresh identity and restart its
        // `DisplayLinkPacer`; it reads everything it needs from the observable
        // models, so it does not want re-pushing.
        guard streamingHost == nil else { return }
        let host = UIHostingController(rootView: AnyView(
            content
                // The host view is always the collection's full width. A
                // hugging child (the thinking chip, before any tokens) would
                // otherwise be centred in that box.
                .frame(maxWidth: .infinity, alignment: .leading)
                // The trigger, not the truth: SwiftUI says "my height changed",
                // and the layout pass below asks how much. Without it nothing
                // tells the scroll view that a subview it frames by hand has
                // grown.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                    guard let self, abs(self.streamingHeight - height) > 0.5 else { return }
                    self.streamingHeight = height
                    if height > 1 { self.lastKnownStreamingHeight = height }
                    self.collectionView.setNeedsLayout()
                }
        ))
        host.view.backgroundColor = .clear
        // The transcript draws its own background; a hosting view that clips
        // would cut the reply off at whatever height was last measured.
        host.view.clipsToBounds = false
        addChild(host)
        collectionView.addSubview(host.view)
        host.didMove(toParent: self)
        streamingHost = host
        collectionView.supplementalAccessibilityViews = [host.view]
        collectionView.setNeedsLayout()
    }

    private func layoutStreamingView() {
        // CHROME ONLY — the home indicator is UIKit's to add and it already
        // does. `contentInsetAdjustmentBehavior` is `.always`, so paying it
        // back here reserves it twice and the transcript rests 34pt past its
        // own content. `testTheHomeIndicatorIsReservedOnceNotTwice`.
        let chrome = bottomChromeInset
        guard let host = streamingHost else {
            // Never reserve the gap between the old content end and the new
            // one here: that band has nothing drawn in it and the hold pins
            // the reader inside it (constraint 9, `assertNothingBlank`). The
            // clamp it avoided self-corrects in a frame. The anchor's slack
            // is a different quantity — capped at one viewport minus the
            // prompt, under the cell that just replaced the stream.
            let bottom = chrome + (anchorGeometry()?.placeholder ?? 0)
            if abs(collectionView.contentInset.bottom - bottom) > 0.5 {
                collectionView.contentInset.bottom = bottom
            }
            return
        }
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        #if DEBUG
        // How many times a generation actually measures the streaming view.
        // `sizeThatFits` on a table-bearing answer costs 8.4ms mounted-once
        // (Debug sim, PerformanceBenchmarks), so the count per pacer tick is
        // the difference between a fifth of the frame budget and several
        // frames of it.
        StreamingMeasureCounter.shared.measured()
        #endif
        // `sizeThatFits` is the authoritative height — the reported geometry
        // above can only ever describe the box it was given, so measuring from
        // it would ratchet and never grow back.
        let fitted = host.sizeThatFits(in: CGSize(width: width,
                                                  height: UIView.layoutFittingExpandedSize.height))
        streamingHeight = fitted.height
        if fitted.height > 1 { lastKnownStreamingHeight = fitted.height }
        #if DEBUG
        traceStreamGeometry(streamHeight: fitted.height)
        #endif
        let frame = CGRect(x: 0, y: collectionView.contentSize.height,
                           width: width, height: fitted.height)
        if host.view.frame != frame { host.view.frame = frame }
        // SLACK, AND WHY IT IS NOT A BLANK BAND. `placeholder` is what the
        // reply has not grown into yet; reserving it is what lets the prompt
        // sit near the top instead of being slammed against the composer, and
        // it shrinks 1:1 as `fitted.height` grows, so the reachable end stays
        // put and a whole short reply arrives without moving the offset.
        //
        // It is computed AFTER `streamingHeight` is updated above, so the
        // geometry describes this pass and not the last one. It is zero the
        // moment the streaming host is gone — see `anchorGeometry`.
        let placeholder = anchorGeometry()?.placeholder ?? 0
        let bottom = fitted.height + chrome + placeholder
        if abs(collectionView.contentInset.bottom - bottom) > 0.5 {
            collectionView.contentInset.bottom = bottom
        }
    }

    // MARK: Follow

    /// The last user message — what phase A anchors to. Supplied by the host
    /// (`Shape.lastUserMessageID`); a `TranscriptItem` carries only a UUID,
    /// so the collection view cannot work out a role for itself.
    var anchorItem: TranscriptItem?

    /// This layout pass's geometry, or nil when there is no prompt yet.
    /// Feeds `placeholder` — the reserve in `contentInset.bottom` — and
    /// nothing else. Deliberately NOT a scroll target: see
    /// `TranscriptViewport.resolve`.
    private func anchorGeometry() -> TranscriptAnchorGeometry? {
        guard let anchorItem,
              let path = dataSource.indexPath(for: anchorItem),
              let frame = collectionView.layoutAttributesForItem(at: path)?.frame,
              collectionView.bounds.height > 1
        else { return nil }
        return TranscriptAnchorGeometry(
            userHeight: frame.height,
            visibleHeight: collectionView.bounds.height,
            topFade: chrome.topOverlayHeight(titleMaxYInCanvas: measuredTitleMaxY()),
            // THE HOME INDICATOR COUNTS. `contentInsetAdjustmentBehavior` is
            // `.always`, so the scroll view adds its own safe area on top of
            // whatever `contentInset.bottom` says. Leaving it out here makes
            // the reserve 34pt too generous, the content scrolls 34pt past
            // the anchor, and every pin-to-end moment lands a line off — the
            // prompt drifted exactly 34pt in the anchor test before this.
            chrome: bottomChromeInset + windowBottomInset,
            // Ink, not intent: the stream lives past `contentSize`, the cell
            // that replaces it inside. Adding both is what keeps the reserve
            // still at `[DONE]` instead of clamping the prompt back down.
            inkBelow: streamingHeight
                + max(0, collectionView.contentSize.height - frame.maxY))
    }

    private var viewportIntent: TranscriptViewport {
        TranscriptViewport.resolve(
            generating: isGenerating,
            interrupted: interrupted,
            now: CACurrentMediaTime(),
            settleUntil: settleDeadline,
            holdY: hold,
            holdUntil: holdDeadline)
    }

    /// Whether the transcript is tracking the answer right now — by anchoring
    /// the prompt or by pinning the end, which is one state as far as the
    /// trace's `follow=` column is concerned.
    private var isFollowingStream: Bool { isGenerating && !interrupted }

    /// Holds the transcript steady for a beat while the layout settles: on
    /// the prompt if the answer still fits the viewport, on the end if it
    /// does not. At turn start that distinction is the whole point — this
    /// used to slam an empty answer against the composer.
    /// Cancelled by the first touch — the user asking for a position always
    /// outranks the settle.
    private func armSettle(seconds: CFTimeInterval) {
        settleDeadline = CACurrentMediaTime() + seconds
        collectionView.setNeedsLayout()
    }

    /// Holds the reader's ABSOLUTE offset — never a distance from the end.
    /// A distance hold feeds every height change below a deep reader into
    /// their position (measured: it moved one 583pt). Pinned by
    /// `TranscriptHandoffTests`; do not reintroduce without beating that trace.
    private func armHold(seconds: CFTimeInterval) {
        hold = collectionView.contentOffset.y
        holdDeadline = CACurrentMediaTime() + seconds
        collectionView.setNeedsLayout()
    }

    /// Gives the offset back to the reader.
    private func releaseHeldOffset() {
        hold = nil
        holdDeadline = 0
    }

    func update(isGenerating generating: Bool, interrupted externalInterruption: Bool,
                threadID newThreadID: UUID) {
        let turnStarted = generating && !isGenerating
        let turnEnded = !generating && isGenerating
        isGenerating = generating
        threadID = newThreadID

        // The host is authoritative for the flag — `ChatGeneration.generate()`
        // clears it on every send, which is how the follow re-arms for the next
        // turn (`testTheFollowReArmsOnTheNextSend`).
        if interrupted != externalInterruption {
            interrupted = externalInterruption
            isUserDriving = false
        }

        if turnStarted {
            lastKnownStreamingHeight = 0
            latestEstimate = 120
            // The streaming view has just been mounted; put it on screen
            // before the model has written anything into it.
            armSettle(seconds: 0.6)
        }
        if turnEnded {
            pendingHandoffSeed = max(streamingHeight, lastKnownStreamingHeight)
            // THE READER'S POSITION IS CAPTURED FIRST, before anything in this
            // method can write `contentOffset` — the glide below is exactly
            // such a writer.
            if interrupted { armHold(seconds: 1.0) }
            // A glide aimed at the streaming view's end must not keep
            // running after that view is gone — it leaves the persisted
            // row and the leftover offset overlapping. For a reader who
            // scrolled away it must not LAND either: its aim is the end, and
            // landing it would deliver them there.
            if interrupted { collectionView.abandonGlide() } else { collectionView.cancelGlide() }
            // The persisted message has just replaced the streaming view, and
            // its cell has to be MEASURED AGAIN — see `handoffReconfigure`.
            needsHandoffReconfigure = true
        }
        if turnEnded, !interrupted {
            // THE LANDING. The reasoning block folds when the persisted row
            // replaces the streaming view (~1,800pt measured), which is a real
            // content change and moves the true end of the transcript. Holding
            // the end through it puts the viewport on the answer rather than
            // wherever the pre-fold height had it.
            //
            // Skipped when the user scrolled away: dragging someone back to
            // the bottom at the end of a turn they walked away from is the
            // behaviour `scrollInterrupted` exists to prevent.
            armSettle(seconds: 1.0)
        }
        collectionView.showsVerticalScrollIndicator = !generating
        collectionView.setNeedsLayout()
    }

    /// The explicit "go to the end" the host asks for after a turn is
    /// committed (`llm.scrollToBottomToken`) and when the keyboard rises.
    ///
    /// `animated` is for the debug-card reveal: an immediate pin would snap
    /// the answer up by the panel's height. The keyboard path stays
    /// unanimated — it rides the keyboard's own animation via the inset.
    func scrollToEnd(animated: Bool = false) {
        guard !interrupted else { return }
        if animated {
            settleDeadline = 0
            collectionView.layoutIfNeeded()
            let target = collectionView.maxContentOffsetY
            guard abs(collectionView.contentOffset.y - target) > 0.5 else { return }
            UIView.animate(withDuration: 0.4, delay: 0,
                           options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
                self.collectionView.contentOffset.y = target
            }
            return
        }
        armSettle(seconds: 0.5)
    }

    /// Lands the viewport on one message — the search deep-link. The settle
    /// pin the thread-open apply armed is cancelled: it pins the END, and
    /// this is the one open that must not land there. Self-sizing means rows
    /// above the target keep resolving estimates after the first scroll and
    /// shove the target's frame around, so the landing is re-asserted a few
    /// times — unless the user has touched the scroll view, whose position
    /// always outranks ours. No layout invalidation anywhere (constraint 11).
    func scrollTo(messageID: UUID, fraction: Double = 0) {
        let item = TranscriptItem.message(messageID)
        guard dataSource.indexPath(for: item) != nil else { return }
        settleDeadline = 0
        assertDeepLinkTarget(item, fraction: fraction, remaining: 6, flash: true)
    }

    private func assertDeepLinkTarget(_ item: TranscriptItem, fraction: Double,
                                      remaining: Int, flash: Bool) {
        guard let path = dataSource.indexPath(for: item) else { return }
        let cv = collectionView
        guard !cv.isTracking, !cv.isDragging, !cv.isDecelerating else { return }
        cv.layoutIfNeeded()
        guard let frame = cv.layoutAttributesForItem(at: path)?.frame else { return }

        // Land the MATCH on screen, not merely the message: the frame's top,
        // plus the match's share of its height, less some context above it.
        // Until the cell dequeues, `frame.height` is the 120pt estimate and
        // the fraction offset is tiny — the re-asserts below recompute
        // against the real height once self-sizing resolves it.
        let fade = chrome.topOverlayHeight(titleMaxYInCanvas: measuredTitleMaxY())
        let visible = cv.bounds.height
            - cv.adjustedContentInset.top - cv.adjustedContentInset.bottom - fade
        var target = frame.minY - fade
        if fraction > 0, frame.height > visible {
            target = frame.minY + fraction * frame.height - fade - 90
            target = min(target, frame.maxY - visible * 0.5)
            target = max(target, frame.minY - fade)
        }
        target = min(max(target, -cv.adjustedContentInset.top), cv.maxContentOffsetY)
        cv.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        #if DEBUG
        StreamTrace.event("[deeplink] assert remaining=\(remaining) "
            + "frameY=\(Int(frame.minY)) h=\(Int(frame.height)) "
            + "frac=\(String(format: "%.2f", fraction)) target=\(Int(target)) "
            + "contentH=\(Int(cv.contentSize.height))")
        #endif
        var flashStillWanted = flash
        if flash, let cell = cv.cellForItem(at: path) {
            flashDeepLinkHighlight(on: cell)
            flashStillWanted = false
        }
        guard remaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.assertDeepLinkTarget(item, fraction: fraction,
                                       remaining: remaining - 1,
                                       flash: flashStillWanted)
        }
    }

    /// One brief tint pulse so the eye finds the message it was promised.
    private func flashDeepLinkHighlight(on cell: UICollectionViewCell) {
        let overlay = UIView(frame: cell.contentView.bounds.insetBy(dx: -4, dy: -2))
        overlay.backgroundColor = cell.tintColor.withAlphaComponent(0.18)
        overlay.layer.cornerRadius = 12
        overlay.isUserInteractionEnabled = false
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cell.contentView.addSubview(overlay)
        UIView.animate(withDuration: 1.0, delay: 0.35, options: [.curveEaseOut]) {
            overlay.alpha = 0
        } completion: { _ in overlay.removeFromSuperview() }
    }

    private func setInterrupted(_ value: Bool) {
        guard interrupted != value else { return }
        interrupted = value
        #if DEBUG
        StreamTrace.event(value
            ? "scrollInterrupted SET (drag \(Int(Self.interruptionThreshold))pt+)"
            : "scrollInterrupted CLEARED (back at the end)")
        #endif
        onInterruptionChanged?(value)
    }

    // MARK: Text selection

    /// Textual's `UITextInteractionView` does not clear its selection on a tap
    /// or after a copy. Ported verbatim in behaviour from the SwiftUI
    /// transcript's `DismissTextSelectionOnTap`, minus the representable that
    /// existed only to go looking for the scroll view — here the scroll view is
    /// right there.
    private func installTextSelectionDismissal() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleSelectionDismissTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        collectionView.addGestureRecognizer(tap)
    }

    @objc private func handleSelectionDismissTap(_ gesture: UITapGestureRecognizer) {
        guard let window = gesture.view?.window else { return }
        Self.clearTextSelections(in: window)
    }

    private static func clearTextSelections(in view: UIView) {
        if let textInput = view as? UITextInput, textInput.selectedTextRange != nil {
            view.perform(NSSelectorFromString("setSelectedTextRange:"), with: nil)
            _ = view.resignFirstResponder()
        }
        for subview in view.subviews { clearTextSelections(in: subview) }
    }

    // MARK: Trace

    /// WHERE THE SPACE ACTUALLY IS, logged once per turn end.
    ///
    /// Two "large gap" reports in one afternoon turned out to be two different
    /// defects in two different places, and both times the screenshot could
    /// say WHERE the gap was but not WHAT it was made of — a cell taller than
    /// its content, a row that renders nothing, content that ends early, or
    /// the composer's own reserved inset. Those are four different bugs with
    /// four different fixes, and a fixture reproduces none of them faithfully
    /// (`Color.clear` expands to fill a floor; the device's fonts and safe
    /// area are its own).
    ///
    /// So the transcript says it out loud, into the same trace the scroll
    /// analysis already reads. Each line is a realised row and its height;
    /// the summary line is what sits after the last one.
    #if DEBUG
    func dumpColumn(_ label: String) {
        let history = collectionView.numberOfItems(inSection: TranscriptSection.transcript.rawValue)
        let latest = collectionView.numberOfSections > TranscriptSection.latest.rawValue
            ? collectionView.numberOfItems(inSection: TranscriptSection.latest.rawValue) : 0
        let count = history + latest
        var lines = ["[column] \(label) items=\(count)"]
        var previousMaxY: CGFloat?
        let paths: [IndexPath] = {
            var out: [IndexPath] = []
            let t = TranscriptSection.transcript.rawValue
            for index in max(0, history - 6)..<history {
                out.append(IndexPath(item: index, section: t))
            }
            let l = TranscriptSection.latest.rawValue
            for index in 0..<latest {
                out.append(IndexPath(item: index, section: l))
            }
            return out
        }()
        for path in paths {
            let index = path.section == TranscriptSection.latest.rawValue
                ? history + path.item : path.item
            guard let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { continue }
            let gap = previousMaxY.map { frame.minY - $0 } ?? 0
            let realised = collectionView.cellForItem(at: path) != nil
            let item = dataSource.itemIdentifier(for: path)
            let floor = item.flatMap(TranscriptRowHeightCache.height(for:)) ?? -1
            let content = (collectionView.cellForItem(at: path)?.contentView.subviews.first)
                .map { $0.systemLayoutSizeFitting(
                    CGSize(width: frame.width, height: UIView.layoutFittingExpandedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel).height } ?? -1
            lines.append(String(format: "[column]   row %d y=%.1f h=%.1f gap=%.1f realised=%@ floor=%.1f content=%.1f",
                                index, frame.minY, frame.height, gap, realised ? "y" : "n",
                                floor, content))
            previousMaxY = frame.maxY
        }
        // THE TAIL IS PART OF THE COLUMN, and the first run of this found
        // 120pt of it after the last message — one item at the layout's
        // estimate, never realised and therefore never measured down to the
        // nothing it renders.
        let tailSection = TranscriptSection.tail.rawValue
        let tailCount = collectionView.numberOfItems(inSection: tailSection)
        lines.append("[column]   tail items=\(tailCount)")
        for index in 0..<tailCount {
            let path = IndexPath(item: index, section: tailSection)
            guard let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { continue }
            let realised = collectionView.cellForItem(at: path) != nil
            let identity = dataSource.itemIdentifier(for: path).map { "\($0)" } ?? "?"
            let floor = dataSource.itemIdentifier(for: path)
                .flatMap(TranscriptRowHeightCache.height(for:)) ?? -1
            let content = (collectionView.cellForItem(at: path)?.contentView.subviews.first)
                .map { $0.systemLayoutSizeFitting(
                    CGSize(width: frame.width, height: UIView.layoutFittingExpandedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel).height } ?? -1
            lines.append(String(format: "[column]   tail %d y=%.1f h=%.1f realised=%@ floor=%.1f content=%.1f %@",
                                index, frame.minY, frame.height, realised ? "y" : "n",
                                floor, content, identity))
            previousMaxY = max(previousMaxY ?? 0, frame.maxY)
        }
        let end = previousMaxY ?? 0
        lines.append(String(format: "[column]   contentH=%.1f afterLastRow=%.1f inset=%.1f "
                            + "chrome=%.1f home=%.1f offset=%.1f visible=%.1f",
                            collectionView.contentSize.height,
                            collectionView.contentSize.height - end,
                            collectionView.contentInset.bottom,
                            bottomChromeInset, windowBottomInset,
                            collectionView.contentOffset.y,
                            collectionView.bounds.height))
        for line in lines { StreamTrace.event(line) }
    }
    #endif

    #if DEBUG
    private var lastPassOffset: CGFloat?

    /// The offset moved and WE DID NOT MOVE IT. One line per occurrence, only
    /// while a turn is running, so a quiet generation logs nothing at all.
    fileprivate func recordUnpinnedMotion(offset: CGFloat, pinned: Bool) {
        defer { lastPassOffset = offset }
        guard isGenerating, let previous = lastPassOffset else { return }
        let delta = offset - previous
        guard !pinned, abs(delta) > 0.4 else { return }
        StreamTrace.event("[unpinned] delta=\(String(format: "%.1f", delta)) "
            + "offset=\(Int(offset)) contentH=\(Int(collectionView.contentSize.height)) "
            + "inset=\(Int(collectionView.contentInset.bottom)) "
            + "intr=\(interrupted ? 1 : 0) drag=\(isUserDriving ? 1 : 0)")
    }

    private var lastTracedStreamHeight: CGFloat = -1

    /// CONTENT MOTION, WHICH `recordGeometry` STRUCTURALLY CANNOT SEE: that
    /// trace samples on scroll, so a parked reader produces no samples however
    /// much the reply reflows under them. A silent trace is not "nothing
    /// moved". Keyed on the streaming view's height; emits only on change.
    private func traceStreamGeometry(streamHeight: CGFloat) {
        guard abs(streamHeight - lastTracedStreamHeight) > 0.4 else { return }
        lastTracedStreamHeight = streamHeight
        StreamTrace.event("[streamgeom] streamH=\(Int(streamHeight)) "
            + "originY=\(Int(collectionView.contentSize.height)) "
            + "inset=\(Int(collectionView.contentInset.bottom)) "
            + "offset=\(Int(collectionView.contentOffset.y))")
    }

    private var lastTracedGeometry: (CGFloat, CGFloat, CGFloat)?

    /// Emits the same `[scrolltrace]` line the SwiftUI transcript emitted, with
    /// the same columns in the same order. The out-of-band trace analyzers
    /// parse it, and the whole point of the
    /// overscroll metric is that the two implementations' numbers are
    /// comparable — ~600 samples per generation before, zero after.
    fileprivate func recordGeometry() {
        // contentH is the END OF THE SCROLLABLE CONTENT, not
        // `contentSize.height`: the streaming view counts (real content in
        // reserved space), the composer chrome does not. Getting that split
        // wrong silently rescales the overscroll metric the trace analyzer
        // computes, which is what this file is judged
        // by — reporting raw `contentSize` made a healthy follow read as
        // 31,805 against 24,664.
        let geometry = (collectionView.contentOffset.y,
                        collectionView.contentSize.height + streamingHeight,
                        collectionView.bounds.height)
        if let last = lastTracedGeometry, last == geometry { return }
        lastTracedGeometry = geometry
        TranscriptTrace.geometry(offset: geometry.0, contentHeight: geometry.1,
                                 visibleHeight: geometry.2, generating: isGenerating,
                                 interrupted: interrupted, dragged: isUserDriving,
                                 following: isFollowingStream)
    }
    #else
    fileprivate func recordGeometry() {}
    #endif
}

// MARK: - Scroll delegate: the follow's state machine

extension TranscriptViewController: UICollectionViewDelegate {

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserDriving = true
        dragAnchorY = scrollView.contentOffset.y
        // A touch is a statement of intent about where the transcript should
        // be. Whatever the settle window was doing, it is now the user's.
        settleDeadline = 0
        releaseHeldOffset()
        (scrollView as? PinningCollectionView)?.cancelGlide()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        recordGeometry()

        guard let collectionView = scrollView as? PinningCollectionView else { return }
        let fromEnd = collectionView.distanceFromEnd

        // BACK AT THE END RESUMES THE FOLLOW, whoever put it there. This is the
        // only unconditional half of the rule, and it is safe precisely because
        // it can only CLEAR: while interrupted the pin is off, so a growing
        // answer pushes the end further away, never closer.
        if fromEnd <= Self.interruptionThreshold {
            setInterrupted(false)
            if !scrollView.isTracking && !scrollView.isDragging && !scrollView.isDecelerating {
                isUserDriving = false
            }
            return
        }

        // AWAY FROM THE END ONLY COUNTS IF A FINGER PUT IT THERE, and only if
        // it travelled. `isTracking` alone is a tap; displacement alone during
        // a pin is the content growing. Both together is a scroll-away.
        guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
        let travelled = dragAnchorY - scrollView.contentOffset.y
        if travelled > Self.interruptionThreshold {
            setInterrupted(true)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { isUserDriving = false }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isUserDriving = false
    }

    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        #if DEBUG
        if indexPath.section == TranscriptSection.transcript.rawValue
            || indexPath.section == TranscriptSection.latest.rawValue {
            RealizedRowCounter.shared.entered()
        }
        #endif
        if let item = dataSource.itemIdentifier(for: indexPath),
           item == handoffItemToRelax {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                TranscriptRowHeightCache.forget(item)
                self.reconfigure([item], droppingFloor: false)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView,
                        didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        #if DEBUG
        if indexPath.section == TranscriptSection.transcript.rawValue
            || indexPath.section == TranscriptSection.latest.rawValue {
            RealizedRowCounter.shared.left()
        }
        #endif
    }
}

extension TranscriptViewController: UIGestureRecognizerDelegate {
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// Long presses own text selection; this tap only fires when none is
    /// recognised.
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        other is UILongPressGestureRecognizer
    }
}

/// Blur + a dim that never goes fully opaque. Masking the effect view
/// (not the scroll view) is what lets text stay faintly readable through
/// the chrome — Claude's clip — without a `CALayer.mask` on the
/// collection view, which follows `contentOffset` and blanks the app.
private final class GlassEdgeFadeView: UIView {
    enum Edge { case top, bottom }

    private let blurContainer = UIView()
    private let blur = UIVisualEffectView()
    private let fadeMask = UIView()
    private let blurMask = CAGradientLayer()
    private let dim = CAGradientLayer()
    private let edge: Edge

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        // Frost of the content, not a glass plate. `UIGlassEffect` is
        // the capsule material (composer, chips). A full-width glass
        // effect reads as a card; Claude's clip is a progressive blur.
        // Mask the container, not the effect view — a mask on
        // `UIVisualEffectView` itself drops the blur on some iOS builds.
        blur.effect = UIBlurEffect(style: .systemThinMaterial)
        blurContainer.backgroundColor = .clear
        blurContainer.addSubview(blur)
        addSubview(blurContainer)
        fadeMask.backgroundColor = .clear
        fadeMask.layer.addSublayer(blurMask)
        blurContainer.mask = fadeMask
        dim.isOpaque = false
        layer.addSublayer(dim)
        setStops(edge == .top
                 ? ChatGlassFade.topStops(titleHeight: 110)
                 : ChatGlassFade.bottomStops(ramp: 44, hidden: 72, home: 34))
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurContainer.frame = bounds
        blur.frame = bounds
        fadeMask.frame = bounds
        blurMask.frame = bounds
        dim.frame = bounds
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setStops(cachedStops)
    }

    private var cachedStops: [ChatGlassFade.Stop] = []

    func setStops(_ stops: [ChatGlassFade.Stop]) {
        cachedStops = stops
        let stops = stops.isEmpty
            ? (edge == .top
               ? ChatGlassFade.topStops(titleHeight: 110)
               : ChatGlassFade.bottomStops(ramp: 44, hidden: 72, home: 34))
            : stops
        blurMask.startPoint = CGPoint(x: 0.5, y: 0)
        blurMask.endPoint = CGPoint(x: 0.5, y: 1)
        blurMask.colors = stops.map { UIColor.black.withAlphaComponent($0.blur).cgColor }
        blurMask.locations = stops.map { NSNumber(value: Double($0.location)) }
        let bg = UIColor.systemBackground
        dim.startPoint = CGPoint(x: 0.5, y: 0)
        dim.endPoint = CGPoint(x: 0.5, y: 1)
        dim.colors = stops.map { bg.withAlphaComponent($0.dim).cgColor }
        dim.locations = stops.map { NSNumber(value: Double($0.location)) }
    }
}

// MARK: - The SwiftUI face

/// The transcript, as SwiftUI sees it.
///
/// Rows are built by the HOST, not by this file: `rowBuilder` is a closure
/// `ConversationView` supplies, so the rendering stack (MessageView, Textual,
/// the offer card, the error card) is untouched by this change and stays in
/// one place. What crosses this boundary is a list of identifiers and a
/// function from identifier to view — nothing about how a message looks lives
/// in the collection view layer.
struct TranscriptView: UIViewControllerRepresentable {
    let transcript: [TranscriptItem]
    let tail: [TranscriptItem]
    let threadID: UUID
    let isGenerating: Bool
    let interrupted: Bool
    /// Rows whose CONTENTS depend on something other than their identity —
    /// today, the last user message while an error is showing, which grows a
    /// retry affordance without becoming a different message. A cell already
    /// dequeued holds the SwiftUI view it was built with, so a change like that
    /// has to be asked for; the coordinator diffs this set against the previous
    /// one and reconfigures the union, so an unchanged set costs nothing.
    let volatileItems: Set<TranscriptItem>
    /// Title and composer geometry. The canvas is full-bleed; these numbers
    /// become `contentInset` and the bottom fade. See `ChatChrome`.
    var chrome: ChatChrome
    /// The streaming view, or nil when no turn is in flight. Passed as CONTENT
    /// rather than as an item id: it is mounted as a trailing subview of the
    /// scroll view, not as a cell — see `TranscriptSection`.
    let streamingContent: AnyView?
    /// The last user message, for phase A of the follow. Identity only —
    /// `TranscriptItem` has no role, and working one out is the host's job.
    /// Nil means there is nothing to anchor to, and the follow is the old
    /// pin-to-end.
    var anchorItem: TranscriptItem? = nil
    /// Bumped by the host to ask for one landing at the end of the content.
    let scrollToEndToken: Int
    /// When the token bumps, slide to the end instead of pinning immediately.
    var scrollToEndAnimated: Bool = false
    /// When the TARGET token bumps, land on this message instead of the end —
    /// the search deep-link. Identity only, like everything else that crosses
    /// this boundary.
    var scrollTargetID: UUID? = nil
    /// Where in the target message the match sits (0...1); a long reply lands
    /// with the matched passage on screen, not two screens below the fold.
    var scrollTargetFraction: Double = 0
    var scrollTargetToken: Int = 0
    let onInterruptionChanged: (Bool) -> Void
    let rowBuilder: (TranscriptItem) -> AnyView

    func makeUIViewController(context: Context) -> TranscriptViewController {
        let controller = TranscriptViewController()
        controller.rowBuilder = rowBuilder
        controller.onInterruptionChanged = onInterruptionChanged
        // `threadID` is deliberately NOT seeded here: the first
        // `updateUIViewController` must see a thread CHANGE so it arms the
        // settle window that lands a cold open on the newest message.
        context.coordinator.scrollToEndToken = scrollToEndToken
        context.coordinator.scrollTargetToken = scrollTargetToken
        return controller
    }

    func updateUIViewController(_ controller: TranscriptViewController, context: Context) {
        // Re-captured every update: the closure holds the current messages and
        // the current generation state, and a stale one would render a stale
        // transcript into every cell dequeued after it.
        controller.rowBuilder = rowBuilder
        controller.onInterruptionChanged = onInterruptionChanged

        let threadChanged = context.coordinator.threadID != threadID
        context.coordinator.threadID = threadID

        controller.update(isGenerating: isGenerating, interrupted: interrupted,
                          threadID: threadID)
        controller.chrome = chrome
        controller.anchorItem = anchorItem

        // HAND-OFF ORDER. The overlay carries the reply until the persisted
        // row exists. Tearing it down first painted a frame with neither.
        // Apply the row first so `streamingHeight` still floors its cell,
        // then drop the overlay. Never insert the debug card in this
        // snapshot — that cancel-settle path parks the viewport on the
        // top of the new reply. The card is a later tail-only reveal.
        if streamingContent == nil, controller.isStreamingMounted {
            controller.apply(transcript: transcript,
                             tail: TranscriptApplyPolicy.handoffTail(tail),
                             threadChanged: threadChanged)
            controller.setStreaming(nil)
        } else {
            controller.setStreaming(streamingContent)
            controller.apply(transcript: transcript, tail: tail,
                             threadChanged: threadChanged)
        }

        if context.coordinator.volatileItems != volatileItems {
            let touched = volatileItems.union(context.coordinator.volatileItems)
            context.coordinator.volatileItems = volatileItems
            controller.reconfigure(Array(touched))
        }

        if context.coordinator.scrollToEndToken != scrollToEndToken {
            context.coordinator.scrollToEndToken = scrollToEndToken
            controller.scrollToEnd(animated: scrollToEndAnimated)
        }

        if context.coordinator.scrollTargetToken != scrollTargetToken {
            context.coordinator.scrollTargetToken = scrollTargetToken
            if let scrollTargetID {
                controller.scrollTo(messageID: scrollTargetID,
                                    fraction: scrollTargetFraction)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var threadID: UUID?
        var scrollToEndToken = 0
        var scrollTargetToken = 0
        var volatileItems: Set<TranscriptItem> = []
    }
}

#endif

// Platform-guarded like the transcript above it, not merely `#if DEBUG`. Its
// only caller lives inside that guard, so on a macOS Debug build this compiled
// with no users and no UIKit — and `CACurrentMediaTime` resolved only because
// UIKit re-exports QuartzCore, which AppKit does not. That broke the Mac build.
#if DEBUG && (os(iOS) || os(visionOS))
/// Counts `sizeThatFits` calls on the streaming host, reported once per
/// second into the scroll trace. Exists because "it stutters when it reflows
/// tables" is a per-frame cost question and the answer is a RATE, not a
/// stack.
@MainActor
final class StreamingMeasureCounter {
    static let shared = StreamingMeasureCounter()
    private var count = 0
    private var windowStart = CACurrentMediaTime()

    func measured() {
        count += 1
        let now = CACurrentMediaTime()
        guard now - windowStart >= 1 else { return }
        StreamTrace.event("[measures] streamingView sizeThatFits/s=\(count)")
        count = 0
        windowStart = now
    }
}
#endif
