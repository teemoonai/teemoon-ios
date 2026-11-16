//
//  ActionLogBindingTests.swift
//  teemoonTests
//
//  Trust scope (a) and (b) against audit's live glm-5-3-flash report (conformance/nearai-trust, gpu04,
//  2026-10-30T22:41Z) and the spec's mutation set: flip one byte in any action → (a) actions hash fails;
//  swap the nonce → (a) nonce fails; reorder two imr-3 entries → (b) fails.
//

import CryptoKit
import Foundation
import Testing
@testable import teemoon

@Suite("Trust scope — the action log and the boot log are bound to the hardware")
struct ActionLogBindingTests {
    struct Fixture {
        let report: [String: Any]
        let expected: [String: Any]
        var cma: [String: Any] { report["compose_manager_attestation"] as! [String: Any] }
        var actions: Any { cma["actions"]! }
        var cmQuote: Data { try! Data(hexString: cma["quote"] as! String) }
        var nodeQuote: Data { try! Data(hexString: report["intel_quote"] as! String) }
        var nonce: Data { try! Data(hexString: expected["request_nonce_sent"] as! String) }
        var tcb: [String: Any] { (report["info"] as! [String: Any])["tcb_info"] as! [String: Any] }
        var osImageHash: Data { try! Data(hexString: (report["info"] as! [String: Any])["os_image_hash"] as! String) }
    }

    static func fixture(file: String = #filePath) throws -> Fixture? {
        guard TestFixture.sourceTreeAvailable() else { return nil }
        let dir = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conformance/nearai-trust")
        let report = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("glm-5-3-flash-gpu04-5f7ebd85-2026-10-30T2241Z.json")))
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("expected.json")))
        return Fixture(report: report as! [String: Any], expected: expected as! [String: Any])
    }

    private func bind(_ f: Fixture, actions: Any? = nil, nonce: Data? = nil) -> ActionLogBinding.Result {
        ActionLogBinding.check(actions: actions ?? f.actions, cmQuote: f.cmQuote, nodeQuote: f.nodeQuote,
                               nonce: nonce ?? f.nonce, hardware: .verified, tcb: .agree)
    }

    @Test func theCanonicalActionsAreAuditsBytes() throws {
        guard let f = try Self.fixture() else { return }
        let preimage = try #require(ActionLogBinding.canonical(f.actions))
        #expect(preimage.count == f.expected["canonical_actions_sha256_preimage_len"] as? Int)
        #expect(Data(SHA256.hash(data: preimage)).hexString == f.expected["actions_hash_recomputed"] as? String)
    }

    @Test func theLiveReportIsBound() throws {
        guard let f = try Self.fixture() else { return }
        #expect(bind(f) == .bound)
        let node = try #require(TDReport(quote: f.nodeQuote))
        let model = try #require(f.expected["model_node_quote"] as? [String: Any])
        #expect(node.rtmr3.hexString == model["rtmr3"] as? String && node.mrtd.hexString == model["mrtd"] as? String)
    }

    @Test func aChangedActionANewNonceOrAnotherEnclaveBreaksIt() throws {
        guard let f = try Self.fixture() else { return }
        var tampered = f.actions as! [[String: Any]]
        tampered[0]["timestamp"] = "2026-09-02T18:25:33.145082058+00:00"
        #expect(bind(f, actions: tampered) == .mismatch(.actionsHash))
        var other = f.nonce; other[0] ^= 1
        #expect(bind(f, nonce: other) == .mismatch(.nonce))
        var foreign = f.nodeQuote; foreign[48 + 136] ^= 1   // the node's mrtd
        #expect(ActionLogBinding.check(actions: f.actions, cmQuote: f.cmQuote, nodeQuote: foreign, nonce: f.nonce,
                                       hardware: .verified, tcb: .agree) == .mismatch(.sameTD))
        #expect(ActionLogBinding.check(actions: f.actions, cmQuote: f.cmQuote, nodeQuote: f.nodeQuote, nonce: f.nonce,
                                       hardware: .failed, tcb: .agree) == .mismatch(.quote))
        #expect(ActionLogBinding.check(actions: f.actions, cmQuote: f.cmQuote, nodeQuote: f.nodeQuote, nonce: f.nonce,
                                       hardware: .verified, tcb: .differ) == .mismatch(.tcbDiffers))
    }

    /// near-send-gate-rule (the maintainer 2026-11-06): Intel unreachable for either quote is not a mismatch.
    @Test func anIntelOutageIsUncheckedNotAMismatch() throws {
        guard let f = try Self.fixture() else { return }
        for (hw, tcb) in [(ActionLogBinding.Hardware.unchecked, ActionLogBinding.TCB.agree), (.verified, .unchecked), (.unchecked, .unchecked)] {
            #expect(ActionLogBinding.check(actions: f.actions, cmQuote: f.cmQuote, nodeQuote: f.nodeQuote, nonce: f.nonce,
                                           hardware: hw, tcb: tcb) == .unchecked)
        }
        var other = f.nonce; other[0] ^= 1
        #expect(ActionLogBinding.check(actions: f.actions, cmQuote: f.cmQuote, nodeQuote: f.nodeQuote, nonce: other,
                                       hardware: .unchecked, tcb: .unchecked) == .mismatch(.nonce),
                "the local checks still break hard while Intel is down")
        #expect(TrustScope.hardware(.unchecked("pcs down")) == .unchecked)
        #expect(TrustScope.hardware(.failed("bad signature")) == .failed)
        #expect(TrustScope.tcb(.unchecked("x"), .verified(tcbStatus: .upToDate, mrConfigIdHex: "", reportDataHex: "")) == .unchecked)
    }

    @Test func noComposeManagerQuoteIsNotBoundNotBroken() throws {
        guard let f = try Self.fixture() else { return }
        #expect(ActionLogBinding.check(actions: f.actions, cmQuote: nil, nodeQuote: f.nodeQuote, nonce: f.nonce,
                                       hardware: .failed, tcb: .agree) == .notBound)
    }

    @Test func theBootLogReplaysToTheQuote() throws {
        guard let f = try Self.fixture() else { return }
        let entries = try #require(BootLogReplay.entries(from: f.tcb["event_log"]))
        #expect(entries.count == 32 && entries.filter { $0.imr == 3 }.count == 12)
        #expect(entries.filter { $0.imr == 3 }.allSatisfy { BootLogReplay.digest(of: $0) == $0.digest })
        let node = try #require(TDReport(quote: f.nodeQuote))
        #expect(BootLogReplay.check(entries: entries, nodeRTMR3: node.rtmr3,
                                    appCompose: f.tcb["app_compose"] as? String, osImageHash: f.osImageHash) == .matches)
    }

    @Test func reorderedEventsOrAnotherComposeFileBreakTheReplay() throws {
        guard let f = try Self.fixture() else { return }
        var entries = try #require(BootLogReplay.entries(from: f.tcb["event_log"]))
        let node = try #require(TDReport(quote: f.nodeQuote))
        let compose = f.tcb["app_compose"] as? String
        #expect(BootLogReplay.check(entries: entries, nodeRTMR3: node.rtmr3, appCompose: (compose ?? "") + " ",
                                    osImageHash: f.osImageHash) == .mismatch(.composeHash))
        var other = f.osImageHash; other[0] ^= 1
        #expect(BootLogReplay.check(entries: entries, nodeRTMR3: node.rtmr3, appCompose: compose, osImageHash: other)
                == .mismatch(.osImageHash))
        let threes = entries.indices.filter { entries[$0].imr == 3 }
        entries.swapAt(threes[0], threes[1])
        #expect(BootLogReplay.check(entries: entries, nodeRTMR3: node.rtmr3, appCompose: compose, osImageHash: f.osImageHash)
                == .mismatch(.rtmr3))
        #expect(BootLogReplay.check(entries: nil, nodeRTMR3: node.rtmr3, appCompose: compose, osImageHash: f.osImageHash) == .absent)
    }

    @Test func imrAndEventTypeMayArriveAsStrings() {
        let rows: [[String: Any]] = [["imr": "3", "event_type": "134217729", "digest": String(repeating: "00", count: 48),
                                      "event": "x", "event_payload": ""]]
        #expect(BootLogReplay.entries(from: rows)?.first?.eventType == 134_217_729)
    }
}

