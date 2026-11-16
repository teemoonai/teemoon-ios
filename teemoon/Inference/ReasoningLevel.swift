//
//  ReasoningLevel.swift
//  teemoon
//
//  Developer mode's reasoning level per model (docs/REASONING_LEVEL.md). Read per request off the main actor, so it
//  goes to UserDefaults directly. Never a compiled list of levels: the model's own, or the control's.
//

import Foundation

extension UserDefaults {
    /// KVO on the one key, so a view can follow a pick without redrawing on every other defaults write.
    @objc dynamic var reasoningLevels: [String: Any]? { dictionary(forKey: UserDefaultsKey.reasoningLevels) }
}

enum ReasoningLevel {
    /// Low to high, for "is the choice above high"; a level outside it (a provider's new name) ranks as low.
    private static let order = ["none", "minimal", "low", "medium", "high", "xhigh"]

    static func menu(for control: ReasoningControl, offered: [String]) -> [String] {
        switch control {
        case .effort: return ["low", "medium", "high"]
        // Low is what goes without a choice, so it stays on the menu even where the model's list omits it.
        case .openRouter: return offered.isEmpty ? ["low", "medium", "high"] : offered.contains("low") ? offered : offered + ["low"]
        case .thinkingSwitch, .onDevice: return ["off", "on"]
        case .none: return []
        }
    }

    static func defaultLevel(for control: ReasoningControl) -> String {
        switch control {
        case .thinkingSwitch, .onDevice: return "off"
        case .effort, .openRouter, .none: return "low"
        }
    }

    static func key(_ provider: Provider) -> String {
        "\(provider.openAIBaseURL?.host?.lowercased() ?? "")|\(provider.model)"
    }

