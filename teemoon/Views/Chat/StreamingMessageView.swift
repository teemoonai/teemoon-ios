//
//  StreamingMessageView.swift
//  teemoon

import SwiftUI
import Textual

/// Shown during active token generation. Renders llm.output paced by
/// DisplayLinkPacer via StructuredText. When generation ends, MessageView takes
/// over with the final persisted content.
///
/// It does NOT drive the transcript's scroll position. It used to: an
/// `onScroll` callback fired on every paced text change, every tool-execution
/// change and every stall tick, and ConversationView answered each one with an
/// animated `scrollTo("bottom")`. That chase is what made a streaming reply
/// scroll unevenly — see the note in ConversationView. The follow is now a
/// `.defaultScrollAnchor(.bottom, for: .sizeChanges)` on the scroll view, which
/// needs no telling when the content grows.
struct StreamingMessageView: View {
    @Environment(ChatGeneration.self) var llm
    @State private var pacer = DisplayLinkPacer()
    @State private var collapsed = false
    /// Cached thinking parse — only recomputed when the paced text actually changes.
    @State private var lastParsedOutput = ""
    @State private var parsedThinking: String?
    @State private var parsedAfterThink: String?
    @State private var isStillThinking = false
    @State private var stallTimer: Task<Void, Never>?
    @State private var isStalled = false
    @State private var stall = StallIndicator(at: .now)
    #if DEBUG
    /// `-scrollTrace` only: samples the pipeline flags every 250ms so a stall
    /// window has state inside it, not just a gap. See `StreamTrace.record`.
    @State private var traceHeartbeat: Task<Void, Never>?
    #endif

    @ViewBuilder
    private func renderedText(_ content: String, fading: String? = nil) -> some View {
        // Split rather than one StructuredText: blocks that are already finished
        // keep their SwiftUI identity and stop re-parsing and re-laying-out on
        // every pacer tick. See StreamingMarkdownView.
        StreamingMarkdownView(content: content, fadingText: fading)
    }


    private func updateThinkingParse() {
        let output = pacer.text
        #if DEBUG
        recordTraceSample(kind: "tick")
        #endif
        guard output != lastParsedOutput else { return }
        lastParsedOutput = output
        let (t, a) = ThinkingContentParser.parse(output)
        parsedThinking = t
        parsedAfterThink = a
        let stillThinking = ThinkingClock.isStillThinking(output)
        if stillThinking != isStillThinking {
            isStillThinking = stillThinking
            llm.isThinking = stillThinking
        }
    }

