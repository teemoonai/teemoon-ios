//
//  SentBeforeConfirmedWiringTests.swift
//  teemoonTests
//
//  A sealed send that went out while its record was still being checked: the question and its reply carry
//  "pending|<recordKey>", the session does not count it as end-to-end encrypted, and when the record's verdict
//  settles the mark clears (pass) or turns into "failed|" (hard fail).
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@Suite("sentBeforeConfirmed is written at send and settled per record", .serialized)
@MainActor struct SentBeforeConfirmedWiringTests {

    final class SealedAnswer: GenerationTransport, @unchecked Sendable {
        func runTurn(messages: [[String: Any]], includeTools: Bool,
                     onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
            onPartialContent("sealed answer")
            var out = TurnOutput(content: "sealed answer", finish: .stop)
            out.report.isE2EEActive = true
            return out
        }
    }

    struct Rig {
        let container: ModelContainer
        let store: ProviderStore
        let session: ConfidentialSession
        let vm: ChatViewModel
        let thread: ChatThread?
        let never: Task<Void, Never>
        var question: Message? { thread?.sortedMessages.first { $0.role == .user } }
        var reply: Message? { thread?.sortedMessages.last { $0.role == .assistant } }
    }

    /// The near.ai preview record with TLS still checking; the user confirms at the settle timeout.
    /// `model`: stamp the record for a model id no other test uses, so its near.ai tier can be changed safely.
    private func sentWhileChecking(model: String? = nil) async throws -> Rig {
        var provider = Provider.nearAI
        provider.model = model ?? AttestationRecord.preview.model ?? provider.model
        provider.requiresAPIKey = false
        var record = AttestationRecord.preview
        if let model { record.model = model }
        let store = ProviderStore(inMemory: true)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let session = ConfidentialSession(providers: store)
        session.attestationTask?.cancel()
        session.attestation = record
        session.lastRequestUsedE2EE = true
        session.imageProvenance = .allVerified(verified: [], thirdParty: [])
        session.provenanceSettled = true
        let ok = DCAPVerification.verified(tcbStatus: .upToDate, mrConfigIdHex: "", reportDataHex: "")
        var dcap = RecordDCAPVerification()
        dcap.gateway = ok; dcap.model = ok
        session.dcapVerification = dcap
        session.gpuAttestation = .verified
        session.trustScope = TrustScope(binding: .bound, boot: .matches)
        session.tlsAttestation = nil
        let never = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        session.tlsTask = never
        let previous = ConfidentialSession.verifierSettleTimeout
        ConfidentialSession.verifierSettleTimeout = .milliseconds(200)
        defer { ConfidentialSession.verifierSettleTimeout = previous }

        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: SealedAnswer(), priorMessages: prior, events: events)
        }
        let vm = ChatViewModel()
        vm.prompt = "private question"
        var thread: ChatThread?
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm)
        for _ in 0..<250 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.hardwareConfirmRequested, "precondition: the gate asked")
        session.rememberConfirmation(pending: true, answering: .verification)
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm, acceptedDegrade: true)
        for _ in 0..<250 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.generatingThreadID == nil)
        return Rig(container: container, store: store, session: session, vm: vm, thread: thread, never: never)
    }

    private var pendingKey: String {
        SentBeforeConfirmed.pending(SentBeforeConfirmed.recordKey(for: .preview))
    }

    @Test func aSendConfirmedWhileCheckingIsMarkedAndNotCounted() async throws {
        let rig = try await sentWhileChecking()
        defer { rig.never.cancel() }
        #expect(rig.reply?.content == "sealed answer")
        #expect(rig.reply?.sentBeforeConfirmed == pendingKey)
        #expect(rig.question?.sentBeforeConfirmed == pendingKey)
        #expect(rig.session.e2eeMessageCount == 0, "a reply sent before its record was confirmed counted as E2EE")
    }

    @Test func aPassClearsTheMark() async throws {
        let rig = try await sentWhileChecking()
        rig.never.cancel()
        rig.session.tlsTask = nil
        rig.session.tlsAttestation = .verified
        rig.vm.settleSentBeforeConfirmed(session: rig.session, modelContext: rig.container.mainContext)
        #expect(rig.reply?.sentBeforeConfirmed == nil)
        #expect(rig.question?.sentBeforeConfirmed == nil)
    }

    @Test func aHardFailMarksTheReply() async throws {
        let rig = try await sentWhileChecking()
        rig.never.cancel()
        rig.session.tlsTask = nil
        rig.session.tlsAttestation = .failed("fingerprint mismatch")
        rig.vm.settleSentBeforeConfirmed(session: rig.session, modelContext: rig.container.mainContext)
        let failed = SentBeforeConfirmed.failed(SentBeforeConfirmed.recordKey(for: .preview))
        #expect(rig.reply?.sentBeforeConfirmed == failed)
        #expect(rig.question?.sentBeforeConfirmed == failed)
    }

    /// F5 (formal model): the model's tier was unknown at send (so it was attested and sealed); the tier list then
    /// resolves it to third-party, the attestation capability goes away and nothing reads as pending while the record's
    /// checks still run. That is not a verdict: the reply stays pending and is not counted.
    @Test func anUnknownTierResolvingToThirdPartyIsNotAPass() async throws {
        let model = "zai-org/S1-F5-TIER-PROBE"
        let rig = try await sentWhileChecking(model: model)
        defer { rig.never.cancel() }
        try #require(rig.reply?.sentBeforeConfirmed == pendingKey, "precondition: sent while checking")
        NearAIModelCatalog.recordTiers([model: .teeThirdParty])
        #expect(!(rig.store.activeProvider?.capabilities.contains(.attestation) ?? true), "precondition: the tier moved")
        #expect(!rig.session.verdictsPending, "precondition: nothing reads as pending without the capability")
        rig.vm.settleSentBeforeConfirmed(session: rig.session, modelContext: rig.container.mainContext)
        #expect(rig.reply?.sentBeforeConfirmed == pendingKey, "the pending mark was cleared without a verdict")
        #expect(rig.question?.sentBeforeConfirmed == pendingKey)
        #expect(rig.session.e2eeMessageCount == 0)
    }
}
