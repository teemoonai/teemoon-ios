//
//  WhereChip.swift
//  teemoon
//
//  Option B chrome: 44pt model·place control above the composer. Opens the
//  Where sheet. Title bar stays E2EETitleBlock → trust ladder.
//
//  Related: WhereSheetView, ChatView.
//

import SwiftUI

struct WhereChip: View {
    let provider: Provider?
    /// 0…1 while the selected model's weights are still arriving.
    ///
    /// Reported HERE rather than on a line of its own. The separate note that
    /// used to sit above the composer had no background, so the transcript ran
    /// straight through it and the sentence was unreadable — and fixing that by
    /// giving it a plate would have put a second opaque slab in a bottom inset
    /// that is already two elements deep. The chip is where "which model, and can
    /// it answer" belongs; a percentage is part of that answer, not a separate
    /// announcement.
    var progress: Double?
    /// Selected, local, and the weights aren't on disk with nothing running — an
    /// interrupted download. Said on the chip because otherwise the state is
    /// invisible until send fails: the model is chosen, named, and unable to
    /// answer, which looks identical to a working setup.
    var needsDownload: Bool = false
    var action: () -> Void

    /// Drives the one settle on appear. Starts false so the chip renders a
    /// touch UNDERsized for a frame, then rises into place — never larger than
    /// resting, per the brand's no-overshoot rule (nothing overshoots visibly).
    @State private var settled = false

    /// Nothing configured. The chip is the only thing on an empty screen the
    /// user must tap, so it stops being quiet chrome and fills.
    ///
    /// STATE-DRIVEN, not first-launch-driven. The design proposed a single
    /// animation on first launch, which needs a persisted "already played" flag
    /// and can never be seen again — and a user who looks a second late sees a
    /// grey capsule with no hint at all. Tying it to `provider == nil` means the
    /// emphasis is present exactly while it is true, and removes itself the
    /// moment something is configured. No flag, nothing to migrate, and it is
    /// correct again if the user later deletes their last setup.
    private var unconfigured: Bool { provider == nil }

    /// Label colour on the accent fill. White, because the fill is `ML.accent`
    /// — a fixed orange, not a colour that inverts with appearance. White on
    /// #FF7A1A clears contrast, and unlike `systemBackground` it cannot flip to
    /// black and leave the label fighting the fill.
    private var onAccent: AnyShapeStyle { AnyShapeStyle(Color.white) }

