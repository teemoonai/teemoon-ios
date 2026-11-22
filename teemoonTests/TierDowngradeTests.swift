//
//  TierDowngradeTests.swift
//  teemoonTests
//
//  1.1.1 item 1 (docs/TIER_DOWNGRADE.md, 1.1.0 audit LOW): a near.ai model a send went to sealed, now listed
//  third-party or proxied, asks once before its first plain send.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@MainActor
@Suite("Tier downgrade asks once (item 1)")
struct TierDowngradeTests {

    /// One id per test: the tier cache is process-wide and the suites run in parallel.
    let model = "z-ai/downgrade-\(UUID().uuidString.prefix(8).lowercased())"

    static func defaults() -> UserDefaults {
        let name = "tierdowngrade-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// near.ai with `model`, its tier forced through the catalogue cache the capability guard reads.
    func session(tier: NearAIModelCatalog.Confidentiality, sealed: SealedModels) -> ConfidentialSession {
        var provider = Provider.nearAI
        provider.model = model
        NearAIModelCatalog.recordTiers([model: tier])
        let store = ProviderStore(inMemory: true)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let s = ConfidentialSession(providers: store, sealedModels: sealed)
        s.attestationTask?.cancel()
        return s
    }

    @Test func aListThatDemotesASealedModelMakesTheNextSendAsk() {
        let sealed = SealedModels(defaults: Self.defaults())
        sealed.arm(model)
        let s = session(tier: .teeThirdParty, sealed: sealed)
        #expect(s.sealedModelWentPlain)
        #expect(s.sendPolicy == .confirm)
        #expect(!s.degradeIsHardFailure)
        let ask = s.e2eeAskTierDowngrade
        #expect(ask?.title == TierDowngrade.title(model: ModelCatalog.compactName(forID: model)))
        #expect(ask?.choices == [.sendAnyway(stillEncrypted: false), .dontSend])
    }

    /// Card tier-downgrade-ask v4 + follow-ups (approved 2026-11-19T06:26:42Z), word for word: the model is named once,
    /// in the title, and the way through is "send without encryption".
    @Test func theAskIsTheApprovedCopyExactly() throws {
        let sealed = SealedModels(defaults: Self.defaults())
        sealed.arm(model)
        let ask = try #require(session(tier: .teeThirdParty, sealed: sealed).e2eeAskTierDowngrade)
        let name = ModelCatalog.compactName(forID: model)
        #expect(ask.title == "\(name) isn't end-to-end encrypted anymore")
        #expect(ask.message == "near.ai now lists it as running outside its own enclaves, so this message would reach near.ai over ordinary TLS. your earlier messages to it were sealed.")
        #expect(!ask.message.contains(name))
        #expect(ask.choices.map(\.label) == ["send without encryption", "don't send"])
        #expect(ask.choices.filter(\.isDestructive) == [.sendAnyway(stillEncrypted: false)])
    }

    /// The label is "send without encryption" everywhere (audit 1.1.1 B1): no app source says the old one.
    @Test func noShippingSourceSaysSendUnencrypted() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("teemoon")
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in files where ["swift", "xcstrings", "strings", "plist"].contains(url.pathExtension) {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            #expect(text.range(of: "send unencrypted", options: .caseInsensitive) == nil, "\(url.lastPathComponent)")
        }
        #expect(scanned > 100)
        #expect(E2EESendChoice.sendAnyway(stillEncrypted: false).label == "send without encryption")
    }

    @Test func proxiedIsADowngradeToo() {
        let sealed = SealedModels(defaults: Self.defaults())
        sealed.arm(model)
        #expect(session(tier: .proxied, sealed: sealed).sendPolicy == .confirm)
    }

    @Test func answeringOnceDoesNotAskAgain() {
        let sealed = SealedModels(defaults: Self.defaults())
        sealed.arm(model)
        let s = session(tier: .teeThirdParty, sealed: sealed)
        s.rememberConfirmation(pending: false, answering: .tierDowngrade)   // "send without encryption"
        #expect(!s.sealedModelWentPlain)
        #expect(s.sendPolicy == .allow)
        #expect(sealed.ids.isEmpty)
    }

