//
//  FreshStartRule.swift
//  teemoon
//
//  The break in a transcript answered by a provider that never sees the
//  conversation. Brave Answers today: `maxMessages: 1` means every question is
//  sent alone, so "and the second one?" arrives with no idea what the first was.
//
//  This is drawn rather than explained. The caption that used to sit above the
//  composer described the limitation in the abstract, permanently, for a fact
//  that never changes — so it read as a warning banner and went invisible. The
//  discontinuity is real and it has a location, so mark the location: the same
//  move as a time separator in Messages. It appears where the break happens,
//  scrolls away with the history it belongs to, and costs no standing layout.
//
//  Where the fact still lives durably: `WhereLocality` leads the provider's
//  caption with "single turn q&a", which the Where row shows before the provider
//  is picked and the chip shows for as long as it is selected.
//

import SwiftUI

/// Which turns in a transcript begin a session the provider answers blind.
///
/// Pure, and separated from the view so it can be asserted on: the off-by-one
/// here (the FIRST question is not a fresh start — nothing preceded it) is the
/// kind of thing no preview shows and no screenshot catches.
enum FreshStart {

    /// Indices in `roles` that should be preceded by a rule.
    ///
    /// Every user turn except the first, and only when the provider answers one
    /// question at a time. Tested by capability, never by provider name, so
    /// anything else with the same shape reads the same way.
    ///
    /// Assistant messages are never marked: the break belongs to the QUESTION
    /// that will be sent alone, not to the answer that came back.
    static func indices(roles: [Role], singleTurn: Bool) -> Set<Int> {
        guard singleTurn else { return [] }
        var result: Set<Int> = []
        var seenUserTurn = false
        for (i, role) in roles.enumerated() where role == .user {
            // The first question is not a fresh start — there is no conversation
            // behind it yet for the provider to have missed.
            if seenUserTurn { result.insert(i) }
            seenUserTurn = true
        }
        return result
    }
}

/// A dashed rule labelled "starts fresh", drawn between turns.
///
/// `.tertiary` and caption2: this is structure, not a message. It should read
/// the way a date separator does — noticed when looked for, ignored otherwise.
struct FreshStartRule: View {
    var body: some View {
        HStack(spacing: 8) {
            dashes
            Text("starts fresh")
                .font(.caption2)
                .textCase(.lowercase)
                .foregroundStyle(.tertiary)
                .fixedSize()
            dashes
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        // One element, and it says what the rule MEANS rather than reading the
        // two words out. "starts fresh" alone is not self-explanatory without
        // the visual break beside it, which VoiceOver does not get.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New session. This provider answers one question at a time and does not see the conversation above.")
        .accessibilityIdentifier("chat.freshStartRule")
    }

    private var dashes: some View {
        DashedLine()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(.tertiary)
            .frame(height: 1)
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

#Preview("starts fresh") {
    VStack(alignment: .leading, spacing: 0) {
        Text("King Arthur is the higher-protein flour, best for bread.")
            .padding()
        FreshStartRule()
        Text("what about the second one?")
            .padding()
    }
}
