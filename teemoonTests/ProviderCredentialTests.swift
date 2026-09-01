//
//  ProviderCredentialTests.swift
//  teemoonTests
//
//  The provider API-key lifecycle — the behavior that made keys look lost:
//
//   • Keys are stored per provider INSTANCE (`save()` mints a fresh UUID), while
//     the add screen pre-filled from the PRESET's fixed UUID, which only
//     onboarding ever writes. A key added from Settings was therefore invisible
//     the next time the same preset was picked → `credential(forEndpoint:)`.
//   • Emptying the field could not clear a stored key: the save path only wrote
//     when the field was non-empty, so `setCredential`'s delete branch was
//     unreachable and the removed key kept being sent.
//   • Deleting a provider orphaned its key in the keychain forever.
//   • A failed keychain write was swallowed, so the screen dismissed as if the
//     key had been stored.
//
//  These run against the REAL keychain (as `KeychainTests` do) with per-test
//  UUIDs, and clean up after themselves.
//

import Foundation
import Testing
@testable import teemoon

@MainActor
@Suite("Provider credentials")
struct ProviderCredentialTests {

    private func makeStore() -> ProviderStore { ProviderStore(inMemory: true) }

    private func provider(_ endpoint: String = "https://api.example.com/v1") -> Provider {
        Provider(name: "test", endpoint: endpoint, model: "m")
    }

    @Test func setCredentialRoundTripsThroughTheKeychain() throws {
        let store = makeStore()
        let p = provider()
        defer { store.removeProvider(p) }
        store.addProvider(p)

        try store.setCredential("sk-secret-1", forProviderID: p.id)
        #expect(store.credential(for: p) == "sk-secret-1")
    }

    /// The clear path: an emptied field must DELETE, not no-op.
    @Test func emptyCredentialDeletesTheStoredKey() throws {
        let store = makeStore()
        let p = provider()
        defer { store.removeProvider(p) }
        store.addProvider(p)

        try store.setCredential("sk-secret-2", forProviderID: p.id)
        try store.setCredential("", forProviderID: p.id)
        #expect(store.credential(for: p) == "")

        // Whitespace is not a key either.
        try store.setCredential("sk-secret-2", forProviderID: p.id)
        try store.setCredential("   ", forProviderID: p.id)
        #expect(store.credential(for: p) == "")
    }

    @Test func credentialsAreTrimmedOnWrite() throws {
        let store = makeStore()
        let p = provider()
        defer { store.removeProvider(p) }
        store.addProvider(p)

        try store.setCredential("  sk-padded  ", forProviderID: p.id)
        #expect(store.credential(for: p) == "sk-padded")
    }

    /// THE fix for "the add screen forgot my key": it is found by endpoint,
    /// wherever it was saved from — not only under the preset's own UUID.
    // MARK: - One record per endpoint (observed on device, 2026-07-29)

    /// Rotating a key produced a SECOND record for the same endpoint: a fresh
    /// UUID was minted on every save, so the new secret went to a new Keychain
    /// slot and the stale record kept the revoked one — while still offering a
    /// model the new record did not have.
    @Test func rotatingAKeyUpdatesTheRecordInsteadOfDuplicatingIt() throws {
        let store = makeStore()
        let endpoint = "https://cloud-api.near.ai/v1/chat/completions"
        var original = Provider(name: "near.ai", endpoint: endpoint, model: "z-ai/glm-5.2")
        original.equippedModels = ["z-ai/glm-5.2", "zai-org/GLM-5.1-FP8"]
        let firstID = store.addProvider(original)
        try store.setCredential("sk-old", forProviderID: firstID)
        defer { try? Keychain.delete(for: firstID.uuidString) }

        // What the add screen does on a re-entry: same endpoint, NEW id, new key.
        let reentered = Provider(name: "near.ai", endpoint: endpoint, model: "z-ai/glm-5.2")
        let savedID = store.addProvider(reentered)
        try store.setCredential("sk-new", forProviderID: savedID)

        #expect(store.providers.count == 1)
        // The surviving id is the original — which is what keeps the rotation in
        // ONE Keychain slot instead of orphaning the old one.
        #expect(savedID == firstID)
        #expect(store.credential(for: store.providers[0]) == "sk-new")
        // And no model the user could previously run disappeared.
        #expect(Set(store.providers[0].equipped) == ["z-ai/glm-5.2", "zai-org/GLM-5.1-FP8"])
    }