@Suite("Trust scope — what the action log names as running")
struct ActionLogReadingTests {
    @Test func theRunningComposeManagerIsTheLastStart() throws {
        guard let f = try ActionLogBindingTests.fixture() else { return }
        let cm = try #require(f.expected["compose_manager"] as? [String: Any])
        let declared = try #require(ActionLogReading.digest(of: (cm["declared_default_in_measured_compose"] as? [String])?.first ?? ""))
        let seat = ActionLogReading.composeManager(actions: f.actions as! [[String: Any]], declared: declared)
        #expect(seat.declared == "6e035c8fb99c1d31f41760d25af178683a658cca4afd73cd0d366fbb5bf884be")
        #expect(seat.running == ActionLogReading.digest(of: cm["running_last_started"] as? String ?? ""))
        #expect(seat.differs && seat.source == .actionLog)
        #expect(ActionLogReading.composeManager(actions: [], declared: declared).source == .declaredOnly)
    }

    /// audit's mutation running_manager_no_page (expected.json b8c99a88): the live fleet since 2026-11-04 runs a
    /// compose manager with no audit page. Applied after (a) binds. The row must not borrow 6e035c8f's page.
    @Test func aRunningManagerWithNoPageIsUnreviewedNotTheDeclaredOnesReview() throws {
        guard let f = try ActionLogBindingTests.fixture() else { return }
        let mutations = try #require((f.expected["compose_manager"] as? [String: Any])?["mutations"] as? [[String: Any]])
        let m = try #require(mutations.first { $0["id"] as? String == "running_manager_no_page" })
        let expected = try #require(m["expected"] as? [String: Any])
        let newImage = try #require(expected["running_last_started"] as? String)
        var actions = f.actions as! [[String: Any]]
        let last = try #require(actions.lastIndex { $0["action"] as? String == "compose_manager_started" })
        actions[last]["image"] = newImage
        let declared = try #require(ActionLogReading.digest(of: expected["declared_default"] as? String ?? ""))
        let seat = ActionLogReading.composeManager(actions: actions, declared: declared)
        #expect(seat.running == ActionLogReading.digest(of: newImage) && seat.differs)
        let declaredPage = URL(string: "https://example.com/compose-manager/sha256-\(declared).md")!
        let pages = [declared: declaredPage]          // the index lists 6e035c8f only
        #expect(seat.review { pages[$0] } == .unreviewed, "the declared manager's page never covers the running one")
        #expect(ActionLogReading.composeManager(actions: [], declared: declared).review { pages[$0] } == .reviewed(declaredPage),
                "declared-only: its own page is the right one")
    }

    /// The whole-file bodies the log's entries name, as vendored under conformance/nearai-trust/compose-files,
    /// and every up revision's service names (up-revision-services.json, each body hash-checked when vendored).
    static func vendoredServices(file: String = #filePath) -> (ActionLogReading.Source) -> [String]? {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conformance/nearai-trust")
        let dir = root.appendingPathComponent("compose-files")
        struct Revisions: Decodable { let services: [String: [String]] }
        let revisions = (try? JSONDecoder().decode(Revisions.self,
            from: Data(contentsOf: root.appendingPathComponent("up-revision-services.json"))))?.services ?? [:]
        return { source in
            if let names = revisions["\(source.commit)/\(source.file)"] { return names }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(source.commit)/\(source.file)")),
                  source.fileSHA256.isEmpty || Data(SHA256.hash(data: data)).hexString == source.fileSHA256 else { return nil }
            return ActionLogReading.serviceNames(inCompose: String(decoding: data, as: UTF8.self))
        }
    }

    /// audit 2026-11-06, canonical (A): the whole log is walked and only whole files are fetched — four pairs.
    @Test func theRunningPairsAreAuditsUnderTheWholeFileRule() throws {
        guard let f = try ActionLogBindingTests.fixture() else { return }
        let pairs = try #require((f.expected["running_pairs"] as? [String: Any])?["pairs"] as? [[String: Any]])
        let table = ActionLogReading.runningServices(actions: f.actions as! [[String: Any]],
                                                     servicesIn: Self.vendoredServices())
        let (check, rest) = ActionLogReading.pairsToCheck(table)
        #expect(rest.isEmpty && pairs.count == 4)
        #expect(check.map { "\($0.commit) \($0.file)" } == pairs.map { "\($0["commit"] as! String) \($0["file"] as! String)" })
        for pair in pairs {
            let services = table.filter { $0.source.commit == pair["commit"] as? String && $0.source.file == pair["file"] as? String }
            #expect(Set(services.map(\.service)) == Set(pair["services"] as! [String]), "\(pair["file"]!)")
            #expect(services.allSatisfy { $0.source.fileSHA256 == pair["file_sha256"] as? String })
        }
        let dropped = ["2781fa66", "1121ee56", "0e55b0e7", "0a51138e"]
        #expect(!check.contains { s in dropped.contains { s.commit.hasPrefix($0) } }, "mutation #5: 1121ee56 is absent")
    }

    /// Mutation #9 (rule 3): every up runs --remove-orphans. A scoped up of the Q8Canary file at a revision
    /// without r4, after r4's up, retires r4, and the Q8Canary pair is gone.
    @Test func anyUpRetiresServicesItsRevisionLacks() throws {
        guard let f = try ActionLogBindingTests.fixture() else { return }
        var actions = f.actions as! [[String: Any]]
        let canary = "prod/GLM-5.3-Flash-SGL-TP2x4-W4AFP8-Q8Canary.yaml"
        let i = try #require(actions.lastIndex { $0["file"] as? String == canary
            && $0["services"] as? [String] == ["model-sg-glm53-w4afp8-tp2-r4"] })
        actions.insert(["action": "compose_up", "file": canary, "commit": "mut9", "file_sha256": "m9",
                        "services": ["proxy-glm53"], "timestamp": "2026-10-28T01:30:00Z"], at: i + 1)
        let vendored = Self.vendoredServices()
        let table = ActionLogReading.runningServices(actions: actions) { $0.commit == "mut9" ? ["proxy-glm53"] : vendored($0) }
        #expect(!table.contains { $0.service == "model-sg-glm53-w4afp8-tp2-r4" })
        #expect(!ActionLogReading.pairsToCheck(table).check.contains { $0.file == canary }, "listing it is red")
        let unmutated = ActionLogReading.runningServices(actions: f.actions as! [[String: Any]], servicesIn: vendored)
        #expect(ActionLogReading.pairsToCheck(unmutated).check.count == 4, "rule 3 leaves the fixture's four pairs")
    }

    /// Mutation #10: S in R1 and R3 but not R2 was removed as an orphan at R2's up. Bounding by R3 alone would
    /// give S back to R1; neither R1 nor an older file may claim it.
    @Test func aMiddleRevisionThatDroppedAServiceRetiresIt() {
        let actions: [[String: Any]] = [
            ["action": "compose_up", "file": "g.yaml", "commit": "g0", "file_sha256": "sg", "services": ["S"]],
            ["action": "compose_up", "file": "f.yaml", "commit": "r1", "file_sha256": "s1", "services": ["S", "X"]],
            ["action": "compose_up", "file": "f.yaml", "commit": "r2", "file_sha256": "s2", "services": ["X"]],
            ["action": "compose_up", "file": "f.yaml", "commit": "r3", "file_sha256": "s3", "services": ["Y"]],
        ]
        let revisions = ["g0": ["S"], "r1": ["S", "X"], "r2": ["X", "Y"], "r3": ["S", "X", "Y"]]
        let rows = ActionLogReading.runningServices(actions: actions) { revisions[$0.commit] }
        #expect(rows.map { "\($0.service)@\($0.source.commit)" } == ["Y@r3", "X@r2"])
    }

    @Test func everyUpRevisionIsFetchedOnce() throws {
        guard let f = try ActionLogBindingTests.fixture() else { return }
        let sources = ActionLogReading.upRevisionSources(actions: f.actions as! [[String: Any]])
        #expect(sources.count == 47 && Set(sources).count == 47)
    }

    /// Mutation #6: a cap on fetches changes only how many pairs are marked fetched, never the set.
    @Test func theCapNeverChangesWhichPairsAreListed() throws {
        guard let f = try ActionLogBindingTests.fixture() else { return }
        let table = ActionLogReading.runningServices(actions: f.actions as! [[String: Any]],
                                                     servicesIn: Self.vendoredServices())
        let all = ActionLogReading.pairsToCheck(table).check
        for cap in 0...all.count {
            let (check, rest) = ActionLogReading.pairsToCheck(table, cap: cap)
            #expect(check + rest == all && check.count == cap)
        }
    }

    /// Mutation #5: a whole-file up of F, newer than a service-scoped up of F that named S, where the new
    /// revision has no S. S isn't running and the older pair isn't listed.
    @Test func aWholeFileUpRetiresServicesItsRevisionDropped() {
        let actions: [[String: Any]] = [
            ["action": "compose_up", "file": "f.yaml", "commit": "old", "file_sha256": "s1", "services": ["r1", "r2"], "timestamp": "1"],
            ["action": "compose_up", "file": "f.yaml", "commit": "new", "file_sha256": "s2", "timestamp": "2"],
        ]
        let rows = ActionLogReading.runningServices(actions: actions) { $0.commit == "new" ? ["dp0", "dp1"] : nil }
        #expect(rows.map(\.service) == ["dp0", "dp1"])
        #expect(ActionLogReading.pairsToCheck(rows).check.map(\.commit) == ["new"])
    }

    @Test func aNewerEntryDecidesBeforeAnOlderWholeFile() {
        let actions: [[String: Any]] = [
            ["action": "compose_up", "file": "f.yaml", "commit": "c1", "file_sha256": "s1", "timestamp": "1"],
            ["action": "compose_down", "file": "f.yaml", "commit": "c1", "file_sha256": "s1", "services": ["y"], "timestamp": "2"],
            ["action": "compose_up", "file": "g.yaml", "commit": "c2", "file_sha256": "s2", "services": ["x"], "timestamp": "3"],
        ]
        let rows = ActionLogReading.runningServices(actions: actions) { _ in ["x", "y", "z"] }
        #expect(rows.map { "\($0.service)@\($0.source.commit)" } == ["x@c2", "z@c1"])
    }

    @Test func aWholeFileDownTakesTheFile() {
        let actions: [[String: Any]] = [
            ["action": "compose_up", "file": "a.yaml", "commit": "c1", "file_sha256": "s1", "services": ["x", "y"], "timestamp": "1"],
            ["action": "compose_up", "file": "b.yaml", "commit": "c2", "file_sha256": "s2", "services": ["z"], "timestamp": "2"],
            ["action": "compose_down", "file": "a.yaml", "commit": "c1", "file_sha256": "s1", "timestamp": "3"],
        ]
        #expect(ActionLogReading.runningServices(actions: actions) { _ in ["x", "y"] }.map(\.service) == ["z"])
        let back = actions + [["action": "compose_up", "file": "a.yaml", "commit": "c3", "file_sha256": "s3", "services": ["x"], "timestamp": "4"]]
        #expect(ActionLogReading.runningServices(actions: back) { _ in ["x", "y"] }.map(\.service) == ["x", "z"])
    }

    /// A whole file that can't be read is one row with services unknown; it still retires its own file's older
    /// entries, and the walk goes on.
    @Test func anUnreadableWholeFileStillSupersedesItsFile() {
        let actions: [[String: Any]] = [
            ["action": "compose_up", "file": "g.yaml", "commit": "c0", "file_sha256": "s0", "services": ["other"], "timestamp": "0"],
            ["action": "compose_up", "file": "f.yaml", "commit": "c0", "file_sha256": "s0f", "services": ["old"], "timestamp": "1"],
            ["action": "compose_up", "file": "f.yaml", "commit": "c1", "file_sha256": "s1", "timestamp": "2"],
            ["action": "compose_up", "file": "h.yaml", "commit": "c2", "file_sha256": "s2", "services": ["x"], "timestamp": "3"],
        ]
        let rows = ActionLogReading.runningServices(actions: actions) { _ in nil }
        #expect(rows.map { "\($0.service)@\($0.source.commit)" } == ["x@c2", "@c1", "other@c0"])
    }

    /// audit 2026-11-06, per service: rotate-token is undecidable, evicted (or not) by entry 76, the
    /// 2026-09-30T19:49:51Z TP4-W4AFP8 up whose revision lacks the name. Every other service runs, so the
    /// three other pairs are running and rotate-token's pair is the one leftover.
    @Test func livenessIsAuditsPerService() throws {
        guard let f = try ActionLogBindingTests.fixture() else { return }
        let actions = f.actions as! [[String: Any]]
        let pairs = try #require((f.expected["running_pairs"] as? [String: Any])?["pairs"] as? [[String: Any]])
        let running = ActionLogReading.runningServices(actions: actions, servicesIn: Self.vendoredServices())
        let undecidable = ActionLogReading.undecidableServices(actions: actions, running: running, servicesIn: Self.vendoredServices())
        #expect(undecidable == ["rotate-token": 76])
        for pair in pairs {
            let services = running.filter { $0.source.file == pair["file"] as? String }.map(\.service)
            let leftover = services.allSatisfy { undecidable[$0] != nil }
            #expect(leftover == (pair["liveness"] as? String == "undecidable"), "\(pair["file"]!)")
        }
    }

    /// Mutation #7: rotate-token's up moved after every other up → running.
    /// Mutation #8: an up of another file after everything, whose revision defines only "late" → every service
    /// but that one undecidable.
    @Test func livenessMutations() throws {
        guard let f = try ActionLogBindingTests.fixture() else { return }
        var actions = f.actions as! [[String: Any]]
        let rotate = "prod/rotate-compose-manager-token.yaml"
        let i = try #require(actions.firstIndex { $0["file"] as? String == rotate })
        var moved = actions
        moved.append(moved.remove(at: i))
        let movedRunning = ActionLogReading.runningServices(actions: moved, servicesIn: Self.vendoredServices())
        #expect(ActionLogReading.undecidableServices(actions: moved, running: movedRunning, servicesIn: Self.vendoredServices())["rotate-token"] == nil)

        actions.append(["action": "compose_up", "file": "prod/late.yaml", "commit": "c", "file_sha256": "s", "timestamp": "2026-10-30T00:00:00Z"])
        let names = { (s: ActionLogReading.Source) in s.file == "prod/late.yaml" ? ["late"] : Self.vendoredServices()(s) }
        let running = ActionLogReading.runningServices(actions: actions, servicesIn: names)
        let undecidable = ActionLogReading.undecidableServices(actions: actions, running: running, servicesIn: names)
        #expect(Set(running.map(\.service)).subtracting(undecidable.keys) == ["late"])
    }

    @Test func aNameTheLaterFileAlsoDefinesIsNotAnOrphanAndDownsNeverCount() {
        let actions: [[String: Any]] = [
            ["action": "compose_up", "file": "a.yaml", "commit": "c1", "file_sha256": "s1", "services": ["x", "shared"]],
            ["action": "compose_down", "file": "b.yaml", "commit": "c2"],
            ["action": "compose_up", "file": "c.yaml", "commit": "c3", "file_sha256": "s3", "services": ["y"]],
        ]
        let names = ["c1": ["x", "shared"], "c3": ["y", "shared"]]
        let running = ActionLogReading.runningServices(actions: actions) { names[$0.commit] }
        let undecidable = ActionLogReading.undecidableServices(actions: actions, running: running) { names[$0.commit] }
        #expect(undecidable == ["x": 2], "x: c.yaml's up lacks it; shared: c.yaml defines it; the down never counts")
        let unread = ActionLogReading.undecidableServices(actions: actions, running: running) { $0.commit == "c3" ? nil : names[$0.commit] }
        #expect(unread.keys.sorted() == ["shared", "x"], "an unreadable later revision counts as evicting")
    }

    /// The proxy that answered this report is alive: a later up of another file lacking its name didn't evict
    /// its file, so that file's ups count against nothing in the proxy's file (gpu13, sage-pull).
    @Test func theAnsweringProxyRefutesAnEviction() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let actions = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: ChatPathTests.kit
            .appendingPathComponent("actions-5e513dbd72e1-2026-11-04T1933Z.json"))) as? [[String: Any]])
        let names = Self.vendoredServices()
        let running = ActionLogReading.runningServices(actions: actions, servicesIn: names)
        let unrefuted = ActionLogReading.undecidableServices(actions: actions, running: running, servicesIn: names)
        #expect(unrefuted.count > 20, "precondition: sage-pull's later whole-file up reads as evicting the serving stack")
        let alive = running.filter { s in
            ChatPathTests.body(s.source).map { ChatPath.Compose($0).services[s.service]?.modelName == "Qwen/Qwen3.8-27B" } == true
        }
        #expect(alive.map(\.service) == ["proxy-qwen38-27b"], "MODEL_NAME matches exactly, not by prefix")
        #expect(ActionLogReading.undecidableServices(actions: actions, running: running, servicesIn: names, alive: alive).isEmpty)
    }

    @Test func aDownIsHashCheckedAgainstAnUpOfTheSameRevision() {
        let actions: [[String: Any]] = [
            ["action": "compose_up", "file": "p.yaml", "commit": "c1", "file_sha256": "pin", "services": ["x"]],
            ["action": "compose_down", "file": "p.yaml", "commit": "c1"],
            ["action": "compose_down", "file": "q.yaml", "commit": "c9"],
        ]
        let sources = ActionLogReading.wholeFileSources(actions: actions)
        #expect(sources.first { $0.file == "p.yaml" }?.fileSHA256 == "pin")
        #expect(sources.first { $0.file == "q.yaml" }?.fileSHA256 == "", "no up pins it: read unhashed")
        var seen: [ActionLogReading.Source] = []
        _ = ActionLogReading.runningServices(actions: actions) { seen.append($0); return ["x"] }
        #expect(seen.allSatisfy { s in sources.contains(s) }, "the walk asks for exactly the prefetched sources")
    }

    @Test func onlyTheNewestWholeFileOfEachFileIsFetched() throws {
        guard let f = try ActionLogBindingTests.fixture() else { return }
        let sources = ActionLogReading.wholeFileSources(actions: f.actions as! [[String: Any]])
        #expect(Set(sources.map(\.file)).count == sources.count)
        #expect(sources.contains { $0.commit.hasPrefix("cd948600") && $0.file == "prod/GLM-5.3-Flash-SGL-TP2x4-W4AFP8.yaml" })
        #expect(!sources.contains { $0.commit.hasPrefix("2781fa66") && $0.file == "prod/sage.yaml" }, "an older whole file of sage.yaml is dead")
    }
}