    @Test func dontSendLeavesTheModelArmed() {
        let sealed = SealedModels(defaults: Self.defaults())
        sealed.arm(model)
        let s = session(tier: .teeThirdParty, sealed: sealed)
        // "don't send" is the reverify path: nothing remembered, so the next send asks again.
        #expect(s.sendPolicy == .confirm)
        #expect(sealed.ids == [model.lowercased()])
    }

    @Test func aSecondSealingReArmsAndASecondDowngradeAsks() {
        let sealed = SealedModels(defaults: Self.defaults())
        sealed.arm(model)
        let plain = session(tier: .teeThirdParty, sealed: sealed)
        plain.rememberConfirmation(pending: false, answering: .tierDowngrade)
        _ = session(tier: .teeOwn, sealed: sealed)   // near.ai lists it own-fleet again
        sealed.arm(model)   // a sealed request reached the wire (SealedArmingTests)
        #expect(session(tier: .teeThirdParty, sealed: sealed).sendPolicy == .confirm)
    }

    /// Rule 5: Shortcuts has no one to ask, so it refuses while the ask is owed, with its existing line.
    @Test func shortcutsRefusesWhileTheAskIsOwed() {
        let sealed = SealedModels(defaults: Self.defaults())
        sealed.arm(model)
        let s = session(tier: .teeThirdParty, sealed: sealed)
        #expect(RequestLLMIntent.refusalDialog(policy: s.sendPolicy, providerIsAttested: false, canSeal: false) != nil)
    }

    @Test func aModelNeverSealedNeverAsks() {
        let s = session(tier: .teeThirdParty, sealed: SealedModels(defaults: Self.defaults()))
        #expect(!s.sealedModelWentPlain)
        #expect(s.sendPolicy == .allow)
    }

    @Test func anotherProviderNeverAsks() {
        var fw = Provider.fireworks
        fw.model = model
        #expect(!TierDowngrade.owed(provider: fw, sealed: [model.lowercased()]))
    }

    /// The record and the soft state an own-fleet model asks "still checking" on: Intel's collateral couldn't be read.
    func softAsk(_ s: ConfidentialSession) {
        var record = AttestationRecord.preview
        record.model = model   // the session's read gate hides a record stamped for another model
        s.attestation = record
        s.lastRequestUsedE2EE = true
        s.imageProvenance = .allVerified(verified: [], thirdParty: [])
        s.provenanceSettled = true
        var dcap = RecordDCAPVerification()
        dcap.gateway = SendGateRuleTests.upToDate
        dcap.model = .unchecked("collateral: pcs unreachable")
        s.dcapVerification = dcap
        s.gpuAttestation = .verified
        s.tlsAttestation = .verified
        s.trustScope = TrustScope(binding: .bound, boot: .matches)
    }

    /// Audit 1.1.1 B1 read: a confirmation given before the flip, on the record the session still holds, never answers
    /// the downgrade ask; only its own "send without encryption" does. A flip refreshes nothing, so the record stays.
    @Test func anEarlierConfirmationNeverAnswersTheDowngradeAsk() throws {
        let sealed = SealedModels(defaults: Self.defaults())
        sealed.arm(model)
        let s = session(tier: .teeOwn, sealed: sealed)
        softAsk(s)
        #expect(s.sendPolicyAfterConfirmations == .confirm, "precondition: the soft ask")
        #expect(s.softButSealed, "precondition: the still-encrypted ask")
        let earlierKey = try #require(s.confirmationKey(pending: false))
        s.rememberConfirmation(pending: false, answering: .verification)   // "send anyway" on record R
        #expect(s.sendPolicyAfterConfirmations == .allow)
        #expect(sealed.ids == [model.lowercased()], "a soft confirm is not the downgrade consent")

        NearAIModelCatalog.recordTiers([model: .teeThirdParty])     // near.ai flips it while R is held
        #expect(s.attestation != nil, "the flip leaves the record in place")
        #expect(s.sealedModelWentPlain)
        #expect(s.confirmedDegrades == [earlierKey], "the flip clears no confirmation either")
        // Today the reason half of the key moves (a plain model has no degrade reason), so this one answer misses;
        // the guard must not rest on that. Any confirmation for this record and reason, then:
        #expect(s.confirmationKey(pending: false) != earlierKey)
        if let key = s.confirmationKey(pending: false) { s.confirmedDegrades.insert(key) }
        if let key = s.confirmationKey(pending: true) { s.confirmedDegrades.insert(key) }
        #expect(s.sendPolicyAfterConfirmations == .confirm, "the composer asks")
        #expect(s.e2eeAskTierDowngrade != nil, "and the ask is the downgrade sheet")
        for pending in [false, true] {
            #expect(!s.hasConfirmed(pending: pending))
            // ChatViewModel's gate after prepareTurn: nothing goes out plain on an earlier answer.
            let gate = ChatViewModel.postPrepare(policy: s.sendPolicy, acceptedDegrade: s.hasConfirmed(pending: pending),
                                                 verdictsPending: false, sealed: false)
            #expect(gate != .proceed)
        }
        s.rememberConfirmation(pending: false, answering: .tierDowngrade)   // the downgrade ask's own answer
        #expect(sealed.ids.isEmpty)
        #expect(s.sendPolicyAfterConfirmations == .allow)
    }

