//
//  LiveCatalogStoreTests.swift
//  teemoonTests
//
//  The saved copy of what each server answered with. It is the only place a
//  model count, a browse row and a model's name come from, so what it keeps —
//  and what it refuses to keep — is the whole contract.
//

import Foundation
import Testing
@testable import teemoon

@Suite("LiveCatalogStore")
@MainActor
struct LiveCatalogStoreTests {

    private func tempStore() -> (LiveCatalogStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catalog-\(UUID().uuidString)", isDirectory: true)
        return (LiveCatalogStore(directory: dir), dir)
    }

    private func rows(_ ids: [String]) -> [KnownModel] {
        ids.map { KnownModel(id: $0, displayName: $0, vendor: "v", price: "$1.00/$2.00") }
    }

    private var openRouter: Provider { .openRouter }
    private var fireworks: Provider { .fireworks }

    @Test func aSavedListSurvivesANewStore() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(rows(["a/one", "a/two"]), for: openRouter, apiKey: "")

        let reopened = LiveCatalogStore(directory: dir)
        #expect(reopened.count(for: openRouter, apiKey: "") == 2)
        #expect(reopened.model(id: "a/two", for: openRouter, apiKey: "")?.price == "$1.00/$2.00")
    }

    /// No answer yet is nil, never 0: a row prints nothing rather than a number
    /// that reads as "this server has no models".
    @Test func anUnaskedServerHasNoCount() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.count(for: openRouter, apiKey: "") == nil)
        #expect(store.models(for: openRouter, apiKey: "").isEmpty)
    }

    /// A keyed list is one account's entitlements. A different key must not see
    /// them, and must not leave them behind either.
    @Test func aKeyedListBelongsToItsAccount() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(rows(["accounts/a/models/one"]), for: fireworks, apiKey: "key-one")
        #expect(store.count(for: fireworks, apiKey: "key-one") == 1)
        #expect(store.count(for: fireworks, apiKey: "key-two") == nil)

        store.record(rows(["accounts/b/models/x", "accounts/b/models/y"]),
                     for: fireworks, apiKey: "key-two")
        #expect(store.count(for: fireworks, apiKey: "key-two") == 2)
        #expect(store.count(for: fireworks, apiKey: "key-one") == nil, "the old account's list is gone")
    }

    /// A public list has no account in it, so one copy serves every key —
    /// including none.
    @Test func aPublicListIsNotScopedToAKey() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(rows(["a/one"]), for: openRouter, apiKey: "")
        #expect(store.count(for: openRouter, apiKey: "some-key") == 1)
    }

    @Test func forgettingAServerDropsEveryScope() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(rows(["accounts/a/models/one"]), for: fireworks, apiKey: "key-one")
        store.forget(endpoint: fireworks.endpoint)
        #expect(store.count(for: fireworks, apiKey: "key-one") == nil)
    }

    /// Badges age on disk. A row saved as "new" months ago must not still wear
    /// the badge when the copy is read back.
    @Test func savedBadgesAgeThemselves() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var fresh = KnownModel(id: "a/new", displayName: "New", vendor: "v", price: "")
        fresh.isNew = true
        fresh.created = Date()
        var old = KnownModel(id: "a/old", displayName: "Old", vendor: "v", price: "")
        old.isNew = true                                   // as saved, months ago
        old.created = Date(timeIntervalSinceNow: -60 * 24 * 3600)
        store.record([fresh, old], for: openRouter, apiKey: "")

        let reopened = LiveCatalogStore(directory: dir)
        let models = reopened.models(for: openRouter, apiKey: "")
        #expect(models.first { $0.id == "a/new" }?.isNew == true)
        #expect(models.first { $0.id == "a/old" }?.isNew == false)
    }

    /// A key never reaches the disk — not in a filename, not in a file.
    @Test func noKeyIsWrittenDown() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = "sk-secret-value-123"
        store.record(rows(["accounts/a/models/one"]), for: fireworks, apiKey: secret)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        for file in files {
            #expect(!file.lastPathComponent.contains(secret))
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains(secret))
        }
    }

    /// A refresh fetches once for a fresh copy, and shares one fetch between
    /// callers — opening the sheet twice is not two catalogue downloads.
    @Test func refreshHonoursAgeAndSharesOneFetch() async {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calls = LockedBox(0)
        store.list = { _, _, _, _ in
            calls.value += 1
            try? await Task.sleep(for: .milliseconds(20))
            return .connected([KnownModel(id: "a/one", displayName: "One", vendor: "v", price: "")])
        }

        async let first = store.refresh(openRouter, apiKey: "", maxAge: 3600)
        async let second = store.refresh(openRouter, apiKey: "", maxAge: 3600)
        _ = await (first, second)
        #expect(calls.value == 1, "concurrent callers share one fetch")

        await store.refresh(openRouter, apiKey: "", maxAge: 3600)
        #expect(calls.value == 1, "a fresh copy is not re-fetched")

        await store.refresh(openRouter, apiKey: "", maxAge: 0)
        #expect(calls.value == 2)
    }

    /// A failed refresh keeps what was there. An empty list on screen because
    /// the network blinked is worse than yesterday's list.
    @Test func aFailedRefreshKeepsTheSavedCopy() async {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(rows(["a/one", "a/two"]), for: openRouter, apiKey: "")
        store.list = { _, _, _, _ in .failed(.offline) }
        let refreshed = await store.refresh(openRouter, apiKey: "", maxAge: 0)
        #expect(refreshed == nil)
        #expect(store.count(for: openRouter, apiKey: "") == 2)
    }

    /// Counting a public catalogue must not hand it a credential it never
    /// asked for.
    @Test func aPublicListIsCountedWithoutTheKey() async {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sentKeys = LockedBox([String]())
        store.list = { _, _, key, _ in
            sentKeys.value = sentKeys.value + [key]
            return .connected([KnownModel(id: "a/one", displayName: "One", vendor: "v", price: "")])
        }
        await store.refresh(openRouter, apiKey: "sk-openrouter", maxAge: 0)
        await store.refresh(fireworks, apiKey: "sk-fireworks", maxAge: 0)
        #expect(sentKeys.value == ["", "sk-fireworks"])
    }

    /// near.ai's tiers ride with the rows, so a cold launch labels them from
    /// what near.ai said rather than from the id guess.
    @Test func nearAITiersAreSavedAndSeeded() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        NearAIModelCatalog.recordTiers(["moonshotai/kimi-k9": .teeThirdParty])
        store.record(rows(["moonshotai/kimi-k9"]), for: .nearAI, apiKey: "")
        NearAIModelCatalog.resetTierCache()
        #expect(NearAIModelCatalog.confidentiality(forID: "moonshotai/kimi-k9") == .teeOwn,
                "without the saved tier the guess answers own-fleet")

        LiveCatalogStore(directory: dir).seedNearAITiers()
        #expect(NearAIModelCatalog.confidentiality(forID: "moonshotai/kimi-k9") == .teeThirdParty)
        NearAIModelCatalog.resetTierCache()
    }

    /// A near.ai list built while the endpoints directory was cold has no
    /// hosts. The directory, once on disk, answers for every own-fleet row —
    /// not only for rows that already had one.
    @Test func aColdListGetsItsHostsFromTheDirectoryOnReopen() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        NearAIModelCatalog.recordTiers(["z-ai/glm-cold-test": .teeOwn])
        EndpointDirectory.rememberPersisted(["z-ai/glm-cold-test": "https://glm-cold.completions.near.ai/v1"])
        store.record(rows(["z-ai/glm-cold-test"]), for: .nearAI, apiKey: "")
        #expect(store.model(id: "z-ai/glm-cold-test", for: .nearAI, apiKey: "")?.directBaseURL == nil)

        let reopened = LiveCatalogStore(directory: dir)
        #expect(reopened.model(id: "z-ai/glm-cold-test", for: .nearAI, apiKey: "")?.directBaseURL
                == "https://glm-cold.completions.near.ai/v1")
        // And the picker offers the row in the same session, before any reopen.
        let choices = NearAIModelCatalog.encryptedChoices(from: store.models(for: .nearAI, apiKey: ""))
        #expect(choices.map(\.id) == ["z-ai/glm-cold-test"])
    }

    /// The daily refresh is for catalogues teemoon knows. A custom endpoint's
    /// `/models` may not exist, and sending its key there unprompted is not
    /// something a Where-sheet open consents to; a browse tap is.
    @Test func theDailyRefreshNeverProbesACustomEndpoint() async {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var asked: [EndpointModelCatalog.Source] = []
        store.list = { source, _, _, _ in asked.append(source); return .failed(.offline) }
        let custom = Provider(name: "mine", endpoint: "https://llm.example.com/v1/chat/completions", model: "m")
        await store.refreshAll([custom, .openRouter], maxAge: 0, credential: { _ in "sk-custom" })
        #expect(asked == [.openRouter])
    }
}
