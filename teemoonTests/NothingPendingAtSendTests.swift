//
//  NothingPendingAtSendTests.swift
//  teemoonTests
//
//  S30 (the maintainer 2026-11-07): "the user feels like the e2ee is theater if status show verifying and the message
//  still goes out". Nothing leaves while anything is pending: a hard verdict, a stale record's refetch, image
//  provenance, the near.ai tier. At the settle timeout the send asks; provenance alone asks its own question. An
//  inconclusive provenance lookup (T2b) asks too. formal/ NothingPendingAtSend, ChipNeverVerifyingAtSend.
//
//  The Pixel log behind it: a record past attestationMaxAge sent at once, sealed to the old key, while its refetch
//  ran; the new record landed ~0.7 s later and the chip read "verifying" for the rest of the reply.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@Suite("Nothing leaves while the chip reads verifying", .serialized)
@MainActor struct NothingPendingAtSendTests {

    final class Recorder: GenerationTransport, @unchecked Sendable {
        let calls = LockedBox<Int>(0)
        func runTurn(messages: [[String: Any]], includeTools: Bool,
                     onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
            calls.value += 1
            onPartialContent("an answer")
            return TurnOutput(content: "an answer")
        }
    }

    /// What the request carried as it left: the record it was sealed to, and what the chip read then.
    struct Sent { let nonce: String?; let sealed: Bool; let chip: AttestationState }

    /// Holds DCAP until the test opens it; the open answer is an outage the cancelled task never writes.
    struct HeldCollateral: CollateralProvider {
        let gate: AsyncGate
        func collateralJSON(forQuote rawQuote: Data) async throws -> Data {
            await gate.pass()
            throw URLError(.timedOut)
        }
    }

    static let upToDate = DCAPVerification.verified(tcbStatus: .upToDate, mrConfigIdHex: "", reportDataHex: "")

    /// The preview record for `model` with every verdict in and verified, the tier known own-fleet unless `knownTier`
    /// is false.
    private func verifiedSession(model: String, knownTier: Bool = true,
                                 dcap: DCAPService = DCAPService()) -> (ProviderStore, ConfidentialSession) {
        var provider = Provider.nearAI
        provider.model = model
        provider.requiresAPIKey = false
        let store = ProviderStore(inMemory: true)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        if knownTier { NearAIModelCatalog.recordTiers([model: .teeOwn]) }
        let session = ConfidentialSession(providers: store, dcapService: dcap)
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
        session.tlsAttestation = .verified
        session.trustScope = TrustScope(binding: .bound, boot: .matches)
        return (store, session)
    }

    @MainActor final class Chat {
        let vm = ChatViewModel()
        let llm = ChatGeneration()
        let transport = Recorder()
        let container: ModelContainer
        let store: ProviderStore
        let session: ConfidentialSession
        var thread: ChatThread?
        var sent: [Sent] = []

        init(_ store: ProviderStore, _ session: ConfidentialSession) throws {
            container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            self.store = store
            self.session = session
            let transport = transport
            llm.makeLanguageModel = { [weak self] _, _, prior, tee, events in
                MainActor.assumeIsolated {
                    self?.sent.append(Sent(nonce: tee?.attestation.gpuNonce, sealed: tee?.e2eePeer != nil,
                                           chip: session.chipState))
                }
                return TransportLanguageModel(transport: transport, priorMessages: prior, events: events)
            }
        }

        func send(_ text: String) {
            vm.prompt = text
            vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                        providers: store, session: session, llm: llm)
        }

        func sendAnyway() {
            vm.sendAnyway(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                          providers: store, session: session, llm: llm)
        }

