//
//  LiteRTSpeculativeDecoding.swift
//  teemoon
//
//  Whether the LiteRT engine is built with speculative decoding (the bundle's
//  MTP drafter, verified by the main model). On by default on Metal, where it
//  measured 1.7x decode; Android found it slower on every GPU but Adreno, so
//  a new backend must be measured, not assumed.
//

import Foundation
import LiteRTLM

enum LiteRTSpeculativeDecoding {

    /// Off only when the launch environment says so (`TEEMOON_SPECULATIVE=0`,
    /// the benchmark's baseline arm). On by default wherever the file carries
    /// a drafter; the numbers are in LiteRTSpeculativeDecodingTests.
    static var disabledByEnvironment: Bool {
        ProcessInfo.processInfo.environment["TEEMOON_SPECULATIVE"] == "0"
    }

    /// The value to hand the runtime: `true` when the loaded file carries a
    /// drafter and nothing disabled it; otherwise nil, which leaves the
    /// runtime's own default untouched. Never `false` from here — a bundle
    /// without a drafter has nothing to speculate with, and the runtime
    /// decides what its default means.
    static func setting(disabled: Bool, fileSupports: Bool) -> Bool? {
        !disabled && fileSupports ? true : nil
    }

    /// Greedy sampling for the bench only (`TEEMOON_BENCH_GREEDY=1`), so the
    /// flag-off and flag-on replies can be compared byte for byte. nil in
    /// normal use, leaving the engine's own sampler.
    static var benchSampler: LiteRTLM.SamplerConfig? {
        guard ProcessInfo.processInfo.environment["TEEMOON_BENCH_GREEDY"] == "1" else { return nil }
        return try? LiteRTLM.SamplerConfig(topK: 1, topP: 1, temperature: 0, seed: 0)
    }
}
