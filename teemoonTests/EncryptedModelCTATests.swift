//
//  EncryptedModelCTATests.swift
//  teemoonTests
//
//  The not-encrypted sheet's last button, 2026-09-12: from an NVIDIA chat it
//  read "choose an end-to-end encrypted model" and opened a list of near.ai
//  models with no provider named, whenever a near.ai setup existed — keyed
//  or not. Two states now, gated on the key, both naming near.ai.
//

import Testing
@testable import teemoon

@Suite("EncryptedModelCTA")
struct EncryptedModelCTATests {

    @Test func aKeyedNearAISetupOffersTheSwitch() {
        let cta = EncryptedModelCTA.resolve(nearAI: .nearAI, hasKey: true)
        #expect(cta == .switchToNearAI(.nearAI))
        #expect(cta.opensPicker)
        #expect(cta.title.hasPrefix("switch to"))
    }

    @Test func noNearAIAtAllOffersTheKeyForm() {
        let cta = EncryptedModelCTA.resolve(nearAI: nil, hasKey: false)
        #expect(cta == .addNearAIKey(existing: nil))
        #expect(!cta.opensPicker)
    }

    /// A setup that exists without a key (legacy, or a lost key) must not
    /// open the picker — the pick would die at send with "no api key".
    @Test func aKeylessNearAISetupOffersTheKeyFormForThatSetup() {
        let cta = EncryptedModelCTA.resolve(nearAI: .nearAI, hasKey: false)
        #expect(cta == .addNearAIKey(existing: .nearAI))
        #expect(!cta.opensPicker)
    }

    /// The whole complaint: the provider was never named.
    @Test func everyStateNamesNearAIAndTheKey() {
        for cta in [EncryptedModelCTA.resolve(nearAI: .nearAI, hasKey: true),
                    EncryptedModelCTA.resolve(nearAI: nil, hasKey: false)] {
            #expect(cta.title.contains("near.ai"), "\(cta)")
            #expect(cta.detail.contains("near.ai key"), "\(cta)")
        }
    }
}
