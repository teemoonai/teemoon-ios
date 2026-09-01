//
//  ProviderStore+Credentials.swift
//  teemoon
//
//  Where a provider key lives in the Keychain, and how it is read and
//  written. Kept off ProviderStore.swift so CRUD is not also the account.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "providers")

extension ProviderStore {

    // MARK: Credential accounts

    /// The Keychain account a provider's key lives under: its ENDPOINT, normalized.
    ///
    /// It used to be the record's UUID. That is *a* server id, but not the server's
    /// IDENTITY — a record can be recreated, merged, or written by a screen that
    /// minted a fresh id, and the secret then sat under a UUID nothing pointed at.
    /// The symptom shipped twice in one evening: browsing a keyed provider fetched
    /// unauthenticated, and the edit sheet showed an EMPTY key field for a setup that
    /// had one. Both were patched by trying a second lookup by endpoint, which is the
    /// tell — if the endpoint is what actually answers, the endpoint is the account.
    ///
    /// Keying on it makes "one key per server" true by construction rather than by
    /// convention, and it composes with `addProvider`'s one-record-per-endpoint
    /// upsert: the surviving record and the stored key can no longer disagree.
    ///
    /// nil for on-device providers, which share the literal endpoint `"on-device"` and
    /// have no key — without that guard every local model would address one account.
    static func keyAccount(for provider: Provider) -> String? { keyAccount(endpoint: provider.endpoint) }

    static func keyAccount(endpoint: String) -> String? {
        let key = endpointKey(endpoint)
        guard !key.isEmpty, key != "on-device" else { return nil }
        // Prefixed so it can never collide with a legacy UUID account.
        return "endpoint:" + key
    }

    /// Reads a key, moving it to the endpoint account if it is still under the record's
    /// UUID. Copy first, delete only after the write succeeds — a migration that loses
    /// a key costs the user a trip to a vendor console.
    @discardableResult
    static func migratedCredential(for provider: Provider) -> String {
        guard let account = keyAccount(for: provider) else { return "" }
        if let current = Keychain.load(for: account), !current.isEmpty { return current }
        let legacyAccount = provider.id.uuidString
        guard let legacy = Keychain.load(for: legacyAccount), !legacy.isEmpty else { return "" }
        do {
            try Keychain.save(legacy, for: account)
            try? Keychain.delete(for: legacyAccount)
            logger.info("[providers] moved a key to its endpoint account")
        } catch {
            // Keep the legacy copy and keep working from it — a failed move must not
            // look like a missing key.
            logger.error("[providers] could not move a key to its endpoint account: \(error)")
        }
        return legacy
    }

    /// The stored API key for a provider, or empty when none is required/saved.
    func credential(for provider: Provider) -> String {
        provider.requiresAPIKey ? Self.migratedCredential(for: provider) : ""
    }

    /// The key already saved for whichever configured provider points at this
    /// endpoint, or nil when none does.
    ///
    /// Keys are stored per provider **instance** (a fresh UUID per save), while
    /// the add screen pre-filled from the *preset's* fixed UUID — which only
    /// onboarding ever writes. So a key added through Settings looked lost the
    /// next time the same preset was picked. Matching on the endpoint finds it
    /// wherever it was saved from.
    func credential(forEndpoint endpoint: String) -> String? {
        let target = endpoint.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return nil }
        for provider in providers
        where provider.endpoint.trimmingCharacters(in: .whitespaces).lowercased() == target {
            let key = credential(for: provider)
            if !key.isEmpty { return key }
        }
        return nil
    }

    /// The key to reach a provider's CATALOGUE with — both lookups, by record
    /// and then by endpoint.
    ///
    /// `credential(for:)` alone returns "" for a provider that is demonstrably
    /// keyed: keys are stored per instance, and a key added from Settings lives
    /// under a different id than the preset's. The symptom is not an error —
    /// the fetch simply goes out unauthenticated, the 401 comes back, and the
    /// caller silently falls back to the shipped snapshot. A list that is merely
    /// STALE, with nothing on screen saying why.
    ///
    /// It lived as a private helper in the Where sheet, so the chat chip's
    /// model page reimplemented the single-lookup version and got exactly that
    /// silent fallback — the same model, described two ways, depending on which
    /// long press you used.
    func browseCredential(for provider: Provider) -> String {
        let byID = credential(for: provider).trimmingCharacters(in: .whitespaces)
        if !byID.isEmpty { return byID }
        return (credential(forEndpoint: provider.endpoint) ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Stores (or clears, when empty) the API key for a provider ID.
    ///
    /// Takes an id because that is what a save site has after `addProvider` returns
    /// the surviving record — but writes to the ENDPOINT account, resolved from the
    /// stored provider. A key written under the id and read back by endpoint is the
    /// bug this migration exists to end, so both halves have to agree here.
    ///
    /// Throws when the keychain write fails: swallowing it dismissed the screen
    /// as if the key had been saved, and the failure only surfaced later as an
    /// unauthorized request with no explanation.
    func setCredential(_ apiKey: String, forProviderID id: UUID) throws {
        let endpoint = providers.first { $0.id == id }?.endpoint
        try setCredential(apiKey, forEndpoint: endpoint, legacyID: id)
    }

    /// The endpoint-keyed write. `legacyID` is cleared alongside, so a record that
    /// still had a UUID copy doesn't keep answering with a key the user just removed.
    func setCredential(_ apiKey: String, forEndpoint endpoint: String?, legacyID: UUID?) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        let account = endpoint.flatMap { Self.keyAccount(endpoint: $0) }
        if trimmed.isEmpty {
            if let account { try Keychain.delete(for: account) }
            if let legacyID { try? Keychain.delete(for: legacyID.uuidString) }
        } else {
            guard let account else {
                // No endpoint to key on — an on-device row, or a record saved before
                // its endpoint was valid. Refuse rather than write a secret to an
                // account nothing will read.
                throw Keychain.KeychainError.invalidInput("no endpoint to store this key under")
            }
            try Keychain.save(trimmed, for: account)
            if let legacyID { try? Keychain.delete(for: legacyID.uuidString) }
        }
    }
}
