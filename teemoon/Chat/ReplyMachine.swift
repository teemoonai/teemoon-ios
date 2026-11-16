//
//  ReplyMachine.swift
//  teemoon
//
//  The reply (turn) lifecycle of conformance/reply-machine.json. `handle` is the only writer of reply state; it
//  returns effects and never touches SwiftData. Change the kit first, then this file.
//

import Foundation

/// A turn's id. Increases per chat; an event carrying any other id than the live one changes nothing.
struct ReplyGeneration: Hashable, Comparable, Sendable {
    let value: Int
    init(_ value: Int) { self.value = value }
    static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}

enum ReplyPlace: String, Sendable { case remote, local }

enum FinishReason: String, Sendable { case stop, length, contentFilter, none }

/// Message.statusRaw. nil (rows from before V3) reads as complete.
enum ReplyStatus: String, CaseIterable, Sendable {
    case interrupted, complete, stopped, cutOff, failed, decryptFailed

    /// The marker a saved row shows when it is read back.
    static func reloadMarker(_ status: ReplyStatus?) -> ReplyMarker? {
        switch status {
        case nil, .complete: nil
        case .interrupted, .failed: .didntFinish
        case .stopped: .stopped
        case .cutOff: .cutShort
        case .decryptFailed: .decryptFailed
        }
    }
}

/// Marker ids; their words are decided elsewhere.
enum ReplyMarker: String, CaseIterable, Sendable {
    case didntFinish = "marker.didntFinish"
    case stopped = "marker.stopped"
    case cutShort = "marker.cutShort"
    case decryptFailed = "marker.decryptFailed"
}

enum ReplyState: String, CaseIterable, Sendable {
    case idle
    case gating, awaitingConfirm, requesting, streaming, toolRunning
    case complete, stopped, cutOff, failed, decryptFailed, interrupted, restored, discarded, returned

    var isLive: Bool { [.gating, .awaitingConfirm, .requesting, .streaming, .toolRunning].contains(self) }
    var isTerminal: Bool { self != .idle && !isLive }
    /// Engine work is under way: the stream or the on-device decode exists.
    var isEngineLive: Bool { [.requesting, .streaming, .toolRunning].contains(self) }

    /// What a terminal state writes to the reply row; nil = no row (restored, discarded) or not terminal.
    var status: ReplyStatus? {
        switch self {
        case .complete: .complete
        case .stopped: .stopped
        case .cutOff: .cutOff
        case .failed: .failed
        case .decryptFailed: .decryptFailed
        case .interrupted: .interrupted
        default: nil
        }
    }

    /// Shown in session when the turn ends here.
    var marker: ReplyMarker? {
        switch self {
        case .stopped: .stopped
        case .cutOff: .cutShort
        case .decryptFailed: .decryptFailed
        case .interrupted: .didntFinish
        default: nil
        }
    }

    /// Text kept on the row; failures keep none (never ciphertext, never an error string).
    fileprivate var keepsText: Bool { [.complete, .stopped, .cutOff, .interrupted].contains(self) }
}

enum ReplyEvent: Equatable, Sendable {
    case send(ReplyGeneration, place: ReplyPlace, images: Int = 0)
    /// `restorable`: a replaced row has content and is not interrupted, failed or decryptFailed (the caller reads the store).
    case retry(ReplyGeneration, place: ReplyPlace, replaces: [ReplyGeneration], restorable: Bool = false)
    case thinkHarder(ReplyGeneration, place: ReplyPlace, supersedes: [ReplyGeneration])
    case reverifyRetry(ReplyGeneration, place: ReplyPlace, replaces: [ReplyGeneration], captured: ReplyGeneration,
                       restorable: Bool = false)
    case autoResume(ReplyGeneration, place: ReplyPlace, replaces: [ReplyGeneration], restorable: Bool = false)
    case gatePassed(ReplyGeneration, sealed: Bool, sentBeforeConfirmed: String?)
    case gateNeedsConfirm(ReplyGeneration)
    case gateRefused(ReplyGeneration)
    /// The turn started attestable and the send would now leave unsealed: nothing is sent, it ends like a decline.
    case gateWouldGoPlain(ReplyGeneration)
    case confirm(ReplyGeneration, sentBeforeConfirmed: String?)
    case decline(ReplyGeneration)
    case firstToken(ReplyGeneration, text: String)
    case token(ReplyGeneration, text: String)
    case toolRound(ReplyGeneration)
    case toolResult(ReplyGeneration, sources: Int)
    case toolRoundEnded(ReplyGeneration)
    case finish(ReplyGeneration, reason: FinishReason)
    case streamEndedWithoutDone(ReplyGeneration)
    case decryptFailed(ReplyGeneration, field: String)
    case error(ReplyGeneration, kind: String)
    case engineAbandoned(ReplyGeneration, reason: String)
    case engineLateCallback(ReplyGeneration, kind: String)
    case userStop, appBackgrounded, backgroundTimeExpired, appKilled, launchRecovery, deleteChat, draftEdited