    @Test func oneEndpointTypedTwoWaysIsStillOneRecord() {
        let store = makeStore()
        store.addProvider(Provider(name: "a", endpoint: "https://api.example.com/v1", model: "m"))
        store.addProvider(Provider(name: "b", endpoint: "  https://API.Example.com/v1/  ", model: "m2"))

        #expect(store.providers.count == 1)
        #expect(Set(store.providers[0].equipped) == ["m", "m2"])
    }

    @Test func onDeviceModelsAreNotFoldedTogether() {
        // Every local provider shares the literal endpoint "on-device", so
        // matching on it would collapse the whole local catalogue into one row.
        let store = makeStore()
        store.addProvider(Provider(name: "Gemma", endpoint: "on-device", model: "gemma",
                                   requiresAPIKey: false, localModelID: "gemma"))
        store.addProvider(Provider(name: "Qwen", endpoint: "on-device", model: "qwen",
                                   requiresAPIKey: false, localModelID: "qwen"))

        #expect(store.providers.count == 2)
    }

    /// The device's exact state: a stale record holding a REVOKED key plus the
    /// selected record holding the live one. The selected record must survive,
    /// or the heal would trade a working setup for a dead one.
    @Test func healingKeepsTheSelectedRecordAndItsLiveKey() throws {
        let store = makeStore()
        let endpoint = "https://cloud-api.near.ai/v1/chat/completions"
        var stale = Provider(name: "near.ai", endpoint: endpoint, model: "z-ai/glm-5.2")
        stale.equippedModels = ["z-ai/glm-5.2", "zai-org/GLM-5.1-FP8"]
        var live = Provider(name: "near.ai", endpoint: endpoint, model: "z-ai/glm-5.2")
        live.id = UUID()
        store.providers.append(stale)            // the shape the old save path left
        store.providers.append(live)
        try store.setCredential("sk-revoked", forProviderID: stale.id)
        try store.setCredential("sk-live", forProviderID: live.id)
        store.currentProviderID = live.id.uuidString
        defer { try? Keychain.delete(for: stale.id.uuidString)
                try? Keychain.delete(for: live.id.uuidString) }

        store.mergeDuplicateEndpointsForTesting()

        #expect(store.providers.count == 1)
        #expect(store.providers[0].id == live.id)
        #expect(store.credential(for: store.providers[0]) == "sk-live")
        // The model that only the stale record offered must not vanish with it.
        #expect(Set(store.providers[0].equipped) == ["z-ai/glm-5.2", "zai-org/GLM-5.1-FP8"])
        // The revoked key is gone, because the survivor demonstrably has one.
        #expect(Keychain.load(for: stale.id.uuidString) == nil)
    }

    /// A merge can no longer lose the last copy of a key — for a structural reason
    /// rather than a careful one.
    ///
    /// This used to assert a TIE-BREAK: two records for one endpoint, only one holding
    /// a secret, and the merge had to keep that one or the key was gone forever. Keys
    /// are now stored under the ENDPOINT, so both records resolve the same secret and
    /// neither can be "the one with the key" — whichever record survives, the key
    /// survives with it. The rule's purpose is satisfied by the storage, so the test
    /// asserts the purpose instead of the mechanism.
    @Test func aMergeCannotLoseTheLastCopyOfAKey() throws {
        let store = makeStore()
        var keyless = provider()
        keyless.requiresAPIKey = true
        var keyed = provider()
        keyed.requiresAPIKey = true
        keyed.id = UUID()
        store.providers.append(keyless)
        store.providers.append(keyed)
        try store.setCredential("sk-only-copy", forProviderID: keyed.id)
        defer {
            if let account = ProviderStore.keyAccount(for: keyed) { try? Keychain.delete(for: account) }
            try? Keychain.delete(for: keyed.id.uuidString)
        }

        store.mergeDuplicateEndpointsForTesting()

        #expect(store.providers.count == 1)
        // Whoever won, the key is still reachable from the survivor.
        #expect(store.credential(for: store.providers[0]) == "sk-only-copy")
        // And it lives under the endpoint, not under either record's uuid.
        let account = try #require(ProviderStore.keyAccount(for: keyed))
        #expect(Keychain.load(for: account) == "sk-only-copy")
        #expect(Keychain.load(for: keyed.id.uuidString) == nil)
        #expect(Keychain.load(for: keyless.id.uuidString) == nil)
    }

