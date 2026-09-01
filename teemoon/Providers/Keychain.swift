//
//  Keychain.swift
//  teemoon
//

import Foundation
import os
import Security

private let logger = Logger(subsystem: "ai.teemoon", category: "keychain")

struct Keychain {
    private static let service = "ai.teemoon.apikeys"

    static func save(_ value: String, for key: String) throws {
        guard !key.isEmpty else { throw KeychainError.invalidInput("key must not be empty") }
        guard !value.isEmpty else { throw KeychainError.invalidInput("value must not be empty") }
        let data = Data(value.utf8)

        // UPDATE, THEN ADD — never delete-then-add.
        //
        // The delete-then-add form has no duplicate problem (that is why it was
        // written that way), but it is NOT ATOMIC: the delete lands first, so if
        // the add then fails — locked before first unlock, an entitlement
        // problem, a storage error — the OLD KEY IS GONE and the new one was
        // never written. The throw tells the caller something failed; it cannot
        // tell them the previous value is unrecoverable, and a lost inference
        // key costs a trip to a vendor console.
        //
        // `SecItemUpdate` either replaces the value or leaves the stored one
        // exactly as it was. Nothing is destroyed to make room.
        let search: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        // Accessibility is updated alongside the value, so an item written
        // before that attribute was set does not keep the old protection class
        // forever — an add-only fix would never reach items already stored.
        //
        // AfterFirstUnlock (not ...ThisDeviceOnly) is deliberate — decided in
        // the 2026-08 OSS audit (item 0.6): provider API keys restore onto a
        // new phone via encrypted backup instead of being re-typed. These are
        // API-key-class secrets, not device credentials; migration convenience
        // wins. Changing this requires the update-alongside-value behavior
        // above, or existing items would silently keep the old class.
        var attributes: [CFString: Any] = [kSecValueData: data]
        #if !os(macOS)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        #endif

        let updated = SecItemUpdate(search as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw KeychainError.saveFailed(updated)
        }

        var insert = search
        insert[kSecValueData] = data
        #if !os(macOS)
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        #endif
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw KeychainError.saveFailed(added)
        }
    }

    static func load(for key: String) -> String? {
        guard !key.isEmpty else {
            logger.warning("Attempted to load with empty key")
            return nil
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: kCFBooleanTrue!,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain load failed for key '\(key, privacy: .private)': OSStatus \(status)")
        }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for key: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    enum KeychainError: Error, LocalizedError {
        case saveFailed(OSStatus)
        case deleteFailed(OSStatus)
        case invalidInput(String)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status): "Keychain save failed (OSStatus \(status))"
            case .deleteFailed(let status): "Keychain delete failed (OSStatus \(status))"
            case .invalidInput(let reason): "Invalid keychain input: \(reason)"
            }
        }
    }
}
