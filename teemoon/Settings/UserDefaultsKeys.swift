//
//  UserDefaultsKeys.swift
//  teemoon
//

enum UserDefaultsKey {
    static let systemPrompt = "systemPrompt"
    static let appTintColor = "appTintColor"
    static let appFontDesign = "appFontDesign"
    static let appFontSize = "appFontSize"
    static let appFontWidth = "appFontWidth"
    static let shouldPlayHaptics = "shouldPlayHaptics"
    static let numberOfVisits = "numberOfVisits"
    static let numberOfVisitsOfLastRequest = "numberOfVisitsOfLastRequest"
    static let currentProviderID = "currentProviderID"
    static let braveGroundingEnabled = "braveGroundingEnabled"
    static let developerModeEnabled = "developerModeEnabled"
    static let providers = "providers"
    static let systemPromptVersion = "systemPromptVersion"
    /// Last N Where-sheet picks (provider id + model id), JSON-encoded.
    static let whereRecents = "whereRecents"
}
