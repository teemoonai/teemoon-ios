//
//  E2EETitleBlock.swift
//  teemoon
//
//  Attestation sheet focused on cryptographic verification.
//  Shows whether the TDX quote was verified on-device (signature + cert chain)
//  rather than just displaying server-provided data.
//

import SwiftUI

// UN-GATED. This screen is the product's central claim; it was iOS-only
// for four platform-specific calls, not for its design.

// `teeVerified` / `teeVerifiedSoft` used to be declared here, inside this
// guard. They are design tokens, not iOS facts, and one of their consumers
// (AddEditProviderView) is not gated — so on macOS they disappeared while the
// code using them still compiled. They now live beside the other tokens in
// Appearance.swift, with the same values. The sheet below stays iOS-only.

// MARK: - AttestationState UI

extension AttestationState {
    var captionColor: Color {
        switch self {
        case .degraded: return .orange
        default:        return .secondary
        }
    }
}

// MARK: - VerifyingLock

/// Pulsing lock icon — fades in/out while verifying, solid otherwise.
struct VerifyingLock: View {
    let state: AttestationState
    var size: CGFloat = 12
    var sealedDespiteDegrade: Bool = false

    @State private var pulse = false

    var body: some View {
        // degraded shows an OPEN lock — never a closed lock next to
        // "E2EE unavailable" (design review: glyph must match the words)
        Image(systemName: (state == .degraded && !sealedDespiteDegrade) ? "lock.open.fill" : "lock.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(state == .verifying ? .secondary : .primary)
            .opacity(state == .verifying && pulse ? 0.45 : 1.0)
            .animation(state == .verifying
                ? .easeInOut(duration: 0.85).repeatForever()
                : .default, value: pulse)
            .onAppear { pulse = true }
    }
}

// MARK: - E2EETitleBlock

/// Two-line nav bar title: lock + title row, then a tiny status caption.
/// Tapping always opens the unified attestation sheet.
struct E2EETitleBlock: View {
    let title: String
    let state: AttestationState
    var provider: Provider? = nil
    /// A hard integrity break (tamper / MITM / replay / unbound key) — sending is
    /// hard-blocked. Drives the RED header tier the plain `state` (orange at most)
    /// can't express, so a break never reads like a benign "no E2EE" model.
    var isHardFailure: Bool = false
    /// GitHub 404s only, send still sealed. Caption must not say unencrypted.
    var unpublishedButSealed: Bool = false
    /// Replies whose signature failed to verify this session. A red header cue:
    /// the session is still sealed, but a delivered reply couldn't be authenticated.
    var mismatchCount: Int = 0
    /// Whether line 2 names the model.
    ///
    /// False wherever the Where chip is on screen, which is every chat. The
    /// chip already says `model · place` 60pt lower and says it with an
    /// affordance attached, so repeating the model here bought a second copy
    /// of the same string and spent the width that made `ViewThatFits` drop it.
    /// With the model gone the caption never competes for the principal, and
    /// the division of labour is legible: the chip is identity you can change,
    /// this is the verdict you can only inspect.
    var showsModel: Bool = true

    @State private var showSheet = false

    private var chipMode: TrustChipMode {
        TrustVerdict.chipMode(.init(
            attestationState: state,
            requiresConfirmation: false,
            degradeIsHardFailure: isHardFailure,
            mismatchedResponseCount: mismatchCount,
            modelName: "",
            isLocal: provider?.isLocal == true,
            isSelfHosted: provider?.isSelfHosted == true,
            provenanceDetail: "",
            hasSigningAddress: false,
            quantDrift: false,
            deviceBoundary: "",
            deviceSubject: "",
            unpublishedButSealed: unpublishedButSealed
        ))
    }

    private var displayCaption: String {
        TrustVerdict.chipCaption(mode: chipMode, state: state,
                                 unpublishedButSealed: unpublishedButSealed)
    }

    private var displayColor: Color {
        switch chipMode {
        case .hardBlock, .mismatch: return .red
        default:                    return state.captionColor
        }
    }

    /// The model, as short as it can be and still be the model. `ModelCatalog`
    /// owns the naming rules; don't grow a second copy of them here.
    ///
    /// Some providers have no `/models` endpoint and carry a placeholder id
    /// instead — Brave Answers is literally `model: "brave"`. A placeholder says
    /// less than the provider's own name does, so when the id is just an echo of
    /// the provider, show the provider: "brave answers", not "brave".
    private var modelLabel: String? {
        guard let provider else { return nil }
        return ModelCatalog.titleLabel(model: provider.model, providerName: provider.name)
    }

