//
//  ChatViewModel.swift
//  teemoon

import Foundation
import Observation
import UniformTypeIdentifiers
import SwiftData
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "chat")

@Observable
@MainActor
final class ChatViewModel {
    var prompt = ""
    /// Counts questions the gate handed back to the composer, so the field can show each from its start.
    private(set) var questionsReturned = 0
    var generatingThreadID: UUID?
    /// The level a running Think Harder's request carries, for developer mode's chip; nil for any other turn.
    var thinkHarderLevel: String?

    /// Soft tap. Wired by the view — this type must not import Haptics.
    @ObservationIgnored
    var onPlayHaptic: (() -> Void)?

    var isPromptEmpty: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Images to send (IMAGES.md §4)

    static let cloudImagesPerSend = 10
    /// The on-device model keeps 4 until the phone probe sets its number per phone (IMAGES.md §4b).
    /// A phone model takes what was measured for it (PhoneImageMemory.maxImages); a server model the cloud cap.
    static func imagesPerSend(localModelID: String?) -> Int {
        localModelID.map(PhoneImageMemory.maxImages(modelID:)) ?? cloudImagesPerSend
    }
    static func tooManyImagesMessage(limit: Int) -> String { "up to \(limit) images per message" }
    static let unreadableImageMessage = "this image couldn't be read"

    /// Picked or taken, already re-encoded by ImageIntake; stored with the message when it is sent.
    var pendingImages: [ImageIntake.Image] = []
    /// A one-line note for the composer after an add (too many, or one couldn't be read).
    var imageNote: String?
    /// Verdicts were still pending at the settle timeout with the seal in hand: the chat asks.
    var hardwareConfirmRequested = false
    /// What was still pending when the settle timeout asked; read only while `hardwareConfirmRequested`.
    var pendingAskKind: ConfidentialSession.PendingKind = .hardware
    /// The question that ask held back. "send anyway" answers it; never the composer's newer draft.
    private var gatedQuestion: Message?
    private var gatedEffort: ReasoningEffort = .chatDefault
    /// The question the current turn asks: the one just sent, or the one a retry asks again.
    private var turnQuestion: Message?
    /// Whether the current turn started while the provider was attestable (attested or unknown tier).
    private var turnStartedAttestable = false
    private var gatedSupersession = ReplySupersession()
    /// Every reply's lifecycle; the only writer of Message.statusRaw.
    let replies = ReplyTurns()
    /// The latest turn this view model started. An older turn's task ending must not end the newer one.
    private var latestTurn = 0

    /// The active provider's images-per-message; the host keeps it current.
    var imageLimit = ChatViewModel.cloudImagesPerSend
    /// More images than the limit (a returned question, or a switch to a lower limit): every one is kept, send is
    /// refused and the composer shows `overLimitNote` until enough are removed.
    var imagesOverLimit: Bool { pendingImages.count > imageLimit }
    var overLimitNote: String? { imagesOverLimit ? Self.tooManyImagesMessage(limit: imageLimit) : nil }

    /// Nothing to send: no text and no image.
    var hasNothingToSend: Bool { isPromptEmpty && pendingImages.isEmpty }

    /// Photos picked, pasted or taken whose decode has not finished; the composer shows a placeholder for each.
    private(set) var imagesLoading = 0
    /// A share's photos are in the strip on the first frame; do not animate them in (Android's 81 dp climb).
    private(set) var animatesImageArrival = true
    var canSend: Bool {
        ComposerImages.canSend(prompt: prompt, picked: pendingImages.count, pending: imagesLoading, limit: imageLimit)
    }

    /// A load's results, handed back on the main queue.
    typealias ImageLoad = (@escaping ([Result<ImageIntake.Image, ImageIntake.Failure>]) -> Void) -> Void

    /// Counts `count` photos as loading before `load` starts; send waits until it calls back.
    func loadImages(count: Int, limit: Int, _ load: ImageLoad) {
        let tiles = ComposerImages.loadingTiles(requested: count, limit: limit, ready: pendingImages.count,
                                                loading: imagesLoading)
        imagesLoading += tiles
        load { results in
            MainActor.assumeIsolated { self.finishLoad(count: tiles, results, limit: limit) }
        }
    }

    private func finishLoad(count: Int, _ results: [Result<ImageIntake.Image, ImageIntake.Failure>], limit: Int) {
        imagesLoading = max(0, imagesLoading - count)
        addImages(results, limit: limit)
    }

    /// Adds picker or camera results, at most `limit` in all.
    func addImages(_ results: [Result<ImageIntake.Image, ImageIntake.Failure>], limit: Int) {
        var note: String?
        for result in results {
            switch result {
            case .success(let image):
                if pendingImages.count < limit { pendingImages.append(image) }
                else { note = Self.tooManyImagesMessage(limit: limit) }
            case .failure:
                note = note ?? Self.unreadableImageMessage
            }
        }
        imageNote = note
    }

    /// A paste attaches like a pick, on any model: the send is where a model that can't see images stops it (§4d).
    func pasteImages(_ results: [Result<ImageIntake.Image, ImageIntake.Failure>], limit: Int) {
        addImages(results, limit: limit)
    }