    /// The generation an engine, gate or confirm event speaks for; nil for user/app events.
    var speaksFor: ReplyGeneration? {
        switch self {
        case .gatePassed(let g, _, _), .gateNeedsConfirm(let g), .gateRefused(let g), .gateWouldGoPlain(let g),
             .confirm(let g, _), .decline(let g),
             .firstToken(let g, _), .token(let g, _), .toolRound(let g), .toolResult(let g, _), .toolRoundEnded(let g),
             .finish(let g, _), .streamEndedWithoutDone(let g), .decryptFailed(let g, _), .error(let g, _),
             .engineAbandoned(let g, _), .engineLateCallback(let g, _):
            g
        default: nil
        }
    }
}

/// A reply row as the store should hold it after an effect.
struct ReplyRow: Equatable, Sendable {
    var status: ReplyStatus
    var content: String
    var sources: Int
    var sentBeforeConfirmed: String?
}

enum ReplyEffect: Equatable, Sendable {
    case ignoreStale(ReplyGeneration?)
    case refuseSendKeepDraft
    case cancelEngine(ReplyGeneration)
    case deleteRows([ReplyGeneration])
    case persistRow(ReplyGeneration, ReplyRow)
    case persistSentBeforeConfirmed(ReplyGeneration, String?)
    case persistQuestion(ReplyGeneration, images: Int)
    case startGate(ReplyGeneration)
    case askUser(ReplyGeneration)
    case sendRequest(ReplyGeneration, images: Int)
    /// Declined on a fresh send: delete the question and its reply row; the question's text and images go back to
    /// the composer (ChatViewModel.composerAfterReturn). Nothing persisted, no marker.
    case returnQuestionToComposer(ReplyGeneration)
    case showMarker(ReplyMarker)
    case showLastRequestCard
    case armResume
    case disarmResume
    case swapSupersededDisplay(ReplyGeneration)
}

/// One chat's reply slot. `handle` is the only writer.
struct ReplyMachine: Sendable {
    enum Origin: Sendable { case send, retry, thinkHarder, reverifyRetry, autoResume }

    private struct Live: Sendable {
        let id: ReplyGeneration
        let place: ReplyPlace
        let supersedes: [ReplyGeneration]
        let origin: Origin
        var images = 0
        var replaces: [ReplyGeneration] = []
        var restorable = false
        var sent = false
        /// A retry, re-verify retry or auto-resume whose request has not gone out: it has changed nothing on disk.
        var unsentRetry: Bool { [.retry, .reverifyRetry, .autoResume].contains(origin) && !sent }
        var text = ""
        var sources = 0
        var sentBeforeConfirmed: String?
        var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private(set) var state: ReplyState = .idle
    private(set) var highest: ReplyGeneration
    private(set) var resumeArmed = false
    private var current: Live?

    var live: ReplyGeneration? { current?.id }

    init(highest: ReplyGeneration = ReplyGeneration(0)) { self.highest = highest }

