//
//  TestFixture.swift
//  teemoonTests
//
//  Resolves a file under `teemoonTests/Fixtures/`.
//
//  Every loader used to compute the path from `#filePath`, which is the path of
//  the SOURCE FILE ON THE BUILD MACHINE. That works on a Mac and in a simulator,
//  which share the host filesystem, and fails on a device — where it produced 60+
//  "couldn't be opened because there is no such file" errors naming
//  /Users/someone/dev/... on a phone that has no such directory.
//
//  The Fixtures folder is already copied into the test bundle by the target's
//  Resources phase (the synchronized group picks it up), FLATTENED — every file
//  lands at the bundle root regardless of the subdirectory it lives in. So the
//  bundle is the one copy that exists everywhere, and it is tried first.
//
//  The `#filePath` route stays as a fallback for the things that genuinely are
//  host-only: tests that read teemoon's own SOURCE (LocalModelCatalogTests,
//  LocalInferenceOracleTests) can never work from a bundle, and should skip on
//  device rather than pretend.
//

import Foundation

enum TestFixture {

    /// The bytes of a fixture, by name — `"dcap_pcs_snapshot.json"`, or
    /// `"parsing/whatever.jsonl"` (the subdirectory is ignored in the bundle).
    static func data(_ name: String, file: String = #filePath) throws -> Data {
        try Data(contentsOf: try url(name, file: file))
    }

    static func string(_ name: String, file: String = #filePath) throws -> String {
        try String(contentsOf: try url(name, file: file), encoding: .utf8)
    }

    /// Bundle first, source tree second.
    static func url(_ name: String, file: String = #filePath) throws -> URL {
        if let bundled = bundled(name) { return bundled }
        let onDisk = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        guard FileManager.default.fileExists(atPath: onDisk.path) else {
            throw Missing(name: name)
        }
        return onDisk
    }

    /// Whether a fixture is reachable at all — for tests that must skip rather
    /// than fail where their input cannot exist.
    static func exists(_ name: String, file: String = #filePath) -> Bool {
        (try? url(name, file: file)) != nil
    }

    /// True when teemoon's own SOURCE is reachable.
    ///
    /// A handful of tests read the source itself — "every `supportsTools: true`
    /// carries a note of what was measured", "every error literal is in the
    /// catalog". Those cannot work from a bundle, and on a device there is no
    /// source tree at all, so they are `.enabled(if:)` on this rather than
    /// failing with a path from someone else's Mac.
    static func sourceTreeAvailable(file: String = #filePath) -> Bool {
        FileManager.default.fileExists(atPath: file)
    }

    /// Every bundled fixture with this extension. Replaces directory walks,
    /// which have nothing to walk once the resources are flattened.
    static func all(withExtension ext: String) -> [URL] {
        Bundle(for: BundleToken.self)
            .urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
    }

    private static func bundled(_ name: String) -> URL? {
        let leaf = (name as NSString).lastPathComponent          // drop any subdirectory
        let ext = (leaf as NSString).pathExtension
        let base = (leaf as NSString).deletingPathExtension
        return Bundle(for: BundleToken.self).url(forResource: base, withExtension: ext)
    }

    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String {
            "fixture '\(name)' is in neither the test bundle nor the source tree"
        }
    }

    /// Locates the test bundle. `Bundle.main` is the app host, not this bundle.
    private final class BundleToken {}
}
