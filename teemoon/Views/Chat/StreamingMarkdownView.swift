//
//  StreamingMarkdownView.swift
//  teemoon
//
//  Renders markdown that is still arriving, without re-rendering the part that
//  has already arrived.
//
//  `StructuredText` re-parses whenever its `markup` string changes and rebuilds
//  its whole block tree from a fresh `AttributedString`. Handing it one growing
//  document means every paragraph of a long answer re-parses and re-lays-out on
//  every pacer tick. Here the settled blocks are separate `StructuredText`
//  views with strings that never change again, so SwiftUI skips them and only
//  the tail costs anything per frame.
//
//  Once generation ends, MessageView renders the final content as a single
//  `StructuredText` — which is what makes the one real trade-off acceptable:
//  text selection is per-`StructuredText`, so selection can't span blocks while
//  the answer is still streaming.
//

import SwiftUI
import Textual

struct StreamingMarkdownView: View {
    let content: String
    /// The paragraph that appeared whole and is fading in ("whole if quick"); its block fades on appear.
    var fadingText: String? = nil

    /// Textual's block spacing is a multiple of the font size, so the gaps have
    /// to scale with Dynamic Type the same way.
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 17

    var body: some View {
        let split = MarkdownStreamSplitter.split(content)
        let blocks = split.tail.isEmpty ? split.settled : split.settled + [split.tail]

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                // Identity is the offset, and a settled block at a given offset
                // never changes its text — that is the whole point. The tail is
                // always last, so it is the only view that re-renders.
                //
                // The tail is still being written: incomplete links and tables
                // would otherwise paint as raw markdown and shrink when they
                // close. Settled blocks are complete and must stay verbatim.
                let rendered = (index == blocks.count - 1 && !split.tail.isEmpty)
                    ? MarkdownStreamSplitter.displayTail(block)
                    : block
                StructuredText.cached(rendered)
                    .modifier(FadeInOnAppear(active: fadingText.map { fades(block, in: $0) } ?? false))
                    .padding(.top, index == 0 ? 0 : gap(blocks[index - 1], block))
            }
        }
    }

    private func fades(_ block: String, in fading: String) -> Bool {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && fading.contains(trimmed)
    }

    private func gap(_ previous: String, _ next: String) -> CGFloat {
        MarkdownStreamSplitter.collapsedSpacingEm(after: previous, before: next) * fontSize
    }
}

/// Opacity only: a layout animation here would move the transcript under a reader (see StreamingMessageView).
private struct FadeInOnAppear: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(active && !visible && !reduceMotion ? 0 : 1)
            .onAppear {
                guard active, !reduceMotion else { return }
                withAnimation(.easeOut(duration: StreamReveal.fadeMs / 1000)) { visible = true }
            }
    }
}

#Preview("Streaming — mid-answer") {
    ScrollView {
        StreamingMarkdownView(
            content: """
                Here is the short version, and then the detail.

                ## What changed

                - The parse moved off the hot path
                - The settled blocks stopped re-rendering

                ```swift
                func stream() {
                    print("only the tail re-renders")
                }
                ```

                | Approach | Cost |
                | --- | --- |
                | Whole document | O(n) |

                > Only the tail should cost anything per frame.

                And this last paragraph is still being writt
                """
        )
        .padding()
    }
}
