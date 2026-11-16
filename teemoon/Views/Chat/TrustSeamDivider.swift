//
//  TrustSeamDivider.swift
//  teemoon
//

import SwiftUI

/// A single dashed horizontal rule — the visual "seam" between the hardware-
/// measured items and the action-log-pinned recipe.
struct DashedRule: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return p
    }
}

/// The trust seam: a dashed divider with a centered caption marking that
/// everything below it is pinned by the action log (vs the measured items
/// above, which the hardware measures at boot).
struct TrustSeamDivider: View {
    var binding: ActionLogBinding.Result? = nil

    var body: some View {
        HStack(spacing: 8) {
            rule
            Text(TrustScopeText.seamCaption(binding))
                .font(.caption2).foregroundStyle(.tertiary)
                // Wraps, never .fixedSize(): one line is wider than the phone at the largest text sizes.
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            rule
        }
        .padding(.vertical, 3)
    }

    private var rule: some View {
        DashedRule()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(.tertiary)
            .frame(height: 1)
    }
}
