//
//  AddEditProviderModelTests.swift
//  teemoonTests
//
//  Pins the server-side model delete's FAILURE path. The confirm dialog says
//  "this frees disk and can't be undone" — so a delete that fails must say so
//  through `modelDeleteError`, not `try?` its way to a silently reappearing
//  row. Offline: both network surfaces (delete, re-probe) are injected seams.
//

import Foundation
import Testing
@testable import teemoon

/// Reference cell so the escaping seam closures can record without capturing
/// mutable locals (and without inheriting the suite's MainActor isolation).
private final class Recorder: @unchecked Sendable {
    var deleted: [String] = []
    var haptics = 0
}

@MainActor
@Suite("AddEditProviderModel server-side delete")
struct AddEditProviderModelTests {

    /// Offline probe: every surface answers without the network, so the
    /// re-probe after a delete runs for real and still costs nothing.
    private func offlineCatalog() -> EndpointProbe.Catalog {
        EndpointProbe.Catalog(
            detectKind: { _ in .unknown },
            listOllama: { _ in .failed(.offline) },
            listLMStudio: { _ in .failed(.offline) },
            liveCatalog: { _, _, _, _ in .failed(.offline) },
            loadedOllama: { _ in [] },
            loadedLMStudio: { _ in [] },
            validateKey: { _, _ in .otherFailure }
        )
    }

    private func makeForm() -> AddEditProviderModel {
        let form = AddEditProviderModel(mode: .add)
        form.scheme = .http
        form.endpointHost = "box.local:11434/v1"
        form.model = "gemma4:e4b"
        form.probeCatalog = offlineCatalog()
        return form
    }

    private let gemma = KnownModel(id: "gemma4:e4b", displayName: "gemma4", vendor: "", price: "")

    @Test func failedDeleteSurfacesAlertAndKeepsSelection() async {
        let form = makeForm()
        let rec = Recorder()
        form.deleteModelFromServer = { _, _ in
            throw OllamaPullError(status: 500, message: "delete failed on server")
        }
        form.onPlayHaptic = { rec.haptics += 1 }

        await form.performDelete(gemma)

        #expect(form.modelDeleteError?.contains("gemma4") == true)                  // names the model
        #expect(form.modelDeleteError?.contains("delete failed on server") == true) // and the reason
        #expect(form.model == "gemma4:e4b")   // still on the server — selection kept
        #expect(form.hasProbed)               // re-probed anyway, so the list shows the true state
        #expect(rec.haptics == 0)             // no success tap for a failure
        #expect(form.pendingDelete == nil)
    }

    @Test func successfulDeleteClearsSelectionAndRaisesNoAlert() async {
        let form = makeForm()
        let rec = Recorder()
        form.deleteModelFromServer = { id, _ in rec.deleted.append(id) }
        form.onPlayHaptic = { rec.haptics += 1 }

        await form.performDelete(gemma)

        #expect(rec.deleted == ["gemma4:e4b"])
        #expect(form.modelDeleteError == nil)
        #expect(form.model == "")             // the deleted model was selected — cleared
        #expect(form.hasProbed)
        #expect(rec.haptics == 1)
    }
}

/// A tester picked the Brave Answers preset, left the key blank, and saved —
/// the form only asked for a name, an endpoint and a model. The setup then
/// sent its first message with no auth header (HTTP 422 "Field required" for
/// `header x-subscription-token`).
@MainActor
@Suite("AddEditProviderModel required key")
struct AddEditProviderModelRequiredKeyTests {

    @Test func cloudPresetCannotBeAddedWithoutAKey() throws {
        let store = ProviderStore(inMemory: true)
        let form = AddEditProviderModel(mode: .add)
        form.providerStore = store
        form.apply(preset: .braveAnswers)
        #expect(form.requiresAPIKey)
        // Save stays ENABLED; the refusal is inline, on the field.
        #expect(form.isValid)
        #expect(form.apiKeyPlaceholder == "api key — required")
        #expect(form.keyFieldError == nil)

        #expect(form.save() == false)
        #expect(store.providers.isEmpty, "a keyless cloud setup must not be created")
        #expect(form.keyFieldError?.contains("api key") == true)
        #expect(form.keyFocusRequest == 1)

        form.apiKey = "   "
        #expect(form.save() == false)
        #expect(form.keyFocusRequest == 2)

        // Typing clears the error; saving then stores the setup and its key.
        form.apiKey = "BSA-test"
        #expect(form.keyFieldError == nil)
        #expect(form.apiKeyPlaceholder == "api key")
        #expect(form.save())
        let saved = try #require(store.providers.first)
        defer { store.removeProvider(saved) }
        #expect(store.credential(for: saved) == "BSA-test")
    }

