//
//  ConversationView.swift
//  teemoon
//
//  Created by Xavier on 16/12/2024.
//

import SwiftUI
import SwiftData
import Textual
import UniformTypeIdentifiers

// The tap-to-dismiss-text-selection workaround used to live here as a
// `UIViewRepresentable` whose only job was to go hunting for the enclosing
// UIScrollView. On iOS the transcript IS a scroll view now — see
// `TranscriptViewController.installTextSelectionDismissal`, which installs the
// same gesture on the collection view directly, with the same simultaneous
// recognition and the same deference to long-press.

// MARK: - Bottom fade

private extension View {
    /// Dissolves the transcript into the background where it passes the floating
    /// composer, so it never stays crisp in the transparent gaps around the glass
    /// capsule. Deliberately a gradient mask and not iOS 26's
    /// `.scrollEdgeEffectStyle`, which only attaches to real toolbars and tab bars —
    /// a `safeAreaInset` capsule is neither, and the system effect lands outside the
    /// composer's padding where it covers nothing that matters.
    ///
    /// The band is sized to the composer (48pt capsule + 16pt padding either side),
    /// not more. An earlier 96pt version, stacked with the system effect that was
    /// also enabled at the time, is what made this edge look like it was eating the
    /// answer. `.black` through the first third holds the text at full opacity until
    /// it is genuinely at the capsule, so the dissolve reads as depth rather than as
    /// a band of dimmed text.
    ///
    /// Alternatives that were tried on device and are worse: no treatment at all
    /// (text ghosts through the glass and a line strands itself between capsule and
    /// keyboard) and an opaque `.bar` shelf (a grey slab with a hard edge that
    /// slices glyphs). Every option here is a trade; this one is the least visible.
    ///
    /// The shape itself is `ChatFadeBand`, which is where the reasoning and the
    /// regression tests live.
    @ViewBuilder func chatBottomScrollFade(_ band: ChatFadeBand) -> some View {
        #if os(iOS)
        self.modifier(ChatBottomScrollFade(band: band))
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Tracks NOTHING about the keyboard, deliberately — see the mask below.
private struct ChatBottomScrollFade: ViewModifier {
    let band: ChatFadeBand

    /// The UIKit transcript ignores the container's bottom safe area so it
    /// can run behind the composer. That also pulls the view through the
    /// home indicator. The mask is laid out in those full bounds, so
    /// without this extra clear the ramp sits `homeIndicator` points too
    /// low and text runs through the chips. Zero when the keyboard is up
    /// (the collection view has already shrunk, and the indicator is gone).
    private var homeIndicator: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    func body(content: Content) -> some View {
        content
            .mask {
                VStack(spacing: 0) {
                    Color.black               // above the chip: untouched
                    // The ramp spans the CHIP, and only the chip. Stretching it
                    // across the whole inset left the gap between the chip and
                    // the composer around 78% opaque — legible, which is the
                    // recurring "text bleeds through between the capsules".
                    // Above the chip nothing may fade, below it nothing may show;
                    // the dissolve has exactly one capsule's height to happen in.
                    // See ChatFadeBand.
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: ChatFadeBand.plateau),
                            .init(color: .black.opacity(0), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: band.ramp)
                    // Everything below the chip — the gap, the composer, the
                    // padding under it — is fully masked. An opaque shelf across
                    // the inset is NOT the same thing and was tried and reverted:
                    // it slices glyphs on its hard top edge and reads as a grey
                    // slab on the keyboard's grey. This hides the transcript
                    // without drawing anything.
                    Color.clear.frame(height: band.hidden)
                    // Parks the ramp on the chrome, not on the home indicator.
                    // See `homeIndicator` — this is zero with the keyboard up.
                    Color.clear.frame(height: homeIndicator)
                    // NO keyboard spacer here, and no keyboard observers on the
                    // modifier. The mask is laid out in the SCROLL VIEW's bounds,
                    // and the scroll view already shrinks when the keyboard comes
                    // up — so the band is anchored to the bottom of that box and
                    // rides the keyboard for free.
                    //
                    // Subtracting the keyboard as well double-counted it. MEASURED
                    // on an iPhone 17 Pro with a populated transcript: the mask's
                    // container is 592pt with the keyboard down and 291pt with it
                    // up, while the notification reports a 335pt keyboard. The old
                    // VStack therefore asked for 116 + 335 = 451pt of fixed content
                    // inside a 291pt box; the flexible spacer above collapsed to
                    // zero, the stack overflowed and centred, and the gradient was
                    // drawn ~160pt above the chrome — the transcript dissolving
                    // into empty background well before it reached anything.
                }
                .ignoresSafeArea()
            }
    }
}
#endif

#if !os(macOS)
/// The environment and styling every hosted piece of the transcript needs.
/// Extracted so a cell and the trailing streaming view cannot drift apart —
/// they are separate hosting contexts and neither inherits from the host.
struct TranscriptRowChrome: ViewModifier {
    let llm: ChatGeneration
    let settings: AppSettings
    let providerStore: ProviderStore?

