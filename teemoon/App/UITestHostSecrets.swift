//
//  UITestHostSecrets.swift
//  teemoon
//
//  Simulator UI tests may load a near.ai key from a file on the Mac. They
//  must not take it from the process environment: `NEAR_AI_API_KEY=…` shows
//  up in `ps`, in xcodebuild's launch log, and in anything that dumps
//  `launchEnvironment`.
//
//  DEBUG + `--uitesting` + simulator only. A shipping build has none of this.
//  An existing Keychain entry is never overwritten.
//

import Foundation

#if DEBUG
enum UITestHostSecrets {

    /// Host-home filenames, same pair the live unit suites already accept.
    static let nearAIFileNames = [".NEAR_AI_API_KEY", ".nearai_api_key"]
    static let grokFileNames = [".XAI_API_KEY", ".xai_api_key"]
    static let fireworksFileNames = [".FIREWORKS_API_KEY", ".fireworks_api_key"]
    static let braveAnswersFileNames = [".BRAVE_ANSWERS_API_KEY"]
    /// Brave *Search* / grounding — not the Answers chat key.
    static let braveGroundingFileNames = [".BRAVE_API_KEY", ".brave_api_key"]

    static func keyFileNames(forPreset raw: String) -> [String] {
        switch raw.lowercased() {
        case "nearai", "near.ai", "near": return nearAIFileNames
        case "grok", "xai":               return grokFileNames
        case "fireworks":                 return fireworksFileNames
        case "brave", "braveanswers":     return braveAnswersFileNames
        default:                          return []
        }
    }

    static func keyFromHostFile(preset: String) -> String? {
        let names = keyFileNames(forPreset: preset)
        // 1. Files the UI-test runner copied into this app container.
        //    The sandboxed app often cannot read /Users/… even when
        //    SIMULATOR_HOST_HOME is set; unit tests can, UI launches cannot.
        if let key = readKey(hostHome: stagedKeysDirectory, names: names) { return key }
        // 2. Path-only env the runner forwards. Not a reserved SIMULATOR_* name
        //    (those can be stripped from XCUIApplication.launchEnvironment).
        if let key = readKey(hostHome: teemoonHostHome, names: names) { return key }
        // 3. Apple's own host-home, when the runtime actually exposes it.
        return readKey(hostHome: simulatorHostHome, names: names)
    }

    /// Read a key from `hostHome/<name>`. `hostHome` is a directory the
    /// caller already decided is allowed — never a process-environment secret.
    static func readKey(hostHome: String?, names: [String] = nearAIFileNames) -> String? {
        guard let hostHome, !hostHome.isEmpty else { return nil }
        for name in names {
            let url = URL(fileURLWithPath: hostHome).appendingPathComponent(name)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Directory the UI-test runner stages `~/.…_API_KEY` files into.
    /// Prefer `TEEMOON_STAGED_KEYS` (sim tmp the runner can write); fall back
    /// to this app's Application Support in case a later launch copies there.
    static var stagedKeysDirectory: String? {
        if let path = ProcessInfo.processInfo.environment["TEEMOON_STAGED_KEYS"], !path.isEmpty {
            return path
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("uitest-host-keys", isDirectory: true)
            .path
    }

    /// Mac home forwarded as `TEEMOON_HOST_HOME` (path only, never the key).
    static var teemoonHostHome: String? {
        let home = ProcessInfo.processInfo.environment["TEEMOON_HOST_HOME"]
        return home?.isEmpty == false ? home : nil
    }

    /// The Mac home as the simulator runtime sees it. Nil on device.
    /// XCTest may omit this on the app process; the UI-test launcher
    /// forwards the path (not the key) via `TEEMOON_HOST_HOME`.
    static var simulatorHostHome: String? {
        #if targetEnvironment(simulator)
        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"]
        return home?.isEmpty == false ? home : nil
        #else
        return nil
        #endif
    }

    static func braveGroundingKeyFromHostFile() -> String? {
        let names = braveGroundingFileNames
        if let key = readKey(hostHome: stagedKeysDirectory, names: names) { return key }
        if let key = readKey(hostHome: teemoonHostHome, names: names) { return key }
        return readKey(hostHome: simulatorHostHome, names: names)
    }
}
#endif
