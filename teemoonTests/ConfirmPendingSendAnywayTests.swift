//
//  ConfirmPendingSendAnywayTests.swift
//  teemoonTests
//
//  A fresh send whose verdicts are still pending at the settle timeout asks ("still checking"). The question is
//  already saved and the composer already cleared, so "send anyway" must still send that question.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@Suite("Send anyway after a still-checking question", .serialized)
@MainActor struct ConfirmPendingSendAnywayTests {

    final class Counting: GenerationTransport, @unchecked Sendable {
        let calls = LockedBox<Int>(0)
        let lastUser = LockedBox<(text: String, images: Int)?>(nil)
        func runTurn(messages: [[String: Any]], includeTools: Bool,
                     onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
            calls.value += 1
            if let user = messages.last(where: { $0["role"] as? String == "user" }) {
                if let text = user["content"] as? String {
                    lastUser.value = (text, 0)
                } else {
                    let parts = user["content"] as? [[String: Any]] ?? []
                    let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                    lastUser.value = (text, parts.filter { $0["type"] as? String == "image_url" }.count)
                }
            }
            onPartialContent("an answer")
            return TurnOutput(content: "an answer")
        }
    }

    /// The near.ai preview record, every verdict in except TLS, which never answers.
    /// `model`: stamp the record for a model id no other test uses, so its near.ai tier can be moved safely.
    private func sessionWithTLSPending(model: String? = nil) -> (ProviderStore, ConfidentialSession, Task<Void, Never>) {
        var provider = Provider.nearAI
        provider.model = model ?? AttestationRecord.preview.model ?? provider.model
        provider.requiresAPIKey = false
        provider.modelCapabilities = [.vision]
        let store = ProviderStore(inMemory: true)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let session = ConfidentialSession(providers: store)
        session.attestationTask?.cancel()
        var record = AttestationRecord.preview
        if let model { record.model = model }
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
        return (store, session, never)
    }

    struct Run {
        let vm: ChatViewModel
        let transport: Counting
        let thread: ChatThread?
        /// Held so the thread's models outlive the helper (a released container destroys them).
        let container: ModelContainer
    }

    /// Sends `prompt` (with `images`), lets the gate ask, runs `between` (the user typing on), then "send anyway"
    /// through `ChatViewModel.sendAnyway`, the path ChatView's button calls.
    enum Answer { case sendAnyway, decline, reverify }