    func body(content: Content) -> some View {
        content
            .environment(llm)
            .environment(settings)
            .environment(providerStore)
            .textual.tableStyle(MinimalChatTableStyle())
            .textual.tableCellStyle(MinimalChatTableCellStyle())
            .blockingRemoteTranscriptAttachments()
    }
}
#endif

// MARK: - ConversationView

struct ConversationView: View {
    @Environment(ChatGeneration.self) var llm
    @Environment(AppSettings.self) private var settings
    // Optional lookup: a non-optional @Observable @Environment *traps* when absent,
    // which crashes any standalone render of ConversationView (e.g. the perf-test
    // harness that doesn't inject a store). nil → the grounding-recovery gate below
    // simply treats the provider as having no built-in grounding.
    @Environment(ProviderStore.self) private var providerStore: ProviderStore?
    let messages: [Message]
    let threadID: UUID
    let generatingThreadID: UUID?
    var onRetry: ((Message) -> Void)? = nil
    /// Raised by the offer card. The host opens settings deep-linked to search.
    var onSetUpWebSearch: (() -> Void)? = nil
    /// Raised once a key is accepted IN THE CARD, with the question to re-ask.
    /// Declared before `onDeclineWebSearch` so the call site's argument order
    /// matches the declaration order Swift requires.
    var onRetryAfterSetup: ((Message) -> Void)? = nil
    /// Raised when the offer is DECLINED, so the host can point at the chip.
    var onDeclineWebSearch: (() -> Void)? = nil
    /// Shape of the transcript's bottom fade, measured from the real chrome.
    /// See `ChatFadeBand` — this edge has been got wrong three ways and the
    /// reasoning lives there, with tests.
    var fadeBand = ChatFadeBand(chipTop: 16, chipBottom: 60, insetHeight: 132)

    @State private var showDebugInfo = false
    /// Captured when generation ends: true if the user was following the stream (not scrolled away).
    @State private var wasFollowingGeneration = true

    #if os(macOS)
    /// Whether a FINGER moved the transcript away from the end. Distance from
    /// the bottom alone cannot say — a lazy stack re-measuring rows above the
    /// viewport moves the content by thousands of points on its own — and
    /// conflating the two is what killed the streaming follow. See the note on
    /// `onScrollPhaseChange`.
    @State private var userDraggedAway = false
    /// Coalesces the explicit follow's scrollTo to one per runloop turn — see
    /// the content-size `.onScrollGeometryChange` on the transcript.
    @State private var followScrollScheduled = false
    /// Keeps the streaming view mounted (invisible) for a beat after the turn
    /// ends, so the hand-off never collapses the content height — see the
    /// ballast comment at the mount site.
    @State private var handoffBallast = false
    /// The streaming view's last rendered height while generating, in a plain
    /// reference box so per-tick writes cost no invalidations. The ballast
    /// pins to this: the view's own content shrinks at turn end (the expanded
    /// reasoning block folds, ~1,800pt measured) and an unpinned ballast
    /// passed that collapse straight through to contentH.
    private final class HeightBox { var value: CGFloat? }
    @State private var ballastHeight = HeightBox()
    /// Whether a finger is currently on the scroll view (phase .interacting).
    /// The explicit follow must not scrollTo during an active touch: it would
    /// cancel the user's gesture before the 50pt interruption rule can latch.
    @State private var touchIsDown = false
    #else
    /// Bumped to ask the collection view for one landing at the end of its
    /// content: after a turn is committed, and when the keyboard rises on an
    /// idle thread. Not a follow — the follow is the collection view's own
    /// layout-time pin, and it needs no telling.
    @State private var scrollToEndToken = 0
    /// When true, the next `scrollToEndToken` bump slides to the end instead
    /// of snapping. Used for the developer-mode debug card so the panel
    /// lifts the answer rather than jumping it.
    @State private var scrollToEndAnimated = false
    /// Cancels a pending debug-card reveal if the next turn starts first.
    @State private var debugRevealTask: Task<Void, Never>?
    /// Same, for the delayed animated landing after a debug reveal.
    @State private var endScrollTask: Task<Void, Never>?
    /// The search deep-link: the message to land on when this thread was
    /// opened from a search result, and the token that asks for it.
    @State private var scrollTargetID: UUID?
    @State private var scrollTargetFraction: Double = 0
    @State private var scrollTargetToken = 0
    /// Observed so a result tap re-fires even when the SAME thread is
    /// already on screen — its stamp moves; the thread id does not.
    @State private var deepLink = TranscriptDeepLink.shared
    #endif

    private var isGenerating: Bool { llm.running && threadID == generatingThreadID }
    /// Whether the transcript should be pinned to the newest text right now:
    /// a reply is arriving into THIS thread and the user has not scrolled away
    /// from it. Gates the explicit follow below — and nothing else; the
    /// `.sizeChanges` anchor it used to drive is deleted, see 1f415ca.
    private var isFollowingStream: Bool { isGenerating && !llm.scrollInterrupted }
    private var isPendingGeneration: Bool {
        threadID == generatingThreadID && !llm.running && llm.output.isEmpty
    }

    @ViewBuilder
    private var pendingChip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            GenerationActivityChipView(state: .thinking, elapsedTime: llm.elapsedTime)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Extracted from the ForEach body. Inlined, the offer's states pushed the
    /// row's expression past what the type-checker will solve in reasonable
    /// time ("unable to type-check this expression in reasonable time"). A
    /// @ViewBuilder func costs nothing at runtime and keeps each piece
    /// independently checkable.
    @ViewBuilder
    private func offerCard(for message: Message) -> some View {
        if let query = llm.offerByMessageID[message.id] {
            WebSearchOffer(
                query: query,
                onDismiss: { declineOffer() },
                onKeyAccepted: { key in acceptKey(key, for: message) }
            )
            .padding(.horizontal)
            .padding(.bottom, 8)
            .id("weboffer-\(message.id.uuidString)")
            .accessibilityIdentifier("chat.webSearchOffer")
            .transition(.opacity.animation(.easeInOut(duration: 0.25)))
        }
    }

    private func declineOffer() {
        Haptics.play()
        llm.declineOffer(inThread: threadID, messageIDs: messages.map(\.id))
        onDeclineWebSearch?()
    }