    mutating func handle(_ event: ReplyEvent) -> [ReplyEffect] {
        if let g = event.speaksFor, g != current?.id { return [.ignoreStale(g)] }
        if case .reverifyRetry(_, _, _, let captured, _) = event, captured != highest { return [.ignoreStale(captured)] }

        switch event {
        case .send(let g, let place, let images):
            if state.isLive { return [.refuseSendKeepDraft] }
            return [.persistQuestion(g, images: images)]
                + start(g, place: place, replaces: [], supersedes: [], origin: .send, images: images)
        case .retry(let g, let place, let replaces, let restorable):
            return retire() + start(g, place: place, replaces: replaces, supersedes: [], origin: .retry, restorable: restorable)
        case .reverifyRetry(let g, let place, let replaces, _, let restorable):
            return retire() + start(g, place: place, replaces: replaces, supersedes: [], origin: .reverifyRetry,
                                    restorable: restorable)
        case .thinkHarder(let g, let place, let supersedes):
            return retire() + start(g, place: place, replaces: [], supersedes: supersedes, origin: .thinkHarder)
        case .autoResume(let g, let place, let replaces, let restorable):
            guard state == .interrupted, resumeArmed else { return [] }
            return start(g, place: place, replaces: replaces, supersedes: [], origin: .autoResume, restorable: restorable)
        case .launchRecovery:
            guard state == .interrupted else { return [] }
            resumeArmed = false
            return [.showMarker(.didntFinish), .disarmResume]
        default:
            break
        }
        guard var live = current, state.isLive else { return [] }

        switch (state, event) {
        case (_, .userStop):
            return [.cancelEngine(live.id)] + end(as: .stopped)
        case (_, .appKilled):
            current = nil
            state = live.supersedes.isEmpty && !live.unsentRetry ? .interrupted : .restored
            return []
        case (_, .deleteChat):
            current = nil
            state = .discarded
            return [.cancelEngine(live.id), .deleteRows((live.unsentRetry ? live.replaces : []) + [live.id])]

        case (.gating, .gatePassed(_, _, let sbc)), (.awaitingConfirm, .confirm(_, let sbc)):
            live.sentBeforeConfirmed = sbc
            // An unsent retry commits only now: the replaced rows go and its own row is written.
            let commit: [ReplyEffect] = live.unsentRetry
                ? [.deleteRows(live.replaces),
                   .persistRow(live.id, ReplyRow(status: .interrupted, content: "", sources: 0, sentBeforeConfirmed: sbc))]
                : []
            live.sent = true
            current = live
            state = .requesting
            return commit + [.persistSentBeforeConfirmed(live.id, sbc), .sendRequest(live.id, images: live.images)]
        case (.gating, .gateNeedsConfirm):
            state = .awaitingConfirm
            return [.askUser(live.id)]
        case (.gating, .gateRefused):
            return end(as: .failed)
        // Confirm re-reads the gate: a hard verdict while the user was asked ends the turn like a decline.
        case (.awaitingConfirm, .decline), (.awaitingConfirm, .gateRefused),
             (.awaitingConfirm, .gateWouldGoPlain), (.gating, .gateWouldGoPlain):
            guard live.origin == .send else { return end(as: .stopped) }   // retry family: restored when restorable
            current = nil
            state = .returned
            return [.returnQuestionToComposer(live.id), .deleteRows([live.id])]

        case (.requesting, .firstToken(_, let text)), (.requesting, .token(_, let text)), (.streaming, .token(_, let text)):
            let first = !live.hasText
            live.text += text
            current = live
            state = .streaming
            return first && !live.supersedes.isEmpty ? [.swapSupersededDisplay(live.id)] : []
        case (.requesting, .toolRound), (.streaming, .toolRound):
            state = .toolRunning
            return []
        case (.toolRunning, .toolResult(_, let sources)):
            live.sources += sources
            current = live
            return []
        case (.toolRunning, .toolRoundEnded):
            state = .requesting
            return []
        case (.requesting, .finish(_, let reason)), (.streaming, .finish(_, let reason)):
            guard live.hasText else { return end(as: .failed) }
            return end(as: reason == .length || reason == .contentFilter ? .cutOff : .complete)
        case (.requesting, .streamEndedWithoutDone), (.streaming, .streamEndedWithoutDone):
            return end(as: live.hasText ? .cutOff : .failed)

        case (_, .decryptFailed) where state.isEngineLive:
            return end(as: .decryptFailed)
        case (_, .error) where state.isEngineLive:
            return end(as: .failed)
        case (_, .appBackgrounded) where state.isEngineLive && live.place == .local:
            let arm = live.supersedes.isEmpty
            let effects: [ReplyEffect] = [.cancelEngine(live.id)] + end(as: .interrupted)
            resumeArmed = arm
            return effects + (arm ? [.armResume] : [])
        case (_, .backgroundTimeExpired) where state.isEngineLive && live.place == .remote:
            return [.cancelEngine(live.id)] + end(as: .interrupted)
        default:
            return []
        }
    }

