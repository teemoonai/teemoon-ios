//
//  UITestIsolationTests.swift
//  teemoonTests
//
//  A UI test must not touch the real user's configuration.
//
//  The conversation store has been ephemeral under `--uitesting` for a while,
//  with a note saying exactly that. The PROVIDER config was not, and the
//  seeding those tests rely on opens with `providerStore.providers.removeAll()`
//  — which `didSet { save() }` writes straight through to
//  `Application Support/teemoon-config.json`.
//
//  On 2026-08-06 that ran three times against the development phone and
//  replaced the real provider list with a single seeded "fake-model" entry.
//  Endpoints, model choices and Where recents went; the API keys survived only
//  because they are keyed by endpoint and `removeAll()` never reaches the
//  Keychain-deleting path.
//
//  These pin the rule so a future launch flag cannot quietly re-open it.
//

import XCTest
@testable import teemoon

final class UITestIsolationTests: XCTestCase {

    func testProviderStoreIsEphemeralUnderUITesting() {
        XCTAssertTrue(
            TeemoonApp.usesEphemeralProviderStore(arguments: ["teemoon", "--uitesting"]),
            "a --uitesting launch must get a throwaway provider store; without this, "
            + "the UITEST_SEED_* paths overwrite the real teemoon-config.json")
    }

    func testProviderStorePersistsForAnOrdinaryLaunch() {
        XCTAssertFalse(
            TeemoonApp.usesEphemeralProviderStore(arguments: ["teemoon"]),
            "a normal launch must keep the user's configured providers")
        XCTAssertFalse(
            TeemoonApp.usesEphemeralProviderStore(arguments: ["teemoon", "-scrollTrace"]),
            "an unrelated debug flag must not make the provider store ephemeral")
    }

    /// The store itself must honour the flag — the guard above is only as good
    /// as this.
    @MainActor
    func testInMemoryProviderStoreDoesNotWriteTheSharedConfig() throws {
        let configURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("teemoon-config.json")
        let before = configURL.flatMap { try? Data(contentsOf: $0) }

        let store = ProviderStore(inMemory: true)
        store.providers.removeAll()
        store.addProvider(Provider(name: "throwaway",
                                   endpoint: "https://example.invalid/v1",
                                   model: "fake-model",
                                   requiresAPIKey: false))

        let after = configURL.flatMap { try? Data(contentsOf: $0) }
        XCTAssertEqual(before, after,
                       "an in-memory ProviderStore wrote to the shared config file")
    }
}