    /// Brave accepted the key, so this is the moment search becomes real: save,
    /// enable, clear the card, and re-ask the question — frame 6 without ever
    /// leaving the thread.
    private func acceptKey(_ key: String, for message: Message) {
        Haptics.play()
        settings.braveSearchKey = key
        settings.braveGroundingEnabled = true
        llm.offerByMessageID.removeValue(forKey: message.id)
        guard let idx = messages.firstIndex(where: { $0.id == message.id }),
              let userMessage = messages[..<idx].last(where: { $0.role == .user })
        else { return }
        onRetryAfterSetup?(userMessage)
    }

    /// The handful of derived facts every row in the transcript is decided by.
    /// Computed once per body evaluation and shared by both transcripts, so the
    /// two implementations cannot drift on what an error, a retry affordance or
    /// a fresh-start rule means.
    private struct Shape {
        let hasError: Bool
        let lastUserMessageID: UUID?
        /// Indices into `messages` that the provider will answer without sight
        /// of the conversation above them. See `FreshStartRule`.
        let freshStarts: Set<Int>
    }

    private var shape: Shape {
        let hasLLMError = llm.lastError != nil && llm.lastErrorThreadID == threadID
        // Also catch malformed responses (e.g. raw XML tool calls in output) that
        // complete with HTTP 200 so llm.lastError is never set.
        let lastIsMalformed = messages.last?.role == .assistant &&
            messages.last?.content.contains("<tool_call>") == true
        return Shape(
            hasError: hasLLMError || lastIsMalformed,
            lastUserMessageID: messages.last(where: { $0.role == .user })?.id,
            freshStarts: FreshStart.indices(
                roles: messages.map(\.role),
                singleTurn: providerStore?.activeProvider?.answersSingleTurnOnly == true))
    }

    /// Whether the request-debug card is currently earned. Read by both
    /// transcripts; the iOS one also needs it to decide whether the item is in
    /// the tail at all.
    ///
    /// Gated on `showDebugInfo` so the card is NOT in the hand-off snapshot.
    /// Inserting it there cancels the settle pin and leaves the viewport on
    /// the top of the new reply (the cell grows downward from a short
    /// estimate). The card arrives a beat later as its own animated tail.
    private var showsDebugCard: Bool {
        settings.developerModeEnabled && showDebugInfo
            && llm.lastRequestDebugInfo?.threadID == threadID && llm.lastError == nil
    }

    var body: some View {
        #if os(macOS)
        macTranscript
        #else
        uiKitTranscript
        #endif
    }

    // MARK: - macOS: the SwiftUI transcript
    //
    // The Mac keeps the ScrollView + LazyVStack this project spent two days
    // hardening, unchanged. It has none of the symptoms the UIKit transcript
    // exists for — no device freeze, no blank screen, no near-end flash — and
    // there is no UICollectionView here to move it to. Everything below is the
    // implementation as it stood at b124889; the iOS-only modifiers that were
    // no-ops on macOS (the fade band, `scrollDismissesKeyboard`, the keyboard
    // observer) are the only things gone.

