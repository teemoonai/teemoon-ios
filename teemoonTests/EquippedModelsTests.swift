//
//  EquippedModelsTests.swift
//  teemoonTests
//
//  A provider is a connection plus a credential; a model is a thing that
//  connection can run. `Provider.model` stays the ACTIVE model — it is read in
//  ~44 places including the whole inference and attestation chain — and
//  `equippedModels` is the set it is drawn from.
//
//  The tests that matter here are the migration ones. Providers live as Codable
//  JSON in UserDefaults, so a shape change that fails to decode doesn't degrade:
//  the user's configured providers and keys are simply gone.
//

import Foundation
import Testing
@testable import teemoon

struct EquippedModelsTests {

    // MARK: - Migration

    /// The whole migration, and the reason nothing has to be rewritten on
    /// upgrade: `nil` reads as `[model]`.
    @Test func nilEquippedReadsAsTheActiveModel() {
        let p = Provider(name: "near.ai", endpoint: "https://x/v1", model: "glm-5.2")

        #expect(p.equippedModels == nil)
        #expect(p.equipped == ["glm-5.2"])
    }

    /// Decoding JSON written by a build that had no `equippedModels` must
    /// succeed and yield one equipped model. If this fails, shipping the field
    /// wipes every saved provider.
    @Test func decodesProviderJSONWrittenBeforeTheFieldExisted() throws {
        let legacy = """
        {
          "id": "7B7C1E2A-0000-4000-8000-000000000001",
          "name": "near.ai",
          "endpoint": "https://api.near.ai/v1",
          "model": "glm-5.2",
          "requiresAPIKey": true,
          "supportsModelBrowsing": true,
          "extraParams": {},
          "hasBuiltInGrounding": false,
          "omitSystemPrompt": false
        }
        """.data(using: .utf8)!

        let p = try JSONDecoder().decode(Provider.self, from: legacy)

        #expect(p.model == "glm-5.2")
        #expect(p.equippedModels == nil)
        #expect(p.equipped == ["glm-5.2"])
    }

    /// Round-trips, so a provider saved by this build reloads with its set.
    @Test func equippedSurvivesACodableRoundTrip() throws {
        let p = Provider(name: "near.ai", endpoint: "https://x/v1", model: "glm-5.2")
            .equipping("qwen3-235b")

        let decoded = try JSONDecoder().decode(
            Provider.self, from: JSONEncoder().encode(p)
        )
        #expect(decoded.equipped == ["glm-5.2", "qwen3-235b"])
        #expect(decoded.model == "qwen3-235b")
    }

    /// An `equippedModels` that somehow lost the active model still renders it,
    /// rather than showing a list that omits what is running.
    @Test func activeModelIsAlwaysEquippedEvenIfTheStoredSetDisagrees() {
        var p = Provider(name: "x", endpoint: "https://x/v1", model: "running-this")
        p.equippedModels = ["something-else"]

        #expect(p.equipped.contains("running-this"))
        #expect(p.equipped.first == "running-this")
    }

    // MARK: - Equip

    @Test func equippingAppendsAndActivates() {
        let p = Provider(name: "near.ai", endpoint: "https://x/v1", model: "glm-5.2")
            .equipping("qwen3-235b")

        #expect(p.equipped == ["glm-5.2", "qwen3-235b"])
        #expect(p.model == "qwen3-235b")
    }

    /// Browse used to REPLACE the model. The point of the split is that the
    /// first pick is still there after the second.
    @Test func equippingTwiceKeepsBoth() {
        let p = Provider(name: "near.ai", endpoint: "https://x/v1", model: "a")
            .equipping("b")
            .equipping("c")

        #expect(p.equipped == ["a", "b", "c"])
    }

    @Test func equippingIsIdempotent() {
        let p = Provider(name: "near.ai", endpoint: "https://x/v1", model: "a")
            .equipping("b")
            .equipping("b")

        #expect(p.equipped == ["a", "b"])
        #expect(p.model == "b")
    }

    // MARK: - Unequip

