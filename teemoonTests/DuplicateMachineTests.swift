import Foundation
import Testing
@testable import teemoon

/// Two Provider records for the same self-hosted endpoint rendered the whole
/// machine twice in the Where sheet — one row per equipped model per provider,
/// with identical captions and no way to tell them apart. Deduping on `id`
/// never caught it: a duplicate is a different record of the same machine.
@Suite("Duplicate self-hosted machines")
@MainActor
struct DuplicateMachineTests {

    private func ollama(_ endpoint: String, model: String, models: [String]? = nil) -> Provider {
        var provider = Provider(name: "ollama", endpoint: endpoint, model: model,
                                requiresAPIKey: false)
        provider.equippedModels = models
        return provider
    }

    // MARK: - machineIdentity

    @Test func sameEndpointTypedTwoWays_isOneMachine() {
        let a = ollama("https://ringzero.tailnet-name.ts.net:11434/v1", model: "gemma4:latest")
        let b = ollama("https://RingZero.tailnet-name.ts.net:11434/v1/", model: "qwen3.5:4b")
        #expect(a.machineIdentity != nil)
        #expect(a.machineIdentity == b.machineIdentity)
    }

    @Test func differentPortsOnOneHost_areDifferentMachines() {
        // Ollama on 11434 and llama.cpp on 8080 is a documented setup.
        let ollamaBox = ollama("https://ringzero.tailnet-name.ts.net:11434/v1", model: "gemma4:latest")
        let llamaBox = ollama("https://ringzero.tailnet-name.ts.net:8080/v1", model: "bonsai")
        #expect(ollamaBox.machineIdentity != llamaBox.machineIdentity)
    }

    @Test func cloudProvidersHaveNoMachineIdentity() {
        // Two keys on one cloud host is a legitimate setup and must never merge.
        #expect(Provider.nearAI.machineIdentity == nil)
    }

    @Test func aSelfHostedEndpointThatNeedsAKeyHasNoMachineIdentity() {
        // Merging would mean dropping a record that owns a credential.
        var guarded = ollama("https://ringzero.tailnet-name.ts.net:11434/v1", model: "gemma4:latest")
        guarded.requiresAPIKey = true
        #expect(guarded.machineIdentity == nil)
    }

    // MARK: - Merging

    @Test func addingTheSameMachineTwice_leavesOneRecord() {
        let store = ProviderStore(inMemory: true)
        store.addProvider(ollama("https://ringzero.tailnet-name.ts.net:11434/v1",
                                 model: "gemma4:latest",
                                 models: ["gemma4:latest", "gemma4:e2b", "qwen3.5:4b"]))
        store.addProvider(ollama("https://ringzero.tailnet-name.ts.net:11434/v1",
                                 model: "gemma4:latest",
                                 models: ["gemma4:latest", "gemma4:e2b", "qwen3.5:4b"]))
        #expect(store.providers.count == 1)
        // The Where sheet lists one row per equipped model — three, not six.
        #expect(store.providers[0].equipped.count == 3)
    }

    @Test func mergeKeepsModelsOnlyTheDuplicateHad() {
        let store = ProviderStore(inMemory: true)
        store.addProvider(ollama("https://box.ts.net:11434/v1", model: "a", models: ["a"]))
        store.addProvider(ollama("https://box.ts.net:11434/v1", model: "b", models: ["b", "c"]))
        #expect(store.providers.count == 1)
        #expect(Set(store.providers[0].equipped) == ["a", "b", "c"])
    }

    @Test func mergingTheACTIVErecord_keepsWhatWasRunning() {
        let store = ProviderStore(inMemory: true)
        let first = ollama("https://box.ts.net:11434/v1", model: "a", models: ["a"])
        let second = ollama("https://box.ts.net:11434/v1", model: "c", models: ["c"])
        store.addProvider(first)
        store.providers.append(second)          // bypass the merge, as an old store would
        store.currentProviderID = second.id.uuidString
        store.mergeDuplicateMachines()

        #expect(store.providers.count == 1)
        // The surviving record must point at the model the user was running, and
        // be the one selected — otherwise the merge silently switches models.
        #expect(store.activeProvider?.id == first.id)
        #expect(store.activeProvider?.model == "c")
    }

