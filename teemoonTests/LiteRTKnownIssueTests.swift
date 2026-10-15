//
//  LiteRTKnownIssueTests.swift
//  teemoonTests
//
//  Three upstream iOS bugs are open against the exact configuration teemoon
//  ships. These tests answer, on real hardware, whether we are exposed to any of
//  them — before a number or a claim goes anywhere public, and independently of
//  that, because two of the three would be user-visible defects.
//
//    LiteRT #6765   Gemma 4 E4B .litertlm with max_num_tokens > 4096 SIGSEGVs in
//                   reshape on iOS arm64. `LiteRTTransport` defaults to 8192 and
//                   E4B is in the shipping catalog, so if this reproduces it is
//                   a crash in the product, not a benchmark footnote.
//
//    gallery #692   Gemma 4 E2B "Failed to allocate tensors" /
//                   "DYNAMIC_UPDATE_SLICE failed to prepare" — reported on an
//                   iPhone 16 Pro, which is this phone.
//
//    LiteRT-LM #2814  iOS/Metal corrupts digit sequences (clean on CPU), from a
//                   reversed sampler condition. teemoon quotes prices, dates and
//                   token counts, so a runtime that mangles digits is worse than
//                   a slow one.
//
//  None of the eight vendored patches in Packages/LiteRTLM/VENDORING.md touches
//  any of these, so "we are probably fine" is not evidence. The v0.17.1 bump
//  (2026-09-18) is the only reason to expect them fixed, and that is a guess
//  until measured.
//
//  A NOTE ON #6765: a SIGSEGV kills the test runner rather than failing an
//  expectation. A crashed run of `e4bSurvivesTheProductionContext` IS the
//  positive result — check for the .ips via the device-diagnostics recipe before
//  concluding the suite merely failed to start.
//
//  REAL DEVICE ONLY. Off by default:
//
//      TEST_RUNNER_LITERT_LIVE=1 xcodebuild test … \
//        -only-testing:teemoonTests/LiteRTKnownIssueTests
//

import Foundation
import Testing
@testable import teemoon

@Suite(.serialized)
struct LiteRTKnownIssueTests {

    static var enabled: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let env = ProcessInfo.processInfo.environment
        return env["LITERT_LIVE"] != nil || env["TEST_RUNNER_LITERT_LIVE"] != nil
        #endif
    }

    static var e2b: LocalModel { LocalModelCatalog.all[0] }
    static var e4b: LocalModel { LocalModelCatalog.all[1] }

    static func installed(_ model: LocalModel) -> Bool {
        FileManager.default.fileExists(atPath: LocalModelStorage.file(for: model).path)
    }

    static func transport(for model: LocalModel, contextTokens: Int) -> LiteRTTransport {
        LiteRTTransport(modelPath: LocalModelStorage.file(for: model),
                        estimatedSizeMB: model.sizeMB,
                        contextTokens: contextTokens)
    }

    static func ask(_ transport: LiteRTTransport, _ prompt: String) async throws -> String {
        let out = try await transport.runTurn(messages: [
            ["role": "system", "content": "You are a helpful assistant."],
            ["role": "user", "content": prompt],
        ], includeTools: false) { _ in }
        return out.content
    }

    // MARK: - #6765 — E4B above 4096 context

    /// Drives E4B at the context the app actually asks for.
    ///
    /// `LiteRTLM.benchmark(...)` cannot catch this: it sizes the engine at
    /// prefill + decode + 32, which never crosses 4096. Only the real transport
    /// at its real default does.
    @Test(.enabled(if: Self.enabled, "set LITERT_LIVE=1"), .timeLimit(.minutes(20)))
    func e4bSurvivesTheProductionContext() async throws {
        try #require(Self.installed(Self.e4b), "E4B bundle is not on this device")
        // 8192 is LiteRTTransport's default and the value the product ships.
        let reply = try await Self.ask(Self.transport(for: Self.e4b, contextTokens: 8192),
                                       "Name three colours. One line, no preamble.")
        #expect(!reply.isEmpty, "E4B produced nothing at 8192 context")
        print("[known-issue] #6765 did NOT reproduce at 8192: \(reply.prefix(120))")
    }

    // MARK: - #692 — E2B tensor allocation on an iPhone 16 Pro

    /// The reporter's device is this device. If engine creation is broken for
    /// our bundle, this is where it surfaces — as a thrown load failure rather
    /// than a wrong answer.
    @Test(.enabled(if: Self.enabled, "set LITERT_LIVE=1"), .timeLimit(.minutes(20)))
    func e2bEngineBuildsOnThisPhone() async throws {
        try #require(Self.installed(Self.e2b), "E2B bundle is not on this device")
        let reply = try await Self.ask(Self.transport(for: Self.e2b, contextTokens: 8192),
                                       "Say the word ready and nothing else.")
        #expect(!reply.isEmpty, "E2B produced nothing — check the log for tensor allocation errors")
        print("[known-issue] #692 did NOT reproduce: \(reply.prefix(120))")
    }

    // MARK: - #2814 — digit corruption on Metal

    /// Echo a long digit run and check it came back intact.
    ///
    /// Echoing is deliberate: it needs no arithmetic and no world knowledge, so
    /// a wrong answer is a token-emission fault rather than the model being bad
    /// at maths. The sequences are chosen to include a repeated run and a
    /// zero-led group, which is where a reversed sampler condition shows first.
    ///
    /// This runs on the GPU because that is what `LiteRTTransport` uses in
    /// production (`backend: .gpu`). A failure here is a shipping defect, and the
    /// CPU comparison that would confirm it as #2814 specifically is the next
    /// step, not this test's job.
    @Test(.enabled(if: Self.enabled, "set LITERT_LIVE=1"), .timeLimit(.minutes(20)))
    func digitSequencesSurviveTheMetalPath() async throws {
        try #require(Self.installed(Self.e2b), "E2B bundle is not on this device")
        let transport = Self.transport(for: Self.e2b, contextTokens: 8192)
        let sequences = ["4051992300077", "1000000000001", "90210-33139"]
        var corrupted: [String] = []
        for sequence in sequences {
            let reply = try await Self.ask(
                transport,
                "Repeat this exactly, with no other words: \(sequence)")
            if !reply.contains(sequence) {
                corrupted.append("sent \(sequence), got back: \(reply.prefix(80))")
            }
        }
        #expect(corrupted.isEmpty, """
            digit sequences did not survive the round trip — this is what \
            LiteRT-LM #2814 looks like, and teemoon quotes prices and dates:
            \(corrupted.joined(separator: "\n"))
            """)
    }
}
