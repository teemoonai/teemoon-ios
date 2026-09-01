//
//  WebSearchChip.swift
//  teemoon
//
//  The second chip in the composer inset: whether answers are grounded in live
//  search. Sits beside `WhereChip` — that one says WHERE the model runs, this
//  one says whether it can look anything up.
//
//  It only fits because `WhereChip` stopped repeating the guarantee the title
//  block already states. On a real device the where chip was filling ~85% of
//  the row on its own.
//
//  WHY IT IS VISIBLE WHEN UNCONFIGURED, which is the whole point:
//  an unclaimed capability the app never mentions is one nobody finds. This is
//  the only place teemoon advertises web search outside Settings, and it does
//  it by existing rather than by nagging — dim, never a badge, never a dot.
//
//  WHY DIM RATHER THAN TINTED when off: a lit control that does nothing is a
//  bug; a dim one is an invitation.
//
//  Related: WhereChip, ChatView, SearchSettingsView.
//

import SwiftUI

struct WebSearchChip: View {
    enum State: Equatable {
        /// No key. The chip is a funnel to setup.
        case unconfigured
        /// Key present and grounding enabled.
        case on
        /// Key present, grounding deliberately off — or paused because the
        /// month's credit is spent. A third state, because "off because you
        /// turned it off" and "off because you never set it up" want different
        /// taps, and collapsing them sends a configured user to a setup screen.
        case off
        /// Nothing is equipped, so grounding cannot run whatever the setting
        /// says. The ONLY state that dims — and it only reads as disabled
        /// because nothing else on the plate does.
        case disabled
    }

    let state: State
    var action: () -> Void
    /// Bumped by the offer card when the user declines it. The chip answers by
    /// drawing the eye to itself ONCE — no copy.
    ///
    /// This is where the offer goes when it is dismissed. The card is transient
    /// and the chip is permanent, so the moment the card leaves is the last
    /// honest chance to show where the capability lives — and `web off` in
    /// tertiary grey is quiet enough to miss forever otherwise.
    ///
    /// Motion, not a sentence. The user just said "not now"; a line of text
    /// explaining how to change their mind argues with the answer they gave.
    /// The brand's motion rule allows motion that explains a state change and
    /// forbids motion that decorates one — the offer moving from card to chip is a
    /// state change, and this is the only thing that says so.
    var pointHereToken: Int = 0

    // `SwiftUI.State` spelled out: this view declares its own nested `State`
    // enum, which shadows the property wrapper and makes a bare `@State` read
    // as "enum 'State' cannot be used as an attribute".
    @SwiftUI.State private var pointing = false

