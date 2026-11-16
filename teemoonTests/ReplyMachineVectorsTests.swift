//
//  ReplyMachineVectorsTests.swift
//  teemoonTests
//
//  conformance/reply-machine.json is the reply lifecycle Android ports from (pm ios-state-machines Tier 2, G1–G8).
//  These tests hold the kit to itself: every name it uses is declared, every state is reachable, terminal states
//  persist a statusRaw and restart only through the restart events, and every vector replays through the kit's own
//  table to the outcome it states. No app type is involved yet.
//

import Foundation
import Testing

@Suite("reply-machine.json is internally consistent")
struct ReplyMachineVectorsTests {
    typealias Object = [String: Any]

    static func kit(file: String = #filePath) throws -> Object? {
        guard TestFixture.sourceTreeAvailable() else { return nil }
        let url = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conformance/reply-machine.json")
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? Object)
    }

    static func states(_ kit: Object) -> [String: Object] { kit["states"] as? [String: Object] ?? [:] }
    static func events(_ kit: Object) -> [String: Object] { kit["events"] as? [String: Object] ?? [:] }
    static func transitions(_ kit: Object) -> [Object] { kit["transitions"] as? [Object] ?? [] }
    static func vectors(_ kit: Object) -> [Object] { kit["vectors"] as? [Object] ?? [] }
    static func statusValues(_ kit: Object) -> Set<String> {
        let fields = kit["persistedFields"] as? Object
        return Set((fields?["statusRaw"] as? Object)?["values"] as? [String] ?? [])
    }

    @Test func header() throws {
        guard let kit = try Self.kit() else { return }
        #expect(kit["fixtureClass"] as? String == "reply-machine")
        #expect(kit["kitVersion"] as? String == "0.6.6")
        #expect(kit["sourceOfTruth"] as? String == "teemoon-ios")
        #expect(!((kit["rule"] as? String) ?? "").isEmpty)
    }

    @Test func everyNameInTheTableIsDeclared() throws {
        guard let kit = try Self.kit() else { return }
        let states = Self.states(kit), events = Self.events(kit)
        let ops = Set((kit["ops"] as? Object)?.keys.map { $0 } ?? [])
        let guards = Set((kit["guards"] as? Object)?.keys.map { $0 } ?? [])
        #expect(states[kit["initialState"] as? String ?? ""] != nil)
        for row in Self.transitions(kit) {
            let label = "\(row["from"] ?? "?") × \(row["event"] ?? "?")"
            #expect(states[row["from"] as? String ?? ""] != nil, "\(label): from")
            #expect(states[row["to"] as? String ?? ""] != nil, "\(label): to")
            #expect(events[row["event"] as? String ?? ""] != nil, "\(label): event")
            for op in row["ops"] as? [String] ?? [] { #expect(ops.contains(op), "\(label): op \(op)") }
            for key in (row["when"] as? Object)?.keys.map({ $0 }) ?? [] { #expect(guards.contains(key), "\(label): guard \(key)") }
            #expect(!((row["effects"] as? [String]) ?? []).isEmpty, "\(label): effects")
        }
    }

    @Test func noTwoRowsMatchTheSameStateEventAndGuard() throws {
        guard let kit = try Self.kit() else { return }
        var seen = Set<String>()
        for row in Self.transitions(kit) {
            let when = (row["when"] as? Object).map { w in w.keys.sorted().map { "\($0)=\(w[$0]!)" }.joined(separator: ",") } ?? ""
            let key = "\(row["from"]!)|\(row["event"]!)|\(when)"
            #expect(seen.insert(key).inserted, "duplicate row \(key)")
        }
    }

    @Test func everyStateIsReachable() throws {
        guard let kit = try Self.kit() else { return }
        let initial = try #require(kit["initialState"] as? String)
        var reached: Set<String> = [initial], frontier = [initial]
        while let state = frontier.popLast() {
            for row in Self.transitions(kit) where row["from"] as? String == state {
                if let to = row["to"] as? String, reached.insert(to).inserted { frontier.append(to) }
            }
        }
        #expect(reached == Set(Self.states(kit).keys))
    }

    @Test func everyLiveStateCanEnd() throws {
        guard let kit = try Self.kit() else { return }
        let states = Self.states(kit)
        for (name, state) in states where state["kind"] as? String == "live" {
            let events = Set(Self.transitions(kit).filter { $0["from"] as? String == name }.compactMap { $0["event"] as? String })
            #expect(events.isSuperset(of: ["userStop", "appKilled", "deleteChat", "retry", "thinkHarder"]), "\(name) lacks an exit")
        }
    }

    @Test func everyTerminalStatePersistsAStatusRaw() throws {
        guard let kit = try Self.kit() else { return }
        let states = Self.states(kit), values = Self.statusValues(kit)
        let terminal = try #require(kit["terminalStates"] as? [String])
        #expect(Set(terminal) == Set(states.filter { $0.value["kind"] as? String == "terminal" }.keys))
        for name in terminal {
            let state = try #require(states[name])
            #expect(state.keys.contains("statusRaw"), "\(name) has no statusRaw")
            switch state["persist"] as? String {
            case "kept":
                #expect(values.contains(state["statusRaw"] as? String ?? ""), "\(name) persists an undeclared statusRaw")
            case "untouched", "deleted":
                #expect(state["statusRaw"] is NSNull, "\(name) writes no row, so no statusRaw")
            default:
                Issue.record("\(name): persist must be kept, untouched or deleted")
            }
        }
        // The value written at turn start, read back at launch, is one of the persisted values.
        #expect(values.contains("interrupted"))
    }

    @Test func terminalStatesRestartOnlyThroughRestartEvents() throws {
        guard let kit = try Self.kit() else { return }
        let terminal = Set(kit["terminalStates"] as? [String] ?? [])
        let restart = Set(kit["restartEvents"] as? [String] ?? [])
        #expect(restart.isSubset(of: Set(Self.events(kit).keys)))
        for row in Self.transitions(kit) where terminal.contains(row["from"] as? String ?? "") {
            #expect(restart.contains(row["event"] as? String ?? ""), "\(row["from"]!) × \(row["event"]!)")
        }
    }

    @Test func markersAreIdsAndCoverEveryStatus() throws {
        guard let kit = try Self.kit() else { return }
        let markers = Set((kit["markers"] as? Object)?.keys.map { $0 } ?? [])
        #expect(markers == ["marker.didntFinish", "marker.stopped", "marker.cutShort", "marker.decryptFailed"])
        let reload = try #require(((kit["persistedFields"] as? Object)?["statusRaw"] as? Object)?["reloadMarker"] as? Object)
        #expect(Set(reload.keys) == Self.statusValues(kit).union(["nil"]))
        for (_, marker) in reload { if let id = marker as? String { #expect(markers.contains(id)) } }
        for (name, state) in Self.states(kit) { if let id = state["marker"] as? String { #expect(markers.contains(id), "\(name)") } }
    }

    @Test func everyBugHasAVector() throws {
        guard let kit = try Self.kit() else { return }
        let cache = (kit["engineCache"] as? Object)?["vectors"] as? [Object] ?? []
        let bugs = Set((Self.vectors(kit) + cache).compactMap { $0["bug"] as? String })
        #expect(bugs == Set((1...8).map { "G\($0)" }))
        let named = Set(Self.vectors(kit).compactMap { $0["name"] as? String })
        #expect(named.count == Self.vectors(kit).count, "vector names are unique")
    }

    @Test func platformNotesNameRealVectors() throws {
        guard let kit = try Self.kit() else { return }
        let names = Set(Self.vectors(kit).compactMap { $0["name"] as? String })
        for note in kit["platformNotes"] as? [Object] ?? [] {
            #expect(!((note["note"] as? String) ?? "").isEmpty)
            for name in note["vectors"] as? [String] ?? [] { #expect(names.contains(name), "\(name)") }
        }
    }

    @Test func vectorsUseOnlyDeclaredNames() throws {
        guard let kit = try Self.kit() else { return }
        let events = Self.events(kit), states = Self.states(kit), values = Self.statusValues(kit)
        let recordKey = try Regex(#"^(pending|failed)\|\d+\|.+$"#)
        for vector in Self.vectors(kit) {
            let name = vector["name"] as? String ?? "?"
            for event in vector["events"] as? [Object] ?? [] {
                let kind = event["event"] as? String ?? ""
                let declared = try #require(events[kind], "\(name): undeclared event \(kind)")
                let payload = Set(declared["payload"] as? [String] ?? []).union(["event"])
                #expect(Set(event.keys).isSubset(of: payload), "\(name): \(kind) carries undeclared fields")
            }
            let expect = try #require(vector["expect"] as? Object)
            #expect(states[expect["state"] as? String ?? ""] != nil, "\(name): undeclared state")
            for row in expect["rows"] as? [Object] ?? [] {
                if let raw = row["statusRaw"] as? String { #expect(values.contains(raw), "\(name): statusRaw \(raw)") }
                if let sbc = row["sentBeforeConfirmed"] as? String { #expect(sbc.wholeMatch(of: recordKey) != nil, "\(name): \(sbc)") }
            }
        }
    }

    @Test func vectorsReplayThroughTheTable() throws {
        guard let kit = try Self.kit() else { return }
        let reload = ((kit["persistedFields"] as? Object)?["statusRaw"] as? Object)?["reloadMarker"] as? Object ?? [:]
        for vector in Self.vectors(kit) {
            let name = vector["name"] as? String ?? "?"
            var replay = ReplyKitReplay(kit: kit, given: vector["given"] as? [Object] ?? [])
            let checkpoints = vector["checkpoints"] as? [Object] ?? []
            for (index, event) in (vector["events"] as? [Object] ?? []).enumerated() {
                try replay.apply(event, index: index)
                for point in checkpoints where point["after"] as? Int == index {
                    #expect(replay.state == point["state"] as? String, "\(name) after \(index)")
                    #expect(replay.live == point["live"] as? Int, "\(name) after \(index): live")
                    if let armed = point["resumeArmed"] as? Bool { #expect(replay.armed == armed, "\(name) after \(index)") }
                }
            }
            let expect = try #require(vector["expect"] as? Object)
            #expect(replay.state == expect["state"] as? String, "\(name): state")
            #expect(replay.live == expect["live"] as? Int, "\(name): live")
            #expect(replay.ignored == (expect["ignored"] as? [Int] ?? []), "\(name): ignored")
            #expect(replay.armed == (expect["resumeArmed"] as? Bool ?? false), "\(name): resumeArmed")
            let rows = (expect["rows"] as? [Object] ?? []).map(ReplyKitRow.init)
            #expect(replay.rows.values.sorted { $0.generation < $1.generation } == rows, "\(name): rows")
            for (generation, marker) in expect["markers"] as? [String: String] ?? [:] {
                let raw = replay.rows[Int(generation) ?? -1]?.statusRaw ?? "nil"
                #expect(reload[raw] as? String == marker, "\(name): reload marker of \(generation)")
            }
            if let marker = expect["sessionMarker"] as? String {
                #expect(Self.states(kit)[replay.state]?["marker"] as? String == marker, "\(name): session marker")
            }
            if let requests = expect["requests"] as? [Object] {
                #expect(replay.requests == requests.map { [$0["generation"] as? Int ?? -1, $0["images"] as? Int ?? -1] }, "\(name): requests")
            }
            if let turns = expect["userTurns"] as? Int { #expect(replay.userTurns == turns, "\(name): user turns") }
            if let draft = expect["draft"] as? String { #expect(replay.draft == draft, "\(name): draft") }
            if let returned = expect["returned"] as? [Int] { #expect(replay.returned == returned, "\(name): returned") }
        }
    }

    @Test func engineCacheVectorsReplay() throws {
        guard let kit = try Self.kit() else { return }
        let cache = try #require(kit["engineCache"] as? Object)
        let rows = cache["transitions"] as? [Object] ?? []
        let states = Set(cache["states"] as? [String] ?? []), events = Set(cache["events"] as? [String] ?? [])
        for row in rows {
            #expect(states.contains(row["from"] as? String ?? "") && states.contains(row["to"] as? String ?? ""))
            #expect(events.contains(row["event"] as? String ?? ""))
        }
        for vector in cache["vectors"] as? [Object] ?? [] {
            var state = "empty", epoch = 0
            for event in vector["events"] as? [Object] ?? [] {
                let kind = event["event"] as? String ?? ""
                if kind == "evict" { epoch += 1 }
                let current = (event["epoch"] as? Int).map { $0 == epoch }
                let row = rows.first { row in
                    guard row["from"] as? String == state, row["event"] as? String == kind else { return false }
                    guard let want = (row["when"] as? Object)?["epochCurrent"] as? Bool else { return true }
                    return want == current
                }
                if let to = row?["to"] as? String { state = to }
            }
            let expect = try #require(vector["expect"] as? Object)
            #expect(state == expect["state"] as? String, "\(vector["name"] ?? "?")")
            #expect((state == "resident" ? 1 : 0) == expect["resident"] as? Int)
            #expect(epoch == expect["epoch"] as? Int)
        }
    }
}

/// A persisted reply row as the vectors state it.
struct ReplyKitRow: Equatable {
    var generation: Int
    var statusRaw: String?
    var content: String
    var sources: Int
    var sentBeforeConfirmed: String?

    init(generation: Int, statusRaw: String?, content: String, sources: Int, sentBeforeConfirmed: String?) {
        self.generation = generation; self.statusRaw = statusRaw; self.content = content
        self.sources = sources; self.sentBeforeConfirmed = sentBeforeConfirmed
    }

    init(_ o: [String: Any]) {
        self.init(generation: o["generation"] as? Int ?? -1, statusRaw: o["statusRaw"] as? String,
                  content: o["content"] as? String ?? "", sources: o["sources"] as? Int ?? 0,
                  sentBeforeConfirmed: o["sentBeforeConfirmed"] as? String)
    }
}

/// Runs vectors through the kit's own table and ops, exactly as the kit's `ops` and `staleRule` describe them.
/// It stands in for nothing in the app: it proves the vectors agree with the table they ship with.
struct ReplyKitReplay {
    typealias Object = [String: Any]
    struct Generation { var place: String; var supersedes: [Int]; var text = ""; var sources = 0; var sbc: String?; var images = 0; var origin = "send"; var replaces: [Int] = []; var sent = false
        var isRetry: Bool { ["retry", "reverifyRetry", "autoResume"].contains(origin) }
        var unsentRetry: Bool { isRetry && !sent }
    }

    let kit: Object
    var state: String
    var live: Int?
    var highest = 0
    var armed = false
    var generations: [Int: Generation] = [:]
    var rows: [Int: ReplyKitRow] = [:]
    var ignored: [Int] = []
    var requests: [[Int]] = []
    var userTurns = 0
    var draft: String?
    var returned: [Int] = []
    private var questionImages = 0

    init(kit: Object, given: [Object]) {
        self.kit = kit
        state = kit["initialState"] as? String ?? "idle"
        for row in given.map(ReplyKitRow.init) { rows[row.generation] = row; highest = max(highest, row.generation) }
    }

    mutating func apply(_ event: Object, index: Int) throws {
        let kind = try #require(event["event"] as? String)
        if kind == "draftEdited" { draft = "kept" }
        let category = (ReplyMachineVectorsTests.events(kit)[kind]?["category"] as? String) ?? ""
        if category == "engine" || category == "gate" || kind == "confirm" || kind == "decline",
           event["generation"] as? Int != live {
            ignored.append(index); return
        }
        if kind == "reverifyRetry", event["captured"] as? Int != highest { ignored.append(index); return }

        let current = live.flatMap { generations[$0] }
        let facts: Object = [
            "supersedes": !(current?.supersedes.isEmpty ?? true),
            "hasText": !(current?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            "place": current?.place ?? "",
            "resumeArmed": armed,
            "reason": event["reason"] as? String ?? "",
            "origin": current?.origin ?? "",
            "unsentRetry": current?.unsentRetry ?? false,
            "restorable": (current?.unsentRetry ?? false) && (current?.replaces ?? []).contains { g in
                guard let row = rows[g] else { return false }
                return !row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !["interrupted", "failed", "decryptFailed"].contains(row.statusRaw ?? "")
            },
        ]
        let match = ReplyMachineVectorsTests.transitions(kit).first { row in
            guard row["from"] as? String == state, row["event"] as? String == kind else { return false }
            return ((row["when"] as? Object) ?? [:]).allSatisfy { key, want in
                if let options = want as? [String] { return options.contains(facts[key] as? String ?? "") }
                if let flag = want as? Bool { return facts[key] as? Bool == flag }
                return facts[key] as? String == want as? String
            }
        }
        guard let row = match, let to = row["to"] as? String else { return }
        for op in row["ops"] as? [String] ?? [] { try run(op, event: event, to: to) }
        state = to
    }

    private mutating func run(_ op: String, event: Object, to: String) throws {
        switch op {
        case "retireLive":
            if let g = live, let c = generations[g], c.supersedes.isEmpty, !c.unsentRetry {
                rows[g] = ReplyKitRow(generation: g, statusRaw: "stopped", content: c.text, sources: c.sources, sentBeforeConfirmed: c.sbc)
            }
            live = nil
        case "deleteRows":
            for g in event["replaces"] as? [Int] ?? [] { rows[g] = nil }
        case "persistQuestion":
            userTurns += 1
            questionImages = event["images"] as? Int ?? 0
            if draft == "kept" { draft = "consumed" }
        case "returnQuestion":
            userTurns -= 1
            returned.append(try #require(live))
        case "sendRequest":
            let g = try #require(live)
            if let c = generations[g], c.unsentRetry {
                for old in c.replaces { rows[old] = nil }
                rows[g] = ReplyKitRow(generation: g, statusRaw: "interrupted", content: "", sources: 0, sentBeforeConfirmed: c.sbc)
            }
            generations[g]?.sent = true
            requests.append([g, generations[g]?.images ?? 0])
        case "newGeneration":
            let g = try #require(event["generation"] as? Int)
            live = g; highest = max(highest, g); armed = false
            generations[g] = Generation(place: event["place"] as? String ?? "remote", supersedes: event["supersedes"] as? [Int] ?? [],
                                        images: event["event"] as? String == "send" ? questionImages : 0,
                                        origin: event["event"] as? String ?? "", replaces: event["replaces"] as? [Int] ?? [])
            questionImages = 0
        case "writeLiveRow":
            if let g = live, generations[g]?.supersedes.isEmpty == true {
                rows[g] = ReplyKitRow(generation: g, statusRaw: "interrupted", content: "", sources: 0, sentBeforeConfirmed: nil)
            }
        case "setSentBeforeConfirmed":
            let g = try #require(live)
            generations[g]?.sbc = event["sentBeforeConfirmed"] as? String
            rows[g]?.sentBeforeConfirmed = event["sentBeforeConfirmed"] as? String
        case "appendText":
            generations[try #require(live)]?.text += event["text"] as? String ?? ""
        case "appendSources":
            generations[try #require(live)]?.sources += event["sources"] as? Int ?? 0
        case "armResumeUnlessSupersedes":
            armed = generations[try #require(live)]?.supersedes.isEmpty ?? false
        case "disarmResume":
            armed = false
        case "kill":
            live = nil
        case "end":
            let g = try #require(live), c = try #require(generations[g])
            let target = try #require(ReplyMachineVectorsTests.states(kit)[to])
            if c.unsentRetry, to != "restored" { for old in c.replaces { rows[old] = nil } }
            switch target["persist"] as? String {
            case "kept":
                let content = target["content"] as? String == "textSoFar" ? c.text : ""
                rows[g] = ReplyKitRow(generation: g, statusRaw: target["statusRaw"] as? String, content: content,
                              sources: c.sources, sentBeforeConfirmed: c.sbc)
                if !c.supersedes.isEmpty, to == "complete" || to == "cutOff" { for old in c.supersedes { rows[old] = nil } }
            case "deleted":
                rows[g] = nil
            default:
                break
            }
            live = nil
        default:
            Issue.record("undeclared op \(op)")
        }
    }
}
