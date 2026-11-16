//
//  ReplyMachineTests.swift
//  teemoonTests
//
//  Every vector in conformance/reply-machine.json, replayed through ReplyMachine. The machine returns effects; a
//  dictionary stands in for the store and applies them, so what is compared is what the app would persist.
//

import Foundation
import Testing
@testable import teemoon

@Suite("ReplyMachine replays every reply-machine.json vector")
struct ReplyMachineTests {
    typealias Object = [String: Any]

    static func gen(_ any: Any?) -> ReplyGeneration? { (any as? Int).map(ReplyGeneration.init) }
    static func gens(_ any: Any?) -> [ReplyGeneration] { (any as? [Int] ?? []).map(ReplyGeneration.init) }

    /// The kit's event object as a ReplyEvent. `next` stands in for a send's id when the vector gives none (a refused send).
    static func event(_ o: Object, next: ReplyGeneration, restorable: Bool = false) throws -> ReplyEvent {
        let kind = try #require(o["event"] as? String)
        let g = gen(o["generation"]) ?? next
        let place = ReplyPlace(rawValue: o["place"] as? String ?? "remote") ?? .remote
        switch kind {
        case "send": return .send(g, place: place, images: o["images"] as? Int ?? 0)
        case "draftEdited": return .draftEdited
        case "retry": return .retry(g, place: place, replaces: gens(o["replaces"]), restorable: restorable)
        case "thinkHarder": return .thinkHarder(g, place: place, supersedes: gens(o["supersedes"]))
        case "reverifyRetry":
            return .reverifyRetry(g, place: place, replaces: gens(o["replaces"]), captured: try #require(gen(o["captured"])),
                                  restorable: restorable)
        case "autoResume": return .autoResume(g, place: place, replaces: gens(o["replaces"]), restorable: restorable)
        case "gatePassed":
            return .gatePassed(g, sealed: o["sealed"] as? Bool ?? false, sentBeforeConfirmed: o["sentBeforeConfirmed"] as? String)
        case "gateNeedsConfirm": return .gateNeedsConfirm(g)
        case "gateRefused": return .gateRefused(g)
        case "gateWouldGoPlain": return .gateWouldGoPlain(g)
        case "confirm": return .confirm(g, sentBeforeConfirmed: o["sentBeforeConfirmed"] as? String)
        case "decline": return .decline(g)
        case "firstToken": return .firstToken(g, text: o["text"] as? String ?? "")
        case "token": return .token(g, text: o["text"] as? String ?? "")
        case "toolRound": return .toolRound(g)
        case "toolResult": return .toolResult(g, sources: o["sources"] as? Int ?? 0)
        case "toolRoundEnded": return .toolRoundEnded(g)
        case "finish": return .finish(g, reason: try #require(FinishReason(rawValue: o["reason"] as? String ?? "")))
        case "streamEndedWithoutDone": return .streamEndedWithoutDone(g)
        case "decryptFailed": return .decryptFailed(g, field: o["field"] as? String ?? "")
        case "error": return .error(g, kind: o["kind"] as? String ?? "")
        case "engineAbandoned": return .engineAbandoned(g, reason: o["reason"] as? String ?? "")
        case "engineLateCallback": return .engineLateCallback(g, kind: o["kind"] as? String ?? "")
        case "userStop": return .userStop
        case "appBackgrounded": return .appBackgrounded
        case "backgroundTimeExpired": return .backgroundTimeExpired
        case "appKilled": return .appKilled
        case "launchRecovery": return .launchRecovery
        case "deleteChat": return .deleteChat
        default: throw KitError.unknownEvent(kind)
        }
    }

    enum KitError: Error { case unknownEvent(String) }

    struct StoredRow: Equatable {
        var status: String?
        var content: String
        var sources: Int
        var sentBeforeConfirmed: String?
    }

    @Test func everyVectorReplays() throws {
        guard let kit = try ReplyMachineVectorsTests.kit() else { return }
        let vectors = ReplyMachineVectorsTests.vectors(kit)
        #expect(vectors.count >= 25)
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            var store: [ReplyGeneration: StoredRow] = [:]
            for row in vector["given"] as? [Object] ?? [] {
                store[ReplyGeneration(row["generation"] as? Int ?? 0)] = StoredRow(
                    status: row["statusRaw"] as? String, content: row["content"] as? String ?? "",
                    sources: row["sources"] as? Int ?? 0, sentBeforeConfirmed: row["sentBeforeConfirmed"] as? String)
            }
            var machine = ReplyMachine(highest: store.keys.max() ?? ReplyGeneration(0))
            var ignored: [Int] = []
            var shown: ReplyMarker?
            var requests: [[Int]] = [], userTurns = 0
            var draft: String?
            var returned: [Int] = []
            let checkpoints = vector["checkpoints"] as? [Object] ?? []
            for (index, raw) in (vector["events"] as? [Object] ?? []).enumerated() {
                if raw["event"] as? String == "draftEdited" { draft = "kept" }
                // The kit's `restorable`, read from the stand-in store as the app reads it from SwiftData.
                let restorable = Self.gens(raw["replaces"]).contains { g in
                    guard let row = store[g] else { return false }
                    return !row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !["interrupted", "failed", "decryptFailed"].contains(row.status ?? "")
                }
                let effects = machine.handle(try Self.event(raw, next: ReplyGeneration(machine.highest.value + 1),
                                                            restorable: restorable))
                for effect in effects {
                    switch effect {
                    case .ignoreStale: ignored.append(index)
                    case .persistRow(let g, let row):
                        store[g] = StoredRow(status: row.status.rawValue, content: row.content, sources: row.sources,
                                             sentBeforeConfirmed: row.sentBeforeConfirmed)
                    case .persistSentBeforeConfirmed(let g, let value):
                        store[g]?.sentBeforeConfirmed = value
                    case .deleteRows(let gs): for g in gs { store[g] = nil }
                    case .showMarker(let marker): shown = marker
                    case .persistQuestion:
                        userTurns += 1
                        if draft == "kept" { draft = "consumed" }
                    case .sendRequest(let g, let images): requests.append([g.value, images])
                    case .returnQuestionToComposer(let g):
                        userTurns -= 1
                        returned.append(g.value)
                    default: break
                    }
                }
                for point in checkpoints where point["after"] as? Int == index {
                    #expect(machine.state.rawValue == point["state"] as? String, "\(name) after \(index)")
                    #expect(machine.live == Self.gen(point["live"]), "\(name) after \(index): live")
                    if let armed = point["resumeArmed"] as? Bool { #expect(machine.resumeArmed == armed, "\(name) after \(index)") }
                }
            }
            let expect = try #require(vector["expect"] as? Object)
            #expect(machine.state.rawValue == expect["state"] as? String, "\(name): state")
            #expect(machine.live == Self.gen(expect["live"]), "\(name): live")
            #expect(ignored == (expect["ignored"] as? [Int] ?? []), "\(name): ignored")
            #expect(machine.resumeArmed == (expect["resumeArmed"] as? Bool ?? false), "\(name): resumeArmed")
            var want: [ReplyGeneration: StoredRow] = [:]
            for row in expect["rows"] as? [Object] ?? [] {
                want[ReplyGeneration(row["generation"] as? Int ?? -1)] = StoredRow(
                    status: row["statusRaw"] as? String, content: row["content"] as? String ?? "",
                    sources: row["sources"] as? Int ?? 0, sentBeforeConfirmed: row["sentBeforeConfirmed"] as? String)
            }
            #expect(store == want, "\(name): persisted rows")
            for (g, marker) in expect["markers"] as? [String: String] ?? [:] {
                let status = store[ReplyGeneration(Int(g) ?? -1)]?.status.flatMap(ReplyStatus.init(rawValue:))
                #expect(ReplyStatus.reloadMarker(status)?.rawValue == marker, "\(name): reload marker of \(g)")
            }
            if let want = expect["requests"] as? [Object] {
                #expect(requests == want.map { [$0["generation"] as? Int ?? -1, $0["images"] as? Int ?? -1] }, "\(name): requests")
            }
            if let turns = expect["userTurns"] as? Int { #expect(userTurns == turns, "\(name): user turns") }
            if let want = expect["draft"] as? String { #expect(draft == want, "\(name): draft") }
            if let want = expect["returned"] as? [Int] { #expect(returned == want, "\(name): returned") }
            if let marker = expect["sessionMarker"] as? String {
                #expect(shown?.rawValue == marker, "\(name): session marker")
                #expect(machine.state.marker?.rawValue == marker, "\(name): state marker")
            }
        }
    }

    /// The type's vocabulary is the kit's: same states, statusRaw values, markers, terminal set.
    @Test func vocabularyMatchesTheKit() throws {
        guard let kit = try ReplyMachineVectorsTests.kit() else { return }
        let states = ReplyMachineVectorsTests.states(kit)
        #expect(Set(ReplyState.allCases.map(\.rawValue)) == Set(states.keys))
        #expect(Set(ReplyStatus.allCases.map(\.rawValue)) == ReplyMachineVectorsTests.statusValues(kit))
        #expect(Set(ReplyMarker.allCases.map(\.rawValue)) == Set((kit["markers"] as? Object)?.keys.map { $0 } ?? []))
        for state in ReplyState.allCases {
            let declared = try #require(states[state.rawValue])
            #expect(state.isTerminal == (declared["kind"] as? String == "terminal"), "\(state)")
            #expect(state.isLive == (declared["kind"] as? String == "live"), "\(state)")
            #expect(state.status?.rawValue == declared["statusRaw"] as? String, "\(state): statusRaw")
            #expect(state.marker?.rawValue == declared["marker"] as? String, "\(state): marker")
        }
        let reload = ((kit["persistedFields"] as? Object)?["statusRaw"] as? Object)?["reloadMarker"] as? Object ?? [:]
        #expect(ReplyStatus.reloadMarker(nil)?.rawValue == reload["nil"] as? String)
        for status in ReplyStatus.allCases {
            #expect(ReplyStatus.reloadMarker(status)?.rawValue == reload[status.rawValue] as? String, "\(status)")
        }
    }

    @Test func engineCacheVectorsReplay() throws {
        guard let kit = try ReplyMachineVectorsTests.kit() else { return }
        let cache = try #require(kit["engineCache"] as? Object)
        for vector in cache["vectors"] as? [Object] ?? [] {
            var epochs = EngineCacheEpochs()
            for event in vector["events"] as? [Object] ?? [] {
                switch event["event"] as? String {
                case "build": _ = epochs.build()
                case "evict": _ = epochs.evict()
                case "initialized": _ = epochs.initialized(epoch: event["epoch"] as? Int ?? -1)
                default: Issue.record("unknown engine cache event")
                }
            }
            let expect = try #require(vector["expect"] as? Object)
            #expect(epochs.state.rawValue == expect["state"] as? String, "\(vector["name"] ?? "?")")
            #expect(epochs.residentCount == expect["resident"] as? Int)
            #expect(epochs.epoch == expect["epoch"] as? Int)
        }
    }

    @Test func aStaleInitializeIsReleasedNotInserted() {
        var epochs = EngineCacheEpochs()
        let started = epochs.build()
        #expect(started == .startBuild(epoch: 0))
        #expect(epochs.evict() == .bumped(epoch: 1))
        #expect(epochs.initialized(epoch: 0) == .releaseStale)
        #expect(epochs.residentCount == 0)
    }
}