    /// A state where something is wrong — the weighting on line 2 inverts here.
    private var isAlert: Bool {
        switch chipMode {
        case .softDegrade, .hardBlock, .mismatch:             return true
        case .verified, .verifying, .onDevice, .selfHosted, .none: return false
        }
    }

    /// Model styling: medium weight throughout, but it dims out of the way once
    /// the status has something urgent to say.
    private var modelStyle: AnyShapeStyle {
        isAlert ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)
    }

    /// Status styling: the same `.secondary` as the model beside it while
    /// everything is fine, semibold in its own colour the moment it isn't.
    /// It was one step quieter (0.45 white) and read as washed-out at 11pt —
    /// this is the app's core claim, so it sits level with the model rather
    /// than below it.
    private var statusStyle: AnyShapeStyle {
        isAlert ? AnyShapeStyle(displayColor) : AnyShapeStyle(.secondary)
    }

    /// Line 2: which model, then whether the channel is sealed.
    ///
    /// The principal is narrow (~266pt on a 402pt phone, ~239pt on a 375pt one),
    /// and `provider \u{00B7} model \u{00B7} status` does not fit there \u{2014} on a 375pt phone it
    /// truncated the model even in the ordinary verified state, which defeats
    /// the point. So the provider *name* is dropped (it lives in the sheet, one
    /// tap away) and the model is compacted to `ModelCatalog.compactName`.
    ///
    /// In the healthy state the two segments read as one line: same `.secondary`
    /// colour, the model only a hair heavier in weight. Orange and red break the
    /// tie \u{2014} status goes semibold in its colour and the model dims to tertiary \u{2014}
    /// so a problem always outranks identity without the line changing shape.
    ///
    /// If the pair doesn't fit, `ViewThatFits` drops the model whole *and its
    /// middot with it*, rather than shredding it in place: layout priority
    /// produced `ne\u{2026} \u{00B7}  \u{00B7} verification failed`, orphaned separators around a
    /// model that had truncated to nothing. The status is what survives \u{2014} a red
    /// "sending blocked" vanishing is a safety bug where a missing model slug is
    /// only cosmetic. In practice only the hard block is long enough to trigger
    /// the drop; the sheet still holds the identity.
    ///
    /// With `showsModel` false the fallback is the only row, and the whole
    /// width contest above disappears — the Where chip took identity, so the
    /// caption is alone on the line and never truncates.
    @ViewBuilder private var secondaryLine: some View {
        if showsModel {
            ViewThatFits(in: .horizontal) {
                metaRow(showModel: true)
                metaRow(showModel: false)
            }
        } else {
            metaRow(showModel: false)
        }
    }

    private func metaRow(showModel: Bool) -> some View {
        HStack(spacing: 0) {
            if showModel, let modelLabel {
                // the middot belongs to the model, and leaves with it
                Text(chipMode == .none ? modelLabel : modelLabel + " \u{00B7} ")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(modelStyle)
            }
            if chipMode != .none {
                Text(displayCaption)
                    .font(.system(size: 11, weight: isAlert ? .semibold : .regular))
                    .foregroundStyle(statusStyle)
            }
        }
        .lineLimit(1)
    }

    /// VoiceOver keeps the provider name even though the visible line drops it —
    /// there is no width budget to spend here, and "which service" is exactly
    /// the thing a non-sighted user can't infer from the lock glyph.
    private var accessibilityText: String {
        var parts: [String] = []
        if let provider, let modelLabel { parts.append("\(provider.name) \u{00B7} \(modelLabel)") }
        if chipMode != .none { parts.append(displayCaption) }
        parts.append(title)
        return parts.joined(separator: ", ") + ". \(PointerVerb.actTwice) to view details."
    }