    /// Extracted rather than written inline: the ternary that picked between
    /// `AnyShapeStyle(...).opacity(...)` and `.tertiary` inside the body blew
    /// the type-checker's budget outright ("unable to type-check in reasonable
    /// time"). Same values, resolved one step at a time.
    private var chevronStyle: AnyShapeStyle {
        guard unconfigured else { return AnyShapeStyle(.tertiary) }
        return AnyShapeStyle(Color.white.opacity(0.75))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: glyph)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(glyphColor)
                if let provider {
                    Text(WhereProviderPresentation.modelLabel(for: provider))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if let progress {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        // "downloading" plus a number, not a bar: a 2pt bar
                        // inside a 44pt capsule is decoration, and the percentage
                        // is the part that tells you whether to wait.
                        Text("downloading \(Int(progress * 100))%")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    // The place is dropped when the title bar is already saying
                    // it. For an on-device model the trust caption up there IS
                    // "on this device", so printing it again 60pt lower put the
                    // same three words on screen twice — the exact duplication
                    // `showsModel: false` was added to remove, arriving from the
                    // other direction.
                    if needsDownload {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        // RED, not orange. `ML.accent` (#FF7A1A) became the app
                        // tint and now means "actionable" — this same chip fills
                        // with it for `choose where`. SwiftUI's `.orange`
                        // (#FF9F0A) is 8% away, so an invitation and a blocked
                        // state were rendering as the same colour in one control.
                        //
                        // Red because this state BLOCKS: the model is selected,
                        // named, and cannot answer, and send is gated on it. Not
                        // a caution — a failure.
                        Text("not downloaded")
                            .font(.system(size: 14))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                    // Place only when there's no progress to report — a chip
                    // saying model · place · downloading 5% is three facts in a
                    // capsule that has room for two.
                    if progress == nil, !needsDownload, let place = chipPlace(for: provider) {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(place)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("choose where")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(onAccent)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(chevronStyle)
            }
            .textCase(.lowercase)
            .padding(.horizontal, ControlMetrics.pillHorizontalPadding)
            .frame(minHeight: ControlMetrics.pillHeight)
            // Two layers, and the order is the point.
            //
            // `secondarySystemFill` is a TRANSLUCENT fill. The chip floats in a
            // safeAreaInset over the scrolling transcript, so the article ran
            // straight through it and the label became unreadable against its
            // own background. The composer right below already had this problem
            // and solved it the same way: an opaque plate that occludes, with
            // the visual fill on top of it.
            //
            // Innermost background is nearest the label, so the fill goes first
            // and the occluder behind it.
            // Solid card fill plus a hairline border, per the design — and it
            // still has to occlude, because the chip floats over the scrolling
            // transcript. `secondarySystemBackground` is opaque where
            // `secondarySystemFill` was not, so one layer now does the job two
            // were doing, and the border gives the capsule an edge against a
            // dark transcript instead of dissolving into it.
            // ONE surface, both states. The chip keeps the opaque plate it has
            // always needed — it floats over a scrolling transcript — and the
            // unconfigured state FILLS. Nothing else on that screen is coloured.
            //
            // I briefly made this an outline, on the theory that a filled accent
            // capsule would compete with the composer's send button ~60pt below,
            // which is also tinted. THAT WAS WRONG AND I NEVER CHECKED IT:
            // ChatView.swift disables the send button while the prompt is empty,
            // so on first run it renders grey. At the one moment this chip needs
            // to be seen, it is the only saturated object in the frame — black
            // screen, grey composer, grey send button.
            //
            // THE FILL MEANS EXACTLY ONE THING: "nothing is set up, act here."
            // Keep it scarce. When the web/sources chip lands, its "on" state
            // must NOT be a full accent fill — tinted glyph and label on the
            // normal surface — or a filled capsule will mean both "tap me" and
            // "this is active", which is a collision we get to avoid only
            // because that chip does not exist yet.
            // THE FILL IS THE ANIMATION.
            //
            // Scale was the wrong lever: 10% of a 44pt capsule is ~4pt of
            // travel, and a critically-damped spring makes that gentle by
            // design — "so subtle" on device. Pushing the travel further just
            // starts to read as the bounce brand forbids.
            //
            // A whole capsule changing colour is far more perceptible, and it
            // satisfies the brand's motion rule better: the chip ARRIVES as ordinary
            // chrome and BECOMES the accent, which is motion explaining a state
            // change rather than decorating a static one. Plain `Color` on both
            // sides, not AnyShapeStyle, because SwiftUI can only interpolate
            // between concrete colours.
            .background(
                Capsule(style: .continuous)
                    .fill(unconfigured && settled ? ML.accent
                                                  : PlatformColors.secondaryBackground)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(PlatformColors.separator.opacity(unconfigured ? 0 : 0.65),
                                  lineWidth: unconfigured ? 0 : 0.5)
            )
            // Rises INTO place — .96 → 1 — and never exceeds resting size.
            //
            // The first version opened at 1.06 and sprang down, which is a
            // visible overshoot, and the brand's motion rule forbids it outright:
            // "Springs are low-bounce; nothing overshoots visibly. The app
            // holds to this strictly." Same attention-getting movement on an
            // otherwise still screen, without the bounce.
            //
            // Damping 1.0, so the spring cannot ring past its target no matter
            // what response is set — a spring that could overshoot is the same
            // bug waiting for a tuning change.
            .scaleEffect(settled || !unconfigured ? 1 : 0.94)
            .opacity(settled || !unconfigured ? 1 : 0.6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // `.task`, and DELAYED — not `.onAppear`.
        //
        // onAppear fires while the launch image is still up, so the settle ran
        // and finished before the first frame the user could see: the chip was
        // simply there, already at rest. Observed on device as "I don't notice
        // an animation", which is exactly right — there wasn't one to notice.
        //
        // The wait covers the launch transition. `.task` rather than a detached
        // Task so it is cancelled if the view goes away first.
        .task {
            guard unconfigured, !settled else { return }
            try? await Task.sleep(for: .milliseconds(420))
            withAnimation(.easeOut(duration: 0.55)) { settled = true }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("opens where the model runs")
        .accessibilityIdentifier("chat.whereChip")
    }

    /// The place, unless the title bar is already stating it.
    ///
    /// `E2EETitleBlock` shows the trust verdict, and for an on-device model that
    /// verdict is literally "on this device". Cloud and home don't collide: the
    /// title says "end-to-end encrypted" or "on your own machine", where the chip
    /// names the provider or the server.
    private func chipPlace(for provider: Provider) -> String? {
        switch WhereLocality.of(provider) {
        case .phone:
            return nil
        case .home:
            return WhereProviderPresentation.placeCaption(for: provider)
        case .cloud:
            // The provider's NAME, without the trust suffix.
            //
            // `placeCaption` appends the guarantee — "near.ai · end-to-end
            // encrypted" — which is correct for the Where sheet, whose cloud
            // header promises that every row says whether it is. It is wrong
            // here, because `E2EETitleBlock` is stating the same phrase
            // verbatim at the top of the same screen. On a real device that
            // produced "glm-5.2 · near.ai · end-to-end encrypted" filling ~85%
            // of the width, with "end-to-end encrypted" also in the header
            // above it and a padlock beside that — one guarantee, three times,
            // and no room left for anything else on the row.
            //
            // Both directions are dropped, not just the positive one. The
            // title block says "not end-to-end encrypted" too, so keeping the
            // negative here would be the same duplication with the opposite
            // sign — and a chip that carries the guarantee sometimes is worse
            // than one that never does, because its silence would then mean
            // something.
            //
            // Everything else `placeCaption` returns for cloud stays: Brave
            // Answers' "fast built-in search, single turn q&a" is a capability
            // warning rather than a guarantee, and nothing above repeats it.
            if provider.capabilities.contains(.endToEndEncryption)
                || provider.endpoint.contains("near.ai") {
                return WhereProviderPresentation.canonicalName(for: provider)
            }
            return WhereProviderPresentation.placeCaption(for: provider)
        }
    }

    private var glyph: String {
        guard let provider else { return "arrow.triangle.branch" }
        return WhereProviderPresentation.systemImage(for: provider)
    }

    /// Always secondary.
    ///
    /// It used to tint by provider — primary for e2ee, orange for a near.ai
    /// model without it — which put a warning colour on one cloud row and left
    /// an identical-looking row beside it untinted, for a distinction the
    /// caption already states in words. The design tints nothing here: the chip
    /// says WHICH model and WHERE, and the guarantee is text.
    /// Secondary when the chip is ordinary chrome; inverted against the fill
    /// when it isn't, for the same reason as `onAccent`.
    private var glyphColor: AnyShapeStyle {
        unconfigured ? onAccent : AnyShapeStyle(.secondary)
    }


    private var accessibilityLabel: String {
        guard let provider else { return "choose where" }
        return "\(WhereProviderPresentation.modelLabel(for: provider)), \(WhereProviderPresentation.placeCaption(for: provider))"
    }
}

#if os(iOS)
/// One row per locality, because the glyph is the claim. `phone` is the case
/// that regressed: it has no host, so the original classifier called it cloud
/// and drew a cloud over the one model that never leaves the device.
#Preview("where chip · every state", traits: .fixedLayout(width: 402, height: 460)) {
    let home = Provider(
        name: "second mac",
        endpoint: "http://100.100.0.12:11434/v1",
        model: "qwen3:14b",
        requiresAPIKey: false
    )
    return VStack(alignment: .leading, spacing: 14) {
        Group {
            WhereChip(provider: .local(LocalModelCatalog.all[0]), action: {})
            WhereChip(provider: home, action: {})
            WhereChip(provider: .nearAI, action: {})
            WhereChip(provider: .grok, action: {})
            // Weights arriving: the place is dropped, because a capsule saying
            // model · place · downloading 5% is three facts in a space for two.
            WhereChip(provider: .local(LocalModelCatalog.all[1]), progress: 0.42, action: {})
            // Selected, local, nothing on disk and nothing running.
            WhereChip(provider: .local(LocalModelCatalog.all[1]), needsDownload: true, action: {})
            WhereChip(provider: nil, action: {})
        }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
}
#endif