    #if os(iOS)
    /// A paste whose text came from an item offering an image (§4c): the text goes back out and the item's image attaches.
    /// Only a focused composer can have been pasted into; do not read the pasteboard for any other change.
    @discardableResult
    func takeImageItemPaste(before old: String, focused: Bool, from pasteboard: () -> PastedImage.Items,
                            limit: Int) -> Task<Void, Never>? {
        guard focused, PastedImage.mayHavePutInAURL(before: old, after: prompt) else { return nil }
        let board = pasteboard()
        guard PastedImage.mayHoldImageItemText(board.types) else { return nil }
        let items = board.types.indices.map { PastedImage.ItemText(isImage: board.isImage($0), texts: board.texts($0)) }
        guard let kept = PastedImage.keptText(before: old, after: prompt, items: items) else { return nil }
        prompt = kept
        // In item order: each image item, and each text item that is a data: URL (S41).
        let reads: [PastedImage.Read] = board.types.indices.compactMap { item in
            if board.isImage(item) {
                guard let id = PastedImage.choice(offered: board.types[item]).readIdentifier else { return .refused }
                return .bytes(board.data(item, id), id)
            }
            return items[item].texts.lazy.compactMap { PastedImage.soleDataURL(before: "", after: $0) }.first.map { .dataURL($0) }
        }
        imagesLoading += reads.count
        return Task {
            let results = await Task.detached(priority: .userInitiated) { reads.map(\.result) }.value
            finishLoad(count: reads.count, results, limit: limit)
        }
    }

    /// A paste of a lone `data:` URL becomes an image, never text (§4c). nil when `prompt` changed some other way.
    @discardableResult
    func takeDataURLPaste(before old: String, limit: Int) -> Task<Void, Never>? {
        guard let url = PastedImage.soleDataURL(before: old, after: prompt) else { return nil }
        prompt = old
        imagesLoading += 1
        return Task {
            let result = await Task.detached(priority: .userInitiated) { ImageIntake.fromDataURL(url) }.value
            finishLoad(count: 1, [result], limit: limit)
        }
    }

    /// The newest shared entry replaces this composer's draft (docs/SHARE_IN.md step 3); nil when the inbox is empty.
    /// Photos go through paste's intake. Never sends: the user presses send.
    @discardableResult
    func takeShare(from inbox: ShareInbox?) -> Task<Void, Never>? {
        guard let entry = inbox?.take() else { return nil }
        prompt = entry.text
        pendingImages = []
        imageNote = nil
        let limit = imageLimit
        let tiles = ComposerImages.loadingTiles(requested: entry.imageFiles.count, limit: limit, ready: 0,
                                                loading: imagesLoading)
        animatesImageArrival = false
        imagesLoading += tiles
        return Task {
            let results = await Task.detached(priority: .userInitiated) {
                entry.readImages().map { PastedImage.imported($0, as: .image).result }
            }.value
            finishLoad(count: tiles, results, limit: limit)
            let failed = results.filter { if case .failure = $0 { true } else { false } }.count
            if entry.unreadable > 0, imageNote == nil || imageNote == Self.unreadableImageMessage {
                imageNote = ShareJump.Line.unreadable(entry.unreadable + failed)
            }
            animatesImageArrival = true
        }
    }
    #endif

    func removePendingImage(at index: Int) {
        guard pendingImages.indices.contains(index) else { return }
        pendingImages.remove(at: index)
        imageNote = nil
    }

    /// Same send policy the ladder and title block render — delegated to the
    /// session's canonical `sendPolicy` so there is exactly ONE definition
    /// (the Siri/Shortcuts intent consults the same one). The view shows the
    /// alert; the send path refuses to generate unless the policy is `.allow`.
    func sendPolicy(session: ConfidentialSession) -> TrustSendPolicy {
        session.sendPolicy
    }

    /// Why send cannot proceed. Trust allow/confirm/block is `TrustSendPolicy`;
    /// this adds no-provider and still-downloading. The view presents; it does
    /// not decide. See SendPrepTests.
    enum SendPrep: Equatable {
        case blockedEmptyPrompt
        case blockedImagesLoading
        /// More images than the current limit; the composer already says so.
        case blockedTooManyImages
        /// Images attached for a model whose catalogue doesn't say it takes them.
        case blockedImagesUnsupported
        case blockedNoProvider
        case blockedNoKey
        case blockedDownloading
        case confirmE2EE
        case blockedE2EE
        case ready
    }

    func prepareSend(
        hasProvider: Bool,
        hasKey: Bool,
        isDownloading: Bool,
        trust: TrustSendPolicy,
        requirePrompt: Bool = true,
        seesImages: Bool = true
    ) -> SendPrep {
        if requirePrompt, imagesLoading > 0 { return .blockedImagesLoading }
        if requirePrompt, hasNothingToSend { return .blockedEmptyPrompt }
        if requirePrompt, imagesOverLimit { return .blockedTooManyImages }
        if !hasProvider { return .blockedNoProvider }
        if requirePrompt, !pendingImages.isEmpty, !seesImages { return .blockedImagesUnsupported }
        if !hasKey { return .blockedNoKey }
        if isDownloading { return .blockedDownloading }
        switch trust {
        case .allow: return .ready
        case .confirm: return .confirmE2EE
        case .block: return .blockedE2EE
        }
    }

    /// Weights still arriving on the phone or a home pull. Copy is data.
    /// See SendPrepTests.
    struct Arrival: Equatable {
        enum Kind: Equatable { case phone, home, homeManifest }
        var name: String
        var fraction: Double?
        var kind: Kind

