//
//  MacAttestationInspector.swift
//  teemoon
//
//  THE EXPERT RUNG, AS A WINDOW.
//
//  Not a sheet. A sheet is modal — it blocks the window it belongs to — and this
//  rung ends in "copy this into your terminal and re-verify yourself". Blocking
//  the conversation while the user pastes into Terminal is the one thing this
//  screen must not do. Keychain Access opens a certificate in its own window;
//  Mail puts raw source in its own window on ⌥⌘U, for the same reason.
//
//  Not a right-hand pane either, which was built out and rejected: a pane is
//  ~320pt, the values here are 64-character digests wanting four columns, and
//  the transcript beside it is already capped at 720pt. They would fight over
//  the same width.
//
//  ONE shared inspector, not one window per conversation. Finder shipped both
//  answers — Get Info (⌘I, one window per object) and the Inspector (⌥⌘I, one
//  window that follows the selection) — and the shared one is right when the
//  property varies by class rather than by instance. Attestation varies by
//  MODEL, not by thread: n windows for n threads on one model is noise.
//
//  Design: Claude Design v2.
//

#if os(macOS)

import SwiftUI

/// Identifier for the single inspector window, and the one place that opens it.
enum MacAttestationInspector {
    static let windowID = "attestation-inspector"

    /// The rung the inspector should land on. Set by whoever opens it.
    ///
    /// `show the proof…` opened the window on the EVERYDAY rung, so the flow was
    /// read six claims, click "show the proof…", read the same six claims
    /// larger, then click "expert". The everyday rung existed twice and the
    /// button did not do what it says.
    @MainActor static var pendingRung: TrustRung = .everyday

    /// Opens (or raises) the inspector on a given rung.
    ///
    /// Routed through a notification rather than `@Environment(\.openWindow)`
    /// because the callers are a toolbar popover and a menu command, neither of
    /// which reliably carries the scene environment — the same reason File ▸ New
    /// Chat posts a notification instead of mutating state directly.
    @MainActor
    static func open(rung: TrustRung = .everyday) {
        pendingRung = rung
        NotificationCenter.default.post(name: .teemoonOpenAttestation, object: nil)
    }
}

extension Notification.Name {
    static let teemoonOpenAttestation = Notification.Name("ai.teemoon.openAttestation")
}

/// The window's content: the full ladder, both rungs, with the everyday/expert
/// segments living here rather than in the popover.
///
/// The segments belong in this container because both rungs FIT it — which is
/// what a segmented control is for. In the popover they would have had to
/// dissolve their own container, which no Apple control does.
struct MacAttestationInspectorView: View {
    @Environment(ConfidentialSession.self) private var session
    @Environment(ProviderStore.self) private var providerStore

    var body: some View {
        // Opens on whichever rung asked for it — `show the proof…` asks for
        // expert, ⌘I and the menu ask for everyday.
        TrustLadderView(initialRung: MacAttestationInspector.pendingRung)
            // PROSE CAPS AT 680, THE WHOLE MAC PASS IS BUILT ON THAT.
            //
            // Without it "before anything leaves this Mac…" set as one 809pt
            // line, and `maxWidth: 1100` let it get worse — in a window whose
            // sibling transcript is capped at 720. Only the enclave table wants
            // the full width.
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(minWidth: 640, idealWidth: 790, maxWidth: 1100,
                   minHeight: 420, idealHeight: 620, maxHeight: .infinity)
            .accessibilityIdentifier("attestation.inspector")
    }
}

#endif