    // Explicit because `pointing` is private, which would otherwise make the
    // synthesized memberwise initializer private too and lock out every call
    // site including the previews.
    init(state: State, pointHereToken: Int = 0, action: @escaping () -> Void) {
        self.state = state
        self.pointHereToken = pointHereToken
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(glyphColor)
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(labelColor)
            }
            .textCase(.lowercase)
            .padding(.horizontal, ControlMetrics.pillHorizontalPadding)
            // Matches WhereChip exactly. Two capsules of different heights on
            // one row reads as two kinds of control rather than a pair.
            .frame(minHeight: ControlMetrics.pillHeight)
            .background(
                Capsule(style: .continuous)
                    // Scale alone was not enough twice. A tinted wash is the
                    // stronger signal at the bottom of a busy screen, and it
                    // says something scale cannot: this is what the control
                    // looks like when it is ON. The pointer previews the thing
                    // being offered.
                    .fill(pointing ? Color.accentColor.opacity(0.28) : fill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(pointing ? Color.accentColor
                                           : PlatformColors.separator.opacity(0.65),
                                  lineWidth: pointing ? 1.5 : strokeWidth)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // 1.12, up from 1.08 — and the scale is now the SMALLER half of the
        // signal. Two rounds of tuning motion alone (0.7s then 1.6s, 1.08 both
        // times) both read as too subtle, which is the answer: a 4pt-tall chip
        // in the corner of a full screen cannot be found by size change. The
        // accent wash above is what actually catches the eye; this just keeps
        // it feeling like one gesture.
        .scaleEffect(pointing ? 1.12 : 1)
        .animation(.easeInOut(duration: 0.38), value: pointing)
        .onChange(of: pointHereToken) { _, newValue in
            // Ignore the initial value so a chip that appears in a thread
            // declined earlier does not pulse at nobody.
            guard newValue > 0 else { return }
            Task {
                // Let the card finish leaving first. Two things moving at once
                // is why the first version was missable — this one waits its
                // turn instead of competing.
                try? await Task.sleep(for: .milliseconds(180))
                pointing = true
                try? await Task.sleep(for: .milliseconds(620))
                pointing = false
            }
        }
        .opacity(state == .disabled ? 0.4 : 1)
        .disabled(state == .disabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(hint)
        .accessibilityIdentifier("chat.webSearchChip")
    }

    /// The hint is the one place the two "off" states differ, and they should:
    /// one navigates to setup, the other flips a switch. Same appearance,
    /// because both are equally available — different consequence, which is
    /// what a hint is for.
    private var hint: String {
        switch state {
        case .unconfigured: return "opens web search setup"
        case .on, .off:     return "turns web search on or off"
        case .disabled:     return "equip a model to use web search"
        }
    }

    // MARK: - Appearance

    /// No "web on". A control that says "on" while lit is saying it twice; the
    /// tint carries the state and the word carries the name.
    /// "web" IN EVERY STATE.
    ///
    /// iOS names a control for what it is and lets appearance carry state — a
    /// Wi-Fi switch stays "Wi-Fi" in both positions. "web off" broke that three
    /// ways: it produced a double-negative tap ("tap web off to turn web on"),
    /// it made VoiceOver announce "web off, off" because the system appends the
    /// state itself, and it RENAMED the control on toggle, so a VoiceOver user
    /// heard a different control rather than a changed one.
    ///
    /// State now lives in `accessibilityValue`, which is where the system looks
    /// for it and which stays correct if the visual treatment changes again.
    private var label: String { "web" }

    /// ALWAYS the surface. No state of this chip fills with the accent.
    ///
    /// R3, which this violated: "the web/sources chip's on state is a tinted
    /// glyph and label on --surface, NEVER a fill." The reasoning is that the
    /// accent fill carries one meaning — "act here, nothing is set up yet" —
    /// and the Where chip is the control that owns it. A second filled capsule
    /// dilutes the first.
    ///
    /// It is also wrong on its own terms: a lit chip is not asking you to act,
    /// it is REPORTING that something is on. Reserving the loudest treatment in
    /// the app for a passive status made the most settled state look like the
    /// most urgent one.
    /// On gets a NEUTRAL LIFT, not the accent fill. R3 reserves the accent
    /// fill for "act here, nothing is set up yet" — the Where chip's job — so
    /// the lit state is a plate change plus tinted ink instead.
    ///
    /// Off and disabled sit on the resting plate, identical to the model chip
    /// beside them, because they ARE peers: available controls that happen not
    /// to be active.
    private var fill: Color {
        // tertiarySystemBACKGROUND, not tertiarySystemFILL. The fill roles are
        // translucent by design — they are meant to layer over an opaque
        // surface — and this chip floats over the transcript, so a fill let the
        // text behind it show straight through the lit state. The background
        // roles are opaque, and tertiary is still a visible lift above the
        // secondary the other states sit on.
        state == .on ? PlatformColors.tertiaryBackground : PlatformColors.secondaryBackground
    }

    /// The hairline is on in EVERY state now. It existed only to give the
    /// unfilled states an edge; with no state filled, dropping it for `.on`
    /// would make the lit chip the one without a border — a difference that
    /// reads as a rendering bug rather than a state.
    private var strokeWidth: CGFloat { 0.5 }

    /// Tertiary when unconfigured, so it reads as available-but-unclaimed
    /// rather than broken. `.off` is secondary: it is a working feature the
    /// user switched off, not an empty slot.
    ///
    /// `AnyShapeStyle` rather than `Color`, because `.tertiary` and `.secondary`
    /// are hierarchical ShapeStyles — they have no `Color` equivalent, and the
    /// where chip beside this one gets them straight from `.foregroundStyle`.
    /// Typing these as `Color` is what broke the first build.
    private var glyphColor: AnyShapeStyle {
        switch state {
        // SECONDARY, not tertiary. Tertiary is the dim, and the dim now means
        // one thing: you cannot tap this. An unconfigured chip is fully
        // tappable — it navigates to setup — so dimming it told the user, in
        // iOS's own vocabulary, not to bother.
        case .unconfigured: return AnyShapeStyle(.secondary)
        case .off:          return AnyShapeStyle(.secondary)
        case .on:           return AnyShapeStyle(Color.accentColor)
        case .disabled:     return AnyShapeStyle(.tertiary)
        }
    }

    private var labelColor: AnyShapeStyle {
        switch state {
        case .unconfigured: return AnyShapeStyle(.secondary)
        case .off:          return AnyShapeStyle(.secondary)
        // The label carries the tint too, not just the glyph — and now it has
        // to. The words are identical in every state ("web"), so ink and plate
        // are the ONLY carriers of the distinction; 12pt of magnifier alone is
        // not enough to hang a state on.
        case .on:           return AnyShapeStyle(Color.accentColor)
        case .disabled:     return AnyShapeStyle(.tertiary)
        }
    }

    /// The NAME only. The system appends the value and the trait itself, so
    /// putting state here produced "web search, off, off".
    private var accessibilityLabel: String { "web search" }

    /// Where state belongs. VoiceOver reads it after the label and keeps it
    /// correct however the visual treatment changes.
    private var accessibilityValue: String {
        state == .on ? "on" : "off"
    }
}

#if os(iOS)
/// All three states beside the where chip they share a row with — the pair is
/// the thing being designed, not the chip alone.
/// All four states in a column, which is the only way the convention is
/// legible: one label, four appearances.
#Preview("web chip · four states", traits: .fixedLayout(width: 402, height: 300)) {
    VStack(alignment: .leading, spacing: 12) {
        WebSearchChip(state: .unconfigured, action: {})
        WebSearchChip(state: .off, action: {})
        WebSearchChip(state: .on, action: {})
        WebSearchChip(state: .disabled, action: {})
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(Color(.systemBackground))
    .environment(\.colorScheme, .dark)
}

#Preview("web search chip · beside where", traits: .fixedLayout(width: 402, height: 300)) {
    VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 8) {
            WhereChip(provider: .local(LocalModelCatalog.all[0]), action: {})
            WebSearchChip(state: .unconfigured, action: {})
        }
        HStack(spacing: 8) {
            WhereChip(provider: .local(LocalModelCatalog.all[0]), action: {})
            WebSearchChip(state: .on, action: {})
        }
        // The row that made the width fix necessary: a cloud provider, whose
        // caption used to carry "· end-to-end encrypted" as well.
        HStack(spacing: 8) {
            WhereChip(provider: .nearAI, action: {})
            WebSearchChip(state: .off, action: {})
        }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
}
#endif