    // MARK: - The keyed-flag gap (observed on device, 2026-07-29)

    /// `AddEditProviderView` hardcoded `requiresAPIKey: true` for everything it
    /// saved. `machineIdentity` is nil whenever that flag is set, so two records
    /// of one Tailscale-served Ollama could never be recognised as one machine.
    ///
    /// Captured from the device: one host, two records, the SAME three models on
    /// each (because `syncHomeEquipped` writes the server's list into both), and
    /// stale crossed names — the record named `gemma4:e2b-it-qat` was running
    /// `gemma4:latest`. Six rows in Where for three distinct models.
    @Test func theDevicesTwoRingzeroRecords_collapseToOne() {
        let store = ProviderStore(inMemory: true)
        let models = ["gemma4:latest", "gemma4:e2b-it-qat", "qwen3.5:4b"]
        var first = ollama("https://ringzero.tailnet-name.ts.net:11434/v1",
                           model: "gemma4:latest", models: models)
        var second = ollama("https://ringzero.tailnet-name.ts.net:11434/v1",
                            model: "qwen3.5:4b", models: models)
        // The form's bug: keyless box, flagged as needing a key.
        first.requiresAPIKey = true
        second.requiresAPIKey = true
        store.addProvider(first)
        store.addProvider(second)

        store.healKeylessSelfHostedForTesting()
        store.mergeDuplicateMachines()

        #expect(store.providers.count == 1)
        #expect(Set(store.providers[0].equipped) == Set(models))
    }

    @Test func healingOnlyTouchesRecordsWithNoStoredKey() throws {
        // A self-hosted endpoint that genuinely holds a key keeps its flag, so
        // no merge that follows can be the thing that deletes a secret.
        let store = ProviderStore(inMemory: true)
        var keyed = ollama("https://ringzero.tailnet-name.ts.net:11434/v1",
                           model: "gemma4:latest", models: ["gemma4:latest"])
        keyed.requiresAPIKey = true
        store.addProvider(keyed)
        // Written the way an OLD build wrote it — under the record's uuid.
        try? Keychain.save("a-real-secret", for: keyed.id.uuidString)
        defer {
            if let account = ProviderStore.keyAccount(for: keyed) { try? Keychain.delete(for: account) }
            try? Keychain.delete(for: keyed.id.uuidString)
        }

        store.healKeylessSelfHostedForTesting()

        #expect(store.providers[0].requiresAPIKey)
        #expect(store.providers[0].machineIdentity == nil)
        // The secret survives — under the ENDPOINT account, because reading it is what
        // migrates it. The old assertion named the uuid slot, which is exactly the
        // storage this change moved away from; what matters is that healing never
        // costs a key, and that is asserted through the lookup the app uses.
        #expect(store.credential(for: store.providers[0]) == "a-real-secret")
        let account = try #require(ProviderStore.keyAccount(for: keyed))
        #expect(Keychain.load(for: account) == "a-real-secret")
    }

    @Test func healingLeavesCloudProvidersAlone() {
        // A cloud key is legitimately configurable twice — "work" and
        // "personal" — so identity there is the record, never the URL.
        let store = ProviderStore(inMemory: true)
        store.addProvider(Provider.nearAI)

        store.healKeylessSelfHostedForTesting()

        #expect(store.providers[0].requiresAPIKey)
        #expect(store.providers[0].machineIdentity == nil)
    }

    @Test func distinctMachinesAreLeftAlone() {
        let store = ProviderStore(inMemory: true)
        store.addProvider(ollama("https://box-one.ts.net:11434/v1", model: "a"))
        store.addProvider(ollama("https://box-two.ts.net:11434/v1", model: "a"))
        store.addProvider(Provider.nearAI)
        #expect(store.providers.count == 3)
    }
}