    @Test func unequippingTheActiveModelMovesActiveToASurvivor() {
        let p = Provider(name: "near.ai", endpoint: "https://x/v1", model: "a")
            .equipping("b")   // b is now active
        let after = p.unequipping("b")

        #expect(after.equipped == ["a"])
        // Must not keep running a model it no longer claims to have.
        #expect(after.model == "a")
    }

    @Test func unequippingANonActiveModelLeavesActiveAlone() {
        let p = Provider(name: "near.ai", endpoint: "https://x/v1", model: "a")
            .equipping("b")
            .equipping("a")   // a active again, both equipped
        let after = p.unequipping("b")

        #expect(after.equipped == ["a"])
        #expect(after.model == "a")
    }

    /// REVERSED. This used to assert nil, and the caller read nil as "delete the
    /// provider" — which deleted its Keychain entry, so one swipe destroyed an api
    /// key. A server is not the models equipped on it: the endpoint, the key and the machine
    /// outlive them, and `ConfigSnapshot` already stores a `Server` with no
    /// `EquippedModel` rows as a normal state.
    @Test func unequippingTheLastModelEmptiesTheServerInsteadOfDeletingIt() {
        let p = Provider(name: "near.ai", endpoint: "https://x/v1", model: "only")
        let after = p.unequipping("only")

        #expect(after.equipped.isEmpty)
        #expect(after.model == "")        // nothing selected, not a stale id
        #expect(after.id == p.id)         // the Keychain entry hangs off this
        #expect(after.endpoint == p.endpoint)
    }

    // MARK: - Store

    @MainActor
    @Test func storeActivateSetsBothModelAndCurrentProvider() {
        let store = ProviderStore(inMemory: true)
        let p = Provider(name: "near.ai", endpoint: "https://x/v1", model: "a")
        store.addProvider(p)

        store.activate(modelID: "b", on: p)

        #expect(store.currentProviderID == p.id.uuidString)
        #expect(store.activeProvider?.model == "b")
        #expect(store.activeProvider?.equipped == ["a", "b"])
    }

    /// REVERSED, and the return value's MEANING changed with it: it reports that
    /// the server is now empty, not that it was deleted — because it isn't.
    ///
    /// `removeProvider` deletes the Keychain entry, so the old behaviour meant one
    /// swipe could destroy an api key the user pasted from somewhere else. The
    /// server is not the models on it (§2.1); deleting a setup is now an explicit
    /// action behind a confirmation.
    @MainActor
    @Test func storeUnequipEmptiesTheServerAndKeepsIt() {
        let store = ProviderStore(inMemory: true)
        let p = Provider(name: "near.ai", endpoint: "https://x/v1", model: "only",
                         requiresAPIKey: true)
        store.addProvider(p)

        let isNowEmpty = store.unequip(modelID: "only", from: p)

        #expect(isNowEmpty)
        let survivor = store.providers.first { $0.id == p.id }
        #expect(survivor != nil, "the server was deleted with its last model")
        #expect(survivor?.equipped.isEmpty == true)
        // Still a usable server: same id (the key hangs off it), same endpoint, so
        // equipping another model is all it takes to run again.
        #expect(survivor?.endpoint == "https://x/v1")
        #expect(survivor?.requiresAPIKey == true)
    }

    @MainActor
    @Test func storeUnequipKeepsTheProviderWhenModelsRemain() {
        let store = ProviderStore(inMemory: true)
        let p = Provider(name: "near.ai", endpoint: "https://x/v1", model: "a").equipping("b")
        store.addProvider(p)

        let deletedProvider = store.unequip(modelID: "b", from: p)

        #expect(!deletedProvider)
        #expect(store.providers.count == 1)
        #expect(store.providers[0].equipped == ["a"])
    }

    // MARK: - On-device

    /// A downloaded model is one model, and `Provider.local` builds it from a
    /// single catalog entry — so the phone tier never grows multi-model rows by
    /// accident.
    @Test func localProviderHasExactlyOneEquippedModel() {
        let p = Provider.local(LocalModelCatalog.all[0])
        #expect(p.equipped == [p.model])
        #expect(p.equipped.count == 1)
    }
}
