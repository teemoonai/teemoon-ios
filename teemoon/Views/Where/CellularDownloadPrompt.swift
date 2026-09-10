//
//  CellularDownloadPrompt.swift
//  teemoon
//
//  The "download over mobile data?" alert, shared by the Where sheet and the
//  chat's restart button. The decision to show it is `CellularDownloadGate`;
//  this only draws the question and hands back the answer.
//

import SwiftUI

/// A download that is waiting on the user's answer.
struct CellularDownloadRequest: Identifiable {
    let model: LocalModel
    let reason: CellularDownloadGate.Reason
    var id: String { model.id }

    /// Starts the download or produces a request, from the current path.
    @MainActor
    static func resolve(_ model: LocalModel, path: NetworkPathObserver,
                        start: (LocalModel, DownloadNetwork) -> Void) -> CellularDownloadRequest? {
        switch CellularDownloadGate.decision(pathIsExpensive: path.isMobileData,
                                             pathIsConstrained: path.isConstrained) {
        case .download(let network):
            start(model, network)
            return nil
        case .ask(let reason):
            return CellularDownloadRequest(model: model, reason: reason)
        }
    }
}

extension View {
    /// Presents the question while `request` is non-nil; `start` receives the
    /// user's allowance. Dismissing without choosing starts nothing.
    func cellularDownloadPrompt(
        _ request: Binding<CellularDownloadRequest?>,
        start: @escaping (LocalModel, DownloadNetwork) -> Void
    ) -> some View {
        alert(
            request.wrappedValue.map { CellularDownloadGate.title(for: $0.reason) } ?? "",
            isPresented: Binding(
                get: { request.wrappedValue != nil },
                set: { if !$0 { request.wrappedValue = nil } }
            ),
            presenting: request.wrappedValue
        ) { pending in
            Button("download now") { start(pending.model, .any) }
            Button("wait for wi-fi") { start(pending.model, .wifiOnly) }
            Button("cancel", role: .cancel) {}
        } message: { pending in
            Text(CellularDownloadGate.message(for: pending.reason, model: pending.model))
        }
    }
}
