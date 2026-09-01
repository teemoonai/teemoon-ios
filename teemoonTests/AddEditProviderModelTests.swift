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