@Suite("Trust scope — one record, all checks", .serialized)
struct TrustScopeRunTests {
    private func checker() -> RunningPairCheck {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Offline.self]
        return RunningPairCheck(session: URLSession(configuration: config),
                                defaults: UserDefaults(suiteName: "scope-\(UUID().uuidString)")!)
    }
    private static let ok = DCAPVerification.verified(tcbStatus: .upToDate, mrConfigIdHex: "", reportDataHex: "")

    private func run(_ f: ActionLogBindingTests.Fixture, cm: DCAPVerification?) async throws -> TrustScope {
        let bytes = try JSONSerialization.data(withJSONObject: f.report)
        return try #require(await TrustScope.run(
            reportJSON: bytes, nodeQuoteHex: f.report["intel_quote"] as? String,
            nonceHex: f.expected["request_nonce_sent"] as? String,
            dcap: { _ in cm }, nodeDCAP: Self.ok, pairs: checker()))
    }

    @Test func theLiveReportIsBoundReplaysAndNamesItsRunningServices() async throws {
        guard let f = try ActionLogBindingTests.fixture() else { return }
        let scope = try await run(f, cm: Self.ok)
        #expect(scope.binding == .bound && scope.boot == .matches)
        #expect(scope.composeManager?.running == "a320bb4882341c8e19ef1944436f6591ed73303732009ed5db9f6db6c9da756a")
        #expect(scope.running.count == 16, "offline: every whole file unreadable, so four rows read services unknown")
        #expect(scope.running.filter { $0.service.service.isEmpty }.count == 4)
        #expect(scope.running.allSatisfy { $0.outcome == .inconclusive }, "offline: every fetched pair inconclusive")
        #expect(!scope.hardBreak)
    }

    @Test func aComposeManagerQuoteThatFailsDCAPIsAHardBreak() async throws {
        guard let f = try ActionLogBindingTests.fixture() else { return }
        let scope = try await run(f, cm: .failed("collateral"))
        #expect(scope.binding == .mismatch(.quote) && scope.hardBreak)
        #expect(scope.composeManager == nil, "nothing from an unbound log is read as running")
    }

    @Test func theDeclaredManagerComesFromTheMeasuredCompose() {
        #expect(TrustScope.declaredComposeManager(in: "image: ${COMPOSE_MANAGER_IMAGE:-nearaidev/compose-manager@sha256:"
                                                  + String(repeating: "6e", count: 32) + "}") == String(repeating: "6e", count: 32))
    }
}