    @Test func distinctEndpointsStayDistinct() {
        let store = makeStore()
        store.addProvider(Provider(name: "a", endpoint: "https://api.example.com/v1", model: "m"))
        store.addProvider(Provider(name: "b", endpoint: "https://other.example.com/v1", model: "m"))

        #expect(store.providers.count == 2)
    }

    @Test func credentialIsFoundByEndpointAcrossInstances() throws {
        let store = makeStore()
        // What `save()` actually creates: the near.ai preset's endpoint, a NEW id.
        var instance = Provider.nearAI
        instance.id = UUID()
        defer { store.removeProvider(instance) }
        store.addProvider(instance)
        try store.setCredential("sk-near-ai", forProviderID: instance.id)

        // The "nothing was written here" slot must be one NOTHING can have
        // written to, so stand in a fresh id for the preset's fixed UUID.
        //
        // Reading `Provider.nearAI` itself was only ever true because the
        // simulator's Keychain is empty. On a device that slot holds the key
        // onboarding saved, so this failed AND printed a real credential into
        // the test log — the Keychain is process-wide, not sandboxed per test.
        // A test asserting a secret's absence must never name a slot a user
        // could have filled.
        var unwritten = Provider.nearAI
        unwritten.id = UUID()
        // THIS FLIPPED, and the flip is the migration. A different record id for the
        // same endpoint used to find nothing — which is why `credential(forEndpoint:)`
        // had to exist and why two screens shipped reading the wrong slot. The key is
        // the SERVER's now, so any record pointing at that server resolves it.
        #expect(store.credential(for: unwritten) == "sk-near-ai")
        // The endpoint lookup keeps working — the add screen uses it before any
        // record exists.
        #expect(store.credential(forEndpoint: Provider.nearAI.endpoint) == "sk-near-ai")
        // Case and padding in a typed endpoint must not defeat the match.
        #expect(store.credential(forEndpoint: "  " + Provider.nearAI.endpoint.uppercased() + " ")
                == "sk-near-ai")
    }

    @Test func credentialByEndpointIsNilWhenNothingMatches() throws {
        let store = makeStore()
        let p = provider("https://api.example.com/v1")
        defer { store.removeProvider(p) }
        store.addProvider(p)
        try store.setCredential("sk-a", forProviderID: p.id)

        #expect(store.credential(forEndpoint: "https://other.example.com/v1") == nil)
        #expect(store.credential(forEndpoint: "") == nil)
    }

    /// A provider with no key stored must not shadow one that has it.
    ///
    /// `addProvider` can no longer BUILD this state — one record per endpoint —
    /// so the duplicate is appended directly, which is the only way it still
    /// arises: a store written before that rule existed. The lookup has to keep
    /// working for those until they are healed, which is exactly why
    /// `credential(forEndpoint:)` is defensive about keyless rows.
    @Test func credentialByEndpointSkipsKeylessDuplicates() throws {
        let store = makeStore()
        let keyless = provider()
        var withKey = provider()
        withKey.id = UUID()
        defer { store.removeProvider(keyless); store.removeProvider(withKey) }
        store.providers.append(keyless)          // bypass the upsert, as an old store would
        store.providers.append(withKey)
        try store.setCredential("sk-the-real-one", forProviderID: withKey.id)

        #expect(store.providers.count == 2)      // the legacy shape, on purpose
        #expect(store.credential(forEndpoint: keyless.endpoint) == "sk-the-real-one")
    }

    /// Deleting a provider must take its secret with it — the id is gone, so a
    /// key left behind is unreachable and unremovable.
    @Test func removingAProviderDeletesItsKey() throws {
        let store = makeStore()
        let p = provider()
        store.addProvider(p)
        try store.setCredential("sk-doomed", forProviderID: p.id)
        #expect(store.credential(for: p) == "sk-doomed")

        store.removeProvider(p)
        #expect(store.credential(for: p) == "")
        #expect(Keychain.load(for: p.id.uuidString) == nil)
    }

    /// Onboarding's writer and the settings writer must agree.
    @Test func connectProviderStoresTheKeyItIsGiven() throws {
        let store = makeStore()
        let p = provider()
        defer { store.removeProvider(p) }

        try store.connectProvider(p, apiKey: "sk-onboarded")
        #expect(store.credential(for: p) == "sk-onboarded")
        #expect(store.credential(forEndpoint: p.endpoint) == "sk-onboarded")
        #expect(store.currentProviderID == p.id.uuidString)
    }

    /// A failed write must be reportable, not swallowed — the screen shows the
    /// reason instead of dismissing into a provider with no key.
    @Test func setCredentialThrowsOnAnInvalidWrite() {
        let store = makeStore()
        // An all-whitespace key takes the DELETE path (never throws); an empty
        // provider id can't happen. The contract that matters to the caller is
        // that the call is `throws` at all — verified by compiling this file —
        // and that Keychain surfaces its failures rather than returning nil.
        #expect(throws: Keychain.KeychainError.self) {
            try Keychain.save("", for: UUID().uuidString)   // empty value is invalid
        }
        #expect(store.credential(for: provider()) == "")
    }
}

