//
//  LiteRTSpeculativeDecodingTests.swift
//  teemoonTests
//

import Testing
@testable import teemoon

@Suite("LiteRT speculative decoding")
struct LiteRTSpeculativeDecodingTests {

    /// On by default where the file carries a drafter: 30 → 52 tok/s on the
    /// iPhone 16 Pro (2026-09-16), prefill and first token unchanged.
    @Test func aFileWithADrafterIsOnByDefault() {
        #expect(LiteRTSpeculativeDecoding.setting(disabled: false, fileSupports: true) == true)
    }

    /// A bundle without a drafter has nothing to speculate with: the flag is
    /// left unset rather than set to a value the runtime would reject.
    @Test func aFileWithoutADrafterLeavesTheRuntimeDefault() {
        #expect(LiteRTSpeculativeDecoding.setting(disabled: false, fileSupports: false) == nil)
    }

    /// The benchmark's baseline arm turns it off explicitly; nothing else does.
    @Test func disabledLeavesTheRuntimeDefault() {
        #expect(LiteRTSpeculativeDecoding.setting(disabled: true, fileSupports: true) == nil)
    }
}
