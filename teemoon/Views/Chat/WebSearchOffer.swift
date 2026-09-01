//
//  WebSearchOffer.swift
//  teemoon
//
//  Shown when a turn ASKED for the web and couldn't have it.
//
//  The trigger is not a guess. The model is handed the `web_search` schema even
//  with no key configured, so when it decides a question needs looking up it
//  emits a real tool call — and that call is the signal. teemoon is reporting
//  something that happened, not inferring intent from the wording of a prompt.
//  That is the whole reason this card can be specific: "it tried to look this
//  up" is a fact, where "this looks like it needs the web" would be a guess.
//

import SwiftUI

/// Sits UNDER the model's answer, which always stands.
///
/// The alternative — withholding the reply behind this card — was built,
/// rendered next to this one, and dropped: a model asking to search does not
/// mean its memory is wrong, so discarding the answer punishes every turn where
/// it was fine, after the user already waited through decode for it.
struct WebSearchOffer: View {
    @Environment(\.openURL) private var openURL
    /// OPTION C — setup happens here, in the thread, with the question that
    /// needed it still on screen above. The reason for the errand never leaves
    /// the view, and the answer arrives in the same place rather than after a
    /// round trip through a sheet.
    ///
    /// A STANDARD LINK, not an in-app browser. A deliberate choice, and it also
    /// settles the clipboard question: with no browser there is no dock
    /// watching the pasteboard, and teemoon should not be reading it anyway.
    /// iOS shows a paste banner for programmatic reads, and an app whose pitch
    /// is what it does not see has no business looking. `PasteButton` is
    /// user-initiated, needs no permission, and reveals nothing until tapped.
    @SwiftUI.State private var key = ""
    @SwiftUI.State private var check: BraveWebSearchTool.KeyCheck?
    @SwiftUI.State private var checking = false
    /// Brave said yes. Held on screen for a beat before the card goes, so the
    /// key landing is something you SEE rather than infer from the card
    /// vanishing under your finger.
    @SwiftUI.State private var accepted = false
    /// What the model actually searched for, straight off the tool call. Naming
    /// it is what separates this from a generic upsell — the user can see the
    /// app is describing their question, not advertising a feature.
    let query: String
    var onDismiss: () -> Void = {}

    /// PREVIEW SEAM. The status states are reachable only by pasting a real
    /// key — or a deliberately bad one — which cannot be done from a preview or
    /// from a UI test that must not type credentials. Seeding them here is what
    /// makes the failure copy reviewable at all; without it, the only way to
    /// look at "brave didn't recognise this key" is to break something on a
    /// phone by hand.
    init(query: String,
         onDismiss: @escaping () -> Void = {},
         onKeyAccepted: @escaping (String) -> Void = { _ in },
         previewKey: String = "",
         previewCheck: BraveWebSearchTool.KeyCheck? = nil,
         previewAccepted: Bool = false) {
        self.query = query
        self.onDismiss = onDismiss
        self.onKeyAccepted = onKeyAccepted
        _key = SwiftUI.State(initialValue: previewKey)
        _check = SwiftUI.State(initialValue: previewCheck)
        _accepted = SwiftUI.State(initialValue: previewAccepted)
    }
    /// Called once brave has ACCEPTED a key. The host saves it and re-runs the
    /// question — frame 6, without the sheet.
    var onKeyAccepted: (String) -> Void = { _ in }