    @Test func theStoreHoldsModelIdsOnly() {
        let d = Self.defaults()
        let sealed = SealedModels(defaults: d)
        sealed.arm("Z-AI/GLM-5.3-Flash")
        #expect(d.stringArray(forKey: SealedModels.key) == ["z-ai/glm-5.3-flash"])
        sealed.clear()
        #expect(d.object(forKey: SealedModels.key) == nil)
    }
}

/// Audit 1.1.1 B1 (review of build 64): the consent is the answer to the ask that was ON SCREEN. A "send anyway" tapped on
/// the list-failed or still-checking ask after near.ai flipped the tier used to read the session at the tap, disarm the
/// model and let the next send go plain with no downgrade ask. Each test drives `ChatViewModel.sendAnyway`, the path
/// ChatView's buttons call, against a counting transport; no network.
@MainActor
@Suite("Only the downgrade ask's own answer disarms", .serialized)
struct DowngradeConsentIsTheShownAskTests {

    let model = "z-ai/consent-\(UUID().uuidString.prefix(8).lowercased())"

    @MainActor struct Chat {
        let store: ProviderStore; let session: ConfidentialSession; let sealed: SealedModels
        let vm = ChatViewModel(); let transport = ConfirmPendingSendAnywayTests.Counting(); let llm = ChatGeneration()
        let container: ModelContainer
        var thread: ChatThread?
        /// Per request handed to the transport: was it sealed.
        let sealedAtSend = LockedBox<[Bool]>([])

        func settle() async throws {
            for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
            try #require(vm.generatingThreadID == nil, "the turn is still running")
        }

        mutating func sendAnyway(answering kind: E2EEAsk.Kind) async throws {
            vm.sendAnyway(answering: kind, currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                          providers: store, session: session, llm: llm)
            try await settle()
        }

        /// The ask ChatView draws now, on this redraw.
        var shownAsk: E2EEAsk { vm.e2eeAsk(session: session) }
    }

    /// An own-fleet near.ai model a send already went to sealed, its record verified; `tweak` sets the soft state.
    func chat(_ tweak: (ConfidentialSession) -> Void) throws -> Chat {
        var provider = Provider.nearAI
        provider.model = model
        provider.requiresAPIKey = false
        NearAIModelCatalog.recordTiers([model: .teeOwn])
        let store = ProviderStore(inMemory: true)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let sealed = SealedModels(defaults: TierDowngradeTests.defaults())
        sealed.arm(model)
        let s = ConfidentialSession(providers: store, sealedModels: sealed)
        s.attestationTask?.cancel()
        var record = AttestationRecord.preview
        record.model = model
        s.attestation = record
        s.now = { AttestationRecord.preview.fetchedAt }
        s.lastRequestUsedE2EE = true
        s.imageProvenance = .allVerified(verified: [], thirdParty: [])
        s.provenanceSettled = true
        var dcap = RecordDCAPVerification()
        dcap.gateway = SendGateRuleTests.upToDate; dcap.model = SendGateRuleTests.upToDate
        s.dcapVerification = dcap
        s.gpuAttestation = .verified
        s.tlsAttestation = .verified
        s.trustScope = TrustScope(binding: .bound, boot: .matches)
        tweak(s)
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let c = Chat(store: store, session: s, sealed: sealed, container: container)
        let transport = c.transport, sealedAtSend = c.sealedAtSend
        c.llm.makeLanguageModel = { _, _, prior, tee, events in
            sealedAtSend.value = sealedAtSend.value + [tee?.e2eePeer != nil]
            return TransportLanguageModel(transport: transport, priorMessages: prior, events: events)
        }
        return c
    }