    private mutating func start(_ g: ReplyGeneration, place: ReplyPlace, replaces: [ReplyGeneration],
                                supersedes: [ReplyGeneration], origin: Origin, images: Int = 0,
                                restorable: Bool = false) -> [ReplyEffect] {
        current = Live(id: g, place: place, supersedes: supersedes, origin: origin, images: images,
                       replaces: replaces, restorable: restorable)
        highest = max(highest, g)
        resumeArmed = false
        state = .gating
        // A retry family turn changes nothing on disk until its request goes out (gatePassed / confirm).
        guard origin == .send || origin == .thinkHarder else { return [.startGate(g)] }
        var effects: [ReplyEffect] = []
        if supersedes.isEmpty {
            effects.append(.persistRow(g, ReplyRow(status: .interrupted, content: "", sources: 0, sentBeforeConfirmed: nil)))
        }
        return effects + [.startGate(g)]
    }

    /// Ends the live generation before a restart: a think harder writes nothing, a plain turn is stopped.
    private mutating func retire() -> [ReplyEffect] {
        guard let live = current, state.isLive else { return [] }
        current = nil
        guard live.supersedes.isEmpty, !live.unsentRetry else { return [.cancelEngine(live.id)] }
        return [.cancelEngine(live.id), .persistRow(live.id, ReplyRow(status: .stopped, content: live.text,
                                                                    sources: live.sources,
                                                                    sentBeforeConfirmed: live.sentBeforeConfirmed))]
    }

    /// The live generation ends in `target`; a think harder that did not produce a reply ends restored.
    private mutating func end(as target: ReplyState) -> [ReplyEffect] {
        guard let live = current, let status = target.status else { return [] }
        current = nil
        let produced = target == .complete || target == .cutOff
        if !live.supersedes.isEmpty, !produced {
            state = .restored
            return target == .failed || target == .decryptFailed ? [.showLastRequestCard] : []
        }
        if live.unsentRetry, live.restorable {
            // Never destroy a reply the user already had: nothing was sent, it stands as it was.
            state = .restored
            return target == .failed ? [.showLastRequestCard] : []
        }
        state = target
        var effects: [ReplyEffect] = live.unsentRetry ? [.deleteRows(live.replaces)] : []
        effects.append(.persistRow(live.id, ReplyRow(status: status, content: target.keepsText ? live.text : "",
                                                                   sources: live.sources,
                                                                   sentBeforeConfirmed: live.sentBeforeConfirmed)))
        if produced, !live.supersedes.isEmpty { effects.append(.deleteRows(live.supersedes)) }
        if let marker = target.marker { effects.append(.showMarker(marker)) }
        if target == .failed { effects.append(.showLastRequestCard) }
        return effects
    }
}

/// G8: the on-device engine cache's epoch. Evict bumps it; a build that finishes under an older epoch is released.
struct EngineCacheEpochs: Sendable {
    enum State: String, Sendable { case empty, building, resident }
    enum Effect: Equatable, Sendable { case startBuild(epoch: Int), joinBuild, reuse, insert, releaseStale, bumped(epoch: Int) }

    private(set) var state: State = .empty
    private(set) var epoch = 0
    var residentCount: Int { state == .resident ? 1 : 0 }

    mutating func build() -> Effect {
        switch state {
        case .empty: state = .building; return .startBuild(epoch: epoch)
        case .building: return .joinBuild
        case .resident: return .reuse
        }
    }

    mutating func evict() -> Effect {
        epoch += 1
        state = .empty
        return .bumped(epoch: epoch)
    }

    mutating func initialized(epoch built: Int) -> Effect {
        guard built == epoch, state == .building else { return .releaseStale }
        state = .resident
        return .insert
    }
}