    /// The lock glyph. A hard block opens the lock in red (no seal); a reply
    /// mismatch keeps it CLOSED (the session is still sealed) but red (a reply
    /// failed its check); everything else uses the state-driven pulsing lock.
    @ViewBuilder private var lockView: some View {
        switch chipMode {
        case .hardBlock:
            Image(systemName: "lock.open.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
        case .mismatch:
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
        case .onDevice:
            // A phone, not a laptop and not a padlock. The distinction is the
            // whole point: "on your own machine" is a machine glyph because the
            // data travels to a machine; this one never travels at all.
            Image(systemName: "iphone")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
        case .selfHosted:
            // A machine, not a padlock — the same glyph the sheet leads with, so
            // both surfaces make the same claim. A padlock would say "sealed",
            // which is the attested enclave's claim; this one is "it's yours",
            // which is a different reason to be private and reads as its own
            // thing rather than a weaker version of e2ee.
            Image(systemName: "lock.laptopcomputer")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
        default:
            VerifyingLock(state: state, size: 12, sealedDespiteDegrade: unpublishedButSealed)
        }
    }

    var body: some View {
        Button { showSheet = true } label: {
            VStack(spacing: 1) {
                HStack(spacing: 6) {
                    if chipMode != .none {
                        lockView
                    }
                    // Chevron rides INLINE on the title line (iMessage-style) —
                    // the tap-affordance for the attestation sheet. Pinned via
                    // layoutPriority so a long title truncates before it; present
                    // in every state, including `.none` where (no lock, no
                    // caption) it is the only hint the title is tappable.
                    // Affordance only: caption-grey, never a status color.
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                    }
                }
                if chipMode != .none || modelLabel != nil {
                    secondaryLine
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        // The block collapses to ONE accessibility element, so a UI test can't
        // reach line 2 separately — the identifier addresses the whole control
        // and the label carries the text. Tests assert on the label.
        .accessibilityIdentifier("chat.titleBlock")
        .sheet(isPresented: $showSheet) {
            // The trust-ladder redesign (Direction D). The former
            // VerificationRunView is retained for the marketing screenshot and
            // design-tour routes.
            NavigationStack { TrustLadderView() }
                #if os(iOS)
                .presentationDragIndicator(.hidden)
                #endif
        }
    }
}

#Preview("title block · model line") {
    let near = Provider(name: "near.ai",
                        endpoint: "https://api.near.ai/v1",
                        model: "zai-org/GLM-5.1-FP8")
    let ollama = Provider(name: "ollama",
                          endpoint: "http://100.100.0.1:11434/v1",
                          model: "unsloth/gemma-4-E4B-it-qat-GGUF:UD-Q4_K_XL")
    // 266pt is the principal on a 402pt phone; 239pt on a 375pt one. The line
    // has to survive the narrower of the two.
    return VStack(spacing: 24) {
        E2EETitleBlock(title: "gold and bitcoin", state: .ok, provider: near)
        E2EETitleBlock(title: "gold and bitcoin", state: .verifying, provider: near)
        E2EETitleBlock(title: "gold and bitcoin", state: .degraded, provider: near)
        E2EETitleBlock(title: "gold and bitcoin", state: .degraded, provider: near,
                       isHardFailure: true)
        E2EETitleBlock(title: "gold and bitcoin", state: .ok, provider: near, mismatchCount: 1)
        // long registry slug, self-hosted: "on your own machine"
        E2EETitleBlock(title: "gold and bitcoin", state: .none, provider: ollama)
        // ON-DEVICE: a stronger claim than the line above it, and it used to
        // render as an empty second line — the most private option teemoon has,
        // shown as the least. The two must be visibly different.
        E2EETitleBlock(title: "gold and bitcoin", state: .none,
                       provider: Provider.local(LocalModelCatalog.all[1]))
        E2EETitleBlock(title: "Whats the best order to watch dragonball z for a newcomer",
                       state: .ok, provider: near)
    }
    .frame(maxWidth: 239)
    .padding()
}

#Preview("title block · all states") {
    VStack(spacing: 28) {
        E2EETitleBlock(title: "chat", state: .ok)
        E2EETitleBlock(title: "gold and bitcoin", state: .ok)
        E2EETitleBlock(title: "Whats the best order to watch dragonball z for a newcomer", state: .ok)
        E2EETitleBlock(title: "gold and bitcoin", state: .verifying)
        E2EETitleBlock(title: "gold and bitcoin", state: .degraded)
        // Soft degrade above (orange); the two RED states below.
        E2EETitleBlock(title: "gold and bitcoin", state: .degraded, isHardFailure: true)
        E2EETitleBlock(title: "gold and bitcoin", state: .ok, mismatchCount: 1)
        E2EETitleBlock(title: "gold and bitcoin", state: .none)
    }
    .frame(maxWidth: 250)
    .padding()
}


