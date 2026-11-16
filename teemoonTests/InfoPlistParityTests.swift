//
//  InfoPlistParityTests.swift
//  teemoonTests
//
//  teemoon ships TWO Info.plists — one for iOS/visionOS, one for macOS — and
//  they must stay identical apart from a small set of documented keys.
//
//  WHY THERE ARE TWO AT ALL
//
//  The split ORIGINALLY existed for CFBundleDocumentTypes: iOS requires
//  `LSSupportsOpeningDocumentsInPlace` beside declared document types
//  (ITMS-90737), and macOS rejects that key outright — so one file could not
//  serve both. The .teemoon backup document machinery was excised 2026-08-30;
//  the near.ai import (1.1.0) declares JSON on iOS again. The iOS-only keys are
//  listed in `allowedIOSOnlyKeys`.
//
//  This test is what makes the duplication safe. Two plists drift silently: someone
//  adds a URL scheme, a usage description, a document type to the one they had
//  open, ships it, and the other platform is quietly missing it — with no build
//  error anywhere, because both files are individually valid. So the delta is
//  pinned to exactly one key here, and anything else fails.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Info.plist parity")
struct InfoPlistParityTests {

    /// The only keys allowed to differ. Adding to this set is a decision about
    /// platform behaviour, not a way to make a failing test pass.
    ///
    /// - `CADisableMinimumFrameDurationOnPhone` — opts the stream pacer out of
    ///   the 60 Hz cap iOS imposes on ProMotion iPhones. It is iPhone-only by
    ///   name and by definition: macOS never caps a layer's frame duration this
    ///   way, so there is no Mac behaviour for it to assert. Copying it into
    ///   Info-macOS.plist would satisfy parity while meaning nothing.
    /// - `NSLocalNetworkUsageDescription` — the string shown by iOS's Local
    ///   Network permission dialog, which macOS does not have. (The ATS
    ///   `NSAllowsLocalNetworking` exception it accompanies IS in both
    ///   plists: both platforms speak plain HTTP to a Mac running Ollama.)
    /// - `CFBundleDocumentTypes` + `LSSupportsOpeningDocumentsInPlace` — the near.ai import (1.1.0): a JSON
    ///   export opened from Files or the share sheet. iOS requires the second key beside the first (ITMS-90737)
    ///   and macOS rejects it; the Mac imports from Settings only.
    /// - `CFBundleURLTypes` — share to teemoon (1.1.0): the share extension opens `<bundle id>://share/<uuid>`. iOS
    ///   only; the Mac has no share extension.
    static let allowedIOSOnlyKeys: Set<String> = [
        "CADisableMinimumFrameDurationOnPhone",
        "NSLocalNetworkUsageDescription",
        "CFBundleDocumentTypes",
        "LSSupportsOpeningDocumentsInPlace",
        "CFBundleURLTypes",
    ]

    private static func plist(_ name: String, file: String = #filePath) throws -> [String: Any] {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()      // teemoonTests/
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("teemoon/\(name)")
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(parsed as? [String: Any], "\(name) is not a dictionary")
    }

    @Test(.enabled(if: TestFixture.sourceTreeAvailable()))
    func theTwoPlistsDifferOnlyByTheDocumentedKey() throws {
        let ios = try Self.plist("Info.plist")
        let mac = try Self.plist("Info-macOS.plist")

        let iosOnly = Set(ios.keys).subtracting(mac.keys)
        let macOnly = Set(mac.keys).subtracting(ios.keys)

        #expect(iosOnly == Self.allowedIOSOnlyKeys,
                """
                Info.plist has keys Info-macOS.plist does not: \
                \(iosOnly.sorted()). Only \(Self.allowedIOSOnlyKeys.sorted()) may differ — \
                add the new key to BOTH files.
                """)
        #expect(macOnly.isEmpty,
                """
                Info-macOS.plist has keys Info.plist does not: \(macOnly.sorted()). \
                Add them to BOTH files.
                """)
    }

    @Test(.enabled(if: TestFixture.sourceTreeAvailable()))
    func sharedKeysHaveIdenticalValues() throws {
        let ios = try Self.plist("Info.plist")
        let mac = try Self.plist("Info-macOS.plist")

        for key in Set(ios.keys).intersection(mac.keys).sorted() {
            let a = ios[key] as? NSObject
            let b = mac[key] as? NSObject
            #expect(a == b, "'\(key)' differs between the two plists: \(a as Any) vs \(b as Any)")
        }
    }

    /// The backup document machinery was EXCISED (2026-08-30): no importer or exporter existed, so an Owner
    /// claim was a promise the app could not keep. The one declaration now is the near.ai import's: iOS views
    /// JSON at Alternate rank (offered, never the default JSON app), with an importer behind it
    /// (ChatImportModel). No exported type, no Owner role, and nothing on the Mac.
    @Test(.enabled(if: TestFixture.sourceTreeAvailable()))
    func onlyTheImportDeclaresADocumentType() throws {
        let ios = try Self.plist("Info.plist")
        let types = try #require(ios["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(types.count == 1)
        #expect(types.first?["CFBundleTypeRole"] as? String == "Viewer")
        #expect(types.first?["LSHandlerRank"] as? String == "Alternate")
        #expect(types.first?["LSItemContentTypes"] as? [String] == ["public.json"])
        #expect(ios["LSSupportsOpeningDocumentsInPlace"] != nil, "ITMS-90737: declared document types need it")
        for name in ["Info.plist", "Info-macOS.plist"] {
            #expect(try Self.plist(name)["UTExportedTypeDeclarations"] == nil, "\(name) exports a type with no exporter")
        }
        let mac = try Self.plist("Info-macOS.plist")
        #expect(mac["CFBundleDocumentTypes"] == nil && mac["LSSupportsOpeningDocumentsInPlace"] == nil)
    }
}
