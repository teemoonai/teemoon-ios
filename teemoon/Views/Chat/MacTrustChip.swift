//
//  MacTrustChip.swift
//  teemoon
//
//  THE TOOLBAR ITEM THAT SAYS WHETHER THIS CHAT IS PROVABLE.
//
//  The Mac computed attestation and showed none of it. `E2EETitleBlock` — the
//  iOS trust header and the only route into the ladder — is a navigation-title
//  item, which a Mac window does not have. So the whole proof surface, the
//  product's central claim, was unreachable on the platform.
//
//  Design: Claude Design v2.
//

#if os(macOS)

import SwiftUI

struct MacTrustChip: View {
    let state: AttestationState
    let isHardFailure: Bool
    var unpublishedButSealed: Bool = false
    let provider: Provider?
    let action: () -> Void

    /// THE CHIP CARRIES A WORD, NOT ONLY A COLOUR.
    ///
    /// Safari does not recolour the padlock when a connection degrades — it adds
    /// the words "not secure". Colour alone fails for roughly a tenth of users
    /// and for every screenshot pasted into a bug report, so the state is always
    /// legible as text.
    private var label: String {
        if isHardFailure { return "not verified" }
        if provider?.isLocal == true { return "on this Mac" }
        switch state {
        case .ok:        return "encrypted"
        case .verifying: return "verifying…"
        // SOFT DEGRADATION IS NOT HARD FAILURE, and this said it was.
        //
        // `.degraded` means the TEE attested but E2EE is unavailable — the
        // enclave still protects the data, the transport layer does not. It
        // returned the same red "not verified" as `isHardFailure`, so the one
        // signal the design has left (the composer banner is unbuilt) told both
        // stories identically, and `isHardFailure` was load-bearing for nothing.
        case .degraded:  return unpublishedButSealed ? "image unpublished" : "not encrypted"
        case .none:      return "not attestable"
        }
    }

    private var tint: Color {
        if isHardFailure { return .red }
        if provider?.isLocal == true { return .secondary }
        switch state {
        case .ok:        return teeVerified
        case .verifying: return .secondary
        // Amber, not red: something is weaker than promised, nothing is broken.
        case .degraded:  return .orange
        // `.none` means the provider cannot be attested at all — a cloud key
        // with no TEE. That is not a failure, it is an absence, so it must not
        // borrow failure's red.
        case .none:      return .secondary
        }
    }

    private var symbol: String {
        if isHardFailure { return "lock.trianglebadge.exclamationmark" }
        if provider?.isLocal == true { return "desktopcomputer" }
        switch state {
        case .ok:        return "lock.fill"
        case .verifying: return "lock.rotation"
        case .degraded:  return unpublishedButSealed ? "lock.fill" : "lock.open.fill"
        case .none:      return "lock.open"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.lowercase)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("who can read this?")
        .accessibilityLabel("attestation: \(label)")
        .accessibilityIdentifier("chat.trustChip")
    }
}

/// THE EVERYDAY RUNG, IN A POPOVER, ENDING IN A PUSH BUTTON.
///
/// Not a segmented control: a segmented control swaps content *inside* a
/// container — it never dissolves the container it sits in. Moving from a
/// popover to a window is exactly that dissolve, so it is a push button, the way
/// Safari's lock popover ends in "show certificate". The everyday/expert
/// segments live in the inspector, where both rungs fit.
struct MacTrustPopover: View {
    @Environment(ConfidentialSession.self) private var session
    @Environment(ProviderStore.self) private var providerStore
    let showProof: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // NOT A FIXED HEIGHT CLAMPING A TALLER VIEW.
            //
            // `.frame(height: 430)` over ~724pt of content cut ~41% of the rung
            // off behind an overlay scroller that draws nothing at rest — so the
            // bottom edge read as FINISHED. On the one surface whose entire job
            // is completeness, a fold that announces itself nowhere is the worst
            // available failure. A range lets it size to content and scroll only
            // when it truly cannot fit.
            TrustLadderView(initialRung: .everyday, showsRungPicker: false)
                .frame(width: 400)
                .frame(minHeight: 280, maxHeight: 560)

            Divider()

            HStack {
                Spacer()
                // THE TWO TINTS WERE SWAPPED. In this app orange is the
                // selected-segment colour (the Where filter) and blue is links
                // and controls. This button inherited orange and sat inches from
                // a green shield and a green chip, so a warm control read as
                // caution on the one screen where colour must mean one thing.
                Button("show the proof…", action: showProof)
                    .controlSize(.small)
                    .tint(.accentColor)
                    .accessibilityIdentifier("attestation.showProof")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 400)
    }
}

#endif
