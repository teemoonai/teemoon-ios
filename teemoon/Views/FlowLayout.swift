//
//  FlowLayout.swift
//  teemoon
//
//  A wrapping row: items run on as many lines as they need, each at its own width. An HStack squeezes the
//  last item into a sliver instead (Android's link rows, 2026-11-01). FlowLayoutTests pins `widths`.
//

import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    /// Each item's width: its own, or the whole line when it is wider than that. Never narrower than either.
    static func widths(ideal: [CGFloat], available: CGFloat) -> [CGFloat] {
        ideal.map { min($0, available) }
    }

    /// Which items share a line, in order.
    static func lines(widths: [CGFloat], available: CGFloat, spacing: CGFloat) -> [[Int]] {
        var out: [[Int]] = []
        var x: CGFloat = 0
        for (i, w) in widths.enumerated() {
            if out.isEmpty || (x > 0 && x + w > available) {
                out.append([i]); x = w + spacing
            } else {
                out[out.count - 1].append(i); x += w + spacing
            }
        }
        return out
    }

    private func measure(_ subviews: Subviews, available: CGFloat) -> (sizes: [CGSize], lines: [[Int]]) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let widths = Self.widths(ideal: ideal, available: available)
        let sizes = zip(subviews, widths).map { view, w in view.sizeThatFits(ProposedViewSize(width: w, height: nil)) }
        return (sizes, Self.lines(widths: widths, available: available, spacing: spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Asked for an ideal size (no width offered), claim the widest item, not the whole row on one line:
        // a parent that sizes to its children would otherwise grow past the screen.
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let (sizes, lines) = measure(subviews, available: available)
        var height: CGFloat = 0, widest: CGFloat = 0
        for line in lines {
            height += (line.map { sizes[$0].height }.max() ?? 0) + (height > 0 ? lineSpacing : 0)
            widest = max(widest, line.map { sizes[$0].width }.reduce(0, +) + spacing * CGFloat(line.count - 1))
        }
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (sizes, lines) = measure(subviews, available: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for i in line {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
            }
            y += (line.map { sizes[$0].height }.max() ?? 0) + lineSpacing
        }
    }
}
