//
//  ReasoningLevelTests.swift
//  teemoonTests
//
//  Developer mode's per-model reasoning level (docs/REASONING_LEVEL.md, the maintainer 2026-11-13): low unless chosen, the
//  model's own levels, and with developer mode off nothing changes on the wire.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Reasoning level", .serialized)
struct ReasoningLevelTests {

    static func provider(_ endpoint: String, model: String = "m") -> Provider {
        Provider(name: "p", endpoint: endpoint, model: model, requiresAPIKey: true)
    }
    static let fireworks = provider("https://api.fireworks.ai/inference/v1/chat/completions")
    static let near = provider("https://cloud-api.near.ai/v1/chat/completions")
    static let nvidia = provider("https://integrate.api.nvidia.com/v1/chat/completions")
    /// Refusals are launch-wide state that other suites read in parallel: a refusal test gets a model of its own.
    static func refusing() -> Provider {
        provider("https://api.fireworks.ai/inference/v1/chat/completions", model: "refused-\(UUID().uuidString)")
    }

    static func scratchDefaults() -> UserDefaults {
        let name = "reasoning-level-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: The menu

    @Test func eachControlOffersItsOwnLevels() {
        #expect(ReasoningLevel.menu(for: .effort(cap: nil), offered: []) == ["low", "medium", "high"])
        #expect(ReasoningLevel.menu(for: .thinkingSwitch, offered: []) == ["off", "on"])
        #expect(ReasoningLevel.menu(for: .onDevice, offered: []) == ["off", "on"])
        #expect(ReasoningLevel.menu(for: .none, offered: ["low", "high"]).isEmpty, "nothing would be sent")
    }

    @Test func openRouterOffersTheModelsListInItsOrder() {
        #expect(ReasoningLevel.menu(for: .openRouter, offered: ["xhigh", "high", "medium", "low", "none"])
                == ["xhigh", "high", "medium", "low", "none"])
        #expect(ReasoningLevel.menu(for: .openRouter, offered: []) == ["low", "medium", "high"])
    }

    @Test func theDefaultIsTheControlsLow() {
        #expect(ReasoningLevel.defaultLevel(for: .effort(cap: nil)) == "low")
        #expect(ReasoningLevel.defaultLevel(for: .openRouter) == "low")
        #expect(ReasoningLevel.defaultLevel(for: .thinkingSwitch) == "off")
        #expect(ReasoningLevel.defaultLevel(for: .onDevice) == "off")
    }

    // MARK: Developer mode