private final class Offline: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}


/// near-trust-scope (the maintainer 2026-11-06): which approved line each result gets.
@Suite("Trust scope — the lines on the screen")
struct TrustScopeLineTests {
    /// near-trust-scope: "signed" only once (a) is bound. Android's broken golden showed it under a mismatch.
    @Test func signedOnlyOnceTheLogIsBound() {
        #expect(TrustScopeText.seamCaption(.bound) == "pinned by the signed action log")
        #expect(TrustScopeText.deploymentSuffix(.bound) == " · per the signed action log")
        let unbound: [ActionLogBinding.Result?] = [nil, .notBound, .unchecked, .mismatch(.actionsHash), .mismatch(.quote)]
        for b in unbound {
            #expect(TrustScopeText.seamCaption(b) == "pinned by the action log", "\(String(describing: b))")
            #expect(TrustScopeText.deploymentSuffix(b) == " · per the action log", "\(String(describing: b))")
        }
        var record = AttestationRecord.preview
        record.modelDeployedAt = "2026-11-04T04:16:10Z"
        #expect(record.deploymentCaption?.contains("signed") == false, "the record alone never claims a signature")
    }

    @Test func eachResultGetsItsApprovedLine() {
        #expect(TrustScopeText.actionLogLine(.bound)?.text == "action log bound to this enclave's hardware ✓")
        #expect(TrustScopeText.actionLogLine(.notBound)?.tone == .caution)
        #expect(TrustScopeText.actionLogLine(.unchecked)?.text.hasPrefix("action log not checked: intel's check") == true)
        #expect(TrustScopeText.actionLogLine(.mismatch(.nonce)) == .init(text: "action log doesn't match its quote. do not trust.",
                                                                       detail: "the quote answers a different request.", tone: .broken))
        #expect(TrustScopeText.actionLogLine(nil) == nil)
        #expect(TrustScopeText.bootLogLine(.matches)?.tone == .proven && TrustScopeText.bootLogLine(.absent)?.tone == .caution)
        #expect(TrustScopeText.bootLogLine(.mismatch(.rtmr3))?.text == "boot event log doesn't match the quote. do not trust.")
        #expect(TrustScopeText.osImageSuffix(.matches) == " · in the quote ✓" && TrustScopeText.osImageSuffix(.absent).isEmpty)
    }

    @Test func theComposeManagerLineNamesWhatRuns() {
        let d = String(repeating: "6e", count: 32), r = String(repeating: "a0", count: 32)
        #expect(TrustScopeText.composeManagerLine(nil) == nil, "nothing from an unbound log")
        #expect(TrustScopeText.composeManagerLine(.init(declared: d, running: nil))?.text
                == "no start recorded in the action log: showing the declared image.")
        #expect(TrustScopeText.composeManagerLine(.init(declared: d, running: d))?.text == "running per the action log")
        let differs = TrustScopeText.composeManagerLine(.init(declared: d, running: r))
        #expect(differs?.text == "declared sha256:6e6e6e6e · running sha256:a0a0a0a0" && differs?.tone == .caution,
                "never green: the running manager isn't measured")
    }

    /// The live fleet since 2026-11-04 (audit): the row must not show 6e035c8f's links or review over a0c07308.
    @Test func aDifferentRunningManagerStripsTheDeclaredImagesLinksAndReview() {
        let d = String(repeating: "6e", count: 32), r = String(repeating: "a0", count: 32)
        var entry = ImageEntry(id: "cm", name: "nearaidev/compose-manager", kind: .registry)
        entry.auditURL = URL(string: "https://example.com/audit.md")
        entry.links = [RunLink(title: "sigstore", url: "https://example.com/sig")]
        let differs = TrustScope.managerRow(entry, seat: .init(declared: d, running: r)) { _ in nil }
        #expect(differs.auditURL == nil && differs.links.isEmpty && differs.projectPointer == nil)
        #expect(differs.name == entry.name, "the declared image stays shown")
        let same = TrustScope.managerRow(entry, seat: .init(declared: d, running: d)) { _ in nil }
        #expect(same.auditURL != nil && !same.links.isEmpty, "the same image keeps its own review")
    }

    /// audits 8c9208b published a page for a0c07308: the row carries the RUNNING manager's own review, never the
    /// declared one's (a live capture of 2026-11-06 showed no review at all on the row).
    @Test func aDifferentRunningManagerWearsItsOwnReview() {
        let d = String(repeating: "6e", count: 32), r = String(repeating: "a0", count: 32)
        let declaredPage = URL(string: "https://example.com/compose-manager/sha256-\(d).md")!
        let runningPage = URL(string: "https://example.com/compose-manager/sha256-\(r).md")!
        var entry = ImageEntry(id: "cm", name: "nearaidev/compose-manager", kind: .registry)
        entry.auditURL = declaredPage
        let pages = [d: declaredPage, r: runningPage]
        let row = TrustScope.managerRow(entry, seat: .init(declared: d, running: r)) { pages[$0] }
        #expect(row.auditURL == runningPage)
        #expect(row.digestFull == "sha256:\(r)" && row.digest == "sha256:\(r.prefix(12))…",
                "the pill under the review is the running image, not the declared one")
    }

    @Test func aRunningRowNamesServiceFileCommitAndItsFilesCheck() {
        let src = ActionLogReading.Source(commit: "7ee4a4c741259d0c", file: "prod/V12Q8.yaml", fileSHA256: "s")
        let svc = ActionLogReading.RunningService(service: "proxy-glm53", source: src, tag: "v0.0.521",
                                                  since: "2026-10-29T00:11:24.857389316+00:00")
        let row = TrustScopeText.runningRow(.init(service: svc, outcome: .unpublished))
        #expect(row.title == "proxy-glm53 · prod/V12Q8.yaml @ 7ee4a4c")
        #expect(row.caption == "v0.0.521 · since 2026-10-29")
        #expect(row.state.text.hasPrefix("not published at this commit") && row.state.tone == .caution)
        #expect(TrustScopeText.runningRow(.init(service: svc, outcome: .mismatch)).state.tone == .broken)
    }
}

