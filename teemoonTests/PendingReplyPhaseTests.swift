//
//  PendingReplyPhaseTests.swift
//  teemoonTests
//
//  S32 (the maintainer 2026-11-07, seen on Android): since S30 prepareTurn can hold a send up to 15 s, and the reply
//  placeholder read "thinking…" the whole time although nothing had been sent. While the gate holds the send it
//  reads "waiting for verification…"; once the request leaves, "thinking…" as before. A plain-TLS or on-device turn
//  never waits at the gate and never shows the waiting label. An engine load line keeps priority.
//  formal/ ThinkingOnlyAfterSend, WaitingOnlyWhenTheGateCanHold.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@Suite("The reply placeholder never reads thinking before the request leaves", .serialized)
@MainActor struct PendingReplyPhaseTests {

    // MARK: the rule

    @Test func aHeldGateReadsWaitingForVerification() {
        #expect(PendingReplyPhase.of(gateWaiting: true, loadLine: nil, thinkingHarder: false) == .waitingForVerification)
        #expect(PendingReplyPhase.of(gateWaiting: true, loadLine: nil, thinkingHarder: true) == .waitingForVerification,
                "a think harder waits at the gate like any send")
    }

    @Test func afterTheGateItIsTodaysThinking() {
        #expect(PendingReplyPhase.of(gateWaiting: false, loadLine: nil, thinkingHarder: false) == .thinking)
        #expect(PendingReplyPhase.of(gateWaiting: false, loadLine: nil, thinkingHarder: true) == .thinkingHarder)
    }

    @Test func aModelLoadLineWins() {
        let line = EngineLoadLine.loading
        #expect(PendingReplyPhase.of(gateWaiting: false, loadLine: line, thinkingHarder: false) == .loadingModel(line))
        #expect(PendingReplyPhase.of(gateWaiting: true, loadLine: line, thinkingHarder: true) == .loadingModel(line))
    }

    /// The approved words (the maintainer 2026-11-07T22:37:08Z), with U+2026. No clock.
    @Test func theWaitingLabelSaysExactlyThis() {
        #expect(GenerationActivityChipView.label(for: .waitingForVerification, elapsed: nil) == "waiting for verification…")
        #expect(GenerationActivityChipView.label(for: .waitingForVerification, elapsed: 9) == "waiting for verification…")
        #expect(GenerationActivityChipView.ActivityState(.waitingForVerification) == .waitingForVerification)
        #expect(GenerationActivityChipView.ActivityState(.thinking) == .thinking)
    }

    // MARK: through the chat

    final class Recorder: GenerationTransport, @unchecked Sendable {
        let calls = LockedBox<Int>(0)
        func runTurn(messages: [[String: Any]], includeTools: Bool,
                     onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
            calls.value += 1
            onPartialContent("an answer")
            return TurnOutput(content: "an answer")
        }
    }

    @MainActor final class Chat {
        let vm = ChatViewModel()
        let llm = ChatGeneration()
        let transport = Recorder()
        let container: ModelContainer
        let store: ProviderStore
        let session: ConfidentialSession
        var thread: ChatThread?
        /// The placeholder's phase as the request left.
        var atSend: [PendingReplyPhase] = []

        init(_ store: ProviderStore, _ session: ConfidentialSession) throws {
            container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            self.store = store
            self.session = session
            let transport = transport
            let llm = llm
            llm.makeLanguageModel = { [weak self] _, _, prior, _, events in
                MainActor.assumeIsolated { self?.atSend.append(llm.pendingReplyPhase(at: Date())) }
                return TransportLanguageModel(transport: transport, priorMessages: prior, events: events)
            }
        }

        var phase: PendingReplyPhase { llm.pendingReplyPhase(at: Date()) }

        func send(_ text: String) {
            vm.prompt = text
            vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                        providers: store, session: session, llm: llm)
        }

        /// Samples the phase every few ms until the turn ends.
        func idle(_ seconds: Double = 8) async throws -> [PendingReplyPhase] {
            var seen: [PendingReplyPhase] = [phase]
            let deadline = ContinuousClock.now + .seconds(seconds)
            while vm.generatingThreadID != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
                if vm.generatingThreadID != nil, !llm.running { seen.append(phase) }
            }
            try #require(vm.generatingThreadID == nil, "the turn is still running")
            return seen
        }
    }

    private static let upToDate = DCAPVerification.verified(tcbStatus: .upToDate, mrConfigIdHex: "", reportDataHex: "")

    /// near.ai, every verdict in and verified except TLS, which never answers: prepareTurn holds the send.
    private func heldSession(model: String) -> (ProviderStore, ConfidentialSession, Task<Void, Never>) {
        var provider = Provider.nearAI
        provider.model = model
        provider.requiresAPIKey = false
        let store = ProviderStore(inMemory: true)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        NearAIModelCatalog.recordTiers([model: .teeOwn])
        let session = ConfidentialSession(providers: store)
        session.attestationTask?.cancel()
        var record = AttestationRecord.preview
        record.model = model
        session.attestation = record
        session.lastRequestUsedE2EE = true
        session.imageProvenance = .allVerified(verified: [], thirdParty: [])
        session.provenanceSettled = true
        var verified = RecordDCAPVerification()
        verified.gateway = Self.upToDate; verified.model = Self.upToDate
        session.dcapVerification = verified
        session.gpuAttestation = .verified
        session.trustScope = TrustScope(binding: .bound, boot: .matches)
        session.tlsAttestation = nil
        let never = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        session.tlsTask = never
        return (store, session, never)
    }

    private func plainSession(_ provider: Provider) -> (ProviderStore, ConfidentialSession) {
        let store = ProviderStore(inMemory: true)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        return (store, ConfidentialSession(providers: store))
    }

    private func withSettleTimeout<T>(_ timeout: Duration, _ body: () async throws -> T) async rethrows -> T {
        let previous = ConfidentialSession.verifierSettleTimeout
        ConfidentialSession.verifierSettleTimeout = timeout
        defer { ConfidentialSession.verifierSettleTimeout = previous }
        return try await body()
    }

    /// The bug: during a held prepareTurn the placeholder read "thinking...". From the tap on, it reads waiting, and
    /// the live empty row (stored as didn't-finish until the turn ends) is never one the transcript draws.
    @Test func aHeldGateReadsWaitingFromTheTapAndNoDidntFinishRowShows() async throws {
        let (store, session, never) = heldSession(model: "zai-org/S32-HELD-GATE-PROBE")
        defer { never.cancel() }
        try await withSettleTimeout(.seconds(2)) {
            let chat = try Chat(store, session)
            chat.send("hello")
            #expect(chat.phase == .waitingForVerification, "the frame after the tap read \(chat.phase)")
            try await Task.sleep(for: .milliseconds(400))
            #expect(chat.session.sendPending, "precondition: the gate is still holding the send")
            #expect(chat.transport.calls.value == 0)
            #expect(chat.phase == .waitingForVerification, "a held gate read \(chat.phase); nothing has been sent")

            let thread = try #require(chat.thread)
            let live = thread.sortedMessages.filter { ReplyMarkerWords.marker(of: $0) == .didntFinish }
            #expect(!live.isEmpty, "precondition: the send's reply row is stored as didn't-finish while it is live")
            let drawn = chat.vm.replies.transcriptRows(thread.sortedMessages)
            #expect(!drawn.contains { ReplyMarkerWords.marker(of: $0) == .didntFinish },
                    "the transcript draws \"this reply didn't finish.\" under the waiting placeholder")

            _ = try await chat.idle()
            #expect(chat.vm.hardwareConfirmRequested, "the settle timeout asks")
            #expect(!chat.llm.waitingForVerification, "the label outlived the gate")
        }
    }

    /// Once the gate passes and the request leaves, today's thinking.
    @Test func afterTheRequestLeavesItReadsThinking() async throws {
        let (store, session, never) = heldSession(model: "zai-org/S32-PASSES-PROBE")
        defer { never.cancel() }
        session.tlsTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            session.tlsAttestation = .verified
        }
        try await withSettleTimeout(.seconds(5)) {
            let chat = try Chat(store, session)
            chat.send("hello")
            let seen = try await chat.idle()
            #expect(chat.transport.calls.value == 1)
            #expect(seen.first == .waitingForVerification)
            #expect(chat.atSend == [.thinking], "the request left reading \(chat.atSend)")
        }
    }

    /// A plain-TLS provider: the gate never waits, so the waiting label never shows, not even for a frame.
    @Test func aPlainTLSProviderNeverShowsTheWaitingLabel() async throws {
        let provider = Provider(name: "plain", endpoint: "https://plain.example/v1/chat/completions",
                                model: "plain-model", requiresAPIKey: false)
        let (store, session) = plainSession(provider)
        let chat = try Chat(store, session)
        chat.send("hello")
        let seen = try await chat.idle()
        #expect(chat.transport.calls.value == 1)
        #expect(!seen.contains(.waitingForVerification), "a plain-TLS turn read \(seen)")
        #expect(chat.atSend == [.thinking])
    }

    /// On-device (LiteRT): no gate wait either.
    @Test func anOnDeviceTurnNeverShowsTheWaitingLabel() async throws {
        let provider = Provider(name: "gemma 4 e2b", endpoint: "on-device",
                                model: "google/gemma-4-e2b-it-litert-lm", requiresAPIKey: false,
                                localModelID: "google/gemma-4-e2b-it-litert-lm")
        let (store, session) = plainSession(provider)
        let chat = try Chat(store, session)
        chat.send("hello")
        let seen = try await chat.idle()
        #expect(chat.transport.calls.value == 1)
        #expect(!seen.contains(.waitingForVerification), "an on-device turn read \(seen)")
    }
}