    @Test func aChoiceCountsOnlyInDeveloperMode() {
        let d = Self.scratchDefaults()
        ReasoningLevel.set("medium", for: Self.fireworks, in: d)
        #expect(ReasoningLevel.chosen(for: Self.fireworks, in: d) == nil, "developer mode off: the choice is ignored")
        d.set(true, forKey: UserDefaultsKey.developerModeEnabled)
        #expect(ReasoningLevel.chosen(for: Self.fireworks, in: d) == "medium")
        #expect(ReasoningLevel.chosen(for: Self.provider("https://api.fireworks.ai/inference/v1", model: "other"), in: d) == nil,
                "per model")
        d.set(false, forKey: UserDefaultsKey.developerModeEnabled)
        #expect(ReasoningLevel.stored(for: Self.fireworks, in: d) == "medium", "kept for when it comes back on")
        ReasoningLevel.set(nil, for: Self.fireworks, in: d)
        #expect(ReasoningLevel.stored(for: Self.fireworks, in: d) == nil)
    }

    /// With no choice in force the body is byte for byte today's, so the prompt cache cannot move.
    @Test func noChoiceSendsTodaysBytes() throws {
        for p in [Self.fireworks, Self.near, Self.nvidia] {
            for effort in ReasoningEffort.allCases {
                let today = try JSONSerialization.data(withJSONObject: effort.bodyFields(for: p) ?? [:], options: .sortedKeys)
                let none = try JSONSerialization.data(withJSONObject: effort.bodyFields(for: p, chosen: nil) ?? [:],
                                                      options: .sortedKeys)
                #expect(today == none, "\(p.endpoint) \(effort)")
            }
        }
    }

    // MARK: What is sent

    @Test func aChosenEffortReplacesLow() {
        #expect(ReasoningEffort.fast.bodyFields(for: Self.fireworks, chosen: "medium")?["reasoning_effort"] as? String == "medium")
        #expect(ReasoningEffort.fast.bodyFields(for: Self.near, chosen: "medium")?["max_tokens"] == nil,
                "near.ai's cap is Think Harder's only")
    }

    @Test func openRouterSendsTheChosenLevelNested() {
        let p = Self.provider("https://openrouter.ai/api/v1/chat/completions")
        ReasoningControl.note(.openRouter, for: p)
        let fields = ReasoningEffort.fast.bodyFields(for: p, chosen: "xhigh")
        #expect((fields?["reasoning"] as? [String: String])?["effort"] == "xhigh")
        #expect((ReasoningEffort.fast.bodyFields(for: p, chosen: "none")?["reasoning"] as? [String: String])?["effort"] == "none",
                "none only where the model lists it, and only by choice")
    }

    @Test func aSwitchSendsTheChosenSide() {
        #expect((ReasoningEffort.fast.bodyFields(for: Self.nvidia, chosen: "on")?["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == true)
        #expect((ReasoningEffort.fast.bodyFields(for: Self.nvidia, chosen: "off")?["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
    }

    @Test func onDeviceThinksWhenChosenOn() {
        #expect(ReasoningLevel.thinksOnDevice(.fast, chosen: nil) == false)
        #expect(ReasoningLevel.thinksOnDevice(.fast, chosen: "on") == true)
        #expect(ReasoningLevel.thinksOnDevice(.thinkHarder, chosen: nil) == true)
        #expect(ReasoningLevel.thinksOnDevice(.thinkHarder, chosen: "off") == true, "Think Harder still thinks")
    }

    /// Think Harder never thinks less than the plain send.
    @Test func thinkHarderSendsHighOrTheChosenLevelAboveIt() {
        #expect(ReasoningEffort.thinkHarder.bodyFields(for: Self.fireworks, chosen: "medium")?["reasoning_effort"] as? String == "high")
        #expect(ReasoningEffort.thinkHarder.bodyFields(for: Self.fireworks, chosen: "low")?["reasoning_effort"] as? String == "high")
        let p = Self.provider("https://openrouter.ai/api/v1/chat/completions")
        ReasoningControl.note(.openRouter, for: p)
        #expect((ReasoningEffort.thinkHarder.bodyFields(for: p, chosen: "xhigh")?["reasoning"] as? [String: String])?["effort"] == "xhigh")
        #expect(ReasoningEffort.thinkHarder.bodyFields(for: Self.near, chosen: "medium")?["max_tokens"] as? Int == 8192)
        #expect((ReasoningEffort.thinkHarder.bodyFields(for: Self.nvidia, chosen: "off")?["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == true)
    }

    /// A refusal is today's path: no level at all for this launch, and the row says so.
    @Test func aRefusedLevelSendsNothingAndIsShown() {
        let p = Self.refusing()
        #expect(!ReasoningEffort.wasRefused(by: p))
        ReasoningEffort.noteRefused(by: p)
        #expect(ReasoningEffort.fast.bodyFields(for: p, chosen: "medium") == nil)
        #expect(ReasoningEffort.wasRefused(by: p))
    }

    // MARK: The detail page's row

    @Test func theRowShowsOnlyInDeveloperModeAndWhereALevelIsSent() {
        let p = Self.refusing()
        #expect(ReasoningLevel.Row(setup: p, developerMode: false, offered: []) == nil)
        #expect(ReasoningLevel.Row(setup: nil, developerMode: true, offered: []) == nil, "no setup: today's read-only row")
        #expect(ReasoningLevel.Row(setup: Provider.braveAnswers, developerMode: true, offered: []) == nil, "nothing would be sent")
        let row = ReasoningLevel.Row(setup: p, developerMode: true, offered: [])
        #expect(row?.levels == ["low", "medium", "high"])
        #expect(row?.label("low") == "low (default)")
        #expect(row?.label("medium") == "medium")
        #expect(ReasoningLevel.Row(setup: Self.nvidia, developerMode: true, offered: [])?.label("off") == "off (default)")
        #expect(row?.refused == false)
        ReasoningEffort.noteRefused(by: p)
        #expect(ReasoningLevel.Row(setup: p, developerMode: true, offered: [])?.refused == true)
    }

    /// A stored level the setup's control can't send counts as no choice, never a bad field.
    @Test func aLevelTheControlCantSendIsIgnored() {
        #expect(ReasoningLevel.usable("on", for: .effort(cap: nil)) == nil)
        #expect(ReasoningLevel.usable("medium", for: .thinkingSwitch) == nil)
        #expect(ReasoningLevel.usable("medium", for: .effort(cap: nil)) == "medium")
        #expect(ReasoningLevel.usable("xhigh", for: .openRouter) == "xhigh")
        #expect(ReasoningEffort.fast.bodyFields(for: Self.fireworks, chosen: "on")?["reasoning_effort"] as? String == "low")
    }

    // MARK: Design review 2026-11-13

    /// Low is what is sent without a choice, so it is always on the menu: a list without it left the value blank.
    @Test func openRouterKeepsLowOnTheMenu() {
        #expect(ReasoningLevel.menu(for: .openRouter, offered: ["high", "medium"]) == ["high", "medium", "low"])
        let row = ReasoningLevel.Row(setup: Self.fireworks, control: .openRouter, developerMode: true, offered: ["high", "medium"])
        #expect(row?.value(stored: nil) == "low")
    }

    /// A stored level the list no longer has shows as the default.
    @Test func aStoredLevelOffTheListShowsTheDefault() {
        let row = ReasoningLevel.Row(setup: Self.fireworks, developerMode: true, offered: [])
        #expect(row?.value(stored: "medium") == "medium")
        #expect(row?.value(stored: "xhigh") == "low")
        #expect(row?.value(stored: nil) == "low")
    }

    /// After a refusal nothing goes on the wire, so the row says the model's own default, and which pick was turned down.
    @Test func aRefusalNamesTheRefusedLevelAndShowsNone() {
        let p = Self.refusing()
        #expect(ReasoningLevel.Row(setup: p, developerMode: true, offered: [])?.footer(stored: "medium") == nil)
        ReasoningEffort.noteRefused(by: p)
        let row = ReasoningLevel.Row(setup: p, developerMode: true, offered: [])
        #expect(row?.footer(stored: "medium") == "the server refused medium, so teemoon leaves the setting out and this model uses its own default for now.")
        #expect(row?.footer(stored: nil) == "the server refused low, so teemoon leaves the setting out and this model uses its own default for now.")
    }

    // MARK: the maintainer's 15:54Z design: the where chip, the where sheet's bar, read-only model info

    @Test func theChipShowsTheLevelOnlyInDeveloperMode() {
        let p = Self.refusing()
        #expect(ReasoningLevel.chipLevel(setup: p, control: .effort(cap: nil), developerMode: false, offered: [], stored: "medium") == nil)
        #expect(ReasoningLevel.chipLevel(setup: p, control: .effort(cap: nil), developerMode: true, offered: [], stored: nil) == "low")
        #expect(ReasoningLevel.chipLevel(setup: p, control: .effort(cap: nil), developerMode: true, offered: [], stored: "medium") == "medium")
        #expect(ReasoningLevel.chipLevel(setup: p, control: .thinkingSwitch, developerMode: true, offered: [], stored: nil) == "off")
        #expect(ReasoningLevel.chipLevel(setup: p, control: ReasoningControl.none, developerMode: true, offered: [], stored: nil) == nil,
                "nothing is sent, so nothing is shown")
        ReasoningEffort.noteRefused(by: p)
        #expect(ReasoningLevel.chipLevel(setup: p, control: .effort(cap: nil), developerMode: true, offered: [], stored: "medium") == nil,
                "after a refusal no level is sent, so the chip shows none")
    }

    @Test func theBarReadsTheLevelWithDefaultOrTheModelsDefaultAfterARefusal() {
        let p = Self.refusing()
        let row = ReasoningLevel.Row(setup: p, control: .effort(cap: nil), developerMode: true, offered: [])
        #expect(row?.barValue(stored: nil) == "low (default)")
        #expect(row?.barValue(stored: "high") == "high")
        ReasoningEffort.noteRefused(by: p)
        #expect(ReasoningLevel.Row(setup: p, control: .effort(cap: nil), developerMode: true, offered: [])?.barValue(stored: "high")
                == "model's default")
    }

    /// Model info is read-only: the levels in developer mode, nothing at all without it (OpenRouter's list included).
    @Test func modelInfoListsTheLevelsOnlyInDeveloperMode() {
        let p = Self.refusing()
        #expect(ReasoningLevel.infoLine(setup: p, control: .openRouter, developerMode: false, offered: ["high", "low"]) == nil)
        #expect(ReasoningLevel.infoLine(setup: nil, control: nil, developerMode: false, offered: ["high", "low"]) == nil)
        #expect(ReasoningLevel.infoLine(setup: p, control: .openRouter, developerMode: true, offered: ["high", "low"]) == "high, low")
        #expect(ReasoningLevel.infoLine(setup: nil, control: nil, developerMode: true, offered: ["high", "low"]) == "high, low",
                "a page with no setup lists what the catalogue says")
    }

    @Test func theLevelsPageFooterExplainsAndAddsTheRefusal() {
        let p = Self.refusing()
        let row = ReasoningLevel.Row(setup: p, control: .effort(cap: nil), developerMode: true, offered: [])
        #expect(row?.pageFooter(stored: nil) == "higher levels think longer before answering, so replies take longer and can cost more.")
        ReasoningEffort.noteRefused(by: p)
        // The refusal first, as its own paragraph, then the explanation (pm's design read, 2026-11-13).
        #expect(ReasoningLevel.Row(setup: p, control: .effort(cap: nil), developerMode: true, offered: [])?.pageFooter(stored: "high")
                == "the server refused high, so teemoon leaves the setting out and this model uses its own default for now."
                + "\n\nhigher levels think longer before answering, so replies take longer and can cost more.")
    }

    // MARK: the maintainer 2026-11-13, "Yes yes"

    /// Developer mode off: not even OpenRouter's "reasoning" capability chips.
    @Test func modelInfoHidesReasoningCapabilitiesWithDeveloperModeOff() {
        let features = ["tools", "reasoning (required)", "structured outputs", "reasoning"]
        #expect(ReasoningLevel.visibleFeatures(features, developerMode: false) == ["tools", "structured outputs"])
        #expect(ReasoningLevel.visibleFeatures(features, developerMode: true) == features)
    }

    /// The where sheet opens large where half height leaves about one model row: accessibility sizes and short phones.
    @Test func theWhereSheetOpensLargeOnShortPhonesAndAtAccessibilitySizes() {
        #expect(ReasoningLevel.whereOpensLarge(accessibilitySize: false, screenHeight: 667), "SE / mini")
        #expect(ReasoningLevel.whereOpensLarge(accessibilitySize: false, screenHeight: 568))
        #expect(!ReasoningLevel.whereOpensLarge(accessibilitySize: false, screenHeight: 852), "iPhone 17")
        #expect(ReasoningLevel.whereOpensLarge(accessibilitySize: true, screenHeight: 852))
    }

    /// "Ok make bigger" (the maintainer 2026-11-13): the where sheet's middle stop is 2/3 of the screen, its top at about 34%.
    @Test func theWhereSheetsMiddleStopIsTwoThirdsOfTheScreen() {
        #expect(ReasoningLevel.whereMiddleHeight(screenHeight: 852) == 568)
        #expect(ReasoningLevel.whereMiddleHeight(screenHeight: 874) == CGFloat(874) * 2 / 3)
    }

    // MARK: The chip during a Think Harder (the maintainer 2026-11-14)

    /// What a turn's request carries, read from the body fields it sends (the card's parser), not recomputed.
    @Test func aThinkHarderTurnReadsTheLevelItsRequestSends() {
        #expect(ReasoningLevel.turnLabel(effort: .thinkHarder, provider: Self.fireworks, chosen: nil) == "high")
        #expect(ReasoningLevel.turnLabel(effort: .thinkHarder, provider: Self.fireworks, chosen: "medium") == "high")
        let or = Self.provider("https://openrouter.ai/api/v1/chat/completions")
        ReasoningControl.note(.openRouter, for: or)
        #expect(ReasoningLevel.turnLabel(effort: .thinkHarder, provider: or, chosen: "xhigh") == "xhigh")
        #expect(ReasoningLevel.turnLabel(effort: .thinkHarder, provider: Self.nvidia, chosen: nil) == "on")
        var local = Provider(name: "Gemma 4 E2B", endpoint: "on-device", model: "litert-community/gemma-4-E2B-it-litert-lm")
        local.localModelID = "litert-community/gemma-4-E2B-it-litert-lm"
        #expect(ReasoningLevel.turnLabel(effort: .thinkHarder, provider: local, chosen: nil) == "on")
        let p = Self.refusing()
        ReasoningEffort.noteRefused(by: p)
        #expect(ReasoningLevel.turnLabel(effort: .thinkHarder, provider: p, chosen: nil) == nil, "a refusal sends none")
    }
}
