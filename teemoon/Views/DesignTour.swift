//
//  DesignTour.swift
//  teemoon
//
//  DEBUG-only launch-argument route for design review. Xcode Previews render
//  a view without the app's composition root (theme settings, environment
//  objects, navigation shell), so preview captures under-style the UI. This
//  route launches the REAL app directly into one verification-flow state fed
//  by the same fixtures Canvas uses, so `simctl io screenshot` captures every
//  screen fully styled, headlessly, and repeatably:
//
//    xcrun simctl launch <udid> <bundle-id> -DesignTour run-verified
//
//  Flags composable with any state:
//    -DesignTourExpandAll   open every run disclosure (per-step rows,
//                           e.g. the provenance section's image list)
//    -DesignTourBottom      scroll the run list to the bottom sections
//                           (trust · verify-it-yourself)
//
//  Release builds keep only inert `false`/`nil` statics — no tour UI ships.
//

#if os(iOS)
import SwiftUI

enum DesignTour: String {
    case runVerified  = "run-verified"
    case runVerifying = "run-verifying"
    case runFlagged   = "run-flagged"
    case glossary     = "glossary"
    case titleBlocks  = "title-blocks"
    case ladderVerified  = "ladder-verified"
    case ladderVerifying = "ladder-verifying"
    case ladderPaused    = "ladder-paused"

    #if DEBUG
    /// The state requested at launch, or nil for a normal run.
    static let current: DesignTour? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-DesignTour"),
              args.indices.contains(i + 1) else { return nil }
        return DesignTour(rawValue: args[i + 1])
    }()
    static let expandAll = ProcessInfo.processInfo.arguments.contains("-DesignTourExpandAll")
    static let scrollToBottom = ProcessInfo.processInfo.arguments.contains("-DesignTourBottom")
    /// Scroll a specific anchor id into view: `-DesignTourScrollTo <id>`.
    static let scrollTarget: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-DesignTourScrollTo"),
              args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }()
    /// Force the trust-ladder rung for capture: `-DesignTourRung everyday`.
    static let initialRung: TrustRung? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-DesignTourRung"),
              args.indices.contains(i + 1) else { return nil }
        return TrustRung(rawValue: args[i + 1])
    }()
    #else
    static let current: DesignTour? = nil
    static let expandAll = false
    static let scrollToBottom = false
    static let scrollTarget: String? = nil
    static let initialRung: TrustRung? = nil
    #endif

    #if DEBUG
    @MainActor @ViewBuilder var view: some View {
        let store = previewStore()
        switch self {
        case .runVerified:
            NavigationStack { VerificationRunView() }
                .environment(previewSession(store: store))
                .environment(store)
        case .runVerifying:
            NavigationStack { VerificationRunView() }
                .environment(ConfidentialSession(providers: store))
                .environment(store)
        case .runFlagged:
            NavigationStack { VerificationRunView() }
                .environment(previewSession(store: store, tls: .notPerformed, allPass: false))
                .environment(store)
        case .glossary:
            // the primer sheet in its real presentation context — medium
            // detent over the dimmed run screen
            NavigationStack { VerificationRunView() }
                .environment(previewSession(store: store))
                .environment(store)
                .sheet(isPresented: .constant(true)) {
                    GlossarySheet(entry: .primer)
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.hidden)
                }
        case .ladderVerified:
            NavigationStack { TrustLadderView() }
                .environment(previewSession(store: store))
                .environment(store)
        case .ladderVerifying:
            NavigationStack { TrustLadderView() }
                .environment(ConfidentialSession(providers: store))
                .environment(store)
        case .ladderPaused:
            // No Ed25519 key → attestationState resolves to .degraded
            // (fail-closed), so the hero reads "sending paused".
            NavigationStack { TrustLadderView() }
                .environment({
                    let session = ConfidentialSession(providers: store)
                    session.attestation = .previewDegraded
                    return session
                }())
                .environment(store)
        case .titleBlocks:
            // the chat title chip — the flow's entry affordance — in each state
            NavigationStack {
                List {
                    Section("verified") {
                        E2EETitleBlock(title: "quantum poetry", state: .ok)
                            .frame(maxWidth: .infinity)
                    }
                    Section("verifying") {
                        E2EETitleBlock(title: "quantum poetry", state: .verifying)
                            .frame(maxWidth: .infinity)
                    }
                    Section("degraded — E2EE unavailable") {
                        E2EETitleBlock(title: "quantum poetry", state: .degraded)
                            .frame(maxWidth: .infinity)
                    }
                }
                .navigationTitle("title block states")
                .navigationBarTitleDisplayMode(.inline)
            }
            .environment(previewSession(store: store))
            .environment(store)
        }
    }
    #endif
}

#endif