    /// Where to go, and somewhere to put what you come back with — BOTH
    /// VISIBLE FROM THE START, which is design C as drawn.
    ///
    /// An earlier pass hid these behind a "set it up" button that expanded the
    /// card. C has no such step: the offer card IS the setup card. That extra
    /// tap bought nothing and was most of what made this feel clunky.
    @ViewBuilder
    private var setupSteps: some View {
        // spacing 0. Every child here carries the design's own top margin, and
        // a container spacing on top of that was ADDING to it — the gap between
        // the button and the paste row measured about 23pt against `.il`'s 13.
        VStack(alignment: .leading, spacing: 0) {
            // FULL WIDTH, and the only filled control on the card — design C's
            // `.b1`. There is one thing to do first and this is it.
            Button {
                openURL(URL(string: "https://brave.com/search/api/")!)
            } label: {
                HStack(spacing: 7) {
                    Text("get a key")
                        .font(.system(size: 15, weight: .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                // WHITE, per design C's `.b1 { color:#fff }` — a deliberate choice.
                // R1 still holds — the fill states its own label colour rather
                // than inheriting one; this just states a different one.
                //
                // Worth knowing: C was drawn against the blue fallback tint,
                // where white is high-contrast. On teemoon's #FF7A1A it is
                // around 2.6:1 where black is about 7:1. Shipping white because
                // it was asked for, noted because contrast is measurable.
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.webOffer.getKey")
            .padding(.top, 12)

            HStack(spacing: 8) {
                // MONOSPACED, per `.il { font-family: SF Mono }` — the glyph and
                // the label are one run in the design, and the key that lands
                // here is monospaced too, so the row reads as a field before
                // anything is in it.
                Text("\u{2318}")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(key.isEmpty ? "paste key" : maskedKey)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(key.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: 8)
                // A PLAIN BUTTON, not a PasteButton.
                //
                // PasteButton is the privacy-preferable control — it hands the
                // string over without the app reading the pasteboard, so no
                // iOS paste banner. But it will not take styling: it ignored
                // `.textCase(.lowercase)` and kept the system's capitalised
                // "Paste", and `.buttonStyle(.borderless)` made it draw an
                // ACCENT-TINTED capsule rather than removing the fill.
                // `.tint(.clear)` had only cleared the fill's colour, not the
                // fill. Three attempts, all visible only on hardware.
                //
                // The cost of this swap is honest and small: reading the
                // pasteboard shows iOS's paste banner. The user just tapped a
                // control labelled "paste", so being told teemoon pasted is
                // redundant rather than surprising — and it is still the user
                // initiating, never a background read.
                Button {
                    #if os(iOS)
                    guard let pasted = UIPasteboard.general.string else { return }
                    #else
                    guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
                    #endif
                    key = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    runCheck()
                } label: {
                    Text("paste")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.webOffer.paste")
            }
            // 11/13 from `.il`, against the 10/12 that made the row too tall.
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemFill)))
            .padding(.top, 13)

            // THE STATUS LINE — accepted, checking, or the reason it failed.
            // Design C has no such state, which is why it had no margin and sat
            // flush against the paste row above it. 9pt, and the row is a
            // baseline-aligned HStack rather than a Label so the glyph does not
            // drift when the text wraps to two lines.
            Group {
                if accepted {
                    statusRow(icon: "checkmark.circle.fill",
                              tint: AnyShapeStyle(Color.green),
                              // Names what happens NEXT, not just what
                              // happened. The card is about to vanish and a new
                              // answer appear; saying so is what turns that
                              // from a jump into a consequence.
                              text: "brave accepted this key — asking again now")
                } else if checking {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("checking with brave…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if let check, check != .valid {
                    statusRow(icon: KeyCheckCopy.icon(for: check),
                              tint: check == .rejected ? AnyShapeStyle(Color.red)
                                                       : AnyShapeStyle(.secondary),
                              text: KeyCheckCopy.message(for: check))
                }
            }
            .padding(.top, 9)
        }
        .padding(.top, 2)
    }

    /// One shape for every outcome, so success and failure cannot drift apart.
    /// `.firstTextBaseline` because the message can wrap and a centred glyph
    /// would float to the middle of a two-line paragraph.
    @ViewBuilder
    private func statusRow(icon: String, tint: AnyShapeStyle, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Enough to recognise, not enough to read over a shoulder.
    private var maskedKey: String {
        key.count > 8 ? "\(key.prefix(4))…\(key.suffix(4))" : "••••"
    }

    private func runCheck() {
        Task {
            checking = true
            check = await BraveWebSearchTool.checkKey(key)
            checking = false
            // ONLY on acceptance. A rejected key must not be saved and must not
            // light the chip — that is the silent failure this whole path
            // exists to prevent.
            guard check == .valid else { return }
            // THE BEAT. Handing the key over used to end with the card
            // disappearing mid-tap and an answer arriving from nowhere — the
            // one moment the user has been working toward, and nothing marked
            // it. Show the acceptance, hold it long enough to read, then go.
            withAnimation(.easeOut(duration: 0.2)) { accepted = true }
            try? await Task.sleep(for: .milliseconds(1700))
            onKeyAccepted(key)
        }
    }

    var body: some View {
        // spacing 0 and explicit top padding per element, taken from design C's
        // own CSS rather than guessed: .n margin-top 7, .d 5, .b1 12, .il 13,
        // .fine 10. A uniform 10 pushed the title away from its eyebrow and
        // bunched the rest.
        VStack(alignment: .leading, spacing: 0) {
            // Names what the answer ABOVE is worth. The design's "to answer
            // this" is forward-looking and only parses when no answer has been
            // shown — under one that already exists it promises something the
            // card is too late to deliver.
            //
            // "training data", not "memory": memory is what the app looks like
            // it has — the thread above is literally a memory of the
            // conversation. The phrase has to name the MODEL's frozen weights,
            // or it reads as "answered from your chat history", which is both
            // wrong and the opposite of reassuring.
            HStack(alignment: .top) {
                Text("to answer this")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer(minLength: 8)
                // DISMISS IN THE CORNER, not a "not now" button beside the
                // action. Declining is not a second choice of equal weight —
                // it is leaving, and leaving lives in the corner. It also frees
                // the button row for the one thing that changes as the card
                // progresses: "set it up" becoming "get a key".
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        // Drawn at 18, tapped at 44. The visual box sets the
                        // header row's height — at 28 it pushed the title well
                        // past the design's 7pt from its eyebrow — while
                        // contentShape keeps the target a comfortable size.
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle().inset(by: -13))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("dismiss")
                .accessibilityIdentifier("chat.webOffer.dismiss")
            }
            .padding(.trailing, -2)

            Text("turn on web search")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.top, 7)

            // The query, named. The one addition kept from the first pass: the
            // model ASKED for this string, so the card is describing the user's
            // own question back to them rather than advertising a feature.
            // The model's OWN query, folded in as the example — it used to be
            // its own line above ("it tried to look up X"). Same evidence, one
            // paragraph shorter, and it now reads as an illustration of the
            // behaviour rather than a separate accusation.
            Text("the model searches when it needs to (e.g. \u{201C}\(query)\u{201D}). needs a brave account with a card on file. you get $5 of free credit per month (about 1,000 searches); extra queries bill your card. setup takes a few minutes on their site.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)

            setupSteps

            // WHAT BRAVE SEES. Below the buttons, in the design's position:
            // it is not a condition of tapping, it is the reassurance that makes
            // tapping reasonable. This is the only card in teemoon that hands
            // anything to a third party, so this line is the positioning, not
            // decoration — dropping it was the worst part of the first pass.
            Text("privacy: brave sees only the search terms, never your conversation.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PlatformColors.secondaryBackground)
        )
    }

}

// MARK: - Previews
//
// Shown IN CONTEXT, under a plausible stale answer, because the thing being
// judged is not the card — it is what the card does to the turn.

/// Stand-in for an assistant bubble. The transcript's real renderer needs a
/// Message and a ModelContext; this is about placement, not typography.
private struct FakeAnswer: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 16))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OfferPreviewShell<Content: View>: View {
    let caption: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(caption)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PlatformColors.background)
        .environment(\.colorScheme, .dark)
    }
}

