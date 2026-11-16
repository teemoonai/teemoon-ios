//
//  ChatImportResultView.swift
//  teemoon
//
//  The import's alerts: a failure, and the delete offer after the sheet closes. The flow itself is NearImportView.
//

import SwiftUI

extension View {
    /// A failed import as a system alert (UI audit #8).
    func chatImportFailureAlert(_ importer: ChatImportModel) -> some View {
        let alert = importer.failureAlert
        return self.alert(alert?.title ?? "", isPresented: Binding(get: { importer.failureAlert != nil },
                                                                   set: { if !$0 { importer.dismissResult() } }),
                          presenting: alert) { _ in
            Button(ChatImportText.alertButton) { importer.dismissResult() }
        } message: { alert in
            if let message = alert.message { Text(message) }
        }
    }

    /// Delete the export? Shown by whoever presented the import sheet, once it has closed: `sheetUp` goes false in
    /// the sheet's onDismiss, since an alert raised during the dismissal is dropped.
    func chatImportDeleteOffer(_ importer: ChatImportModel, fromOutside: Bool, sheetUp: Bool) -> some View {
        self
            .alert(ChatImportText.deleteTitle,
                   isPresented: Binding(get: { !sheetUp && importer.deleteOffer?.fromOutside == fromOutside },
                                        set: { if !$0 { importer.keepExport() } }),
                   presenting: importer.deleteOffer) { offer in
                Button(ChatImportText.deleteButton(offer.name), role: .destructive) { importer.deleteExport() }
                    .accessibilityIdentifier("import.deleteExport")
                Button(ChatImportText.notNow, role: .cancel) { importer.keepExport() }
                    .accessibilityIdentifier("import.keepExport")
            } message: { offer in
                Text(ChatImportText.deleteMessage(offer.name))
            }
            .alert(ChatImportText.deleteFailedTitle,
                   isPresented: Binding(get: { importer.deleteFailed?.fromOutside == fromOutside },
                                        set: { if !$0 { importer.dismissDeleteFailure() } })) {
                Button(ChatImportText.alertButton) { importer.dismissDeleteFailure() }
            } message: {
                Text(ChatImportText.deleteFailedMessage)
            }
    }
}
