//
//  ProviderPresentationModifiers.swift
//  teemoon
//
//  The add/edit provider screen's sheets and alerts, lifted out of the form's
//  modifier chain so each stays a small expression for the type-checker (see
//  `AddEditProviderView.formView`).
//

import SwiftUI

struct ProviderSheets: ViewModifier {
    @Binding var showModelBrowser: Bool
    @Binding var showDownloadSheet: Bool
    @Binding var selectedModel: String
    let models: [KnownModel]
    let showsConfidentialityTags: Bool
    let downloadBaseURL: URL?
    let onSelectModel: (KnownModel) -> Void
    let onDownloadCompleted: (String) -> Void
    /// Fired the moment a pull STARTS, so the arriving model becomes this screen's
    /// selection — the same contract the Where sheet's `onStarted` has.
    let onDownloadStarted: (String) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showModelBrowser) {
                ModelBrowserView(selectedModel: $selectedModel, models: models,
                                 onSelect: onSelectModel,
                                 showsConfidentialityTags: showsConfidentialityTags)
                #if os(macOS)
                .frame(minWidth: 400, minHeight: 450)
                #endif
            }
            .sheet(isPresented: $showDownloadSheet) {
                if let base = downloadBaseURL {
                    // `models` is this screen's probe result — what the server
                    // reported having, which is exactly what the download sheet needs
                    // to stop offering a model that is already there.
                    OllamaModelDownloadView(baseURL: base,
                                            onCompleted: onDownloadCompleted,
                                            onStarted: onDownloadStarted,
                                            installed: models.map(\.id))
                    #if os(macOS)
                    .frame(minWidth: 400, minHeight: 450)
                    #endif
                }
            }
    }
}

struct ProviderConfirmations: ViewModifier {
    @Binding var showDeleteConfirm: Bool
    @Binding var pendingDelete: KnownModel?
    /// Non-nil when the keychain refused the key on save. Surfaced rather than
    /// swallowed: the provider is saved but has no credential, and silence there
    /// only reappears later as an unexplained unauthorized request.
    @Binding var keySaveError: String?
    /// Non-nil when a confirmed server-side model delete failed. The dialog above
    /// promised "this frees disk and can't be undone" — on failure the row simply
    /// reappears, and without this alert nothing says why.
    @Binding var modelDeleteError: String?
    let onDeleteProvider: () -> Void
    let onDeleteModel: (KnownModel) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog("delete this provider?", isPresented: $showDeleteConfirm,
                                titleVisibility: .visible) {
                Button("delete provider", role: .destructive, action: onDeleteProvider)
            }
            .alert(
                "delete model?",
                isPresented: Binding(get: { pendingDelete != nil },
                                     set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { m in
                Button("delete", role: .destructive) { onDeleteModel(m) }
                Button("cancel", role: .cancel) { pendingDelete = nil }
            } message: { m in
                Text("delete “\(m.displayName)” from the server? this frees disk and can't be undone.")
            }
            .alert(
                "couldn't save the api key",
                isPresented: Binding(get: { keySaveError != nil },
                                     set: { if !$0 { keySaveError = nil } }),
                presenting: keySaveError
            ) { _ in
                Button("ok", role: .cancel) { keySaveError = nil }
            } message: { reason in
                Text("the provider was saved, but the key could not be written to the keychain — \(reason)")
            }
            .alert(
                "couldn't delete the model",
                isPresented: Binding(get: { modelDeleteError != nil },
                                     set: { if !$0 { modelDeleteError = nil } }),
                presenting: modelDeleteError
            ) { _ in
                Button("ok", role: .cancel) { modelDeleteError = nil }
            } message: { reason in
                Text(reason)
            }
    }
}