    /// After the stray tap: nothing went out, the model is still armed, and the next send meets the downgrade ask,
    /// whose own "send without encryption" then disarms and sends, as before.
    func expectTheDowngradeAskComesNext(_ c: inout Chat) async throws {
        #expect(c.transport.calls.value == 0, "a tap on another ask sent the message plain")
        #expect(c.sealed.ids == [model.lowercased()], "a tap on another ask disarmed the model")
        #expect(c.session.sendPolicyAfterConfirmations == .confirm)
        c.vm.prompt = "again"
        #expect(c.vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: false,
                                 trust: c.session.sendPolicyAfterConfirmations) == .confirmE2EE, "the next send didn't ask")
        let next = c.shownAsk
        #expect(next.kind == .tierDowngrade, "the next ask is \(next.title)")
        #expect(next.title == TierDowngrade.title(model: ModelCatalog.compactName(forID: model)))

        try await c.sendAnyway(answering: next.kind)   // "send without encryption"
        #expect(c.sealed.ids.isEmpty)
        #expect(c.transport.calls.value == 1, "the downgrade ask's own answer sent nothing")
        #expect(c.session.sendPolicyAfterConfirmations == .allow)
    }

    @Test func aListFailedSendAnywayAfterTheFlipIsNotTheConsent() async throws {
        var c = try chat { s in s.attestation?.modelCandidatesListFailed = true }
        #expect(c.session.enclaveListFailedAsks, "precondition: the list-failed ask")
        c.vm.prompt = "hello"
        #expect(c.vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: false,
                                 trust: c.session.sendPolicyAfterConfirmations) == .confirmE2EE)
        let shown = c.shownAsk
        #expect(shown.title == E2EESendChoice.listFailedTitle && shown.kind == .verification)

        NearAIModelCatalog.recordTiers([model: .teeThirdParty])   // near.ai's list moves it while the ask is up
        #expect(c.session.sealedModelWentPlain, "precondition: the tier flipped")
        try await c.sendAnyway(answering: shown.kind)             // "send anyway" on the list-failed ask
        try await expectTheDowngradeAskComesNext(&c)
    }

    /// The alert redraws live. Downgrade ask on screen, then near.ai lists the model own-fleet again: the redrawn ask is
    /// another kind, and neither its tap nor a tap on the stale downgrade button disarms.
    @Test func aDowngradeAskRedrawnAsAnotherKindIsNotTheConsent() async throws {
        var c = try chat { s in s.attestation?.modelCandidatesListFailed = true }
        NearAIModelCatalog.recordTiers([model: .teeThirdParty])
        #expect(c.shownAsk.kind == .tierDowngrade, "precondition: the downgrade ask is on screen")
        NearAIModelCatalog.recordTiers([model: .teeOwn])          // a verdict lands; the alert redraws
        let redrawn = c.shownAsk
        #expect(redrawn.kind == .verification && redrawn.title == E2EESendChoice.listFailedTitle, "\(redrawn.title)")
        c.session.rememberConfirmation(pending: false, answering: .tierDowngrade)   // a stale button, if one fired
        #expect(c.sealed.ids == [model.lowercased()], "a downgrade answer disarmed with no downgrade owed")
        c.vm.prompt = "hello"
        try await c.sendAnyway(answering: redrawn.kind)
        #expect(c.sealed.ids == [model.lowercased()], "the redrawn ask's tap disarmed the model")
        // The tier moves back: the model is still armed, so the downgrade ask is owed again.
        NearAIModelCatalog.recordTiers([model: .teeThirdParty])
        #expect(c.shownAsk.kind == .tierDowngrade)
    }

    /// Android's real case (its ae867660): the downgrade ask is up, a verdict lands and the alert redraws as the
    /// still-checking ask; that ask's "send anyway" must not accept the downgrade, and nothing goes plain.
    @Test func aDowngradeAskRedrawnAsStillCheckingIsNotTheConsent() async throws {
        let never = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        defer { never.cancel() }
        var c = try chat { s in s.tlsAttestation = nil; s.tlsTask = never }
        let previous = ConfidentialSession.verifierSettleTimeout
        ConfidentialSession.verifierSettleTimeout = .milliseconds(200)
        defer { ConfidentialSession.verifierSettleTimeout = previous }
        NearAIModelCatalog.recordTiers([model: .teeThirdParty])
        #expect(c.shownAsk.kind == .tierDowngrade, "precondition: the downgrade ask is on screen")
        NearAIModelCatalog.recordTiers([model: .teeOwn])          // a verdict lands; the alert redraws
        let redrawn = c.shownAsk
        #expect(redrawn.title == E2EESendChoice.stillCheckingTitle && redrawn.kind == .verification, "\(redrawn.title)")
        c.vm.prompt = "hello"
        try await c.sendAnyway(answering: redrawn.kind)           // the still-checking ask's "send anyway"
        #expect(c.sealed.ids == [model.lowercased()], "the still-checking tap accepted the downgrade")
        #expect(!c.sealedAtSend.value.contains(false), "a request went out plain: \(c.sealedAtSend.value)")
        NearAIModelCatalog.recordTiers([model: .teeThirdParty])
        #expect(c.shownAsk.kind == .tierDowngrade, "the downgrade ask is still owed")
    }

    /// Structural: nothing stores which ask was shown across redraws. The kind is read off the ask built in the same
    /// pass as the alert's buttons (ChatView) or computed per call (ChatViewModel.e2eeAsk), never held in a property.
    @Test func noStoredPropertyHoldsTheAskKind() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("teemoon")
        let stored = try NSRegularExpression(pattern:
            #"^\s*(@\w+(\([^)]*\))?\s+)*(private(\(set\))?\s+|fileprivate\s+)?(var|let)\s+\w+\s*:\s*(E2EEAsk|E2EEAsk\.Kind)\??\s*(=.*)?$"#)
        let kindName = try NSRegularExpression(pattern:
            #"^\s*(@\w+\s+)*(private\s+)?var\s+\w*([Dd]owngrade[A-Z]\w*|[Ss]hownAsk|[Aa]skKind|[Pp]resentedAsk)\w*\s*(:\s*Bool|=\s*(false|true|nil))"#)
        var scanned = 0
        for name in ["Views/Chat/ChatView.swift", "Chat/ChatViewModel.swift", "Presentation/SendChoices.swift"] {
            let text = try String(contentsOf: app.appendingPathComponent(name), encoding: .utf8)
            scanned += 1
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let r = NSRange(line.startIndex..., in: line)
                #expect(stored.firstMatch(in: line, range: r) == nil, "\(name):\(i + 1) stores an ask: \(line)")
                #expect(kindName.firstMatch(in: line, range: r) == nil, "\(name):\(i + 1) stores an ask flag: \(line)")
            }
        }
        #expect(scanned == 3)
        let view = try String(contentsOf: app.appendingPathComponent("Views/Chat/ChatView.swift"), encoding: .utf8)
        #expect(view.contains("let ask = e2eeAsk"), "the alert builds its ask in the pass that draws its buttons")
        #expect(view.contains("generateBypassing(answering: ask.kind)"))
        // The detector catches what it is for.
        for bad in ["    @State private var shownAsk: E2EEAsk?", "    private var tierDowngradeShown = false",
                    "    var askKind: E2EEAsk.Kind = .verification"] {
            let r = NSRange(bad.startIndex..., in: bad)
            #expect(stored.firstMatch(in: bad, range: r) != nil || kindName.firstMatch(in: bad, range: r) != nil, "\(bad)")
        }
    }

    /// The reverse: another ask on screen redraws as the downgrade ask when the tier flips; a tap then answers that.
    @Test func anAskRedrawnAsTheDowngradeAskIsAnsweredByItsTap() async throws {
        var c = try chat { s in s.attestation?.modelCandidatesListFailed = true }
        #expect(c.shownAsk.kind == .verification, "precondition: the list-failed ask is on screen")
        NearAIModelCatalog.recordTiers([model: .teeThirdParty])   // the alert redraws
        let redrawn = c.shownAsk
        #expect(redrawn.kind == .tierDowngrade && redrawn.choices == [.sendAnyway(stillEncrypted: false), .dontSend])
        c.vm.prompt = "hello"
        try await c.sendAnyway(answering: redrawn.kind)           // "send without encryption"
        #expect(c.sealed.ids.isEmpty)
        #expect(c.transport.calls.value == 1)
    }

    /// The kind is the drawn ask's: `.tierDowngrade` exactly when the downgrade sheet is what's drawn.
    @Test func theKindIsTheDrawnAsk() throws {
        let c = try chat { s in s.attestation?.modelCandidatesListFailed = true }
        for tier in [NearAIModelCatalog.Confidentiality.teeOwn, .teeThirdParty, .proxied, .teeOwn] {
            NearAIModelCatalog.recordTiers([model: tier])
            let ask = c.shownAsk
            let isDowngradeSheet = ask.title == TierDowngrade.title(model: ModelCatalog.compactName(forID: model))
            #expect((ask.kind == .tierDowngrade) == isDowngradeSheet, "\(tier): \(ask.title)")
            #expect((ask.kind == .tierDowngrade) == c.session.sealedModelWentPlain)
        }
    }

    @Test func aStillCheckingSendAnywayAfterTheFlipIsNotTheConsent() async throws {
        let never = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        defer { never.cancel() }
        var c = try chat { s in s.tlsAttestation = nil; s.tlsTask = never }
        let previous = ConfidentialSession.verifierSettleTimeout
        ConfidentialSession.verifierSettleTimeout = .milliseconds(200)
        defer { ConfidentialSession.verifierSettleTimeout = previous }
        c.vm.prompt = "hello"
        c.vm.generate(currentThread: &c.thread, modelContext: c.container.mainContext, settings: AppSettings(),
                      providers: c.store, session: c.session, llm: c.llm)
        try await c.settle()
        try #require(c.vm.hardwareConfirmRequested, "precondition: the still-checking ask")
        let shown = c.shownAsk
        #expect(shown.title == E2EESendChoice.stillCheckingTitle && shown.kind == .verification)

        NearAIModelCatalog.recordTiers([model: .teeThirdParty])
        #expect(c.session.sealedModelWentPlain, "precondition: the tier flipped")
        try await c.sendAnyway(answering: shown.kind)             // "send anyway" on the still-checking ask
        try await expectTheDowngradeAskComesNext(&c)
    }
}