    #if os(macOS)
    private var macTranscript: some View {
        let sortedMessages = messages
        let shape = self.shape
        let hasError = shape.hasError
        let lastUserMessage = sortedMessages.last(where: { $0.role == .user })
        let freshStarts = shape.freshStarts

        return ScrollViewReader { scrollView in
            // Indicator hidden WHILE GENERATING.
            //
            // Streaming grows the content and auto-scrolls to follow it, so iOS
            // treats every token as a scroll and keeps the bar on screen for the
            // whole answer. It also can't tell the truth while it's up: the
            // thumb's track stops at the composer inset, so at the actual bottom
            // it still sits well short of the end and reads as "there's more
            // below". A scrollbar that is always visible and never accurate is
            // worse than none; it comes back the moment generation stops, where
            // it means what it says.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // A TRANSCRIPT IS NOT A LIST OF THINGS THAT ALL HAVE TO EXIST.
                    //
                    // This was a plain VStack, so every message in the thread was
                    // materialised the moment the thread opened and stayed alive
                    // for as long as it was on screen. Rendering a message is not
                    // cheap in UIKit terms: selectable text is interaction-backed
                    // and each row carries a context menu, so a row costs roughly
                    // 36 CALayers, 4 gesture recognisers and 4 UIInteractions.
                    // MEASURED, hosting this view in a UIWindow
                    // (ConversationScrollBenchmarks):
                    //
                    //     20 msgs →   52 views,   788 layers,  92 gestures,  89 interactions
                    //     60 msgs →  132 views,  2216 layers, 240 gestures, 249 interactions
                    //    200 msgs →  412 views,  7214 layers, 758 gestures, 809 interactions
                    //
                    // Dead straight lines. That is the answer to "why does
                    // scrolling get worse as a chat goes on": UIKit hit-tests
                    // against every one of those recognisers on every touch and
                    // Core Animation commits the whole layer tree every frame,
                    // and neither cares that 195 of the 200 messages are nowhere
                    // near the screen. Nothing was leaking and nothing was
                    // quadratic — the transcript was simply linear in a place a
                    // viewport should have made it constant.
                    //
                    // LazyVStack makes it constant. Only the ForEach is inside
                    // it: the streaming view, the error card, the debug panel and
                    // the "bottom" sentinel stay in the eager VStack below, so
                    // `scrollTo("bottom")` always has a realised target to aim
                    // at — which is the usual way this change breaks a chat.
                    //
                    // The rows must also be cheap to REBUILD, because a lazy row
                    // is destroyed on the way out and recreated on the way back.
                    // MessageView's thinking parse and disclosure state moved out
                    // of per-row @State for exactly that reason.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sortedMessages.enumerated()), id: \.element.id) { index, message in
                            // The provider never saw the turns above this one, so the
                            // transcript shows the break. See `FreshStartRule`.
                            if freshStarts.contains(index) {
                                FreshStartRule()
                            }
                            let showRetry = hasError && message.role == .user && message.id == lastUserMessage?.id
                            // Scoped to the last row. Passing `isGenerating` to
                            // every row made each one auto-expand its reasoning
                            // block whenever the thread had a generation running;
                            // under a lazy stack that would additionally fire
                            // every time an old row scrolled back into view.
                            let isLast = message.id == sortedMessages.last?.id
                            MessageView(message: message,
                                        isLLMRunning: isGenerating && isLast,
                                        onRetry: showRetry ? { onRetry?(message) } : nil)
                                .padding()
                                // A row-size cache lived here for one day
                                // (2026-08-06/07) and is deliberately GONE —
                                // resurrect it only after reading its commit
                                // trail. Its failure modes were livelock
                                // (corrections chasing the two-pass markdown
                                // flap) and painted-over rows (corrections
                                // capped or unpropagated). What actually fixed
                                // the freezes it chased: the same-value
                                // `output` write flood (ChatGeneration) and
                                // Textual's -Onone glue (Vendor/textual, -O in
                                // Debug) — with those in place, both real
                                // freezing thread shapes ride on a Debug
                                // device build with no cache at all
                                // (RealShapeFreezeUITests).
                                .id(message.id.uuidString)
                                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                                .countsAsRealizedRow()

                            offerCard(for: message)
                        }
                    }
                    if isGenerating || handoffBallast {
                        // NOTHING SCROLLS THE TRANSCRIPT WHILE IT STREAMS, AND
                        // THAT IS THE FIX.
                        //
                        // This used to re-issue
                        // `withAnimation(.linear(0.12)) { scrollTo("bottom") }`
                        // on every pacer tick. The reasoning was sound — content
                        // height grows a whole line at a time, so an unanimated
                        // scrollTo teleports ~22pt — but chasing a moving target
                        // with a fresh animation 120 times a second turns every
                        // irregularity in token arrival into an irregularity in
                        // scroll velocity. Tokens do not arrive evenly (SSE
                        // chunking, network buffering) and height does not grow
                        // evenly (line wraps), so the follow inherited both.
                        //
                        // MEASURED from the app's own scroll trace over a
                        // 200-turn thread and a deterministic 1680-word stream
                        // (a local fake SSE server drives the stream; a
                        // follow-checker parses the trace). "Behind" is how much of
                        // the reply had been written but not scrolled to:
                        //
                        //     main      worst  +71pt   span  364pt
                        //     bad245c   worst +761pt   span 1077pt
                        //     this      worst -188pt   span    0pt
                        //
                        // The bad245c profile is the report, line by line:
                        // velocity starts at 140pt/s while "behind" climbs to
                        // 593pt, then halfway through it spikes to 1552pt/s and
                        // "behind" collapses to zero. Slow, then a jump, then
                        // too fast.
                        //
                        // `.defaultScrollAnchor(.bottom, for: .sizeChanges)`
                        // below does the same job in the layout system instead:
                        // when the content grows, the offset moves with it in
                        // the SAME pass. There is no target to chase, no error
                        // term to catch up on, and no animation to restart — so
                        // the text rises at exactly the rate the model produces
                        // it, which is what was asked for.
                        StreamingMessageView()
                        .padding()
                        // LAYOUT BALLAST at the hand-off. Unmounting the
                        // instant generation ends collapses contentH by the
                        // whole reply (2,895pt → 361pt measured) before the
                        // persisted row's lazy estimate realises — a ~300ms
                        // window with the viewport stranded 2,600pt past the
                        // end: the "screen goes blank at the end of
                        // generation" report (2026-08-07). For ~400ms after
                        // the turn ends the view stays MOUNTED but invisible:
                        // the persisted row realises at its exact position
                        // (no visible double — the ballast sits below it,
                        // under the fold) while total height never collapses.
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                            // Plain box write — no invalidation, by design.
                            if isGenerating { ballastHeight.value = h }
                        }
                        // Pinned to the FINAL generating height while serving
                        // as ballast: the reasoning fold at turn end shrinks
                        // the (invisible) content, and an unpinned ballast
                        // leaked that collapse into contentH.
                        .frame(height: isGenerating ? nil : ballastHeight.value,
                               alignment: .top)
                        .opacity(isGenerating ? 1 : 0)
                        .id("streaming")
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                    } else if isPendingGeneration {
                        pendingChip
                            .padding()
                            .id("pending")
                            .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                    }

                    if settings.developerModeEnabled,
                       showDebugInfo,
                       let info = llm.lastRequestDebugInfo,
                       info.threadID == threadID,
                       llm.lastError == nil {
                        RequestDebugView(info: info)
                            .padding()
                            .id("debuginfo")
                            .accessibilityIdentifier("chat.debugCard")
                            .accessibilityValue(info.isE2EEActive ? "E2EE" : "not-e2ee")
                            .transition(.asymmetric(
                                insertion: .opacity.animation(.easeInOut(duration: 0.25).delay(0.15)),
                                removal: .opacity.animation(.easeOut(duration: 0.1))
                            ))
                    }