    @Test func selfHostedSetupStillSavesKeyless() {
        let form = AddEditProviderModel(mode: .add)
        form.scheme = .http
        form.endpointHost = "box.local:11434/v1"
        form.model = "gemma4:e4b"
        form.name = "box"
        #expect(!form.requiresAPIKey)
        #expect(!form.missingRequiredKey)
    }

    /// Editing must not recreate the keyless state either: a tester cleared the
    /// key of a saved Brave Answers setup from Settings and could save. Revoking
    /// is deleting the setup.
    @Test func editingRefusesAnEmptiedKey() throws {
        let store = ProviderStore(inMemory: true)
        let saved = Provider.braveAnswers
        store.addProvider(saved)
        defer { store.removeProvider(saved) }
        try store.setCredential("BSA-old", forProviderID: saved.id)

        let form = AddEditProviderModel(mode: .edit(saved))
        form.providerStore = store
        form.loadInitialValues()
        #expect(form.isEditing)
        #expect(form.apiKey == "BSA-old")

        form.apiKey = ""
        #expect(form.missingRequiredKey)
        #expect(form.save() == false)
        #expect(form.keyFieldError != nil)
        #expect(store.credential(for: saved) == "BSA-old", "a refused save must not touch the stored key")

        form.apiKey = "BSA-new"
        #expect(form.save())
        #expect(store.credential(for: saved) == "BSA-new")
    }

    /// The clear path still exists where it is safe: a self-hosted box that had
    /// a key and no longer needs one.
    @Test func selfHostedEditCanStillClearItsKey() throws {
        let store = ProviderStore(inMemory: true)
        var box = Provider(name: "box", endpoint: "http://box.local:11434/v1/chat/completions",
                           model: "gemma4:e4b")
        box.requiresAPIKey = true
        store.addProvider(box)
        defer { store.removeProvider(box) }
        try store.setCredential("old", forProviderID: box.id)

        let form = AddEditProviderModel(mode: .edit(box))
        form.providerStore = store
        form.loadInitialValues()
        form.apiKey = ""
        #expect(!form.missingRequiredKey)
        #expect(form.save())
        #expect(store.credential(forEndpoint: box.endpoint) == nil)
    }

    /// Testing a second key in the editor used to write the probe's answer
    /// under that key's hash and prune the saved account's list — so a
    /// test-then-cancel destroyed it. The probe only fills the form; the
    /// store is written on save, under the key that was saved.
    @Test func aProbeDoesNotTouchTheSavedCatalogueUntilSave() async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editor-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LiveCatalogStore(directory: dir)
        let saved = KnownModel(id: "accounts/a/models/saved", displayName: "saved", vendor: "a", price: "")
        store.record([saved], for: .fireworks, apiKey: "key-one")

        let form = AddEditProviderModel(mode: .edit(.fireworks))
        form.scheme = .https
        form.endpointHost = String(Provider.fireworks.endpoint.dropFirst("https://".count))
        form.catalogStore = store
        form.apiKey = "key-two"
        let probed = KnownModel(id: "accounts/b/models/probed", displayName: "probed", vendor: "b", price: "")
        form.probeCatalog = EndpointProbe.Catalog(
            detectKind: { _ in .unknown },
            listOllama: { _ in .failed(.offline) },
            listLMStudio: { _ in .failed(.offline) },
            liveCatalog: { (_: String?, _: URL, _: String, _: String?) async -> EndpointModelCatalog.ProbeResult in
                .connected([probed])
            },
            loadedOllama: { _ in [] },
            loadedLMStudio: { _ in [] },
            validateKey: { _, _ in .otherFailure }
        )

        await form.probe(userInitiated: true)

        #expect(form.fetchedModels.map(\.id) == ["accounts/b/models/probed"])
        #expect(store.count(for: .fireworks, apiKey: "key-one") == 1)    // untouched
        #expect(store.count(for: .fireworks, apiKey: "key-two") == nil)  // not written
    }
}