/// Keys keyed by ENDPOINT, and the migration off record UUIDs.
///
/// The account used to be the record's uuid. That is *a* server id but not the
/// server's identity: a record can be recreated, merged, or written by a screen that
/// minted a fresh id, and the secret then sits under a uuid nothing points at. It
/// shipped twice in one evening — browsing a keyed provider fetched unauthenticated,
/// and the edit sheet showed an empty key field for a setup that had one — and both
/// were patched by trying a second lookup by endpoint. That tell is the whole argument:
/// if the endpoint is what answers, the endpoint is the account.
///
/// Runs against the REAL keychain, like the suite above, and cleans up.
@MainActor
@Suite("Keys are per server", .serialized)
struct EndpointKeyedCredentialTests {

    private func endpoint(_ suffix: String) -> String {
        "https://api.example-\(suffix)-\(UUID().uuidString.prefix(8)).com/v1"
    }

    private func cleanUp(_ providers: [Provider]) {
        for p in providers {
            if let account = ProviderStore.keyAccount(for: p) { try? Keychain.delete(for: account) }
            try? Keychain.delete(for: p.id.uuidString)
        }
    }

    /// The account is the endpoint, normalized the same way records are deduplicated —
    /// so a trailing slash or a capital letter cannot split one server into two keys.
    @Test func theAccountIsTheNormalizedEndpoint() {
        let a = Provider(name: "a", endpoint: "https://API.Example.com/v1", model: "m")
        let b = Provider(name: "b", endpoint: "https://api.example.com/v1/", model: "m")
        #expect(ProviderStore.keyAccount(for: a) == ProviderStore.keyAccount(for: b))
        #expect(ProviderStore.keyAccount(for: a)?.hasPrefix("endpoint:") == true)
    }

    /// On-device providers all share the literal endpoint "on-device" and hold no key.
    /// Without the guard every local model would address ONE account.
    @Test func onDeviceHasNoKeyAccount() {
        #expect(ProviderStore.keyAccount(for: .local(LocalModelCatalog.all[0])) == nil)
        #expect(ProviderStore.keyAccount(endpoint: "on-device") == nil)
    }

    /// A key written under the old uuid account is found, moved, and the old copy
    /// removed — once, on first read.
    @Test func aLegacyKeyIsMigratedOnRead() throws {
        let store = ProviderStore(inMemory: true)
        let p = Provider(name: "legacy", endpoint: endpoint("legacy"), model: "m")
        defer { cleanUp([p]) }
        store.addProvider(p)
        // Exactly what an old build wrote.
        try Keychain.save("sk-legacy-value", for: p.id.uuidString)

        #expect(store.credential(for: p) == "sk-legacy-value")

        let account = try #require(ProviderStore.keyAccount(for: p))
        #expect(Keychain.load(for: account) == "sk-legacy-value")
        #expect(Keychain.load(for: p.id.uuidString) == nil, "the uuid copy outlived the move")
    }

    /// The send path used to look keys up through a static that ignored the store.
    /// It now takes `apiKey` from the caller, and the caller is the store.
    @Test func theInstanceLookupSeesTheSavedKey() throws {
        let store = ProviderStore(inMemory: true)
        var p = Provider(name: "send", endpoint: endpoint("send"), model: "m")
        p.requiresAPIKey = true
        defer { cleanUp([p]) }
        store.addProvider(p)
        try store.setCredential("sk-send-path", forProviderID: p.id)

        #expect(store.credential(for: p) == "sk-send-path")
    }

    /// A second record for the same endpoint reads the SAME key, which is the point:
    /// the record id no longer decides whether a key is found.
    @Test func aRecreatedRecordFindsTheKey() throws {
        let store = ProviderStore(inMemory: true)
        let shared = endpoint("recreated")
        var first = Provider(name: "first", endpoint: shared, model: "m")
        first.requiresAPIKey = true
        defer { cleanUp([first]) }
        store.addProvider(first)
        try store.setCredential("sk-shared", forProviderID: first.id)

        // Same endpoint, brand new id — what a re-add or a restore produces.
        var second = Provider(name: "second", endpoint: shared, model: "m")
        second.requiresAPIKey = true
        #expect(store.credential(for: second) == "sk-shared")
    }