    /// What was picked, whether or not developer mode is on now.
    static func stored(for provider: Provider, in defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: UserDefaultsKey.reasoningLevels) as? [String: String])?[key(provider)]
    }

    /// The level in force: none with developer mode off, so everyone sends today's low.
    static func chosen(for provider: Provider, in defaults: UserDefaults = .standard) -> String? {
        guard defaults.bool(forKey: UserDefaultsKey.developerModeEnabled) else { return nil }
        return stored(for: provider, in: defaults)
    }

    /// nil goes back to the default.
    static func set(_ level: String?, for provider: Provider, in defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: UserDefaultsKey.reasoningLevels) as? [String: String]) ?? [:]
        all[key(provider)] = level
        defaults.set(all, forKey: UserDefaultsKey.reasoningLevels)
    }

    /// Think Harder never thinks less than the plain send.
    static func sent(_ effort: ReasoningEffort, chosen: String?) -> String {
        guard effort == .thinkHarder else { return chosen ?? "low" }
        guard let chosen, let rank = order.firstIndex(of: chosen), rank > order.firstIndex(of: "high")! else { return "high" }
        return chosen
    }

    static func thinksOnDevice(_ effort: ReasoningEffort, chosen: String?) -> Bool {
        effort == .thinkHarder || chosen == "on"
    }

    /// A stored level the control can't send (the setup changed kind) counts as no choice.
    static func usable(_ chosen: String?, for control: ReasoningControl) -> String? {
        guard let chosen else { return nil }
        // OpenRouter's list is per model and lives in the catalogue, so any of its names is taken as given.
        let levels = control == .openRouter ? [chosen] : menu(for: control, offered: [])
        return levels.contains(chosen) ? chosen : nil
    }

    /// The level a turn's request carries, read from the body fields it sends with the card's own parser (not
    /// recomputed): "high", or the pick when it is above high; "on" for a thinking switch or the phone; nil after a
    /// refusal, when none is sent (the maintainer 2026-11-14, the chip during a Think Harder).
    static func turnLabel(effort: ReasoningEffort, provider: Provider, chosen: String?) -> String? {
        if ReasoningControl.current(for: provider) == .onDevice {
            return thinksOnDevice(effort, chosen: chosen) ? "on" : "off"
        }
        guard let fields = effort.bodyFields(for: provider, chosen: chosen),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys),
              let sent = ReasoningEffort.sentLevel(inBodyJSON: String(decoding: data, as: UTF8.self)) else { return nil }
        return sent.replacingOccurrences(of: "effort ", with: "").replacingOccurrences(of: "thinking ", with: "")
    }

    /// The where chip's level after the model name; nil without developer mode, for a model that is sent none, and
    /// after a refusal (nothing goes on the wire then).
    static func chipLevel(setup: Provider?, control: ReasoningControl?, developerMode: Bool, offered: [String],
                          stored: String?) -> String? {
        guard let row = Row(setup: setup, control: control, developerMode: developerMode, offered: offered),
              !row.refused else { return nil }
        return row.value(stored: stored)
    }

    /// Model info's capability chips: with developer mode off not even "reasoning" / "reasoning (required)" (the maintainer
    /// 2026-11-13, "Yes yes").
    static func visibleFeatures(_ features: [String], developerMode: Bool) -> [String] {
        developerMode ? features : features.filter { !$0.lowercased().hasPrefix("reasoning") }
    }

    /// The where sheet's middle stop: 2/3 of the screen, its top at about 34% ("Ok make bigger", the maintainer 2026-11-13;
    /// `.medium` showed 2 of 12 models above the reasoning bar on a 16 Pro). Android matches.
    static func whereMiddleHeight(screenHeight: CGFloat) -> CGFloat { screenHeight * 2 / 3 }

    /// The where sheet opens large where half height leaves about one model row: accessibility sizes and short phones
    /// (667 pt and under: SE, mini; the maintainer 2026-11-13).
    static func whereOpensLarge(accessibilitySize: Bool, screenHeight: CGFloat) -> Bool {
        accessibilitySize || screenHeight <= 667
    }

    /// Model info's read-only "reasoning" line: the levels in developer mode, nothing at all without it.
    static func infoLine(setup: Provider?, control: ReasoningControl?, developerMode: Bool, offered: [String]) -> String? {
        guard developerMode else { return nil }
        if let row = Row(setup: setup, control: control, developerMode: true, offered: offered) {
            return row.levels.joined(separator: ", ")
        }
        return offered.isEmpty ? nil : offered.joined(separator: ", ")
    }

    /// The detail page's row; nil means today's read-only row.
    struct Row: Equatable {
        let levels: [String]
        let defaultLevel: String
        let refused: Bool

        /// `control` nil reads what the transport last noted for this setup.
        init?(setup: Provider?, control: ReasoningControl? = nil, developerMode: Bool, offered: [String]) {
            guard developerMode, let setup else { return nil }
            let control = control ?? ReasoningControl.current(for: setup)
            levels = ReasoningLevel.menu(for: control, offered: offered)
            guard !levels.isEmpty else { return nil }
            defaultLevel = ReasoningLevel.defaultLevel(for: control)
            refused = ReasoningEffort.wasRefused(by: setup)
        }

        func label(_ level: String) -> String { level == defaultLevel ? "\(level) (default)" : level }
        /// The where sheet's bar: the level with "(default)", or the model's own default after a refusal.
        func barValue(stored: String?) -> String { refused ? "model's default" : label(value(stored: stored)) }

        /// The refusal first, as its own paragraph, then what the levels mean.
        func pageFooter(stored: String?) -> String {
            let base = "higher levels think longer before answering, so replies take longer and can cost more."
            return footer(stored: stored).map { "\($0)\n\n\(base)" } ?? base
        }
        /// The picked level, or the default when nothing is picked or the list no longer has it.
        func value(stored: String?) -> String { stored.flatMap { levels.contains($0) ? $0 : nil } ?? defaultLevel }

        /// After a refusal no field is sent: the row reads "model's default" and this names the pick the server turned down.
        func footer(stored: String?) -> String? {
            guard refused else { return nil }
            return "the server refused \(value(stored: stored)), so teemoon leaves the setting out and this model uses its own default for now."
        }
    }

    /// A model on a setup, as the chip, the where sheet and model info need it: the setup moved to that model, how
    /// it is told to think, and the levels its catalogue entry lists.
    struct Setup {
        let provider: Provider
        let control: ReasoningControl
        let offered: [String]

        @MainActor init(_ setup: Provider, model: String, store: ProviderStore) {
            var provider = setup
            provider.model = model
            self.provider = provider
            control = ReasoningControl.resolve(provider: provider, store: store)
            offered = Self.offered(provider)
        }

        /// Where no store is at hand (the model browser): the kind its door was opened with.
        @MainActor init(_ setup: Provider, model: String, serverKind: LocalServerKind?) {
            var provider = setup
            provider.model = model
            self.provider = provider
            let entry = LiveCatalogStore.shared.allModels(forEndpoint: provider.endpoint).first { $0.id == model }
            control = ReasoningControl.resolve(provider: provider, serverKind: serverKind,
                                               modelParameters: entry?.samplingParameters)
            offered = entry?.reasoningEfforts ?? []
        }

        @MainActor private static func offered(_ provider: Provider) -> [String] {
            LiveCatalogStore.shared.allModels(forEndpoint: provider.endpoint)
                .first { $0.id == provider.model }?.reasoningEfforts ?? []
        }

        /// The where chip's level for this model now (developer mode's).
        func chipLevel(developerMode: Bool) -> String? {
            ReasoningLevel.chipLevel(setup: provider, control: control, developerMode: developerMode, offered: offered,
                                     stored: ReasoningLevel.stored(for: provider))
        }

        func row(developerMode: Bool) -> Row? {
            Row(setup: provider, control: control, developerMode: developerMode, offered: offered)
        }
    }
}