/// Audit 1.1.1 B1 read: a model is armed when its sealed request reaches the wire, not when a reply ends. Each test
/// runs the real send path (ChatGeneration → ConfidentialLanguageModel → HTTPTransport) against a stub; no network.
@MainActor
@Suite("A sealed request arms its model at the wire", .serialized)
struct SealedArmingTests {

    let model = "z-ai/arming-\(UUID().uuidString.prefix(8).lowercased())"

    func session(tier: NearAIModelCatalog.Confidentiality, sealed: SealedModels) -> ConfidentialSession {
        var provider = Provider.nearAI
        provider.model = model
        NearAIModelCatalog.recordTiers([model: tier])
        let store = ProviderStore(inMemory: true)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let s = ConfidentialSession(providers: store, sealedModels: sealed)
        s.attestationTask?.cancel()
        return s
    }

    /// An own-fleet model whose record verifies: the send is sealed and nothing is pending.
    func sealedSession(_ sealed: SealedModels) -> ConfidentialSession {
        let s = session(tier: .teeOwn, sealed: sealed)
        s.attestation = record(.preview)
        s.now = { AttestationRecord.preview.fetchedAt }
        s.lastRequestUsedE2EE = true
        s.imageProvenance = .allVerified(verified: [], thirdParty: [])
        s.provenanceSettled = true
        var dcap = RecordDCAPVerification()
        dcap.gateway = SendGateRuleTests.upToDate; dcap.model = SendGateRuleTests.upToDate
        s.dcapVerification = dcap
        s.gpuAttestation = .verified
        s.tlsAttestation = .verified
        s.trustScope = TrustScope(binding: .bound, boot: .matches)
        return s
    }