        var alertMessage: String {
            if let fraction {
                return "\(name) is \(Int(fraction * 100))% downloaded. it'll answer as soon as the rest lands — you can leave this message here and send it then."
            }
            if kind == .homeManifest {
                return "\(name) is still downloading onto that machine. it'll answer as soon as it lands — you can leave this message here and send it then."
            }
            return "\(name) isn't downloaded. pick it again in where to restart the download, or choose something else to send now."
        }
    }

    /// Whether this turn must be refused because the provider promised
    /// attestation + E2EE but no peer could be established — the transport
    /// would run with a nil codec and send PLAINTEXT under that promise
    /// Pure so the regression tests can pin the decision.
    /// Non-attested providers (peer legitimately absent) are unaffected.
    /// The gate, re-read AFTER `prepareTurn` settled the refresh it may have
    /// started. The composer's check ran on the state before that refresh; a
    /// verdict that changed underneath it must not ride the earlier answer.
    /// `acceptedDegrade` is the user having chosen "send anyway" on the soft
    /// alert, which a `.confirm` after settling may honour; a `.block` never
    /// is. Returns the refusal to show, or nil to proceed.
    static func postPrepareRefusal(policy: TrustSendPolicy, acceptedDegrade: Bool,
                                   verdictsPending: Bool) -> String? {
        switch policy {
        case .block:
            return "verification failed while preparing this message, so nothing was sent. re-verify from the lock icon."
        case .confirm where !acceptedDegrade:
            return "verification changed while preparing this message, so nothing was sent. send again to review it."
        case .confirm, .allow:
            if verdictsPending {
                return "verification is still running, so nothing was sent. try again in a moment."
            }
            return nil
        }
    }

    enum PostPrepare: Equatable { case proceed, confirmPending, refuse(String) }

    /// The chat's gate after `prepareTurn`: verdicts still pending at the settle timeout ask instead of
    /// refusing, but only when the message would go out sealed (near-send-gate-rule). Shortcuts keeps
    /// `postPrepareRefusal`: it has no one to ask.
    static func postPrepare(policy: TrustSendPolicy, acceptedDegrade: Bool, verdictsPending: Bool,
                            sealed: Bool) -> PostPrepare {
        guard let refusal = postPrepareRefusal(policy: policy, acceptedDegrade: acceptedDegrade,
                                               verdictsPending: verdictsPending) else { return .proceed }
        if verdictsPending, policy != .block, sealed { return acceptedDegrade ? .proceed : .confirmPending }
        return .refuse(refusal)
    }

    static func mustRefuseUnsealedSend(provider: Provider, teeContext: TEEContext?) -> Bool {
        provider.capabilities.contains(.attestation) && teeContext?.e2eePeer == nil
    }