    /// Clearing the field removes BOTH accounts, so a stale uuid copy can't keep
    /// answering with a key the user just revoked.
    @Test func removingAKeyClearsTheLegacyCopyToo() throws {
        let store = ProviderStore(inMemory: true)
        var p = Provider(name: "revoke", endpoint: endpoint("revoke"), model: "m")
        p.requiresAPIKey = true
        defer { cleanUp([p]) }
        store.addProvider(p)
        try store.setCredential("sk-revoked", forProviderID: p.id)
        try Keychain.save("sk-stale-uuid-copy", for: p.id.uuidString)   // an unmigrated leftover

        try store.setCredential("", forProviderID: p.id)

        #expect(store.credential(for: p).isEmpty)
        #expect(Keychain.load(for: p.id.uuidString) == nil)
    }

    /// Deleting the setup takes the secret with it, under either account.
    @Test func deletingTheProviderLeavesNoSecret() throws {
        let store = ProviderStore(inMemory: true)
        var p = Provider(name: "gone", endpoint: endpoint("gone"), model: "m")
        p.requiresAPIKey = true
        store.addProvider(p)
        try store.setCredential("sk-doomed", forProviderID: p.id)
        try Keychain.save("sk-doomed-legacy", for: p.id.uuidString)

        store.removeProvider(p)

        let account = try #require(ProviderStore.keyAccount(for: p))
        #expect(Keychain.load(for: account) == nil)
        #expect(Keychain.load(for: p.id.uuidString) == nil)
    }

    /// A key can never be written to an account nothing will read.
    @Test func writingWithNoEndpointIsRefused() {
        let store = ProviderStore(inMemory: true)
        #expect(throws: (any Error).self) {
            try store.setCredential("sk-nowhere", forEndpoint: "on-device", legacyID: nil)
        }
    }
}

/// Renaming records off teemoon's own auto-label.
///
/// The label is "<place> <model>", written once when a setup is saved and never
/// refreshed — so a machine added while running gemma4:e2b-it-qat is still CALLED that
/// while running gemma4:e4b, and a user's fireworks key is called "fireworks Qwen3.7
/// Plus" while running deepseek. Three surfaces were patched to route around it; the
/// edit screen can't, because the stored name is the field being edited.
@MainActor
@Suite("Auto-label healing")
struct AutoLabelHealingTests {

    private func machine(_ name: String, model: String, models: [String]) -> Provider {
        var p = Provider(name: name, endpoint: "https://ringzero.tailnet-name.ts.net:11434/v1",
                         model: model, requiresAPIKey: false)
        p.equippedModels = models
        return p
    }

    /// The case on the screenshot: a machine named after a model it no longer runs.
    @Test func aMachineIsRenamedToItsHost() {
        let store = ProviderStore(inMemory: true)
        store.providers = [machine("ringzero gemma4:e2b-it-qat",
                                   model: "gemma4:e4b",
                                   models: ["gemma4:e4b", "gemma4:e2b-it-qat"])]
        store.healAutoLabelsForTesting()
        #expect(store.providers[0].name == "ringzero")
    }

    /// And the cloud half, which surfaced next.
    @Test func aCloudKeyIsRenamedToItsProvider() {
        let store = ProviderStore(inMemory: true)
        var fireworks = Provider.fireworks
        fireworks.name = "fireworks Kimi K2.6"     // a curated display name
        fireworks.model = "accounts/fireworks/models/deepseek-v4-flash"
        fireworks.equippedModels = ["accounts/fireworks/models/deepseek-v4-flash"]
        store.providers = [fireworks]
        store.healAutoLabelsForTesting()
        #expect(store.providers[0].name == "fireworks")
    }

    /// A name teemoon can't prove it wrote is LEFT ALONE. This is the whole risk of
    /// the migration: renaming records is destroying something a user typed.
    @Test func aTypedNameSurvives() {
        let store = ProviderStore(inMemory: true)
        store.providers = [
            machine("ringzero local server", model: "gemma4:e4b", models: ["gemma4:e4b"]),
            machine("the loud one", model: "gemma4:e4b", models: ["gemma4:e4b"]),
            machine("RINGZERO", model: "gemma4:e4b", models: ["gemma4:e4b"]),
        ]
        store.healAutoLabelsForTesting()
        #expect(store.providers.map(\.name) == ["ringzero local server", "the loud one", "RINGZERO"])
    }

