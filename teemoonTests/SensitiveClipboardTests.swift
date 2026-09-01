//
//  SensitiveClipboardTests.swift
//  teemoonTests
//
//  API keys used to be copied with `UIPasteboard.general.string = key`, which
//  is a Universal Clipboard broadcast: the key left the device to every Mac
//  and iPad on the same Apple Account and sat there until something else was
//  copied. `Clipboard.copySensitive` is the single choke point that bounds it
//  to this device and expires it.
//

import Foundation
import Testing
@testable import teemoon

#if canImport(UIKit)
import UIKit
#endif

@Suite("Sensitive clipboard", .serialized)
@MainActor
struct SensitiveClipboardTests {

    /// The paste has to still work — a credential copy that copies nothing is
    /// the other way to break this button, and it would look like a fix.
    @Test func copySensitive_roundTrips() {
        #if canImport(UIKit) && !os(watchOS)
        let key = "sk-test-\(UUID().uuidString)"
        Clipboard.copySensitive(key)
        #expect(UIPasteboard.general.string == key)
        #endif
    }

    /// Replacing the value replaces the ITEM — `setItems` with one item must
    /// not append, or the pasteboard accumulates every key ever copied and the
    /// expiry only ever clears the newest.
    @Test func copySensitive_replacesRatherThanAccumulates() {
        #if canImport(UIKit) && !os(watchOS)
        Clipboard.copySensitive("first-\(UUID().uuidString)")
        let second = "second-\(UUID().uuidString)"
        Clipboard.copySensitive(second)
        #expect(UIPasteboard.general.numberOfItems == 1)
        #expect(UIPasteboard.general.string == second)
        #endif
    }

    /// The bound is a real value, not a placeholder someone can quietly widen
    /// to a day. Two minutes is long enough to switch apps and paste.
    @Test func sensitiveLifetime_isShort() {
        #expect(Clipboard.sensitiveLifetime > 0)
        #expect(Clipboard.sensitiveLifetime <= 300)
    }
}
