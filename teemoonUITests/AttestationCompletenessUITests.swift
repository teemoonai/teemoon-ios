//
//  AttestationCompletenessUITests.swift
//  teemoonUITests
//
//  Drives EVERY attestable near.ai model, opens the EXPERT attestation panel,
//  scrolls the whole sheet, and harvests a comprehensive view per model:
//
//    • verdict            ✅ complete / ❌ incomplete / ⚠️ not-attestable
//    • engine image       sglang · vllm-openai · built-in-enclave (which one)
//    • guest-OS row       present? (tier-1 private-ml-sdk os_image row)
//    • fable miniaudits    which egress reviews render (plaintext/process/log)
//    • E2EE terminator    vllm-proxy-rs "encryption terminates here"
//
//  ── FAN-OUT DESIGN ─────────────────────────────────────────────────────────
//  Each model is its OWN test CLASS (a thin subclass of `ModelExpertHarness`).
//  xcodebuild parallelizes at CLASS granularity — per-method-in-one-class does
//  NOT fan out (verified: it runs serially on a single clone). With per-class,
//  `-parallel-testing-worker-count N` distributes the models across N simulator
//  clones. Every class attaches screenshots + the full accessibility TREE + a
//  machine-readable "ROW-<id>" line; the matrix is assembled from those.
//
//  Run SERIAL (default):
//    xcodebuild test ... -only-testing:teemoonUITests   (all Expert_* classes)
//  Run FANNED OUT (~N× faster):
//    xcodebuild test ... -parallel-testing-enabled YES -parallel-testing-worker-count 3
//
//  RATE LIMIT (attestation only): each model fires several GitHub attestation
//  lookups against the anonymous 60/hr limit — on 16 GB, ~3 workers is the safe
//  sweet spot; higher concurrency wants an authenticated GitHub token. This is
//  UNIQUE to attestation; onboarding/chat/settings suites hit no such API and
//  can fan out fully (subclass a shared harness the same way).
//
//  Assemble the matrix from a finished run:
//    xcrun xcresulttool export attachments --path <run>.xcresult --output-path out
//    then concatenate every ROW-* attachment.
//

import XCTest