        func idle(_ seconds: Double = 8) async throws {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while vm.generatingThreadID != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try #require(vm.generatingThreadID == nil, "the turn is still running")
        }
    }

    private func until(_ seconds: Double = 3, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func withSettleTimeout<T>(_ timeout: Duration, _ body: () async throws -> T) async rethrows -> T {
        let previous = ConfidentialSession.verifierSettleTimeout
        ConfidentialSession.verifierSettleTimeout = timeout
        defer { ConfidentialSession.verifierSettleTimeout = previous }
        return try await body()
    }

    /// (a) A record past its age: the send waits for the refetch AND the new record's checks, then goes to the new
    /// record's key, with the chip off "verifying".
    @Test func aStaleRecordSendsOnlyToItsRefetchedRecordOnceItsChecksSettle() async throws {
        let fetchGate = AsyncGate(), dcapGate = AsyncGate()
        let (store, session) = verifiedSession(model: "zai-org/S30-STALE-PROBE",
                                               dcap: DCAPService(collateral: HeldCollateral(gate: dcapGate)))
        session.directBase = { _ in nil }   // the new record's TLS check: no direct host, neutral
        let fetched = AttestationRecord.preview.fetchedAt
        session.now = { fetched.addingTimeInterval(ConfidentialSession.attestationMaxAge + 1) }
        var fresh = try #require(session.attestation)
        fresh.gpuNonce = "s30-fresh"   // a new record key; the gateway nonce must still echo
        let started = LockedBox(false)
        session.fetchRecord = { [fresh] _, _, _ in
            started.value = true
            await fetchGate.pass()
            return fresh
        }
        try await withSettleTimeout(.seconds(10)) {
            let chat = try Chat(store, session)
            chat.send("hello")
            let refetching = try await until { started.value }
            try await Task.sleep(for: .milliseconds(300))
            #expect(chat.transport.calls.value == 0, "sent to the stale record while its refetch ran")
            try #require(refetching, "no refetch started for a record past attestationMaxAge")

            // The copy keeps the old fetchedAt; past its age but adopted, it is not refetched again by this turn.
            await fetchGate.open()
            try #require(try await until { session.attestation?.gpuNonce == "s30-fresh" }, "the refetch was not adopted")
            session.provenanceTask?.cancel()
            session.imageProvenance = .allVerified(verified: [], thirdParty: [])
            session.provenanceSettled = true
            try await Task.sleep(for: .milliseconds(300))
            #expect(chat.transport.calls.value == 0, "sent before the new record's DCAP answered")

            session.dcapTask?.cancel()
            var verified = RecordDCAPVerification()
            verified.gateway = Self.upToDate; verified.model = Self.upToDate
            session.dcapVerification = verified
            await dcapGate.open()
            try await chat.idle()
            #expect(chat.transport.calls.value == 1, "refused: \(chat.llm.lastError?.userMessage ?? "no error"); \(session.sendPolicy) \(session.attestationState) \(session.e2eeDegradedReason ?? "")")
            #expect(!chat.vm.hardwareConfirmRequested, "nothing was left pending; no question")
            #expect(chat.sent.map(\.nonce) == ["s30-fresh"], "sealed to \(chat.sent.map(\.nonce)), not the new record")
            #expect(chat.sent.allSatisfy { $0.sealed })
            #expect(chat.sent.allSatisfy { $0.chip != .verifying }, "the chip read verifying as the request left")
        }
    }

    /// (a) A stale record whose refetch fails: nothing goes out; the record soft-degrades and the send asks.
    @Test func aStaleRecordWhoseRefetchFailsSendsNothingAndAsks() async throws {
        let (store, session) = verifiedSession(model: "zai-org/S30-STALE-FAIL-PROBE")
        let fetched = AttestationRecord.preview.fetchedAt
        session.now = { fetched.addingTimeInterval(ConfidentialSession.attestationMaxAge + 1) }
        session.fetchRecord = { _, _, _ in
            try await Task.sleep(for: .milliseconds(200))
            throw URLError(.notConnectedToInternet)
        }
        try await withSettleTimeout(.seconds(10)) {
            let chat = try Chat(store, session)
            chat.send("hello")
            try await chat.idle()
            #expect(chat.transport.calls.value == 0, "sent to a stale record whose refetch failed")
            #expect(session.sendPolicy == .confirm)
            #expect(session.e2eeDegradedReason == "couldn't reach the attestation server.")
        }
    }

    /// (b) Provenance alone still running at the settle timeout: nothing goes out; the send asks "couldn't confirm
    /// near.ai's software yet"; "send anyway" sends sealed, and the chip has left verifying.
    @Test func provenanceInFlightAtTheTimeoutAsksItsOwnQuestion() async throws {
        let (store, session) = verifiedSession(model: "zai-org/S30-PROVENANCE-PROBE")
        session.imageProvenance = nil
        session.provenanceSettled = false
        let never = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        defer { never.cancel() }
        session.provenanceTask = never
        try await withSettleTimeout(.milliseconds(300)) {
            let chat = try Chat(store, session)
            chat.send("hello")
            try await chat.idle()
            #expect(chat.transport.calls.value == 0, "sent while provenance was in flight")
            #expect(chat.vm.hardwareConfirmRequested && chat.vm.pendingAskKind == .provenance)
            let ask = E2EEAsk.make(hardFailure: false, pendingAsk: chat.vm.pendingAskKind,
                                   provenanceUnchecked: session.provenanceUncheckedAsks,
                                   softButSealed: session.softButSealed,
                                   provenanceBlocked: session.provenanceBlockedButE2EEIntact, cause: nil)
            #expect(ask.title == E2EESendChoice.provenancePendingTitle)

            chat.sendAnyway()
            try await chat.idle()
            #expect(chat.transport.calls.value == 1)
            #expect(chat.sent.map(\.sealed) == [true])
            #expect(chat.sent.allSatisfy { $0.chip != .verifying }, "the chip read verifying as the request left")
            #expect(session.hasConfirmed(pending: true), "the answer is remembered for this record")
        }
    }

    /// (b) Provenance answering inside the wait: the send goes once it has, with no question and a verified chip.
    @Test func provenanceAnsweringInsideTheWaitSendsWithoutAsking() async throws {
        let (store, session) = verifiedSession(model: "zai-org/S30-PROVENANCE-QUICK-PROBE")
        session.imageProvenance = nil
        session.provenanceSettled = false
        session.provenanceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            session.imageProvenance = .allVerified(verified: [], thirdParty: [])
            session.provenanceSettled = true
        }
        try await withSettleTimeout(.seconds(10)) {
            let chat = try Chat(store, session)
            chat.send("hello")
            try await chat.idle()
            #expect(chat.transport.calls.value == 1)
            #expect(!chat.vm.hardwareConfirmRequested)
            #expect(chat.sent.map(\.chip) == [.ok], "the chip read \(chat.sent.map(\.chip)) as the request left")
        }
    }

    /// (c) The near.ai tier still unknown: nothing goes out until it resolves; at the timeout the hardware
    /// still-checking ask; "send anyway" sends with the chip on "encrypted · hardware not confirmed".
    @Test func anUnknownTierHoldsTheSendAndAsksAtTheTimeout() async throws {
        let model = "zai-org/S30-UNKNOWN-TIER-PROBE"
        try await NearAIModelCatalog.$tierListSeenOverride.withValue(false) {
            let (store, session) = verifiedSession(model: model, knownTier: false)
            #expect(NearAIModelCatalog.confidentiality(forID: model) == .unknown, "precondition: the tier is unknown")
            try await withSettleTimeout(.milliseconds(300)) {
                let chat = try Chat(store, session)
                chat.send("hello")
                try await chat.idle()
                #expect(chat.transport.calls.value == 0, "sent while the tier was unknown")
                #expect(chat.vm.hardwareConfirmRequested && chat.vm.pendingAskKind == .hardware)

                chat.sendAnyway()
                #expect(session.sealedButHardwareUnconfirmed, "the answered look is 'encrypted · hardware not confirmed'")
                try await chat.idle()
                #expect(chat.transport.calls.value == 1)
                #expect(chat.sent.map(\.chip) == [.degraded], "the chip read \(chat.sent.map(\.chip)) as the request left")
            }
        }
    }

    /// A pending hardware verdict answered with "send anyway": the request leaves under the answered look.
    @Test func anAnsweredHardwareAskLeavesWithTheChipOffVerifying() async throws {
        let (store, session) = verifiedSession(model: "zai-org/S30-TLS-PROBE")
        session.tlsAttestation = nil
        let never = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        defer { never.cancel() }
        session.tlsTask = never
        try await withSettleTimeout(.milliseconds(300)) {
            let chat = try Chat(store, session)
            chat.send("hello")
            try await chat.idle()
            #expect(chat.vm.hardwareConfirmRequested && chat.vm.pendingAskKind == .hardware)
            chat.sendAnyway()
            try await chat.idle()
            #expect(chat.transport.calls.value == 1)
            #expect(chat.sent.map(\.chip) == [.degraded], "the chip read \(chat.sent.map(\.chip)) as the request left")
        }
    }

    /// T2b now asks: an inconclusive provenance lookup keeps the chip's look and asks "couldn't confirm near.ai's
    /// software" with the provenance-only choices. Repeat rule: once per (record, reason), so a new record asks again.
    @Test func anInconclusiveProvenanceLookupAsksOncePerRecord() async throws {
        let (store, session) = verifiedSession(model: "zai-org/S30-T2B-PROBE")
        session.imageProvenance = nil
        session.provenanceInconclusive = true
        #expect(session.chipState == .ok, "T2b keeps its approved look")
        #expect(session.sendPolicy == .confirm, "an inconclusive lookup sent with no question")
        let ask = E2EEAsk.make(hardFailure: false, pendingAsk: nil, provenanceUnchecked: session.provenanceUncheckedAsks,
                               softButSealed: session.softButSealed,
                               provenanceBlocked: session.provenanceBlockedButE2EEIntact, cause: session.e2eeDegradedReason)
        #expect(ask == E2EEAsk(title: E2EESendChoice.provenanceUncheckedTitle,
                               message: E2EESendChoice.provenanceUncheckedMessage,
                               choices: E2EESendChoice.choices(hardFailure: false, provenanceOnly: true)))

        let chat = try Chat(store, session)
        chat.send("unanswered")
        try await chat.idle()
        #expect(chat.transport.calls.value == 0, "the gate sent past an unanswered question")

        chat.vm.prompt = "hello"   // the composer as ChatView's "send anyway (still encrypted)" finds it
        chat.sendAnyway()
        try await chat.idle()
        #expect(chat.transport.calls.value == 1)
        session.lastRequestUsedE2EE = true   // the test transport reports no seal on the wire
        #expect(session.sendPolicyAfterConfirmations == .allow, "the same record asked twice")
        chat.send("again")
        try await chat.idle()
        #expect(chat.transport.calls.value == 2, "a confirmed record's next send went nowhere")
        session.lastRequestUsedE2EE = true

        var next = try #require(session.attestation)
        next.gpuNonce = "s30-next-record"
        session.attestation = next
        #expect(session.sendPolicyAfterConfirmations == .confirm, "a new record did not ask again")
    }
}