    /// THE CASE THAT SHIPPED WRONG. A machine keeps the label it was given, and the
    /// stalest labels name a model that has since been DELETED from the box — one real record
    /// was still "ringzero gemma4:e2b-it-qat" after that model was removed.
    ///
    /// The first rule required the suffix to be a model the record still carries,
    /// which rejected exactly the labels most in need of renaming. A self-hosted
    /// suffix is now judged by SHAPE: one token with a tag or a namespace is a model
    /// ref whether or not the machine still serves it.
    @Test func aMachineNamedAfterADeletedModelIsStillRenamed() {
        let store = ProviderStore(inMemory: true)
        store.providers = [
            machine("ringzero gemma4:e2b-it-qat", model: "gemma4:e4b", models: ["gemma4:e4b"]),
            machine("ringzero llama3:70b", model: "gemma4:e4b", models: ["gemma4:e4b"]),
            machine("ringzero hf.co/bartowski/repo", model: "gemma4:e4b", models: ["gemma4:e4b"]),
        ]
        store.healAutoLabelsForTesting()
        #expect(store.providers.map(\.name) == ["ringzero", "ringzero", "ringzero"])
    }

    /// And the shape test is what keeps a typed name: a phrase has spaces, a model ref
    /// does not.
    @Test func shapeTellsAModelRefFromAPhrase() {
        for ref in ["gemma4:e2b-it-qat", "qwen3.5:4b", "hf.co/user/repo",
                    "ollama.com/library/gemma4"] {
            #expect(ProviderStore.looksLikeAModelRef(ref), Comment(rawValue: ref))
        }
        for phrase in ["local server", "the loud one", "in the closet", "mac", "x"] {
            #expect(!ProviderStore.looksLikeAModelRef(phrase), Comment(rawValue: phrase))
        }
    }

    /// Already correct, or nothing to shorten to: no rename, no churn.
    @Test func nothingToDoIsNoChange() {
        let store = ProviderStore(inMemory: true)
        var custom = Provider(name: "my proxy gpt-4", endpoint: "https://llm.example.com/v1",
                              model: "gpt-4", requiresAPIKey: true)
        custom.equippedModels = ["gpt-4"]
        store.providers = [
            machine("ringzero", model: "gemma4:e4b", models: ["gemma4:e4b"]),
            custom,      // custom cloud endpoint — teemoon generated no prefix for it
        ]
        store.healAutoLabelsForTesting()
        #expect(store.providers.map(\.name) == ["ringzero", "my proxy gpt-4"])
    }

    /// The live catalogue spells a model differently from the shipped table — the
    /// label was written from whatever was on screen at the time.
    @Test func liveAndCuratedSpellingsBothMatch() {
        var fireworks = Provider.fireworks
        fireworks.model = "accounts/fireworks/models/qwen3p7-plus"
        fireworks.equippedModels = ["accounts/fireworks/models/qwen3p7-plus"]
        for label in ["fireworks Qwen3.7 Plus",      // live
                      "fireworks qwen3p7-plus"] {    // curated id
            #expect(ProviderStore.isGeneratedLabel(label, place: "fireworks",
                                                   provider: fireworks),
                    Comment(rawValue: label))
        }
    }

    /// And the fuzz must not swallow a name someone chose. This is the guardrail on the
    /// whole migration: a rename that eats a typed label is not recoverable.
    @Test func theFuzzyMatchStillRefusesTypedNames() {
        var fireworks = Provider.fireworks
        fireworks.model = "accounts/fireworks/models/qwen3p7-plus"
        fireworks.equippedModels = ["accounts/fireworks/models/qwen3p7-plus"]
        for label in ["fireworks work account", "fireworks personal",
                      "fireworks billing", "fireworks 2"] {
            #expect(!ProviderStore.isGeneratedLabel(label, place: "fireworks",
                                                    provider: fireworks),
                    Comment(rawValue: label))
        }
    }

    /// On-device records are named after their model BY CONSTRUCTION — `Provider.local`
    /// sets both from one catalog entry — so renaming them would leave a row with no
    /// name at all.
    @Test func onDeviceIsUntouched() {
        let store = ProviderStore(inMemory: true)
        let local = Provider.local(LocalModelCatalog.all[0])
        store.providers = [local]
        store.healAutoLabelsForTesting()
        #expect(store.providers[0].name == local.name)
    }
}