/// Shared harness — NOT a test class itself (no `test*` methods). Each model is
/// a `final` subclass below, so xcodebuild schedules it on its own clone.
class ModelExpertHarness: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = true }

    /// Seed the model, open the expert panel, scroll, harvest, attach a row,
    /// and fail on an incomplete panel.
    func harvest(id: String, name: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = id
        app.launch()
        defer { app.terminate() }

        func emit(_ emoji: String, engine: String, os: Bool, egress: [String],
                  e2ee: Bool, notes: String, fail: String?) {
            let row = [emoji, id, engine, os ? "os:✓" : "os:·",
                       "egress:\(egress.isEmpty ? "—" : egress.joined(separator: "·"))",
                       e2ee ? "e2ee:✓" : "e2ee:·", notes].joined(separator: "\t")
            let a = XCTAttachment(string: row)
            a.name = "ROW-\(safeID(id))"; a.lifetime = .keepAlways; add(a)
            print("ROW\t\(row)")
            if let fail { XCTFail("\(id): \(fail)") }
        }

        let chip = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "double tap to view details")).firstMatch
        guard chip.waitForExistence(timeout: 20) else {
            return emit("❌", engine: "—", os: false, egress: [], e2ee: false,
                        notes: "title chip never appeared", fail: "no title chip")
        }
        chip.tap()
        guard app.staticTexts["who can read this?"].waitForExistence(timeout: 6) else {
            return emit("❌", engine: "—", os: false, egress: [], e2ee: false,
                        notes: "sheet didn't open", fail: "sheet didn't open")
        }
        let expert = app.buttons["expert"].firstMatch
        if expert.waitForExistence(timeout: 5) { expert.tap() }

        let deadline = Date().addingTimeInterval(55)
        while Date() < deadline {
            let l = allLabels(app).joined(separator: "\n").lowercased()
            if l.contains("known code") || l.contains("not end-to-end encrypted") { break }
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 1)
        }
        sleep(4)

        var tree = app.debugDescription
        var labels = Set(allLabels(app))
        takeShot(app, "surface-\(safeID(id))-0")
        for i in 1...8 {
            app.swipeUp(velocity: .slow); usleep(900_000)
            tree += "\n" + app.debugDescription
            labels.formUnion(allLabels(app))
            if i % 3 == 0 { takeShot(app, "surface-\(safeID(id))-\(i)") }
        }
        let hay = (labels.joined(separator: "\n") + "\n" + tree).lowercased()
        let treeAtt = XCTAttachment(string: tree)
        treeAtt.name = "TREE-\(safeID(id))"; treeAtt.lifetime = .keepAlways; add(treeAtt)

        if hay.contains("not end-to-end encrypted") {
            return emit("⚠️", engine: "—", os: false, egress: [], e2ee: false,
                        notes: "not attestable (no confidential endpoint)", fail: nil)
        }
        if hay.contains("determine which images see your message") {
            return emit("❌", engine: "—", os: false, egress: [], e2ee: false,
                        notes: "couldn't determine plaintext set (reused/combined-node)",
                        fail: "couldn't determine plaintext set")
        }

        let engine: String = {
            if hay.contains("vllm/vllm-openai") { return "vllm-openai" }
            if hay.contains("lmsysorg/sglang") { return "sglang" }
            if hay.contains("built in-enclave") { return "in-enclave" }
            return "?"
        }()
        let osRow = hay.contains("private-ml-sdk") || hay.contains("os_image sha256")
        let e2ee = hay.contains("terminates here") || hay.contains("vllm-proxy-rs")
        // Which egress reviews rendered as fable miniaudits (dedup by type).
        let egress = ["plaintext", "process-access", "log-forwarding"]
            .filter { hay.contains("source reviewed for \($0) egress") }
        // Regression guard for the local-engine base-audit adoption: when the
        // engine is `:local` (built in-enclave), it must still surface a
        // plaintext-egress miniaudit (adopted from its FROM-base image audit),
        // not strand it on a duplicate base row.
        let engineAudit = hay.contains("built in-enclave")
            ? egress.contains("plaintext") : true
        let namesModel = hay.contains(name.lowercased()) || hay.contains(shortID(id))
        let hasImages = engine != "?" || labels.contains { $0.contains("@sha256") || $0.contains("nearaidev/") }
        if !hasImages {
            return emit("❌", engine: "—", os: osRow, egress: egress, e2ee: e2ee,
                        notes: "no model-enclave image rows", fail: "no model-enclave image rows")
        }
        var notes: [String] = []
        if !namesModel { notes.append("name?") }
        if !engineAudit { notes.append("engine-audit-missing") }
        if engine == "?" { notes.append("engine-unresolved") }
        emit("✅", engine: engine, os: osRow, egress: egress, e2ee: e2ee,
             notes: notes.joined(separator: ", "), fail: nil)
    }

    // MARK: helpers
    private func allLabels(_ app: XCUIApplication) -> [String] {
        app.staticTexts.allElementsBoundByIndex.map { $0.label }.filter { !$0.isEmpty }
    }
    private func takeShot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot())
        s.name = name; s.lifetime = .keepAlways; add(s)
    }
    private func safeID(_ id: String) -> String { id.replacingOccurrences(of: "/", with: "_") }
    private func shortID(_ id: String) -> String {
        (id.split(separator: "/").last.map(String.init) ?? id).lowercased()
    }
}

// MARK: - per-model classes (each a distributable unit for -parallel-testing)

final class Expert_GLM_5_1: ModelExpertHarness {
    func testExpertSurface() throws { try harvest(id: "zai-org/GLM-5.1-FP8", name: "GLM 5.1") }
}
final class Expert_GLM_5_2: ModelExpertHarness {
    func testExpertSurface() throws { try harvest(id: "z-ai/glm-5.2", name: "GLM 5.2") }
}
final class Expert_Qwen36_27B: ModelExpertHarness {
    func testExpertSurface() throws { try harvest(id: "Qwen/Qwen3.6-27B-FP8", name: "Qwen3.6 27B") }
}
final class Expert_Qwen36_35B: ModelExpertHarness {
    func testExpertSurface() throws { try harvest(id: "Qwen/Qwen3.6-35B-A3B-FP8", name: "Qwen3.6 35B") }
}
final class Expert_Qwen3VL_30B: ModelExpertHarness {
    func testExpertSurface() throws { try harvest(id: "Qwen/Qwen3-VL-30B-A3B-Instruct", name: "Qwen3-VL 30B") }
}
final class Expert_Qwen35_122B: ModelExpertHarness {
    func testExpertSurface() throws { try harvest(id: "Qwen/Qwen3.5-122B-A10B", name: "Qwen3.5 122B") }
}
final class Expert_DeepSeekV4: ModelExpertHarness {
    func testExpertSurface() throws { try harvest(id: "deepseek-ai/DeepSeek-V4-Flash", name: "DeepSeek V4 Flash") }
}
final class Expert_Gemma4: ModelExpertHarness {
    func testExpertSurface() throws { try harvest(id: "google/gemma-4-31B-it", name: "Gemma 4") }
}
final class Expert_GptOss120b: ModelExpertHarness {
    func testExpertSurface() throws { try harvest(id: "openai/gpt-oss-120b", name: "gpt-oss 120b") }
}