    private func gatedThenSendAnyway(prompt: String, images: [ImageIntake.Image] = [],
                                     between: (ChatViewModel) -> Void = { _ in },
                                     answer: Answer = .sendAnyway) async throws -> Run {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let (store, session, never) = sessionWithTLSPending()
        defer { never.cancel() }
        let previous = ConfidentialSession.verifierSettleTimeout
        ConfidentialSession.verifierSettleTimeout = .milliseconds(200)
        defer { ConfidentialSession.verifierSettleTimeout = previous }
        #expect(session.currentTEEContext()?.e2eePeer != nil, "precondition: the send would be sealed")
        #expect(session.verdictsPending, "precondition: TLS is still checking")

        let transport = Counting()
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: transport, priorMessages: prior, events: events)
        }
        let vm = ChatViewModel()
        vm.prompt = prompt
        vm.pendingImages = images
        var thread: ChatThread?
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.generatingThreadID == nil, "the turn is still running; reading its rows now would race it")

        #expect(vm.hardwareConfirmRequested, "precondition: the gate asked instead of sending")
        #expect(transport.calls.value == 0, "precondition: nothing went out before the user answered")
        #expect(thread?.sortedMessages.filter { $0.role == .user }.count == 1, "precondition: the question is saved")

        // What the user answers is the still-checking ask they saw, whatever the alert's flag reads afterwards.
        let askedWhilePending = vm.hardwareConfirmRequested
        between(vm)
        if answer == .decline {
            // ChatView's wait, don't send and dismiss all call this.
            vm.returnGatedQuestion(currentThread: thread, modelContext: container.mainContext)
            return Run(vm: vm, transport: transport, thread: thread, container: container)
        }
        if answer == .reverify {
            // ChatView's Re-verify: a fresh send keeps nothing pending.
            #expect(vm.reverifyHeldTurn(currentThread: thread, modelContext: container.mainContext) == nil)
            return Run(vm: vm, transport: transport, thread: thread, container: container)
        }
        #expect(askedWhilePending == (vm.hardwareConfirmRequested || session.verdictsPending), "the ask changed under the user")
        vm.sendAnyway(answering: .verification, currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                      providers: store, session: session, llm: llm)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.generatingThreadID == nil, "the turn is still running; reading its rows now would race it")
        return Run(vm: vm, transport: transport, thread: thread, container: container)
    }

    /// Case 0: the composer was cleared by the first send, so "send anyway" found nothing to send.
    @Test func sendAnywaySendsSomething() async throws {
        let run = try await gatedThenSendAnyway(prompt: "hello")
        #expect(run.transport.calls.value == 1, "send anyway sent nothing")
        #expect(run.thread?.sortedMessages.contains { $0.role == .assistant } == true, "the question got no answer")
    }

    /// Case 1: the user typed on while the question was up; "send anyway" answers the gated message, and the
    /// new draft stays in the composer.
    @Test func sendAnywaySendsTheGatedMessageNotTheNewDraft() async throws {
        let run = try await gatedThenSendAnyway(prompt: "hello") { $0.prompt = "and one more thing" }
        #expect(run.transport.calls.value == 1)
        // The wire text is the message plus a time note ("\n\n[Sent at …]").
        #expect(run.transport.lastUser.value?.text.hasPrefix("hello") == true, "sent \(run.transport.lastUser.value?.text ?? "nothing")")
        #expect(run.thread?.sortedMessages.filter { $0.role == .user }.map(\.content) == ["hello"])
        #expect(run.vm.prompt == "and one more thing", "the new draft was taken")
    }

    /// Case 2: the gated message's picked images go with it. The test hook never receives prompt images, so this
    /// checks the turn answered the gated question and that question still holds both attachments: the send
    /// path reads a question's images from its attachments (`ImageAttachment.images(of:)`).
    @Test func sendAnywaySendsTheGatedMessagesImages() async throws {
        let images = [ComposerImageTests.kept(1), ComposerImageTests.kept(2)]
        let run = try await gatedThenSendAnyway(prompt: "what is this", images: images)
        #expect(run.transport.calls.value == 1)
        #expect(run.transport.lastUser.value?.text.hasPrefix("what is this") == true)
        let question = try #require(run.thread?.sortedMessages.last { $0.role == .user })
        #expect(question.content == "what is this")
        #expect(ImageAttachment.images(of: question).count == 2, "the gated question lost its images")
        #expect(run.vm.pendingImages.isEmpty, "the images went with the question, not back to the composer")
    }

    /// Wait, don't send and dismiss on the still-checking ask: the unsent question leaves the chat and comes back to
    /// the composer, its images byte for byte, ahead of what the user typed meanwhile. Nothing is sent or kept.
    @Test func declineReturnsTheQuestionToTheComposer() async throws {
        let question = [ComposerImageTests.kept(1), ComposerImageTests.kept(2)]
        let drafted = ComposerImageTests.kept(3)
        let run = try await gatedThenSendAnyway(prompt: "what is this", images: question, between: {
            $0.prompt = "and this one"
            $0.pendingImages = [drafted]
        }, answer: .decline)
        #expect(run.transport.calls.value == 0)
        #expect(run.thread?.sortedMessages.isEmpty == true, "the unsent question (or a reply row) stayed in the chat")
        let leftover = try run.container.mainContext.fetch(FetchDescriptor<ImageAttachment>())
        #expect(leftover.isEmpty, "the question's attachments stayed in the store")
        #expect(run.vm.prompt == "what is this\n\nand this one")
        #expect(run.vm.questionsReturned == 1, "the composer is not told to show the returned question from its start")
        #expect(run.vm.pendingImages.map(\.data) == (question + [drafted]).map(\.data), "image bytes changed or were dropped")
        #expect(run.vm.pendingImages.map(\.thumbnail) == (question + [drafted]).map(\.thumbnail))
        #expect(run.vm.pendingImages.map(\.mimeType) == (question + [drafted]).map(\.mimeType))
        #expect(!run.vm.hardwareConfirmRequested)
    }

    /// A returned question that pushes the composer over its limit keeps every image and refuses send.
    @Test func aReturnedQuestionOverTheLimitKeepsEveryImageAndRefusesSend() async throws {
        let question = (1...3).map { ComposerImageTests.kept($0) }
        let drafted = (4...6).map { ComposerImageTests.kept($0) }
        let run = try await gatedThenSendAnyway(prompt: "q", images: question, between: {
            $0.prompt = "d"
            $0.pendingImages = drafted
            $0.imageLimit = 4
        }, answer: .decline)
        #expect(run.vm.pendingImages.map(\.data) == (question + drafted).map(\.data), "an image was dropped")
        #expect(run.vm.imagesOverLimit)
        #expect(run.vm.overLimitNote == "up to 4 images per message")
        #expect(run.vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: false, trust: .allow) == .blockedTooManyImages)
    }

    /// Think harder whose gate asks: "send anyway" confirms that think harder, and its answer replaces the old one.
    /// It used to send nothing, because the gated question is followed by the reply it supersedes.
    @Test func sendAnywayAfterAThinkHarderAskConfirmsIt() async throws {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let (store, session, never) = sessionWithTLSPending()
        defer { never.cancel() }
        let previous = ConfidentialSession.verifierSettleTimeout
        ConfidentialSession.verifierSettleTimeout = .milliseconds(200)
        defer { ConfidentialSession.verifierSettleTimeout = previous }
        var thread: ChatThread? = ChatThread()
        context.insert(thread!)
        let question = Message(role: .user, content: "why", thread: thread)
        context.insert(question)
        context.insert(Message(role: .assistant, content: "old answer", thread: thread))
        try context.save()

        let transport = Counting()
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: transport, priorMessages: prior, events: events)
        }
        let vm = ChatViewModel()
        vm.retry(from: question, currentThread: &thread, modelContext: context, settings: AppSettings(),
                 providers: store, session: session, llm: llm, effort: .thinkHarder)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.generatingThreadID == nil)
        #expect(vm.hardwareConfirmRequested, "precondition: the gate asked")
        #expect(transport.calls.value == 0)

        session.rememberConfirmation(pending: vm.hardwareConfirmRequested, answering: .verification)
        vm.generate(currentThread: &thread, modelContext: context, settings: AppSettings(),
                    providers: store, session: session, llm: llm, acceptedDegrade: true)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.generatingThreadID == nil)
        #expect(transport.calls.value == 1, "send anyway sent nothing")
        #expect(thread?.sortedMessages.filter { $0.role == .assistant }.map(\.content) == ["an answer"])
    }

    /// F3 residual (formal model): Re-verify in the alert dismisses it, which clears hardwareConfirmRequested. The
    /// held-back turn must still resolve: "send anyway" sends it ...
    @Test func sendAnywayStillWorksAfterTheAlertWasDismissed() async throws {
        let run = try await gatedThenSendAnyway(prompt: "hello") { $0.hardwareConfirmRequested = false }
        #expect(run.transport.calls.value == 1, "the held-back turn wedged: send anyway sent nothing")
        #expect(run.thread?.sortedMessages.last?.statusRaw == "complete")
    }

    /// ... and declining (don't send, or Re-verify's own decline) returns the question to the composer.
    @Test func declineStillWorksAfterTheAlertWasDismissed() async throws {
        let run = try await gatedThenSendAnyway(prompt: "hello", between: { $0.hardwareConfirmRequested = false },
                                                answer: .decline)
        #expect(run.vm.prompt == "hello", "the held-back question did not come back")
        #expect(run.thread?.sortedMessages.isEmpty == true, "the held-back turn is still in the chat")
    }

    /// F4 (formal model): a "send anyway" is for one (record, reason). The user answered the still-checking ask; before
    /// the turn ran, TLS came back inconclusive, a different reason with its own question. The earlier answer must not
    /// carry the send past it.
    @Test func aConfirmationDoesNotCarryOverToADifferentReason() async throws {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let (store, session, never) = sessionWithTLSPending()
        defer { never.cancel() }
        let previous = ConfidentialSession.verifierSettleTimeout
        ConfidentialSession.verifierSettleTimeout = .milliseconds(200)
        defer { ConfidentialSession.verifierSettleTimeout = previous }
        let transport = Counting()
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: transport, priorMessages: prior, events: events)
        }
        let vm = ChatViewModel()
        vm.prompt = "hello"
        var thread: ChatThread?
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.hardwareConfirmRequested, "precondition: the still-checking ask")
        session.rememberConfirmation(pending: true, answering: .verification)

        never.cancel()
        session.tlsTask = nil
        session.tlsAttestation = .inconclusive("probe unreachable")
        #expect(!session.verdictsPending && session.sendPolicy == .confirm, "precondition: a different, soft reason")

        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm, acceptedDegrade: true)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.generatingThreadID == nil)
        #expect(transport.calls.value == 0, "the still-checking answer carried the send past an unconfirmed reason")
    }

    /// A hard verdict (TLS failed) lands while the still-checking ask is up, and the user taps "send anyway". Confirm
    /// re-reads the gate: .block sends nothing, and the held-back turn ends like a decline (the question comes back),
    /// with the existing hard refusal shown. It must not stay live.
    @Test func aHardVerdictWhileAwaitingConfirmSendsNothingAndReturnsTheQuestion() async throws {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let (store, session, never) = sessionWithTLSPending()
        defer { never.cancel() }
        let previous = ConfidentialSession.verifierSettleTimeout
        ConfidentialSession.verifierSettleTimeout = .milliseconds(200)
        defer { ConfidentialSession.verifierSettleTimeout = previous }
        let transport = Counting()
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: transport, priorMessages: prior, events: events)
        }
        let vm = ChatViewModel()
        vm.prompt = "hello"
        var thread: ChatThread?
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.hardwareConfirmRequested, "precondition: the still-checking ask")
        session.rememberConfirmation(pending: true, answering: .verification)

        never.cancel()
        session.tlsTask = nil
        session.tlsAttestation = .failed("fingerprint mismatch")
        #expect(session.sendPolicy == .block, "precondition: a hard verdict")

        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm, acceptedDegrade: true)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.generatingThreadID == nil)
        #expect(transport.calls.value == 0, "sent to a host whose check failed")
        #expect(llm.lastError != nil, "the hard refusal was not shown")
        let t = try #require(thread)
        #expect(vm.heldBackTurn(in: t) == nil, "the held-back turn stayed live")
        #expect(vm.prompt == "hello", "the question did not come back to the composer")
        #expect(t.sortedMessages.isEmpty, "the unsent question stayed in the chat")
    }

    /// formal F3_AcceptedAskNeverDropped: Re-verify on a held RETRY used to drop it — later "send anyway" (after a model
    /// switch) found no held turn, no pending retry and an empty composer, and sent nothing. Re-verify now keeps the
    /// retry pending and leaves the reply the user had untouched until the resent retry's request goes out.
    @Test func reverifyOnAHeldRetryKeepsItPending() async throws {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let (store, session, never) = sessionWithTLSPending()
        defer { never.cancel() }
        let previous = ConfidentialSession.verifierSettleTimeout
        ConfidentialSession.verifierSettleTimeout = .milliseconds(200)
        defer { ConfidentialSession.verifierSettleTimeout = previous }
        var thread: ChatThread? = ChatThread()
        context.insert(thread!)
        let question = Message(role: .user, content: "why", thread: thread)
        context.insert(question)
        context.insert(Message(role: .assistant, content: "old answer", thread: thread))
        context.insert(Message(role: .user, content: "and later?", thread: thread))
        try context.save()
        let transport = Counting()
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: transport, priorMessages: prior, events: events)
        }
        let vm = ChatViewModel()
        vm.retry(from: question, currentThread: &thread, modelContext: context, settings: AppSettings(),
                 providers: store, session: session, llm: llm, effort: .thinkHarder)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.hardwareConfirmRequested, "precondition: the still-checking ask")

        let kept = try #require(vm.reverifyHeldTurn(currentThread: thread, modelContext: context),
                                "Re-verify dropped the held retry")
        #expect(kept.question.id == question.id, "kept the wrong question")
        #expect(kept.effort == .thinkHarder)
        #expect(vm.heldBackTurn(in: try #require(thread)) == nil, "the chat is left with a live turn")
        #expect(thread?.sortedMessages.map(\.content) == ["why", "old answer", "and later?"], "a reply was touched")
        #expect(transport.calls.value == 0)

        // Later, "send anyway": ChatView resends the pending retry.
        session.rememberConfirmation(pending: true, answering: .verification)
        vm.retry(from: kept.question, currentThread: &thread, modelContext: context, settings: AppSettings(),
                 providers: store, session: session, llm: llm, acceptedDegrade: true, effort: kept.effort)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.generatingThreadID == nil)
        #expect(transport.calls.value == 1, "send anyway sent nothing")
    }

    /// formal S20 note: Re-verify keeps a held retry pending; a fresh send during the wait retires that re-verify
    /// (G6), and must retire the pending retry too, or a later "send anyway" with no held turn resends the old question.
    @Test func aFreshSendRetiresAPendingRetry() async throws {
        var c = try await heldFreshSend { vm, context, thread in
            let t = ChatThread()
            context.insert(t)
            let q = Message(role: .user, content: "an older question", thread: t)
            context.insert(q)
            context.insert(Message(role: .assistant, content: "its reply", thread: t))
            try context.save()
            thread = t
            vm.holdRetryForAlert(q, effort: .chatDefault)   // Re-verify kept it pending
        }
        defer { c.never.cancel(); ConfidentialSession.verifierSettleTimeout = .seconds(15) }
        #expect(c.vm.pendingRetry == nil, "a fresh send left an older retry pending")
        try await sendAnyway(&c)
        #expect(c.transport.lastUser.value?.text.hasPrefix("hello") == true,
                "sent \(c.transport.lastUser.value?.text ?? "nothing") instead of the fresh question")
        #expect(c.thread?.sortedMessages.map(\.content).contains("its reply") == true, "the older reply was replaced")
    }

    /// The fresh-send path is unchanged: Re-verify returns the question to the composer and keeps nothing pending.
    @Test func reverifyOnAHeldSendReturnsTheQuestion() async throws {
        let run = try await gatedThenSendAnyway(prompt: "hello", answer: .reverify)
        #expect(run.vm.prompt == "hello", "the question did not come back to the composer")
        #expect(run.thread?.sortedMessages.isEmpty == true)
    }

    /// F4 strict (formal F4_ConfirmScopedStrict): Intel's couldn't-check (DCAP unchecked) is already known while NRAS/TLS
    /// still run. The ask is the couldn't-check one, so the answer is recorded for that record's reason — one answer
    /// covers the record — and the send goes out.
    @Test func aKnownCouldntCheckWhileChecksRunAsksItsOwnQuestion() async throws {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let (store, session, never) = sessionWithTLSPending()
        defer { never.cancel() }
        var dcap = session.dcapVerification ?? RecordDCAPVerification()
        dcap.model = .unchecked("collateral: pcs unreachable")
        session.dcapVerification = dcap
        #expect(session.sendPolicy == .confirm && session.verdictsPending, "precondition: couldn't-check known, checks running")
        #expect(session.confirmationKey(pending: true) == session.confirmationKey(pending: false),
                "the ask answers 'still checking', not the known couldn't-check")
        let previous = ConfidentialSession.verifierSettleTimeout
        ConfidentialSession.verifierSettleTimeout = .milliseconds(200)
        defer { ConfidentialSession.verifierSettleTimeout = previous }
        let transport = Counting()
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: transport, priorMessages: prior, events: events)
        }
        let vm = ChatViewModel()
        vm.prompt = "hello"
        var thread: ChatThread?
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.hardwareConfirmRequested, "precondition: the gate asked")
        session.rememberConfirmation(pending: vm.hardwareConfirmRequested, answering: .verification)   // ChatView.generateBypassing
        #expect(session.sendPolicyAfterConfirmations == .allow, "the answer did not cover the record's couldn't-check")
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm, acceptedDegrade: true)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.generatingThreadID == nil)
        #expect(transport.calls.value == 1, "the answered send did not go out")
    }

    /// The user agreed to "send anyway" for a SEALED send; the near.ai tier then resolves to third-party and the
    /// attestation capability goes away. The re-gate must not send it plain: nothing goes out, the held turn ends like a
    /// decline and the question comes back; the next send meets the normal composer flow.
    @Test func aConfirmForASealedSendNeverGoesPlain() async throws {
        let model = "zai-org/S1-SEALED-CONFIRM-PROBE"
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let (store, session, never) = sessionWithTLSPending(model: model)
        defer { never.cancel() }
        let previous = ConfidentialSession.verifierSettleTimeout
        ConfidentialSession.verifierSettleTimeout = .milliseconds(200)
        defer { ConfidentialSession.verifierSettleTimeout = previous }
        let transport = Counting()
        let sealedAtSend = LockedBox<[Bool]>([])
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, tee, events in
            sealedAtSend.value = sealedAtSend.value + [tee?.e2eePeer != nil]
            return TransportLanguageModel(transport: transport, priorMessages: prior, events: events)
        }
        let vm = ChatViewModel()
        vm.prompt = "hello"
        var thread: ChatThread?
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.hardwareConfirmRequested, "precondition: the still-checking ask for a sealed send")
        session.rememberConfirmation(pending: true, answering: .verification)

        NearAIModelCatalog.recordTiers([model: .teeThirdParty])
        #expect(!(store.activeProvider?.capabilities.contains(.attestation) ?? true), "precondition: the tier moved")

        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm, acceptedDegrade: true)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.generatingThreadID == nil)
        #expect(transport.calls.value == 0, "the confirmed sealed send went out (sealed: \(sealedAtSend.value))")
        let t = try #require(thread)
        #expect(vm.heldBackTurn(in: t) == nil, "the held turn stayed live")
        #expect(vm.prompt == "hello", "the question did not come back to the composer")
    }

    /// Window A: the turn starts attestable (unknown tier, sealed), and the tier resolves to third-party while
    /// prepareTurn waits, before the gate and with no ask. It must not leave unsealed: nothing is sent, the question
    /// comes back.
    @Test func aTurnStartedAttestableNeverGoesPlain() async throws {
        let model = "zai-org/S1-WINDOW-A-PROBE"
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let (store, session, never) = sessionWithTLSPending(model: model)
        defer { never.cancel() }
        let previous = ConfidentialSession.verifierSettleTimeout
        ConfidentialSession.verifierSettleTimeout = .milliseconds(600)
        defer { ConfidentialSession.verifierSettleTimeout = previous }
        let transport = Counting()
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: transport, priorMessages: prior, events: events)
        }
        #expect(store.activeProvider?.capabilities.contains(.attestation) == true, "precondition: starts attestable")
        let vm = ChatViewModel()
        vm.prompt = "hello"
        var thread: ChatThread?
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            NearAIModelCatalog.recordTiers([model: .teeThirdParty])   // the tier list lands mid-prepare
        }
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm)
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(vm.generatingThreadID == nil)
        #expect(!(store.activeProvider?.capabilities.contains(.attestation) ?? true), "precondition: the tier moved")
        #expect(transport.calls.value == 0, "a turn that started attestable went out unsealed")
        #expect(vm.prompt == "hello", "the question did not come back to the composer")
        #expect(thread?.sortedMessages.isEmpty == true)
    }

    @MainActor struct Composer {
        let vm: ChatViewModel; let transport: Counting; let llm: ChatGeneration; let store: ProviderStore
        let session: ConfidentialSession; let container: ModelContainer; let never: Task<Void, Never>
        var thread: ChatThread?
        func settle() async throws {
            for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
            try #require(vm.generatingThreadID == nil)
        }
    }

    /// A fresh "hello" held by the still-checking ask; `before` runs first (e.g. a stale pending retry).
    private func heldFreshSend(_ before: (ChatViewModel, ModelContext, inout ChatThread?) throws -> Void = { _, _, _ in })
        async throws -> Composer {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let (store, session, never) = sessionWithTLSPending()
        ConfidentialSession.verifierSettleTimeout = .milliseconds(200)
        let transport = Counting()
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: transport, priorMessages: prior, events: events)
        }
        let vm = ChatViewModel()
        var thread: ChatThread?
        try before(vm, container.mainContext, &thread)
        vm.prompt = "hello"
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: session, llm: llm)
        var c = Composer(vm: vm, transport: transport, llm: llm, store: store, session: session, container: container,
                         never: never, thread: thread)
        try await c.settle()
        try #require(vm.hardwareConfirmRequested, "precondition: the still-checking ask")
        c.thread = thread
        return c
    }

    private func sendAnyway(_ c: inout Composer) async throws {
        c.vm.sendAnyway(answering: .verification, currentThread: &c.thread, modelContext: c.container.mainContext, settings: AppSettings(),
                        providers: c.store, session: c.session, llm: c.llm)
        try await c.settle()
    }

    /// (a) Re-verify returns the fresh question to the composer; the alert comes back; "send anyway" sends the
    /// composer's question exactly once and clears the composer.
    @Test func reverifyThenSendAnywaySendsTheComposer() async throws {
        var c = try await heldFreshSend()
        defer { c.never.cancel(); ConfidentialSession.verifierSettleTimeout = .seconds(15) }
        c.vm.reverify(currentThread: c.thread, modelContext: c.container.mainContext)
        #expect(c.vm.prompt == "hello" && c.vm.pendingRetry == nil)
        try await sendAnyway(&c)
        #expect(c.transport.calls.value == 1)
        #expect(c.transport.lastUser.value?.text.hasPrefix("hello") == true)
        #expect(c.vm.prompt.isEmpty, "the composer did not clear")
        #expect(c.thread?.sortedMessages.filter { $0.role == .user }.map(\.content) == ["hello"])
    }

    /// (b) An older retry left pending (an alert the system dismissed) never goes out in place of the held send,
    /// with or without Re-verify.
    @Test(arguments: [true, false])
    func aStalePendingRetryNeverLeaks(reverifyFirst: Bool) async throws {
        var old: Message?
        var c = try await heldFreshSend { vm, context, thread in
            let t = ChatThread()
            context.insert(t)
            let q = Message(role: .user, content: "an older question", thread: t)
            context.insert(q)
            context.insert(Message(role: .assistant, content: "its reply", thread: t))
            try context.save()
            thread = t
            old = q
            vm.holdRetryForAlert(q, effort: .chatDefault)   // asked, then dismissed by the system
        }
        defer { c.never.cancel(); ConfidentialSession.verifierSettleTimeout = .seconds(15) }
        _ = try #require(old)
        if reverifyFirst {
            c.vm.reverify(currentThread: c.thread, modelContext: c.container.mainContext)
            #expect(c.vm.pendingRetry == nil, "the stale retry survived the fresh send's return")
        }
        try await sendAnyway(&c)
        #expect(c.transport.calls.value == 1)
        #expect(c.transport.lastUser.value?.text.hasPrefix("hello") == true,
                "sent \(c.transport.lastUser.value?.text ?? "nothing") instead of the held question")
        #expect(c.thread?.sortedMessages.map(\.content).contains("its reply") == true, "the older reply was replaced")
    }

    /// (c) Edited after it came back: what goes is what is in the composer now, text and images.
    @Test func anEditedReturnedQuestionSendsWhatIsOnScreen() async throws {
        var c = try await heldFreshSend()
        defer { c.never.cancel(); ConfidentialSession.verifierSettleTimeout = .seconds(15) }
        c.vm.reverify(currentThread: c.thread, modelContext: c.container.mainContext)
        c.vm.prompt = "hello, edited"
        c.vm.pendingImages = [ComposerImageTests.kept(7)]
        try await sendAnyway(&c)
        #expect(c.transport.calls.value == 1)
        #expect(c.transport.lastUser.value?.text.hasPrefix("hello, edited") == true)
        let sent = try #require(c.thread?.sortedMessages.last { $0.role == .user })
        #expect(sent.content == "hello, edited")
        #expect(ImageAttachment.images(of: sent).map(\.data) == [ComposerImageTests.kept(7).data])
        #expect(c.vm.prompt.isEmpty && c.vm.pendingImages.isEmpty)
    }

    /// Re-verify acts only for the alert it was tapped on (android 917d1cfc). The user sends again during the wait and
    /// the gate asks anew; a clean verdict must not then run the earlier send as well.
    @Test func aGatedSendDuringReverifyRetiresIt() async throws {
        var c = try await heldFreshSend()
        defer { c.never.cancel(); ConfidentialSession.verifierSettleTimeout = .seconds(15) }
        c.vm.reverify(currentThread: c.thread, modelContext: c.container.mainContext)
        let captured = c.vm.reverifyCapture(in: c.thread)
        #expect(c.vm.reverifyStillCurrent(captured, in: c.thread), "nothing newer yet")
        c.vm.generate(currentThread: &c.thread, modelContext: c.container.mainContext, settings: AppSettings(),
                      providers: c.store, session: c.session, llm: c.llm)
        try await c.settle()
        #expect(c.vm.hardwareConfirmRequested, "precondition: the newer send is asked about")
        #expect(!c.vm.reverifyStillCurrent(captured, in: c.thread), "the re-verify would send a second time")
        #expect(c.transport.calls.value == 0)
    }

    /// ... nor in another chat whose newest turn happens to carry the same number, nor in a new, empty chat.
    @Test func aReverifyNeverActsInAnotherChat() async throws {
        var c = try await heldFreshSend()
        defer { c.never.cancel(); ConfidentialSession.verifierSettleTimeout = .seconds(15) }
        c.vm.reverify(currentThread: c.thread, modelContext: c.container.mainContext)
        let captured = c.vm.reverifyCapture(in: c.thread)
        let first = c.thread
        #expect(!c.vm.reverifyStillCurrent(captured, in: nil), "a new chat ran the other chat's re-verify")
        var other: ChatThread?
        c.vm.prompt = "elsewhere"
        c.vm.generate(currentThread: &other, modelContext: c.container.mainContext, settings: AppSettings(),
                      providers: c.store, session: c.session, llm: c.llm)
        try await c.settle()
        #expect(other != nil && other?.id != first?.id)
        #expect(!c.vm.reverifyStillCurrent(captured, in: other), "another chat ran this chat's re-verify")
    }

    /// reply-machine.json composerReturn: every vector, letters standing for distinct image bytes.
    @Test func composerReturnFollowsTheKit() throws {
        guard let kit = try ReplyMachineVectorsTests.kit() else { return }
        let rule = try #require(kit["composerReturn"] as? [String: Any])
        func images(_ any: Any?) -> [ImageIntake.Image] {
            (any as? [String] ?? []).map { ComposerImageTests.kept(Int($0.unicodeScalars.first!.value)) }
        }
        for vector in rule["vectors"] as? [[String: Any]] ?? [] {
            let name = vector["name"] as? String ?? "?"
            let q = try #require(vector["question"] as? [String: Any])
            let d = try #require(vector["draft"] as? [String: Any])
            let want = try #require(vector["expect"] as? [String: Any])
            let got = ChatViewModel.composerAfterReturn(
                question: (q["text"] as? String ?? "", images(q["images"])),
                draft: (d["text"] as? String ?? "", images(d["images"])),
                limit: vector["limit"] as? Int ?? 0)
            #expect(got.text == want["text"] as? String, "\(name)")
            #expect(got.images.map(\.data) == images(want["images"]).map(\.data), "\(name): images")
            #expect(got.overLimit == (want["overLimit"] as? Bool ?? false), "\(name): overLimit")
            #expect((want["sendDisabled"] as? Bool ?? false) == got.overLimit, "\(name): over the limit disables send")
        }
    }
}
