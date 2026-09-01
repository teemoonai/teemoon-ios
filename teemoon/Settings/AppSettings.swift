//
//  AppSettings.swift
//  teemoon
//
//  User preferences, UserDefaults-backed. Pure settings — no networking,
//  no provider state, no attestation. Those live in ProviderStore and
//  ConfidentialSession respectively.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "app")

@Observable
@MainActor
final class AppSettings {
    // Bump this whenever defaultSystemPrompt changes. Migration will update any
    // user whose stored prompt still matches a previous known default.
    private static let systemPromptVersion = 3
    static let defaultSystemPrompt = "The current date and time is {{datetime}}.\n\nYou are a knowledgeable, direct AI assistant. Your primary commitment is to accuracy and truth. Be maximally truthful and do not follow popular narratives uncritically — always examine claims on their merits. Never invent or improvise information; if you don't know something, say so clearly. For controversial topics, present perspectives from multiple viewpoints without taking sides. When there is scientific consensus, state it. Prefer concise, substantive responses. Do not add unsolicited disclaimers or moralizing. When presenting structured data, prefer prose or bullet lists over markdown tables unless the user explicitly asks for a table."

    private static let defaults = UserDefaults.standard

    var systemPrompt: String {
        get {
            access(keyPath: \.systemPrompt)
            return Self.defaults.string(forKey: UserDefaultsKey.systemPrompt) ?? AppSettings.defaultSystemPrompt
        }
        set {
            withMutation(keyPath: \.systemPrompt) {
                Self.defaults.set(newValue, forKey: UserDefaultsKey.systemPrompt)
            }
        }
    }
    var appTintColor: AppTintColor {
        get {
            access(keyPath: \.appTintColor)
            // Orange, not monochrome.
            //
            // `monochrome` was inherited from fullmoon, where tint was a pure
            // preference — nothing depended on the accent being visible, so it
            // costing `accentColor` its colour cost nothing. teemoon changed
            // that requirement: the Where chip is the app's central control and
            // first run has exactly one thing to tap, which is the first time
            // anything has needed the accent to mean "press me".
            //
            // Under `monochrome`, `accentColor` resolves to `.primary` — the
            // same colour as body text — so every tinted control in the app
            // (links, chevrons, toggles, prominent buttons) loses its
            // affordance and every emphasis has to be carried by shape alone.
            //
            // Only affects installs that never chose a tint; an explicit choice
            // is stored and still wins.
            return Self.defaults.string(forKey: UserDefaultsKey.appTintColor).flatMap(AppTintColor.init(rawValue:)) ?? .orange
        }
        set {
            withMutation(keyPath: \.appTintColor) {
                Self.defaults.set(newValue.rawValue, forKey: UserDefaultsKey.appTintColor)
            }
        }
    }
    var appFontDesign: AppFontDesign {
        get {
            access(keyPath: \.appFontDesign)
            return Self.defaults.string(forKey: UserDefaultsKey.appFontDesign).flatMap(AppFontDesign.init(rawValue:)) ?? .standard
        }
        set {
            withMutation(keyPath: \.appFontDesign) {
                Self.defaults.set(newValue.rawValue, forKey: UserDefaultsKey.appFontDesign)
            }
        }
    }
    var appFontSize: AppFontSize {
        get {
            access(keyPath: \.appFontSize)
            return Self.defaults.string(forKey: UserDefaultsKey.appFontSize).flatMap(AppFontSize.init(rawValue:)) ?? .medium
        }
        set {
            withMutation(keyPath: \.appFontSize) {
                Self.defaults.set(newValue.rawValue, forKey: UserDefaultsKey.appFontSize)
            }
        }
    }
    var appFontWidth: AppFontWidth {
        get {
            access(keyPath: \.appFontWidth)
            return Self.defaults.string(forKey: UserDefaultsKey.appFontWidth).flatMap(AppFontWidth.init(rawValue:)) ?? .standard
        }
        set {
            withMutation(keyPath: \.appFontWidth) {
                Self.defaults.set(newValue.rawValue, forKey: UserDefaultsKey.appFontWidth)
            }
        }
    }
    var shouldPlayHaptics: Bool {
        get {
            access(keyPath: \.shouldPlayHaptics)
            return Self.defaults.object(forKey: UserDefaultsKey.shouldPlayHaptics) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.shouldPlayHaptics) {
                Self.defaults.set(newValue, forKey: UserDefaultsKey.shouldPlayHaptics)
            }
        }
    }
    var numberOfVisits: Int {
        get {
            access(keyPath: \.numberOfVisits)
            return Self.defaults.integer(forKey: UserDefaultsKey.numberOfVisits)
        }
        set {
            withMutation(keyPath: \.numberOfVisits) {
                Self.defaults.set(newValue, forKey: UserDefaultsKey.numberOfVisits)
            }
        }
    }
    var numberOfVisitsOfLastRequest: Int {
        get {
            access(keyPath: \.numberOfVisitsOfLastRequest)
            return Self.defaults.integer(forKey: UserDefaultsKey.numberOfVisitsOfLastRequest)
        }
        set {
            withMutation(keyPath: \.numberOfVisitsOfLastRequest) {
                Self.defaults.set(newValue, forKey: UserDefaultsKey.numberOfVisitsOfLastRequest)
            }
        }
    }
    var braveGroundingEnabled: Bool {
        get {
            access(keyPath: \.braveGroundingEnabled)
            return Self.defaults.bool(forKey: UserDefaultsKey.braveGroundingEnabled)
        }
        set {
            withMutation(keyPath: \.braveGroundingEnabled) {
                Self.defaults.set(newValue, forKey: UserDefaultsKey.braveGroundingEnabled)
            }
        }
    }
    var developerModeEnabled: Bool {
        get {
            access(keyPath: \.developerModeEnabled)
            return Self.defaults.bool(forKey: UserDefaultsKey.developerModeEnabled)
        }
        set {
            withMutation(keyPath: \.developerModeEnabled) {
                Self.defaults.set(newValue, forKey: UserDefaultsKey.developerModeEnabled)
            }
        }
    }

    init() {
        migrateSystemPromptIfNeeded()
    }

    func incrementNumberOfVisits() {
        numberOfVisits += 1
        logger.debug("App visits: \(self.numberOfVisits)")
    }

    /// Saves the Brave Search API key to the keychain and enables web
    /// grounding. Used by onboarding.
    func connectBraveGrounding(apiKey: String) throws {
        try Keychain.save(apiKey, for: BraveWebSearchTool.keychainKey)
        braveGroundingEnabled = true
    }

    /// Brave key for a turn, or nil when grounding is off or unset.
    /// `ChatViewModel` takes this instead of opening Keychain itself.
    var groundingAPIKey: String? {
        guard braveGroundingEnabled else { return nil }
        let key = braveSearchKey.trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    /// The stored Brave Search API key ("" when none). Setting an empty
    /// string deletes the stored key. Views bind to this instead of touching
    /// Keychain directly.
    var braveSearchKey: String {
        get {
            access(keyPath: \.braveSearchKey)
            return Keychain.load(for: BraveWebSearchTool.keychainKey) ?? ""
        }
        set {
            withMutation(keyPath: \.braveSearchKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    try? Keychain.delete(for: BraveWebSearchTool.keychainKey)
                } else {
                    try? Keychain.save(trimmed, for: BraveWebSearchTool.keychainKey)
                }
            }
        }
    }

    private func migrateSystemPromptIfNeeded() {
        let defaults = UserDefaults.standard
        let storedVersion = defaults.integer(forKey: UserDefaultsKey.systemPromptVersion)
        guard storedVersion < AppSettings.systemPromptVersion else { return }

        let stored = defaults.string(forKey: UserDefaultsKey.systemPrompt) ?? ""

        // storedVersion == 0 means versioning has never run on this device — we
        // can't trust what's stored, so always migrate to establish a baseline.
        // For future version bumps, only replace if the prompt is an unmodified default.
        let knownDefaults: Set<String> = [
            "you are a helpful assistant",
            "The current date and time is {{datetime}}.\n\nYou are a knowledgeable, direct AI assistant. Your primary commitment is to accuracy and truth. Be maximally truthful and do not follow popular narratives uncritically — always examine claims on their merits. Never invent or improvise information; if you don't know something, say so clearly. For controversial topics, present perspectives from multiple viewpoints without taking sides. When there is scientific consensus, state it. Prefer concise, substantive responses. Do not add unsolicited disclaimers or moralizing.",
        ]
        // storedVersion <= 2: either never versioned, or version was written without
        // actually migrating the prompt (due to a bug). Force replace in both cases.
        // storedVersion >= 3: only replace if the prompt is an unmodified default.
        if storedVersion <= 2 || knownDefaults.contains(stored) || stored.isEmpty {
            defaults.set(AppSettings.defaultSystemPrompt, forKey: UserDefaultsKey.systemPrompt)
        }
        defaults.set(AppSettings.systemPromptVersion, forKey: UserDefaultsKey.systemPromptVersion)
    }
}