    /// Whether this turn must be refused because the provider needs an API
    /// key and none is stored. Consulted BEFORE `prepareTurn`, so a missing
    /// key is reported as a missing key — not as the E2EE failure an
    /// unauthenticated attestation fetch would produce. Keyless providers
    /// (self-hosted, on-device) are unaffected. Pure; see SendPrepTests.
    static func mustRefuseMissingKey(provider: Provider, credential: String) -> Bool {
        provider.requiresAPIKey && !provider.isLocal
            && credential.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The card for a refused keyless send. Names the key and where it goes;
    /// no HTTP status, because nothing went over the wire.
    static func missingKeyError(for provider: Provider) -> LLMError {
        LLMError(
            source: .provider(name: provider.name),
            userMessage: "\(provider.name) needs an api key and none is saved, so nothing was sent. paste one in settings → places & keys → cloud keys, then retry.",
            httpStatus: nil, url: provider.openAIBaseURL, requestHeaders: nil,
            requestBodyJSON: nil, messageHistory: nil, responseBody: nil,
            underlyingError: nil
        )
    }

    func generate(
        currentThread: inout Thread?,
        modelContext: ModelContext,
        settings: AppSettings,
        providers: ProviderStore,
        session: ConfidentialSession,
        llm: ChatGeneration,
        acceptedDegrade: Bool = false
    ) {
        // The held-back turn is the machine's, not the alert's: dismissing the alert (Re-verify) must not wedge it (F3).
        if acceptedDegrade, let thread = currentThread, let gatedG = heldBackTurn(in: thread) {
            // gatedQuestion stays until the turn resolves: a gate that now blocks returns it to the composer.
            // Send anyway confirms the held-back turn: its question and images are saved, the composer keeps whatever
            // was typed since, and a think harder keeps the reply it supersedes.
            llm.superseding = gatedSupersession
            let effort = gatedEffort
            generatingThreadID = thread.id
            Self.startTurnClock(llm, providers: providers, reask: false)
            onPlayHaptic?()
            latestTurn += 1
            let turn = latestTurn
            Task {
                await generateResponse(in: thread, settings: settings, providers: providers, session: session,
                                       llm: llm, modelContext: modelContext, effort: effort,
                                       generation: gatedG, turn: turn)
                if latestTurn == turn { generatingThreadID = nil }
            }
            return
        }
        guard !hasNothingToSend, imagesLoading == 0 else { return }
        // One live reply per chat: a send now is refused and the draft stays (reply-machine.json).
        if let thread = currentThread, replies.state(in: thread.id).isLive { return }
        if currentThread == nil {
            let newThread = Thread()
            currentThread = newThread
            modelContext.insert(newThread)
            do { try modelContext.save() } catch { logger.error("Failed to save new thread: \(error)") }
        }
        guard let thread = currentThread else { return }
        // A fresh send retires any older ask's pending retry; a later "send anyway" must not resend it.
        pendingRetry = nil
        generatingThreadID = thread.id
        // The card's phases count from the tap, on a plain send as on a retry.
        Self.startTurnClock(llm, providers: providers, reask: false)
        let message = prompt
        let images = pendingImages
        prompt = ""
        pendingImages = []
        imageNote = nil
        onPlayHaptic?()
        let sent = Message(role: .user, content: message, thread: thread, isE2EE: session.canSeal)
        for (index, image) in images.enumerated() {
            modelContext.insert(ImageAttachment(id: UUID(), messageID: sent.id, index: index, mimeType: image.mimeType,
                                                width: image.width, height: image.height,
                                                data: image.data, thumbnail: image.thumbnail))
        }
        sendMessage(sent, modelContext: modelContext)
        turnQuestion = sent
        turnStartedAttestable = providers.activeProvider?.capabilities.contains(.attestation) == true
        let generation = replies.newGeneration()
        replies.handle(.send(generation, place: Self.place(providers), images: images.count), in: thread, context: modelContext)
        latestTurn += 1
        let turn = latestTurn
        Task {
            await generateResponse(in: thread, settings: settings, providers: providers, session: session,
                                   llm: llm, modelContext: modelContext,
                                   generation: generation, turn: turn)
            if latestTurn == turn { generatingThreadID = nil }
        }
    }

    /// reply-machine.json composerReturn: question first, a blank line, then the draft; every image kept, the
    /// draft's only where its bytes are new. `overLimit` is reported, never acted on here.
    static func composerAfterReturn(question: (text: String, images: [ImageIntake.Image]),
                                    draft: (text: String, images: [ImageIntake.Image]),
                                    limit: Int) -> (text: String, images: [ImageIntake.Image], overLimit: Bool) {
        let draftIsEmpty = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let text = draftIsEmpty ? question.text : question.text + "\n\n" + draft.text
        var images = question.images
        for image in draft.images where !images.contains(where: { $0.data == image.data }) { images.append(image) }
        return (text, images, images.count > limit)
    }

    /// The still-checking ask was declined (wait, don't send, or dismissed): effect `returnQuestionToComposer`.
    /// A fresh send's unsent question leaves the chat with its images and lands back in the composer.
    func returnGatedQuestion(currentThread: Thread?, modelContext: ModelContext) {
        hardwareConfirmRequested = false
        guard let thread = currentThread, let gatedG = heldBackTurn(in: thread) else { return }
        let effects = replies.handle(.decline(gatedG), in: thread, context: modelContext)
        if effects.contains(.returnQuestionToComposer(gatedG)) { returnToComposer(thread: thread, context: modelContext) }
    }

    struct PendingRetry { let question: Message; let effort: ReasoningEffort }

    /// The retry an alert holds until the user answers it: a pre-send ask, or a held retry Re-verify kept.
    private(set) var pendingRetry: PendingRetry?

    func holdRetryForAlert(_ question: Message, effort: ReasoningEffort) {
        pendingRetry = PendingRetry(question: question, effort: effort)
    }

    func clearPendingRetry() { pendingRetry = nil }

    /// Re-verify: decline the held-back turn. A held retry becomes the pending retry; a fresh send's question goes back
    /// to the composer and clears any older pending retry, which must never be sent in its place.
    func reverify(currentThread: Thread?, modelContext: ModelContext) {
        let heldFresh = currentThread.map { heldBackTurn(in: $0) != nil } ?? false
        if let kept = reverifyHeldTurn(currentThread: currentThread, modelContext: modelContext) {
            pendingRetry = kept
        } else if heldFresh {
            pendingRetry = nil
        }
    }

    /// The ask the send gate shows now. ChatView draws it on every redraw and its buttons carry this kind, so the kind
    /// a tap answers is the ask on screen at the tap.
    func e2eeAsk(session: ConfidentialSession) -> E2EEAsk {
        session.e2eeAskTierDowngrade ?? E2EEAsk.make(
            hardFailure: session.degradeIsHardFailure,
            pendingAsk: hardwareConfirmRequested ? pendingAskKind : nil,
            provenanceUnchecked: session.provenanceUncheckedAsks, softButSealed: session.softButSealed,
            provenanceBlocked: session.provenanceBlockedButE2EEIntact, cause: session.e2eeDegradedReason,
            deadlinePassed: session.deadlinePassed, enclaveListFailed: session.enclaveListFailedAsks)
    }

    /// "send anyway": the held-back turn first, then a pending retry, else the composer as it is now.
    /// `answering`: the kind of the ask the user tapped on, not the one the session would show now.
    func sendAnyway(answering ask: E2EEAsk.Kind, currentThread: inout Thread?, modelContext: ModelContext,
                    settings: AppSettings, providers: ProviderStore, session: ConfidentialSession, llm: ChatGeneration) {
        session.rememberConfirmation(pending: hardwareConfirmRequested || session.sendPending, answering: ask)
        if let thread = currentThread, heldBackTurn(in: thread) != nil {
            generate(currentThread: &currentThread, modelContext: modelContext, settings: settings, providers: providers,
                     session: session, llm: llm, acceptedDegrade: true)
            return
        }
        if let retry = pendingRetry {
            pendingRetry = nil
            self.retry(from: retry.question, currentThread: &currentThread, modelContext: modelContext, settings: settings,
                       providers: providers, session: session, llm: llm, acceptedDegrade: true, effort: retry.effort)
            return
        }
        generate(currentThread: &currentThread, modelContext: modelContext, settings: settings, providers: providers,
                 session: session, llm: llm, acceptedDegrade: true)
    }

    /// Re-verify answers the still-checking ask by declining the held-back turn. A fresh send's question returns to
    /// the composer; a retry, think harder or auto-resume stays pending, returned for a later "send anyway" to resend.
    /// The reply it would replace is untouched until that request goes out.
    func reverifyHeldTurn(currentThread: Thread?, modelContext: ModelContext) -> PendingRetry? {
        let question = gatedQuestion, effort = gatedEffort
        hardwareConfirmRequested = false
        guard let thread = currentThread, let g = heldBackTurn(in: thread) else { return nil }
        let effects = replies.handle(.decline(g), in: thread, context: modelContext)
        if effects.contains(.returnQuestionToComposer(g)) {
            returnToComposer(thread: thread, context: modelContext)
            return nil
        }
        gatedQuestion = nil
        return question.map { PendingRetry(question: $0, effort: effort) }
    }

    /// Effect returnQuestionToComposer: the held-back question leaves the chat and its text and images join the draft.
    private func returnToComposer(thread: Thread, context modelContext: ModelContext) {
        let gated = gatedQuestion ?? turnQuestion
        gatedQuestion = nil
        hardwareConfirmRequested = false
        guard let gated, gated.thread?.id == thread.id else { return }
        let images = ImageAttachment.images(of: gated).map {
            ImageIntake.Image(mimeType: $0.mimeType, width: $0.width, height: $0.height, data: $0.data, thumbnail: $0.thumbnail)
        }
        let merged = Self.composerAfterReturn(question: (gated.content, images), draft: (prompt, pendingImages),
                                              limit: imageLimit)
        ChatSearchService.shared.didDelete(messageIDs: [gated.id])
        MessageDeletion.delete([gated], in: modelContext)
        thread.invalidateSortedMessages()
        do { try modelContext.save() } catch { logger.error("Failed to save after returning a question: \(error)") }
        prompt = merged.text
        pendingImages = merged.images
        questionsReturned += 1
    }

    /// The user message to re-ask when the app returns to the foreground, or
    /// nil. Non-nil only when `thread` is the one whose last turn the on-device
    /// transport abandoned because the app left the foreground (iOS revokes
    /// GPU access), AND that turn left the user message unanswered. A turn the
    /// user stopped is not resumed — they asked for it to stop.
    ///
    /// CONSUMES the flag: the caller re-asks exactly once. Without the resume
    /// the thread carries an orphaned request, and the next question is
    /// answered as if it were that request — "hello" got the potato essay.
    func interruptedUserMessage(in thread: Thread?, llm: ChatGeneration) -> Message? {
        guard let thread, llm.interruptedThreadID == thread.id, !llm.running else { return nil }
        llm.interruptedThreadID = nil
        // THE CUT-OFF REPLY MAY ALREADY BE SAVED after the question: what streamed before iOS revoked the GPU is
        // persisted as the assistant message, so requiring the LAST message to be the user's never matched — the
        // user came back to an essay cut off at its title line and nothing re-asked (iPhone 16 Pro, 2026-10-04,
        // testBackgroundingMidAnswerAbandonsAndResumes). Re-ask the last question when only replies follow it;
        // retry(from:) deletes those replies before asking again.
        let sorted = thread.sortedMessages
        guard let i = sorted.lastIndex(where: { $0.role == .user }),
              sorted[(i + 1)...].allSatisfy({ $0.role == .assistant }) else { return nil }
        return sorted[i]
    }

    func retry(
        from message: Message,
        currentThread: inout Thread?,
        modelContext: ModelContext,
        settings: AppSettings,
        providers: ProviderStore,
        session: ConfidentialSession,
        llm: ChatGeneration,
        acceptedDegrade: Bool = false,
        effort: ReasoningEffort = .chatDefault
    ) {
        guard let thread = message.thread ?? currentThread else { return }
        thinkHarderLevel = effort == .thinkHarder ? providers.activeProvider.flatMap {
            ReasoningLevel.turnLabel(effort: effort, provider: $0, chosen: ReasoningLevel.chosen(for: $0))
        } : nil
        turnQuestion = message
        turnStartedAttestable = providers.activeProvider?.capabilities.contains(.attestation) == true

        // Stop any in-progress generation (e.g. stuck after background timeout)
        if llm.running {
            llm.stop()
        }

        let sorted = thread.sortedMessages
        // A live turn retired by this one keeps what it had shown.
        if let live = replies.live(in: thread.id), replies.state(in: thread.id) == .requesting, !llm.output.isEmpty {
            replies.handle(.firstToken(live, text: llm.output), in: thread, context: modelContext)
        }
        let after = sorted.firstIndex(where: { $0.id == message.id }).map { Array(sorted[($0 + 1)...]) } ?? []
        let generation = replies.newGeneration()
        if effort == .thinkHarder {
            // The old reply stays until the new one lands (`ReplySupersession`).
            llm.superseding = ReplySupersession(replyIDs: Set(after.map(\.id)))
            replies.handle(.thinkHarder(generation, place: Self.place(providers), supersedes: after.map(replies.generation(of:))),
                           in: thread, context: modelContext)
        } else {
            // What follows the question goes only when the request goes out; a reply with content survives a refusal.
            replies.handle(.retry(generation, place: Self.place(providers), replaces: after.map(replies.generation(of:)),
                                  restorable: ReplyTurns.restorable(after)),
                           in: thread, context: modelContext)
        }

        // Clear stale state so the pending activity chip appears immediately.
        llm.lastError = nil
        llm.lastErrorThreadID = nil
        llm.output = ""

        currentThread = thread
        generatingThreadID = thread.id
        Self.startTurnClock(llm, providers: providers, reask: true)
        latestTurn += 1
        let turn = latestTurn
        Task {
            await llm.waitUntilStopped(timeout: .seconds(1))
            onPlayHaptic?()
            await generateResponse(in: thread, settings: settings, providers: providers, session: session,
                                   llm: llm, modelContext: modelContext,
                                   effort: effort, generation: generation, turn: turn)
            if latestTurn == turn { generatingThreadID = nil }
        }
    }

    /// Set in the same frame as `generatingThreadID`, or the placeholder reads thinking before the gate's wait shows.
    private static func startTurnClock(_ llm: ChatGeneration, providers: ProviderStore, reask: Bool) {
        llm.turnOrigin = Date()
        llm.gateEndedAt = nil
        llm.turnIsReask = reask
        // Only an attested provider's prepareTurn waits; a plain-TLS or on-device turn must not flash the label.
        llm.waitingForVerification = providers.activeProvider?.capabilities.contains(.attestation) == true
    }

    /// The gate refused. A held-back turn ends like a decline: a fresh send's question comes back to the composer.
    private func refuseGate(_ g: ReplyGeneration, in thread: Thread, context: ModelContext) {
        let effects = replies.handle(.gateRefused(g), in: thread, context: context)
        if effects.contains(.returnQuestionToComposer(g)) { returnToComposer(thread: thread, context: context) }
    }

    /// The turn the still-checking ask holds back in this chat, if any: live and waiting on the user.
    func heldBackTurn(in thread: Thread) -> ReplyGeneration? {
        replies.state(in: thread.id) == .awaitingConfirm ? replies.live(in: thread.id) : nil
    }

    /// The trust layer's half: when the current record's verdict settles, the rows sent before it was confirmed
    /// lose their mark (pass) or keep a failed one (hard fail).
    func settleSentBeforeConfirmed(session: ConfidentialSession, modelContext: ModelContext) {
        // Settle on the record's own verdicts only: losing the attestation capability (an unknown tier resolving
        // to third-party) makes verdictsPending read false while the checks still run, which is not a pass (F5).
        guard session.activeProvider?.capabilities.contains(.attestation) == true,
              let record = session.attestation, !session.sendPending else { return }
        let outcome: SentBeforeConfirmed.Outcome = session.degradeIsHardFailure ? .hardFail
            : session.sendPolicy == .allow ? .pass : .unsettled
        do {
            try SentBeforeConfirmed.settle(recordKey: SentBeforeConfirmed.recordKey(for: record), outcome: outcome,
                                           in: modelContext)
        } catch { logger.error("Failed to settle sentBeforeConfirmed: \(error)") }
    }

    /// A re-verify captures the chat's newest turn before it waits (reply-machine.json `reverifyRetry`).
    struct ReverifyCapture: Equatable { let threadID: UUID?; let latest: ReplyGeneration? }

    func reverifyCapture(in thread: Thread?) -> ReverifyCapture {
        ReverifyCapture(threadID: thread?.id, latest: thread.map { replies.latest(in: $0.id) })
    }

    /// Its retry runs only in the chat it was tapped in, and only if no newer turn started there meanwhile; otherwise
    /// it would delete that turn (G6) or send another chat's composer.
    func reverifyStillCurrent(_ captured: ReverifyCapture, in thread: Thread?) -> Bool {
        captured == reverifyCapture(in: thread)
    }

    static func place(_ providers: ProviderStore) -> ReplyPlace {
        providers.activeProvider?.isLocal == true ? .local : .remote
    }

    /// How a turn that reached the engine ended, as reply events (reply-machine.json).
    static func endingEvents(_ g: ReplyGeneration, output: String, error: LLMError?, cancelled: Bool, interrupted: Bool,
                             backgroundExpired: Bool, local: Bool, end: TurnEnd?) -> [ReplyEvent] {
        if let error {
            if (error.underlyingError as? E2EEError) == .decryptionFailed { return [.decryptFailed(g, field: "content")] }
            return [.error(g, kind: error.httpStatus.map { "http \($0)" } ?? "other")]
        }
        let text: [ReplyEvent] = output.isEmpty ? [] : [.firstToken(g, text: output)]
        if cancelled {
            // Cancelled from below: on device that is the GPU lost in the background (asked again on return);
            // a remote stream cut that way reads as interrupted, never as a stop the user made.
            if interrupted { return text + [local ? .appBackgrounded : .backgroundTimeExpired] }
            if backgroundExpired { return text + [.backgroundTimeExpired] }
            return text + [.userStop]
        }
        switch end {
        case .length: return text + [.finish(g, reason: .length)]
        case .contentFilter: return text + [.finish(g, reason: .contentFilter)]
        case .endedWithoutDone: return text + [.streamEndedWithoutDone(g)]
        case .none?: return text + [.finish(g, reason: .none)]
        case .stop?, nil: return text + [.finish(g, reason: .stop)]
        }
    }

    /// Think Harder asks again NOW, so its time note says so; a plain retry keeps
    /// the time the question was first sent.
    static func restampIfReasked(_ question: Message, effort: ReasoningEffort, now: Date = Date()) {
        if effort == .thinkHarder { question.timestamp = now }
    }

    /// The question a reply answered: the user message just before it.
    static func question(answeredBy reply: Message, in thread: Thread) -> Message? {
        let sorted = thread.sortedMessages
        guard let idx = sorted.firstIndex(where: { $0.id == reply.id }) else { return nil }
        return sorted[..<idx].last(where: { $0.role == .user })
    }

    private func generateResponse(
        in thread: Thread,
        settings: AppSettings,
        providers: ProviderStore,
        session: ConfidentialSession,
        llm: ChatGeneration,
        modelContext: ModelContext,
        effort: ReasoningEffort = .chatDefault,
        generation g: ReplyGeneration,
        turn: Int
    ) async {
        let supersession = llm.superseding
        // The gate's wait ends on every path out of here, never later than the read below.
        defer { if latestTurn == turn { llm.waitingForVerification = false } }
        // Cleared on every exit, and only after the save below, or the old reply shows for a frame.
        defer { if supersession.isActive, latestTurn == turn { llm.superseding = ReplySupersession() } }
        guard let provider = providers.activeProvider else {
            refuseGate(g, in: thread, context: modelContext)
            return
        }
        let groundingKey = provider.capabilities.contains(.builtInGrounding)
            ? nil : settings.groundingAPIKey

        // FAIL CLOSED, and keep this ahead of `prepareTurn`: attestation with
        // no key 401s and would surface below as an E2EE failure that no
        // lock-icon re-verify can fix. Same presentation as a generation error.
        let apiKey = providers.credential(for: provider)
        let place = ConfidentialSession.TurnPlace(provider)
        if Self.mustRefuseMissingKey(provider: provider, credential: apiKey) {
            logger.warning("[send] \(provider.name, privacy: .public) requires an API key and none is stored — refusing to send")
            llm.output = ""
            llm.lastError = Self.missingKeyError(for: provider)
            llm.lastErrorThreadID = thread.id
            session.abandonTurn(for: place, reason: llm.lastError?.userMessage)
            refuseGate(g, in: thread, context: modelContext)
            llm.scrollToBottomToken += 1
            return
        }

        let teeContext = await session.prepareTurn(for: place)
        llm.gateEndedAt = Date()
        if latestTurn == turn { llm.waitingForVerification = false }
        // A verdict that lands after a provider or model switch must not count for the new one.
        llm.onReplyVerified = { [weak session] verification in
            guard session?.ownsTurn(place) == true else { return }
            session?.recordVerification(verification)
        }
        let pending = session.sendPending
        let gate = Self.postPrepare(policy: session.sendPolicy,
                                    // Only a confirmation for THIS record and reason (F4); "send anyway" is remembered by the session.
                                    acceptedDegrade: session.hasConfirmed(pending: pending),
                                    verdictsPending: pending, sealed: teeContext?.e2eePeer != nil)
        if gate == .confirmPending {
            gatedQuestion = turnQuestion ?? thread.sortedMessages.last { $0.role == .user }
            gatedEffort = effort
            gatedSupersession = supersession
            pendingAskKind = session.pendingKind ?? .hardware
            replies.handle(.gateNeedsConfirm(g), in: thread, context: modelContext)
            session.abandonTurn(for: place, reason: nil)
            hardwareConfirmRequested = true
            return
        }
        if case .refuse(let refusal) = gate {
            logger.warning("[E2EE] gate refused after prepareTurn — \(refusal, privacy: .public)")
            llm.output = ""
            llm.lastError = LLMError(
                source: .provider(name: provider.name), userMessage: refusal,
                httpStatus: nil, url: provider.openAIBaseURL, requestHeaders: nil,
                requestBodyJSON: nil, messageHistory: nil, responseBody: nil,
                underlyingError: E2EEError.encryptionFailed
            )
            llm.lastErrorThreadID = thread.id
            session.abandonTurn(for: place, reason: refusal)
            refuseGate(g, in: thread, context: modelContext)
            llm.scrollToBottomToken += 1
            return
        }
        if Self.mustRefuseUnsealedSend(provider: provider, teeContext: teeContext) {
            // FAIL CLOSED. This used to log a warning and
            // proceed — an attested provider with no E2EE peer reached the
            // transport with a nil codec and sent PLAINTEXT under an E2EE
            // promise. Surface the degraded state exactly like a generation
            // error (the view renders `lastError` keyed to the thread;
            // `retry(...)` clears it) and send NOTHING.
            logger.warning("[E2EE] Ed25519 key unavailable after wait — refusing to send")
            llm.output = ""
            llm.lastError = LLMError(
                source: .provider(name: provider.name),
                userMessage: "end-to-end encryption couldn't be set up, so nothing was sent. try again. if it keeps happening, re-verify from the lock icon.",
                httpStatus: nil, url: provider.openAIBaseURL, requestHeaders: nil,
                requestBodyJSON: nil, messageHistory: nil, responseBody: nil,
                underlyingError: E2EEError.encryptionFailed
            )
            llm.lastErrorThreadID = thread.id
            session.abandonTurn(for: place, reason: llm.lastError?.userMessage)
            refuseGate(g, in: thread, context: modelContext)
            llm.scrollToBottomToken += 1
            return
        }

        // A turn that started attestable never leaves unsealed, ask or no ask: if the tier resolved to third-party (or no
        // peer remains), send nothing and end it like a decline; the next send meets the normal composer flow.
        if turnStartedAttestable, teeContext?.e2eePeer == nil || !provider.capabilities.contains(.attestation) {
            session.abandonTurn(for: place, reason: nil)
            let effects = replies.handle(.gateWouldGoPlain(g), in: thread, context: modelContext)
            if effects.contains(.returnQuestionToComposer(g)) { returnToComposer(thread: thread, context: modelContext) }
            llm.scrollToBottomToken += 1
            return
        }

        // The request goes out: confirm the held-back turn, or pass the gate. A turn that is no longer live sends nothing.
        let sealed = teeContext?.e2eePeer != nil
        let sbc = SentBeforeConfirmed.atSend(sealed: sealed, pending: pending, policy: session.sendPolicy,
                                             record: session.attestation)
        let gateEvent: ReplyEvent = replies.state(in: thread.id) == .awaitingConfirm
            ? .confirm(g, sentBeforeConfirmed: sbc)
            : .gatePassed(g, sealed: sealed, sentBeforeConfirmed: sbc)
        if replies.handle(gateEvent, in: thread, context: modelContext).contains(where: { if case .ignoreStale = $0 { true } else { false } }) {
            session.abandonTurn(for: place, reason: nil)
            return
        }

        await ReasoningControl.classifyIfNeeded(provider, store: providers)
        ReasoningControl.note(ReasoningControl.resolve(provider: provider, store: providers), for: provider)
        let output = await llm.generate(
            provider: provider,
            thread: thread,
            systemPrompt: settings.systemPrompt,
            groundingAPIKey: groundingKey,
            searchTurnedOff: settings.searchKeyTurnedOff,
            apiKey: apiKey,
            teeContext: teeContext,
            effort: effort
        )
        // `generate` has already set `running = false`. Do not yield before
        // the assistant row is in SwiftData — a hop here lets SwiftUI paint
        // one frame with the streaming view gone and no persisted message,
        // which is the flash before the debug panel.
        session.finishTurn(for: place, debugInfo: llm.lastRequestDebugInfo, error: llm.lastError,
                           countsAsE2EE: SentBeforeConfirmed.countsAsE2EE(sbc))

        // A turn that is no longer live (a retry or think harder took over) ends silently: its ending must not reach
        // the new turn, and app events (stop, background) carry no generation.
        guard replies.live(in: thread.id) == g else { return }
        // The chat was deleted mid-answer: write nothing more for it.
        if thread.modelContext == nil || thread.isDeleted {
            replies.handle(.deleteChat, in: thread, context: modelContext)
            return
        }
        for event in Self.endingEvents(g, output: output, error: llm.lastError, cancelled: llm.cancelled,
                                       interrupted: llm.interruptedThreadID == thread.id,
                                       backgroundExpired: llm.backgroundTimeExpired,
                                       local: Self.place(providers) == .local, end: llm.lastTurnEnd) {
            replies.handle(event, in: thread, context: modelContext)
        }
        let ended = replies.state(in: thread.id)
        // Think harder asks again now: the question is restamped and its new reply must still sort after it.
        if supersession.isActive, ended == .complete || ended == .cutOff,
           let question = thread.sortedMessages.last(where: { $0.role == .user }) {
            Self.restampIfReasked(question, effort: effort)
            replies.message(for: g, in: thread)?.timestamp = Date()
            thread.invalidateSortedMessages()
        }
        if let reply = replies.message(for: g, in: thread), ended.status != nil {
            reply.generatingTime = ThinkingClock.savedTime(thinking: llm.thinkingTime, turn: llm.elapsedTime)
            reply.isE2EE = session.lastRequestUsedE2EE == true
            if !reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let sources = GroundingSource.citedOrAll(in: reply.content, grounding: llm.groundingSources)
                reply.sourcesJSON = GroundingSource.encodedJSON(sources)
                // The first moment the turn's web-search request can be tied to the reply it produced.
                llm.attachPendingOffer(to: reply.id)
                ChatSearchService.shared.didWrite(reply)
            }
            do { try modelContext.save() } catch { logger.error("Failed to save the reply: \(error)") }
        }
        // Only a plain on-device turn abandoned in the background is asked again on return.
        if !replies.resumeArmed(in: thread.id) { llm.interruptedThreadID = nil }

        llm.scrollToBottomToken += 1
        // Verification bookkeeping that used to sit in a pre-save yield.
        await Task.yield()
    }

    private func sendMessage(_ message: Message, modelContext: ModelContext) {
        onPlayHaptic?()
        modelContext.insert(message)
        message.thread?.invalidateSortedMessages()
        do { try modelContext.save() } catch { logger.error("Failed to save message: \(error)") }
        // Best-effort; the launch reconcile is what guarantees correctness.
        ChatSearchService.shared.didWrite(message)
    }
}