/// running-manager-unreviewed (the maintainer 2026-11-06): a running compose manager with no review of its own says so in
/// orange, never borrows the declared manager's review, and keeps the everyday screen off "only it can read".
@Suite("Trust scope — an unreviewed running compose manager")
@MainActor
struct RunningManagerUnreviewedTests {
    static let line = "running manager unreviewed: teemoon has no review of this build yet."
    let d = String(repeating: "6e", count: 32), r = String(repeating: "a0", count: 32)

    @Test func theRowSaysSoInOrangeAndNeverBorrowsTheDeclaredReview() {
        let declaredPage = URL(string: "https://example.com/cm/sha256-\(d).md")!
        let lines = TrustScopeText.composeManagerLines(.init(declared: d, running: r)) { $0 == d ? declaredPage : nil }
        #expect(lines.contains(TrustScopeLine(text: Self.line, tone: .caution)))
        let same = TrustScopeText.composeManagerLines(.init(declared: d, running: d)) { _ in nil }
        #expect(same.contains(TrustScopeLine(text: Self.line, tone: .caution)), "the same build with no page is unreviewed too")
    }

    @Test func aReviewedRunningManagerOrNoRecordedStartHasNoSuchLine() {
        let runningPage = URL(string: "https://example.com/cm/sha256-\(r).md")!
        #expect(!TrustScopeText.composeManagerLines(.init(declared: d, running: r)) { $0 == r ? runningPage : nil }
            .contains { $0.text == Self.line })
        #expect(!TrustScopeText.composeManagerLines(.init(declared: d, running: nil)) { _ in nil }
            .contains { $0.text == Self.line }, "no start recorded: no running build to call unreviewed")
        #expect(TrustScopeText.composeManagerLines(nil) { _ in nil }.isEmpty)
    }

    /// A model enclave whose one plaintext toucher has a private review: green, until the running manager has none.
    @Test func itCountsAsNotAllReviewedForTheEverydayScreen() throws {
        let engine = String(repeating: "cd", count: 32)
        let bare = AuditIndex.Index(schema: 1, images: ["docker.io/nearaidev/engine": [engine], "docker.io/nearaidev/compose-manager": [d]],
                                    sources: nil, projects: nil, tagAudits: nil, manifests: [:], measured: [], os: [],
                                    verdicts: nil)
        let engineURL = try #require(AuditIndex(fixedIndex: bare).imageAuditURL(image: "nearaidev/engine", digest: engine))
        let key = String(engineURL.absoluteString.dropFirst(AuditIndex.webBase.count + 1))
        var index = bare
        index.verdictClass = [key: "private"]
        let audit = AuditIndex(fixedIndex: index, loadedAt: Date())
        var row = ImageEntry(id: "engine", name: "nearaidev/engine", kind: .registry)
        row.plaintextRole = .modelServer
        row.auditURL = engineURL
        let group = EnclaveGroup(id: "model", role: "model enclave", primary: true, binding: "", mrConfig: nil,
                                 quoteVerified: true, images: [row])
        func state(_ seat: ActionLogReading.ComposeManagerSeat?) -> EverydayAuditState? {
            ModelNodeAudit.state(groups: [group], hasAttestation: true, composeManager: seat, audit: audit).state
        }
        #expect(state(nil) == .reviewed, "precondition")
        #expect(state(.init(declared: d, running: d)) == .reviewed, "the running build has its own review")
        #expect(state(.init(declared: d, running: r)) == .incomplete, "the declared build's review is not borrowed")
    }
}