    /// The session's read gate hides a record stamped for another model.
    func record(_ base: AttestationRecord) -> AttestationRecord {
        var r = base
        r.model = model
        return r
    }

    func generation(_ mode: WireStub.Mode) -> ChatGeneration {
        WireStub.reset(mode)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WireStub.self]
        let urlSession = URLSession(configuration: config)
        let llm = ChatGeneration()
        llm.makeLanguageModel = { provider, key, prior, context, events in
            ConfidentialLanguageModel(provider: provider, apiKey: key, priorMessages: prior, context: context,
                                      events: events, urlSession: urlSession)
        }
        return llm
    }

    func thread() -> ChatThread {
        let thread = ChatThread()
        thread.messages.append(Message(role: .user, content: "hi", thread: thread, isE2EE: true))
        return thread
    }

    func send(_ llm: ChatGeneration, _ s: ConfidentialSession, context: TEEContext?) async -> String {
        await llm.generate(provider: s.activeProvider!, thread: thread(), systemPrompt: "", groundingAPIKey: nil,
                           apiKey: "k", teeContext: context)
    }

    @Test func aSealedSendThatErrorsBeforeAReplyArms() async throws {
        let sealed = SealedModels(defaults: TierDowngradeTests.defaults())
        let s = sealedSession(sealed)
        let context = try #require(s.currentTEEContext())
        #expect(context.e2eePeer != nil, "precondition: sealed")
        let llm = generation(.fail)
        _ = await send(llm, s, context: context)
        #expect(WireStub.seen.value >= 1, "the request reached the stub")
        #expect(llm.lastError != nil, "and no reply came")
        #expect(sealed.ids == [model.lowercased()])
    }

    @Test func aSealedSendStoppedBeforeAReplyArms() async throws {
        let sealed = SealedModels(defaults: TierDowngradeTests.defaults())
        let s = sealedSession(sealed)
        let context = try #require(s.currentTEEContext())
        let llm = generation(.hang)
        let turn = Task { await send(llm, s, context: context) }
        let start = ContinuousClock.now
        while WireStub.seen.value == 0, ContinuousClock.now - start < .seconds(10) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(WireStub.seen.value == 1, "the request reached the stub")
        llm.stop()
        let out = await turn.value
        #expect(out.isEmpty, "stopped before a reply")
        #expect(sealed.ids == [model.lowercased()])
    }

    /// Shortcuts' path, step for step (RequestLLMIntent.perform): prepareTurn, the same gate, then generate with its context.
    @Test func anIntentSendArms() async throws {
        let sealed = SealedModels(defaults: TierDowngradeTests.defaults())
        let s = sealedSession(sealed)
        let provider = try #require(s.activeProvider)
        #expect(!s.sendPending, "precondition: nothing to wait for")
        let teeContext = await s.prepareTurn(for: ConfidentialSession.TurnPlace(provider))
        #expect(RequestLLMIntent.refusalDialog(policy: s.sendPolicy, providerIsAttested: true,
                                               canSeal: teeContext?.e2eePeer != nil) == nil)
        let llm = generation(.fail)
        _ = await send(llm, s, context: teeContext)
        s.finishTurn(for: ConfidentialSession.TurnPlace(provider), debugInfo: llm.lastRequestDebugInfo, error: llm.lastError)
        #expect(WireStub.seen.value >= 1)
        #expect(sealed.ids == [model.lowercased()])
    }

    @Test func aPlainSendNeverArms() async throws {
        let sealed = SealedModels(defaults: TierDowngradeTests.defaults())
        let s = session(tier: .teeThirdParty, sealed: sealed)
        #expect(s.currentTEEContext() == nil, "precondition: a plain model has no sealed context")
        let llm = generation(.fail)
        _ = await send(llm, s, context: nil)
        #expect(WireStub.seen.value >= 1, "the plain request reached the stub")
        #expect(sealed.ids.isEmpty)
    }

    /// An attested model whose record carries no key: the context exists, the request is not sealed, nothing arms.
    @Test func anUnsealedContextNeverArms() async throws {
        let sealed = SealedModels(defaults: TierDowngradeTests.defaults())
        let s = sealedSession(sealed)
        s.attestation = record(.previewDegraded)
        let context = try #require(s.currentTEEContext())
        #expect(context.e2eePeer == nil, "precondition: not sealed")
        let llm = generation(.fail)
        _ = await send(llm, s, context: context)
        #expect(WireStub.seen.value >= 1)
        #expect(sealed.ids.isEmpty)
    }
}

/// Counts requests; `.fail` answers 500, `.hang` never answers (a stop cancels it).
final class WireStub: URLProtocol, @unchecked Sendable {
    enum Mode { case fail, hang }
    static let mode = LockedBox<Mode>(.fail)
    static let seen = LockedBox(0)
    static func reset(_ m: Mode) { mode.value = m; seen.value = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.value += 1
        guard Self.mode.value == .fail, let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"boom"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
