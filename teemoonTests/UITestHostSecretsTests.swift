//
//  UITestHostSecretsTests.swift
//  teemoonTests
//

import Foundation
import Testing
@testable import teemoon

#if DEBUG
@Suite("UITestHostSecrets")
struct UITestHostSecretsTests {

    @Test func readsTrimmedKeyFromHostHomeFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-host-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "  sk-from-file \n".write(to: dir.appendingPathComponent(".NEAR_AI_API_KEY"),
                                     atomically: true, encoding: .utf8)
        #expect(UITestHostSecrets.readKey(hostHome: dir.path) == "sk-from-file")
    }

    @Test func missingHostHomeIsNil() {
        #expect(UITestHostSecrets.readKey(hostHome: nil) == nil)
        #expect(UITestHostSecrets.readKey(hostHome: "") == nil)
        #expect(UITestHostSecrets.readKey(hostHome: "/tmp/does-not-exist-\(UUID().uuidString)") == nil)
    }

    @Test func prefersNEAR_AI_API_KEYFilename() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-host-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "from-canonical".write(to: dir.appendingPathComponent(".NEAR_AI_API_KEY"),
                                   atomically: true, encoding: .utf8)
        try "from-alt".write(to: dir.appendingPathComponent(".nearai_api_key"),
                             atomically: true, encoding: .utf8)
        #expect(UITestHostSecrets.readKey(hostHome: dir.path) == "from-canonical")
    }

    @Test func mapsPresetToHostFilenames() {
        #expect(UITestHostSecrets.keyFileNames(forPreset: "fireworks") == [".FIREWORKS_API_KEY", ".fireworks_api_key"])
        #expect(UITestHostSecrets.keyFileNames(forPreset: "grok") == [".XAI_API_KEY", ".xai_api_key"])
        #expect(UITestHostSecrets.keyFileNames(forPreset: "brave") == [".BRAVE_ANSWERS_API_KEY"])
        #expect(UITestHostSecrets.braveGroundingFileNames == [".BRAVE_API_KEY", ".brave_api_key"])
    }

    @Test func readsFireworksAndGrokFilenames() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-host-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "fw-key".write(to: dir.appendingPathComponent(".FIREWORKS_API_KEY"),
                           atomically: true, encoding: .utf8)
        try "xai-key".write(to: dir.appendingPathComponent(".XAI_API_KEY"),
                            atomically: true, encoding: .utf8)
        #expect(UITestHostSecrets.readKey(hostHome: dir.path,
                                          names: UITestHostSecrets.fireworksFileNames) == "fw-key")
        #expect(UITestHostSecrets.readKey(hostHome: dir.path,
                                          names: UITestHostSecrets.grokFileNames) == "xai-key")
    }
}
#endif
