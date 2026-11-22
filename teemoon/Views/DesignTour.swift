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
//  Compiled out of Release entirely (a release-build check scans the binary for DesignTour): no call site may name it
//  outside `#if DEBUG`.
//

#if os(iOS) && DEBUG
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
    // 1.1.1 trust surfaces: the sheet's hero, the three send asks over the chat, the no-encryption ladder.
    case trustVerified    = "trust-verified"
    case askCantSeal      = "ask-cant-seal"
    case askEnclaveList   = "ask-enclave-list"
    case askTierDowngrade = "ask-tier-downgrade"
    case ladderNone       = "ladder-none"
    // The five listed-enclave states (KeyCustodyCopy.Listed), each on the ladder.
    case listedChecked    = "listed-checked"
    case listedListFailed = "listed-list-failed"
    case listedChecking   = "listed-checking"
    case listedUnfinished = "listed-unfinished"
    case listedFailed     = "listed-failed"

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
    /// The chat raises its send ask on appear; what it asks comes from the seeded session.
    static var raisesSendAsk: Bool { [.askCantSeal, .askEnclaveList, .askTierDowngrade].contains(current) }

    @MainActor @ViewBuilder var view: some View {
        let store = previewStore()
        switch self {
        case .runVerified:
            NavigationStack { VerificationRunView() }
                .environment(Seed.verified(store))
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
                .environment(Seed.verified(store))
                .environment(store)
        case .trustVerified:
            NavigationStack { TrustLadderView(initialRung: .everyday) }
                .environment(Seed.verified(store))
                .environment(store)
        case .askCantSeal:
            Seed.chat(store: store, session: Seed.cantSeal(store))
        case .askEnclaveList:
            Seed.chat(store: store, session: Seed.enclaveListFailed(store))
        case .askTierDowngrade:
            Seed.chat(store: store, session: Seed.tierDowngrade(store))
        case .ladderNone:
            let fireworks = Seed.fireworks()
            NavigationStack { TrustLadderView(initialRung: .everyday) }
                .environment(ConfidentialSession(providers: fireworks))
                .environment(fireworks)
        case .listedChecked, .listedListFailed, .listedChecking, .listedUnfinished, .listedFailed:
            let session = switch self {
            case .listedListFailed: Seed.enclaveListFailed(store)
            case .listedChecking: Seed.listedChecking(store)
            case .listedUnfinished: Seed.listedDCAP(store, .unchecked("collateral: no response from api.trustedservices.intel.com"))
            case .listedFailed: Seed.listedDCAP(store, .failed("quote signature invalid"))
            default: Seed.verified(store)
            }
            NavigationStack { TrustLadderView() }
                .environment(session)
                .environment(store)
        case .ladderVerifying:
            NavigationStack { TrustLadderView() }
                .environment(ConfidentialSession(providers: store))
                .environment(store)
        case .ladderPaused:
            // No Ed25519 key → attestationState resolves to .degraded
            // (fail-closed), so the hero reads "sending paused".
            NavigationStack { TrustLadderView() }
                .environment(Seed.cantSeal(store))
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

    /// Session state for the tour routes. State only: each screen reads it through the real gates and `E2EEAsk`.
    @MainActor enum Seed {
        static let model = "zai-org/GLM-5.1-FP8"

        /// The verified fixture with near.ai's tier list seen (own fleet) and two listed enclaves, read and clean in
        /// every listed check, so `verdictsPending` is false and the hero isn't "verifying…".
        static func verified(_ store: ProviderStore) -> ConfidentialSession {
            NearAIModelCatalog.recordTiers([model: .teeOwn])
            let session = previewSession(store: store)
            var record = session.attestation ?? .preview
            record.modelCandidates = ModelCandidates.Listed(enclaves: [enclave("listed-1"), enclave("listed-2")])
            session.attestation = record
            let quote = DCAPVerification.verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
            session.dcapVerification?.listed = [quote, quote]
            session.listedTrustScopes = [TrustScope(binding: .bound, boot: .matches), TrustScope(binding: .bound, boot: .matches)]
            return session
        }

        static func enclave(_ id: String) -> ModelCandidates.Enclave {
            ModelCandidates.Enclave(instanceID: id, composeHash: String(repeating: "3a", count: 32), appID: "app-\(id)",
                                    keyProviderID: nil, mrKMS: nil, result: .clean, nvidiaPayload: "{}")
        }

        /// The listed trust scopes still running: `KeyCustodyCopy.Listed.checking`.
        static func listedChecking(_ store: ProviderStore) -> ConfidentialSession {
            let session = verified(store)
            session.listedTrustScopes = nil
            session.listedTrustScopeTask = Task { try? await Task.sleep(for: .seconds(3600)) }
            return session
        }

        /// The second listed enclave's DCAP verdict: `.unchecked` → unfinished, `.failed` → failed.
        static func listedDCAP(_ store: ProviderStore, _ verdict: DCAPVerification) -> ConfidentialSession {
            let session = verified(store)
            session.dcapVerification?.listed[1] = verdict
            return session
        }

        /// No Ed25519 key: nothing to seal to, soft → "end-to-end encryption unavailable".
        static func cantSeal(_ store: ProviderStore) -> ConfidentialSession {
            let session = verified(store)
            session.attestation = .previewDegraded
            return session
        }

        /// Sealed and verified, but near.ai's list of enclaves holding the key didn't load (A8).
        static func enclaveListFailed(_ store: ProviderStore) -> ConfidentialSession {
            let session = verified(store)
            var record = session.attestation ?? .preview
            record.modelCandidates = nil
            record.modelCandidatesListFailed = true
            session.attestation = record
            session.dcapVerification?.listed = []
            session.listedTrustScopes = nil
            return session
        }

        /// A request once went out sealed to the model; near.ai now lists it third-party (rule 2).
        static func tierDowngrade(_ store: ProviderStore) -> ConfidentialSession {
            NearAIModelCatalog.recordTiers([model: .teeThirdParty])
            if var p = store.providers.first(where: { $0.id == Provider.nearAI.id }) {
                p.model = model
                store.updateProvider(p)
            }
            let suite = "ai.teemoon.designtour.sealed"
            UserDefaults().removePersistentDomain(forName: suite)
            let sealed = SealedModels(defaults: UserDefaults(suiteName: suite) ?? .standard)
            sealed.arm(model)
            return ConfidentialSession(providers: store, sealedModels: sealed)
        }

        /// A provider with nothing to attest.
        static func fireworks() -> ProviderStore {
            let store = ProviderStore(inMemory: true)
            store.addProvider(.fireworks)
            store.currentProviderID = Provider.fireworks.id.uuidString
            return store
        }

        static func chat(store: ProviderStore, session: ConfidentialSession) -> some View {
            ChatView(currentThread: .constant(nil), isPromptFocused: FocusState<Bool>().projectedValue,
                     showChats: .constant(false), showSettings: .constant(false),
                     showSettingsProviders: .constant(false), showSettingsSearch: .constant(false))
                .environment(store)
                .environment(session)
                .environment(ChatGeneration())
        }
    }
}

#endif