    private var fadingText: String? {
        pacer.fadeFrom.map { String(pacer.text.dropFirst($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func chipState(at now: Date) -> GenerationActivityChipView.ActivityState {
        if llm.isExecutingTools {
            if !llm.groundingSources.isEmpty {
                return .sourcesFound(llm.groundingSources.count)
            }
            return .searching
        }
        if let wait = llm.providerWait, wait.shownSeconds(at: now) != nil {
            return .waitingForProvider(wait.providerName)
        }
        if let line = llm.engineLoadLine(at: now) { return .loadingModel(line) }
        return llm.superseding.isActive ? .thinkingHarder : .thinking
    }

    /// The counter is the whole turn's (the maintainer), in every state.
    private func chip(at now: Date) -> GenerationActivityChipView {
        GenerationActivityChipView(state: chipState(at: now), elapsedTime: llm.elapsedTime)
    }

    /// Whether the chip in the trailing slot is VISIBLE. The slot itself is
    /// always there while text is on screen — see the note at the call site.
    ///
    /// `llm.isAwaitingModel` is the load-bearing addition. `isStalled` is a
    /// 3-second guess at the same question, and it has a hole exactly the width
    /// of a follow-up round trip plus prefill: after a tool round the
    /// transcript already holds text, so the leading chip is gone and nothing
    /// changes on screen while the model works.
    ///
    /// A model only falls in that hole if it wrote something BEFORE calling the
    /// tool, which is why this looked model-specific. Measured on the same
    /// query: DeepSeek V4 Flash emits a 63-character preamble with its tool
    /// call and first shows text at 0.6s, leaving a 3.0s blind window per tool
    /// round; GLM-5.1 emits no content at all on those turns, so its text stays
    /// empty, the leading chip covers everything, and its worst window is 0.6s
    /// of ordinary token jitter.
    ///
    /// `scrollInterrupted` is deliberately NOT consulted — hiding a progress
    /// indicator from the one user who has scrolled away to wait is backwards.
    /// 047e4fc removed it for exactly that reason; 47ef09b re-added it by
    /// accident while moving the chip back inline, and this comment and the
    /// code disagreed until the second-tool-round diagnosis caught it. The
    /// original worry — the chip appearing as content and yanking the
    /// transcript — no longer applies: once `scrollInterrupted` is set the
    /// `.sizeChanges` follow anchor in ConversationView is off, so content
    /// appearing at the bottom cannot move a scrolled-away viewport.
    private var showTrailingChip: Bool {
        Self.trailingChipVisible(
            hasText: !pacer.text.isEmpty, stalled: isStalled,
            executingTools: llm.isExecutingTools, awaitingModel: llm.isAwaitingModel)
    }

    /// The trailing chip's visibility rule, pure so it is testable: text on
    /// screen, plus some form of work the screen is not otherwise showing.
    ///
    /// These four inputs are the COMPLETE list. Scroll state is not one of
    /// them — see `showTrailingChip` — and `TrailingChipVisibilityTests` pins
    /// both the truth table and that omission.
    static func trailingChipVisible(hasText: Bool, stalled: Bool,
                                    executingTools: Bool, awaitingModel: Bool) -> Bool {
        hasText && (stalled || executingTools || awaitingModel)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if pacer.text.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    chip(at: context.date)
                }
                .transition(Motion.grow(from: 0.95, anchor: .leading, reduceMotion: reduceMotion))
            }

            if !pacer.text.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    if let thinking = parsedThinking {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Button { collapsed.toggle() } label: {
                                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                        .scaledFont(size: 12)
                                        .fontWeight(.medium)
                                }
                                if isStillThinking {
                                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                                        Text(ThinkingClock.liveLabel(elapsed: llm.elapsedTime)).italic()
                                    }
                                } else {
                                    Text("thought for \((llm.thinkingTime ?? llm.elapsedTime ?? 0).formatted)").italic()
                                }
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)

                            if !collapsed, !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                HStack(spacing: 12) {
                                    Capsule()
                                        .frame(width: 2)
                                        .padding(.vertical, 1)
                                        .foregroundStyle(.fill)
                                    renderedText(thinking)
                                        .textual.textSelection(.enabled)
                                        .foregroundStyle(.secondary)
                                }
                                // The Capsule takes any height offered; without this the text centres in it.
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 5)
                            }
                        }
                        .contentShape(.rect)
                        .onTapGesture {
                            collapsed.toggle()
                            llm.collapsed = collapsed
                        }
                    }

                    if let afterThink = parsedAfterThink {
                        renderedText(afterThink, fading: fadingText)
                            .textual.textSelection(.enabled)
                    } else if parsedThinking == nil {
                        renderedText(pacer.text, fading: fadingText)
                            .textual.textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Identified on the CONTAINER so a UI test can tell whether the
                // answer is still growing, from its HEIGHT — one query, one
                // property, no enumeration.
                //
                // Two cheaper signals were tried and both lied. Enumerating
                // `app.staticTexts` races the stream (the query snapshots a
                // count, then re-resolves each element, and a paragraph
                // arriving in between invalidates an index). Reading the text
                // element's own label resolves to StructuredText's FIRST block,
                // which stops changing the moment a second paragraph appears —
                // so a streaming answer read as frozen for 10s.
                .accessibilityIdentifier("chat.streamingText")
            }

            // REAL CONTENT, not an overlay — and that is the whole point.
            //
            // A chip that costs no layout cannot be scrolled into view. Pinned
            // to the bottom of the transcript, an overlay hanging below the
            // last line lands in `ChatBottomScrollFade`'s ramp and behind the
            // composer: rendered and measured, it came out dimmed to a ghost
            // and overlapping the last line. As content it pushes the text up
            // and `scrollTo(bottom)` brings it into the clear.
            //
            // The ~21pt it costs while visible is the price of being adjacent
            // AND legible. Two attempts to avoid paying it — a permanently
            // reserved slot, then a chip pinned above the composer — each
            // traded one of those away, and both were worse.
            if showTrailingChip {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    chip(at: context.date)
                }
                .padding(.top, 4)
                .transition(Motion.grow(from: 0.95, anchor: .leading, reduceMotion: reduceMotion))
            }
        }
        // The streaming view is hosted in a full-width box (UIKit trailing
        // subview, or a cell). Without this the VStack hugs the chip when
        // there is no text yet, and UIHostingController centres that narrow
        // view — the chip flashes in the middle of the transcript.
        .frame(maxWidth: .infinity, alignment: .leading)
        // NO LAYOUT ANIMATION HERE, AND THE VERTICAL AXIS IS WHY.
        //
        // These two were `.spring(duration: 0.3, bounce: 0.1)`. The host's
        // frame is set from `sizeThatFits`, which reports the TARGET height
        // the instant the chip mounts (+35pt: 21 chip, 4 padding, 8 spacing),
        // while the rendered content is still springing from the old height.
        // `UIHostingController` centres content that does not fill its frame
        // — the note above says so for the WIDTH, and nothing pinned the
        // HEIGHT — so a 35pt disagreement displaces everything drawn by half
        // of it, 17.5pt, for the length of the spring.
        //
        // That is "the transcript shifts up and down while I am scrolled up"
        // (2026-08-25): 17.7pt down on mount, back to exactly zero on
        // landing, once per stall. It is invisible to every trace column,
        // because `offset`, the streaming view's origin and `streamH` are all
        // correct throughout — only the DRAWN position is wrong. It took a
        // filmed park to see it.
        //
        // `maxHeight: .infinity, alignment: .top` is NOT the fix: the height
        // is measured with `layoutFittingExpandedSize`, so an expanding frame
        // would report a screen-tall reply.
        //
        // SCOPED WITH `value:`, AND THAT IS LOAD-BEARING. A bare
        // `.transaction { $0.animation = nil }` overrides the whole subtree
        // and killed the chip's breathing pulse —
        // `GenerationActivityChipView.startBreathing()` animates `chipOpacity`
        // 1.0 <-> 0.4 with a `repeatForever`, and it lives inside this view.
        // Keyed to the two values that move LAYOUT, only their updates are
        // unanimated; the pulse, the chip's own `value: state` spring and the
        // disclosure toggle all keep animating.
        //
        // `.transaction` rather than deleting the modifiers, because the
        // hand-off runs a `withAnimation` that would otherwise be inherited
        // and rebuild exactly this bug from outside the view. The cost is
        // that the chip's arrival no longer springs the layout open.
        .transaction(value: showTrailingChip) { $0.animation = nil }
        .transaction(value: pacer.text.isEmpty) { $0.animation = nil }
        .onChange(of: pacer.text) { _, _ in updateThinkingParse() }
        // The stall rule measures from the last arrival, not from what the reveal has drawn.
        .onChange(of: pacer.arrivals) { _, _ in driveStall(textArrived: true) }
        .onChange(of: llm.isExecutingTools) { _, executing in
            if executing {
                stallTimer?.cancel()
            } else {
                driveStall(textArrived: false)
            }
        }
        .onChange(of: llm.searchQueries) { _, _ in
        }
        .onAppear {
            pacer.attach(onDevice: { llm.turnIsOnDevice }) { llm.output }
            updateThinkingParse()
            driveStall(textArrived: false)
            #if DEBUG
            startTraceHeartbeat()
            #endif
        }
        .onDisappear {
            pacer.detach()
            stallTimer?.cancel()
            #if DEBUG
            traceHeartbeat?.cancel()
            traceHeartbeat = nil
            #endif
        }
    }

    #if DEBUG
    private func recordTraceSample(kind: String) {
        StreamTrace.record(
            output: llm.output.count, paced: pacer.text.count,
            executingTools: llm.isExecutingTools, awaitingModel: llm.isAwaitingModel,
            thinking: llm.isThinking, sources: llm.groundingSources.count,
            chipVisible: showTrailingChip, kind: kind)
    }

    private func startTraceHeartbeat() {
        guard ScrollTraceEnabled.value, traceHeartbeat == nil else { return }
        traceHeartbeat = Task { @MainActor in
            while !Task.isCancelled {
                recordTraceSample(kind: "beat")
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
    #endif

    /// Feeds the stall rule and sleeps until it can next change without new text.
    private func driveStall(textArrived: Bool) {
        stallTimer?.cancel()
        if textArrived { stall.textArrived(at: .now) } else { stall.reset(at: .now) }
        settleStall()
    }

    private func settleStall() {
        let shown = stall.settle(at: .now)
        if isStalled != shown { isStalled = shown }
        guard let deadline = stall.nextDeadline else { return }
        stallTimer = Task {
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            settleStall()
        }
    }
}
