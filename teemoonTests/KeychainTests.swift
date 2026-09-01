import Foundation
import Testing
@testable import teemoon

@Suite("Keychain")
struct KeychainTests {

    // MARK: - Input validation

    @Test func save_emptyKey_throws() {
        #expect(throws: Keychain.KeychainError.self) {
            try Keychain.save("value", for: "")
        }
    }

    @Test func save_emptyValue_throws() {
        #expect(throws: Keychain.KeychainError.self) {
            try Keychain.save("", for: "test-key")
        }
    }

    @Test func load_emptyKey_returnsNil() {
        let result = Keychain.load(for: "")
        #expect(result == nil)
    }

    // MARK: - Save / Load / Delete roundtrip
    // These tests use the real iOS Keychain — they will only work in a simulator/device context.

    private let testKey = "ai.teemoon.test.\(UUID().uuidString)"

    @Test func saveAndLoad_roundtrip() throws {
        let value = "test-api-key-\(UUID().uuidString)"
        try Keychain.save(value, for: testKey)
        let loaded = Keychain.load(for: testKey)
        #expect(loaded == value)
        // Cleanup
        try Keychain.delete(for: testKey)
    }

    @Test func save_overwritesExistingValue() throws {
        try Keychain.save("first", for: testKey)
        try Keychain.save("second", for: testKey)
        let loaded = Keychain.load(for: testKey)
        #expect(loaded == "second")
        try Keychain.delete(for: testKey)
    }

    /// Overwriting must never pass through a state where NOTHING is stored.
    ///
    /// `save` used to be `SecItemDelete` then `SecItemAdd`, which has no
    /// duplicate problem but is not atomic: if the add failed after the delete
    /// landed, the old key was gone and the new one was never written — an
    /// unrecoverable loss of a secret the user has to go re-fetch from a vendor.
    /// It is `SecItemUpdate`, falling back to add, so a failure leaves the
    /// stored value exactly as it was.
    ///
    /// The failing add cannot be provoked from a test, so this pins what CAN be
    /// checked: repeated overwrites keep the latest value and never lose one.
    @Test func save_repeatedOverwrites_neverLoseTheValue() throws {
        let key = "test-overwrite-\(UUID().uuidString)"
        defer { try? Keychain.delete(for: key) }
        for i in 1...5 {
            try Keychain.save("value-\(i)", for: key)
            #expect(Keychain.load(for: key) == "value-\(i)")
        }
    }

    /// An add path and an update path must produce the same stored result —
    /// otherwise the first write and every later one disagree.
    @Test func save_firstWriteAndOverwriteAgree() throws {
        let key = "test-agree-\(UUID().uuidString)"
        defer { try? Keychain.delete(for: key) }
        try Keychain.save("same", for: key)          // add branch
        let afterAdd = Keychain.load(for: key)
        try Keychain.save("same", for: key)          // update branch
        #expect(Keychain.load(for: key) == afterAdd)
    }

    @Test func delete_removesValue() throws {
        try Keychain.save("to-delete", for: testKey)
        try Keychain.delete(for: testKey)
        let loaded = Keychain.load(for: testKey)
        #expect(loaded == nil)
    }

    @Test func delete_nonexistentKey_doesNotThrow() throws {
        // Should not throw for keys that don't exist
        try Keychain.delete(for: "ai.teemoon.nonexistent.\(UUID().uuidString)")
    }

    @Test func load_nonexistentKey_returnsNil() {
        let loaded = Keychain.load(for: "ai.teemoon.nonexistent.\(UUID().uuidString)")
        #expect(loaded == nil)
    }

    @Test func save_specialCharacters() throws {
        let value = "sk-proj-abc123!@#$%^&*()_+-=[]{}|;':\",./<>?"
        try Keychain.save(value, for: testKey)
        let loaded = Keychain.load(for: testKey)
        #expect(loaded == value)
        try Keychain.delete(for: testKey)
    }

    @Test func save_unicodeValue() throws {
        let value = "日本語テスト-🔑-مفتاح"
        try Keychain.save(value, for: testKey)
        let loaded = Keychain.load(for: testKey)
        #expect(loaded == value)
        try Keychain.delete(for: testKey)
    }

    @Test func save_longValue() throws {
        let value = String(repeating: "a", count: 10_000)
        try Keychain.save(value, for: testKey)
        let loaded = Keychain.load(for: testKey)
        #expect(loaded == value)
        try Keychain.delete(for: testKey)
    }

    // MARK: - KeychainError

    @Test func keychainError_localizedDescription() {
        let saveError = Keychain.KeychainError.saveFailed(-25299)
        #expect(saveError.localizedDescription.contains("-25299"))

        let deleteError = Keychain.KeychainError.deleteFailed(-25300)
        #expect(deleteError.localizedDescription.contains("-25300"))

        let inputError = Keychain.KeychainError.invalidInput("empty key")
        #expect(inputError.localizedDescription.contains("empty key"))
    }
}