                    if let error = llm.lastError, llm.lastErrorThreadID == threadID {
                        // Offer a one-tap "turn off web search & retry" only when the
                        // failure is plausibly tool-related: a 400 while web-search
                        // grounding was attached (enabled globally + provider has no
                        // built-in grounding). The model likely can't call tools and
                        // its capabilities weren't known up front (generic endpoint).
                        let groundingAttached = settings.braveGroundingEnabled
                            && !(providerStore?.activeProvider?.capabilities.contains(.builtInGrounding) ?? false)
                        let toolLikely400 = error.httpStatus == 400 && groundingAttached
                        ErrorMessageView(
                            error: error,
                            onDisableWebSearch: toolLikely400 ? {
                                settings.braveGroundingEnabled = false
                                Haptics.play()
                                if let m = lastUserMessage { onRetry?(m) }
                            } : nil,
                            consoleRecovery: Provider.consoleRecovery(
                                for: error,
                                activeProvider: providerStore?.activeProvider
                            )
                        )
                        .padding()
                        .id("error")
                    }

                    // Sentinel that scrollTo targets — always at the very end of content.
                    Color.clear.frame(height: 0).id("bottom")
                }
                // A LINE OF TEXT HAS A MAXIMUM USEFUL LENGTH, AND A MAC WINDOW
                // IS WIDER THAN IT.
                //
                // Assistant replies were laid out edge to edge. At the default
                // 1000pt window that is ~95 characters per line; maximised on a
                // 27" display it is closer to 200. Typographic practice — and
                // every Apple app with a reading surface, Notes, Mail, Safari
                // Reader — puts the comfortable range at 45-75 characters,
                // because the eye loses the start of the next line on the
                // return sweep past that.
                //
                // Nothing was visibly broken, which is why it survived: text
                // that is merely hard to read has no error state. It is also the
                // clearest signal that a layout was designed on a phone, where
                // the window is narrow enough that this never comes up.
                //
                // 720pt lands around 80 characters at the default size, so the
                // column stops growing before it becomes tiring but still uses a
                // large window. Centred, so the conversation stays under the
                // toolbar title and the composer rather than hugging the
                // sidebar.
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, alignment: .center)
                .ignoresSafeArea(.keyboard)
            }
            .accessibilityIdentifier("chat.transcript")
            .scrollIndicators(isGenerating ? .hidden : .automatic)
            // OPENING A THREAD LANDS AT THE BOTTOM WITHOUT BUILDING THE THREAD.
            //
            // With the eager VStack the whole transcript existed before first
            // paint, so `onAppear { scrollTo("bottom") }` had a fully-measured
            // content height to jump into. A LazyVStack does not: at first
            // layout only the top rows exist, so a scrollTo would drag the lazy
            // stack through every message on the way down — realising all of
            // them and paying the exact cost this change removes.
            //
            // `.initialOffset` starts the scroll view at the end and lets rows
            // realise upward from there. Deliberately NOT the plain
            // `.defaultScrollAnchor(.bottom)`, which also re-anchors on every
            // content-size change and would fight the streaming follow below
            // (and the composer's keyboard inset) for control of the offset.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // THE STREAMING FOLLOW, driven explicitly: every content-size
            // change while following coalesces into one unanimated
            // scrollTo("bottom") on the next runloop turn.
            //
            // This replaces `.defaultScrollAnchor(.bottom, for: .sizeChanges)`,
            // which is DELETED — not rescued a fifth time. The anchor failed
            // four ways in one session, and the last two were terminal: rich
            // markdown lays out two passes per frame that disagree about the
            // content height (a sustained ~26pt flap around headings), and the
            // anchor's re-pinning silently DIES the moment the content first
            // crosses the viewport height during that flap — offset frozen at
            // one page while the answer grew 3,900pt below the fold, with
            // `isFollowingStream` true and no interruption of any kind
            // (intr=0 drag=0 follow=1 in the trace at the freeze). A watchdog
            // could re-pin it, but a follow whose primary mechanism can
            // silently stop is the wrong foundation; this one is stateless —
            // each size change independently asks for the bottom, so there is
            // no internal anchor state to wedge.
            //
            // Unanimated on purpose. The old, pre-anchor chase was an ANIMATED
            // scrollTo per tick, and interrupted spring animations are what
            // made it ride unevenly. An unanimated jump per layout pass tracks
            // the content exactly — motion is as smooth as the growth cadence,
            // which the 120Hz pacer already smooths.
            //
            // Two guards, both load-bearing:
            // - `isFollowingStream`: off while idle and off once the user has
            //   scrolled away — the contract of `scrollInterrupted` is that
            //   teemoon stops dragging the viewport back.
            // - `!touchIsDown`: a scrollTo during an active drag cancels the
            //   user's gesture. The 50pt interruption rule needs a drag to get
            //   past 50pt before it latches, so without this guard the follow
            //   would fight — and win — the first 50pt of every scroll-away.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentSize.height
            } action: { old, new in
                guard isFollowingStream, new != old, !touchIsDown else { return }
                guard !followScrollScheduled else { return }
                followScrollScheduled = true
                Task { @MainActor in
                    // COALESCE IN REAL TIME, NOT RUNLOOP TURNS. "One scrollTo
                    // per turn" assumed a turn boundary between cycles — but
                    // scrollTo triggers an IMMEDIATE graph update, the lazy
                    // stack revises its content estimate by thousands of
                    // points inside that update (real threads have 3,000pt
                    // rows), the size change fires this action again, and the
                    // chain of immediate updates never yields: the main
                    // thread wedged inside flushTransactions (hang-reporter,
                    // 2026-08-07: 70/70 samples in the update cycle). A 40ms
                    // floor forces the runloop to actually idle between
                    // follow scrolls — worst case ~25 scrolls/s, invisible
                    // behind a stream, impossible to storm. It also settles
                    // the scroll-away race: the interruption latch always
                    // runs before the sleeping scroll wakes.
                    try? await Task.sleep(for: .milliseconds(40))
                    followScrollScheduled = false
                    guard isFollowingStream, !touchIsDown else { return }
                    scrollView.scrollTo("bottom", anchor: .bottom)
                }
            }
            // NO overscroll clamp lives here, and one was tried (2026-08-07):
            // "when past the content end, scrollTo bottom" made the blank
            // WORSE (597 → 639 overscrolled samples, worst 660 → 7,625pt),
            // because scrollTo targets the bottom sentinel, whose position is
            // derived from the same inflated estimates that caused the
            // overscroll — the clamp scrolls INTO the void. The blank is a
            // symptom of LazyVStack estimation instability under this
            // content's size variance (contentH swings of 10k+ pt in a step),
            // and the fix is architectural, not another rescue.
            .scrollTrace(isGenerating: isGenerating, interrupted: llm.scrollInterrupted,
                         dragged: userDraggedAway, following: isFollowingStream)
            .chatBottomScrollFade(fadeBand)
            // Track when the user has scrolled more than 50pt above the bottom.
            // Auto-scroll to bottom is suppressed while this flag is set, but
            // content continues streaming so it's current when the user scrolls back.
            // WHO MOVED THE VIEWPORT — the user, or the content?
            //
            // Distance from the bottom cannot tell you, and treating it as if it
            // could is what broke streaming on a long thread. A LazyVStack only
            // estimates the height of rows outside the viewport, so it revises
            // `contentSize` by THOUSANDS of points in a single step as it
            // realises them. MEASURED on the phone, mid-generation:
            //
            //     t=16.5s  contentH 42272 -> 45619   (+3347pt, one step)
            //     t=16.7s  offset freezes at 41586
            //     t=32.0s  offset still 41586, contentH 71302  -> 28841pt behind
            //
            // A jump like that clears the 50pt threshold instantly, so the old
            // geometry-only rule declared "the user scrolled away", switched off
            // the `.sizeChanges` anchor, and killed the follow. And it LATCHED:
            // with the anchor off the answer kept growing below the viewport, so
            // the condition stayed true and the follow never came back. The
            // screen sat still for the rest of the reply and only a manual
            // scroll brought the answer back — which is exactly the report.
            //
            // `onScrollPhaseChange` is the honest signal. `.interacting` means a
            // finger, and nothing else sets it; content growth and lazy
            // re-estimation do not. So a drag is required before distance from
            // the bottom is allowed to mean anything.
            .onScrollPhaseChange { old, phase in
                #if DEBUG
                StreamTrace.event("scrollPhase \(String(describing: old))->\(String(describing: phase)) drag=\(userDraggedAway ? 1 : 0)")
                #endif
                touchIsDown = phase == .interacting
                if phase == .interacting { userDraggedAway = true }
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.visibleRect.height < geo.contentSize.height - 50
            } action: { _, awayFromBottom in
                if awayFromBottom {
                    // Away because a finger put it there — honour it. Away
                    // because the content grew or was re-measured — ignore it,
                    // and let the anchor pull the viewport back.
                    guard userDraggedAway else { return }
                    #if DEBUG
                    if !llm.scrollInterrupted {
                        StreamTrace.event("scrollInterrupted SET (awayFromBottom, drag=1)")
                    }
                    #endif
                    llm.scrollInterrupted = true
                    // Track whether the user scrolled away during active
                    // generation. Only update while generating so
                    // post-generation layout changes (e.g. StreamingMessageView
                    // disappearing) don't flip this flag.
                    if isGenerating { wasFollowingGeneration = false }
                } else {
                    // Back at the end: following resumes, and the next drag has
                    // to earn the interruption again.
                    #if DEBUG
                    if llm.scrollInterrupted {
                        StreamTrace.event("scrollInterrupted CLEARED (back at bottom)")
                    }
                    #endif
                    llm.scrollInterrupted = false
                    userDraggedAway = false
                }
            }
            // A DIFFERENT THREAD IS A DIFFERENT SCROLL VIEW.
            //
            // Switching threads used to be handled by `onChange(of: threadID)`
            // firing a `scrollTo("bottom")` into the surviving scroll view. That
            // relied on the old eager stack: the new thread's rows all existed
            // immediately, so the jump was free. With a lazy stack the scroll
            // view would start at the top of the new thread and have to realise
            // its way down to the end.
            //
            // Re-identifying instead makes the switch take the same path as a
            // cold open, so `.defaultScrollAnchor(.bottom, for: .initialOffset)`
            // above places it at the end before anything is realised. Discarding
            // the old scroll state is not a loss — it was being thrown away by
            // the scrollTo anyway.
            .id(threadID)
            .onAppear {
                scrollView.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: llm.running) { _, running in
                if running {
                    showDebugInfo = false
                    wasFollowingGeneration = true
                    // ARM the hand-off ballast NOW, at generation start — not
                    // at generation end. onChange observers run after the
                    // update in which `isGenerating` flips false, so arming
                    // in the false-branch left a one-frame unmount gap: the
                    // full contentH collapse for ~100ms (6,851pt past-end in
                    // the gate's trace) before the ballast re-mounted the
                    // view. Armed here, the mount condition
                    // `isGenerating || handoffBallast` never has a hole.
                    handoffBallast = true
                    // llm.scrollInterrupted is already reset inside generate(), but
                    // we scroll to bottom explicitly so the new StreamingMessageView is visible.
                    Task { @MainActor in
                        scrollView.scrollTo("bottom", anchor: .bottom)
                    }
                } else {
                    // Hold the streaming view as invisible layout ballast
                    // through the hand-off — see the mount site. 400ms is
                    // enough for the persisted row to realise; the token
                    // scroll below fires at +500ms, after the ballast is gone
                    // and the layout is settled.
                    handoffBallast = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        handoffBallast = false
                    }
                    withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
                        showDebugInfo = true
                    }
                    // The immediate end-scroll is GONE, deliberately: during
                    // the ballast window "bottom" sits below the invisible
                    // streaming view, and scrolling there is the blank this
                    // hand-off work removes. The scrollToBottomToken handler
                    // (+500ms) does the one final landing on settled layout.
                }
            }
            // Fires after ChatView increments scrollToBottomToken, which happens after
            // sendMessage() commits the assistant message (or on the error path). By the
            // time this observer runs, the message is in SwiftData and the ForEach has
            // laid it out, so scrollTo("bottom") lands at the true end of content.
            .onChange(of: llm.scrollToBottomToken) { _, _ in
                guard wasFollowingGeneration else { return }
                Task { @MainActor in
                    // Wait for the debug panel spring animation (0.4s) to finish laying out
                    // before scrolling, otherwise the "bottom" sentinel isn't at its final position.
                    try? await Task.sleep(for: .milliseconds(500))
                    withAnimation(.easeOut(duration: 0.25)) {
                        scrollView.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
        .textual.tableStyle(MinimalChatTableStyle())
        .textual.tableCellStyle(MinimalChatTableCellStyle())
        .blockingRemoteTranscriptAttachments()
    }
    #endif

    // MARK: - iOS: the UIKit transcript

    #if !os(macOS)
    /// What crosses into the collection view is a LIST OF IDENTIFIERS and a
    /// function from identifier to view. Nothing about how a message looks
    /// lives on the other side of that boundary — the rendering stack
    /// (MessageView, Textual, the offer card, the error card) is not being
    /// rewritten, only rehosted.
    private var uiKitTranscript: some View {
        let shape = self.shape
        return TranscriptView(
            transcript: transcriptItems(shape),
            tail: tailItems,
            threadID: threadID,
            isGenerating: isGenerating,
            interrupted: llm.scrollInterrupted,
            volatileItems: volatileItems(shape),
            chrome: ChatChrome(bottom: fadeBand),
            streamingContent: isGenerating ? AnyView(streamingRow) : nil,
            anchorItem: shape.lastUserMessageID.map(TranscriptItem.message),
            scrollToEndToken: scrollToEndToken,
            scrollToEndAnimated: scrollToEndAnimated,
            scrollTargetID: scrollTargetID,
            scrollTargetFraction: scrollTargetFraction,
            scrollTargetToken: scrollTargetToken,
            onInterruptionChanged: { interrupted in
                llm.scrollInterrupted = interrupted
                // The follow's fate for THIS turn, captured while it happens.
                // Read at turn end to decide whether the transcript may land on
                // the answer or must leave the user where they went.
                if interrupted, isGenerating { wasFollowingGeneration = false }
            },
            rowBuilder: { item in AnyView(row(for: item, shape: shape)) }
        )
        // Full-bleed: the transcript runs under the title and the
        // composer. Both dissolves are overlays sized from measured
        // chrome (`chat.titleBlock` and `ChatChrome.bottom`), not from
        // a status-bar constant. Keyboard is honoured.
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .id(threadID)
        // Consume the search deep-link for this thread. Keyed on the STAMP:
        // a result tap for the thread already on screen changes no other
        // input, but must still jump.
        .task(id: deepLink.stamp) {
            guard let target = deepLink.consume(for: threadID) else { return }
            scrollTargetID = target.messageID
            scrollTargetFraction = target.fraction
            scrollTargetToken += 1
        }
        .onChange(of: llm.running) { _, running in
            debugRevealTask?.cancel()
            if running {
                showDebugInfo = false
                wasFollowingGeneration = true
            } else if settings.developerModeEnabled {
                // After the hand-off, not in it. The settle pin has to hold
                // the end while the persisted row takes its real height;
                // revealing the card in that same apply cancels the pin and
                // parks the viewport on the top of the reply.
                debugRevealTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    showDebugInfo = true
                }
            } else {
                showDebugInfo = true
            }
            // NO HAND-OFF BALLAST, and its absence is the point. The SwiftUI
            // transcript held the streaming view mounted-but-invisible for
            // 400ms so `contentH` would not collapse by the whole reply while
            // the persisted row's lazy ESTIMATE caught up (measured 6,851pt
            // past-end). The collection view swaps both in one unanimated
            // snapshot: the streaming item leaves the tail and the message
            // joins the transcript in the same commit, so there is no
            // intermediate height for a ballast to prop up. Three ballast
            // iterations each fixed one leak and revealed another; this is
            // what they were approximating.
        }
        // Fires after ChatView increments scrollToBottomToken, which happens
        // after sendMessage() commits the assistant message (or on the error
        // path) — so the message is in SwiftData and the debug card has been
        // decided. One landing on settled layout.
        .onChange(of: llm.scrollToBottomToken) { _, _ in
            endScrollTask?.cancel()
            guard wasFollowingGeneration else { return }
            if settings.developerModeEnabled {
                // Land after the card's insert animation has a real height,
                // not the pre-insert end.
                endScrollTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    guard !Task.isCancelled else { return }
                    scrollToEndAnimated = true
                    scrollToEndToken += 1
                }
            } else {
                scrollToEndAnimated = false
                scrollToEndToken += 1
            }
        }
        // The keyboard is a SAFE-AREA change, and the collection view adjusts
        // its content inset for it — so while a turn is running the follow
        // rides the inset for free, inside the layout pass, and this observer
        // is not involved at all (constraint 7). It exists for the IDLE
        // thread: focusing the composer on a finished conversation should
        // bring the last answer up above the keyboard.
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification)) { _ in
            guard !llm.scrollInterrupted else { return }
            scrollToEndAnimated = false
            scrollToEndToken += 1
        }
    }

    // MARK: Items

    private func transcriptItems(_ shape: Shape) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        items.reserveCapacity(messages.count + 1)
        for (index, message) in messages.enumerated() {
            if shape.freshStarts.contains(index) {
                items.append(.freshStart(before: message.id))
            }
            items.append(.message(message.id))
            if llm.offerByMessageID[message.id] != nil {
                items.append(.offer(message.id))
            }
        }
        return items
    }

    /// Everything transient, in its own section so none of it diffs the
    /// conversation. Order matches the eager VStack the SwiftUI transcript
    /// keeps below its lazy stack.
    private var tailItems: [TranscriptItem] {
        var items: [TranscriptItem] = []
        // The streaming view is NOT here — it is mounted as a trailing subview
        // of the scroll view, because a self-sizing cell that grows on every
        // pacer tick invalidates collection-view layout on every pacer tick.
        // See `TranscriptSection`.
        if !isGenerating, isPendingGeneration {
            items.append(.pending)
        }
        if showsDebugCard {
            items.append(.debugInfo(turn: llm.scrollToBottomToken))
        }
        if let error = llm.lastError, llm.lastErrorThreadID == threadID {
            items.append(.error(String(describing: error)))
        }
        return items
    }

    /// Rows whose CONTENTS depend on state outside their own identity. Exactly
    /// one today: the last user message grows a retry button when the turn
    /// fails, without becoming a different message. A cell that is already on
    /// screen holds the view it was built with, so this is how it hears.
    private func volatileItems(_ shape: Shape) -> Set<TranscriptItem> {
        guard shape.hasError, let id = shape.lastUserMessageID else { return [] }
        return [.message(id)]
    }

    // MARK: Rows

    @ViewBuilder
    private func row(for item: TranscriptItem, shape: Shape) -> some View {
        Group {
            switch item {
            case .freshStart:
                FreshStartRule()
            case .message(let id):
                messageRow(id, shape: shape)
            case .offer(let id):
                if let message = messages.first(where: { $0.id == id }) {
                    offerCard(for: message)
                }
            case .pending:
                pendingChip.padding()
            case .debugInfo:
                if let info = llm.lastRequestDebugInfo {
                    RequestDebugView(info: info)
                        .padding()
                        // Hosting measures in two passes. Without this the
                        // first size is the header and the rest of the card
                        // paints a frame later as the cell grows.
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat.debugCard")
                        .accessibilityValue(info.isE2EEActive ? "E2EE" : "not-e2ee")
                }
            case .error:
                errorCard
            }
        }
        .modifier(rowChrome)
    }

    /// The streaming view, dressed the same as a row but mounted as a trailing
    /// subview of the scroll view rather than as a cell — see
    /// `TranscriptSection` for why that distinction is the whole ball game.
    private var streamingRow: some View {
        StreamingMessageView()
            .padding()
            .modifier(rowChrome)
    }

    /// EVERY HOSTED VIEW IS ITS OWN SWIFTUI WORLD. `UIHostingConfiguration` and
    /// `UIHostingController` each start a fresh hosting context, so nothing the
    /// host set on the transcript's environment — the observable models, the
    /// Textual table styling — reaches a row or the streaming view unless it is
    /// set here.
    private var rowChrome: TranscriptRowChrome {
        TranscriptRowChrome(llm: llm, settings: settings, providerStore: providerStore)
    }

    @ViewBuilder
    private func messageRow(_ id: UUID, shape: Shape) -> some View {
        if let message = messages.first(where: { $0.id == id }) {
            let showRetry = shape.hasError && message.role == .user
                && message.id == shape.lastUserMessageID
            // `isLLMRunning` stays scoped to the turn in flight. Passed to
            // every row it auto-expands every historic reasoning block the
            // moment a generation starts.
            MessageView(message: message,
                        isLLMRunning: isGenerating && message.id == messages.last?.id,
                        onRetry: showRetry ? { onRetry?(message) } : nil)
                .padding()
        }
    }

    @ViewBuilder
    private var errorCard: some View {
        if let error = llm.lastError, llm.lastErrorThreadID == threadID {
            // Offer a one-tap "turn off web search & retry" only when the
            // failure is plausibly tool-related: a 400 while web-search
            // grounding was attached (enabled globally + provider has no
            // built-in grounding). The model likely can't call tools and its
            // capabilities weren't known up front (generic endpoint).
            let groundingAttached = settings.braveGroundingEnabled
                && !(providerStore?.activeProvider?.capabilities.contains(.builtInGrounding) ?? false)
            let toolLikely400 = error.httpStatus == 400 && groundingAttached
            ErrorMessageView(
                error: error,
                onDisableWebSearch: toolLikely400 ? {
                    settings.braveGroundingEnabled = false
                    Haptics.play()
                    if let m = messages.last(where: { $0.role == .user }) { onRetry?(m) }
                } : nil,
                consoleRecovery: Provider.consoleRecovery(
                    for: error,
                    activeProvider: providerStore?.activeProvider
                )
            )
            .padding()
        }
    }
    #endif
}

// A 96pt gradient mask used to live here, fading the message list out above the
// composer (and tracking the keyboard so the band sat directly above it). Removed:
// on device it reads as text dissolving mid-sentence — the last line or two of an
// answer become unreadable exactly when you are reading them. Content now runs
// crisp to the composer and simply passes behind the glass capsule.