#Preview("offer · under an answer", traits: .fixedLayout(width: 402, height: 620)) {
    OfferPreviewShell(caption: "the answer stands; the card explains it") {
        VStack(alignment: .leading, spacing: 14) {
            FakeAnswer(text: "as of my training data, the james webb telescope's most distant confirmed galaxy was JADES-GS-z14-0, at redshift 14.32.")
            WebSearchOffer(query: "most distant galaxy confirmed by JWST")
        }
    }
}

#Preview("offer · long query wraps", traits: .fixedLayout(width: 402, height: 620)) {
    OfferPreviewShell(caption: "a query long enough to wrap must not push the buttons off") {
        WebSearchOffer(query: "current price of a 14-inch macbook pro with the m5 max and 64gb of unified memory")
    }
}

/// The states you cannot reach without pasting a key, good or bad.
#Preview("offer · status states", traits: .fixedLayout(width: 402, height: 1250)) {
    OfferPreviewShell(caption: "accepted, rejected, out of credit") {
        VStack(alignment: .leading, spacing: 18) {
            WebSearchOffer(query: "weather in tokyo right now",
                           previewKey: "BSA5xxxxxxxxxxxxZdgn",
                           previewAccepted: true)
            WebSearchOffer(query: "weather in tokyo right now",
                           previewKey: "BSA5xxxxxxxxxxxxZdgn",
                           previewCheck: .rejected)
            WebSearchOffer(query: "weather in tokyo right now",
                           previewKey: "BSA5xxxxxxxxxxxxZdgn",
                           previewCheck: .outOfCredit)
        }
    }
}
