import Foundation
import Testing
@testable import teemoon

// MARK: - Siri app-name matching
//
// "Hey Siri, ask teemoon…" was matching Temu instead. Two causes, both in the
// build inputs rather than in Swift:
//
//   1. The shipping display name is "teemoon.ai" — `INFOPLIST_KEY_CFBundleDisplayName`
//      in project.pbxproj (both configs) overrides `CFBundleDisplayName` in
//      Info.plist, so the plist's `$(APP_DISPLAY_NAME:default=teemoon)` never
//      takes effect. Every `NewChatShortcut` phrase interpolates
//      `\(.applicationName)`, so the recognizer was matching against
//      "teemoon dot ay eye"; nearest high-frequency neighbour is Temu.
//   2. No `INAlternativeAppNames` existed — Apple's designed remedy for this.
//
// These tests read `Bundle.main`, which in this hosted test target is the APP
// bundle's processed Info.plist — i.e. what actually ships, build settings
// applied. That is the point: a build-setting override is what caused the bug,
// and a test against the source plist would not have seen it.
//
// Voice matching itself is empirical and untestable here; these only pin that
// the names Siri indexes are present, well-formed, and within Apple's cap.
//
// That cap is hard: installd REFUSES the bundle at four or more —
// "has 4 INAlternativeAppNames in its Info.plist, maximum of 3 allowed" — so a
// fourth entry is not silently ignored, it makes the app unable to install at
// all. The first draft of this fix had four ("T moon" was the one dropped) and
// failed exactly that way on the simulator.

@Suite("Siri app-name matching")
struct SiriAppNameTests {

    private var alternativeNames: [String] {
        let raw = Bundle.main.object(forInfoDictionaryKey: "INAlternativeAppNames") as? [[String: Any]]
        return (raw ?? []).compactMap { $0["INAlternativeAppName"] as? String }
    }

    /// The key must survive into the built app, not just sit in the source plist.
    @Test func alternativeAppNames_shipInTheBuiltBundle() {
        #expect(!alternativeNames.isEmpty,
                "INAlternativeAppNames missing from the built Info.plist — Siri will only match the display name")
    }

    /// The two-word form is the one that pulls the recognizer off the single
    /// token "Temu"; the bare form covers the spoken name people actually use.
    @Test func alternativeAppNames_includeTheWordBrokenForms() {
        let names = alternativeNames
        #expect(names.contains("tee moon"), "the word-boundary form is the load-bearing one; got \(names)")
        #expect(names.contains("teemoon"), "got \(names)")
    }

    /// Siri indexes these at install time; an empty or malformed entry is
    /// silently dropped, so pin the shape rather than trusting the plist edit.
    @Test func alternativeAppNames_areNonEmptyStrings() {
        for name in alternativeNames {
            #expect(!name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// The Siri phrases in `NewChatShortcut` all interpolate `\(.applicationName)`,
    /// which resolves to this. It was "teemoon.ai" — spoken "teemoon dot ay eye" —
    /// because `INFOPLIST_KEY_CFBundleDisplayName` in project.pbxproj overrode the
    /// Info.plist value. Both lines are gone; do not reintroduce the build setting,
    /// it silently wins over the plist. This also matches the App Store listing name.
    @Test func displayName_isTheSpokenName() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        #expect(name == "teemoon", "got \(name ?? "nil") — a build setting is overriding Info.plist again")
    }

    /// A fourth name does not degrade — it makes the app refuse to install.
    /// Do not add one without removing another.
    @Test func alternativeAppNames_stayWithinApplesCapOfThree() {
        #expect(alternativeNames.count <= 3,
                "installd rejects the bundle above 3; got \(alternativeNames.count)")
    }
}
