//
//  GenerationActivityChipView.swift
//  teemoon

import SwiftUI

/// Unified activity indicator shown during LLM generation before output tokens arrive.
/// Transitions through three states: thinking -> searching -> sourcesFound.
struct GenerationActivityChipView: View {
    enum ActivityState: Equatable {
        case thinking
        case searching
        case sourcesFound(Int)
    }

    let state: ActivityState
    var elapsedTime: TimeInterval?
    @State private var chipOpacity: Double = 1.0

    private var isActive: Bool {
        state == .thinking || state == .searching
    }

    private var iconName: String {
        switch state {
        case .thinking: return "sparkles"
        case .searching, .sourcesFound: return "globe"
        }
    }

    private var label: String {
        switch state {
        case .thinking:
            if let t = elapsedTime, t >= 1 {
                return "thinking... \(Int(t))s"
            }
            return "thinking..."
        case .searching: return "searching..."
        case .sourcesFound(let n): return "\(n) source\(n == 1 ? "" : "s")"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                // .id forces SwiftUI to treat an icon swap as a new view,
                // so the transition crossfades rather than snapping.
                .id(iconName)
                .font(.caption2)
                .transition(.opacity.combined(with: .scale(0.8)))
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                // The per-second tick must be LAYOUT-INERT. This label lives
                // inside the transcript's content, and the follow answers
                // every content-size change with a scrollTo — an animated
                // width change here meant ~15 frames of size flutter per
                // second, and the follow rode each one: the chip visibly
                // bounced through the whole reasoning phase. Monospaced
                // digits hold the width between ticks; the update applies
                // without animation, so a digit-count change is one discrete
                // step, not a chase.
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(.secondary)
        .background(Capsule().fill(.fill))
        // One element with a stable id so a UI test can ask "is the chip on
        // screen right now" without matching on label text — "thinking..."
        // also appears in the collapsible reasoning block above, and matching
        // that would report the chip as present when it isn't.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.activityChip")
        .opacity(chipOpacity)
        .animation(.spring(duration: 0.35, bounce: 0.1), value: state)
        .onAppear { startBreathing() }
        .onChange(of: isActive) { _, active in
            if active { startBreathing() } else { stopBreathing() }
        }
    }

    private func startBreathing() {
        guard isActive else { return }
        chipOpacity = 1.0
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
            chipOpacity = 0.4
        }
    }

    private func stopBreathing() {
        withAnimation(.easeInOut(duration: 0.15)) {
            chipOpacity = 1.0
        }
    }
}

#Preview("Activity Chip") {
    VStack(alignment: .leading, spacing: 16) {
        GenerationActivityChipView(state: .thinking)
        GenerationActivityChipView(state: .thinking, elapsedTime: 45)
        GenerationActivityChipView(state: .searching)
        GenerationActivityChipView(state: .sourcesFound(1))
        GenerationActivityChipView(state: .sourcesFound(5))
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .preferredColorScheme(.dark)
}
