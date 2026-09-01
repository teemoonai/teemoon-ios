//
//  SearchFirstModelBrowser.swift
//  teemoon
//
//  Model browser for large catalogs (OpenRouter-scale): search first, then
//  rows. Same job as ModelBrowserView — pick a model for a place — with a
//  filter so hundreds of rows stay usable.
//
//  Related: WhereSheetView, ModelBrowserView, EndpointModelCatalog.
//

import SwiftUI

struct SearchFirstModelBrowser: View {
    let provider: Provider
    let apiKey: String
    var onSelect: (KnownModel) -> Void

    @State private var query = ""
    @State private var models: [KnownModel] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @Environment(\.dismiss) private var dismiss

    private var filtered: [KnownModel] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = models.filter { !ModelCatalog.isNonChat($0.id) }
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.displayName.lowercased().contains(q)
                || $0.id.lowercased().contains(q)
                || $0.vendor.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("loading models…")
                        .textCase(.lowercase)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadFailed && models.isEmpty {
                    ContentUnavailableView {
                        Label("couldn't load models", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("check the key and network, or type a model id below.")
                            .textCase(.lowercase)
                    }
                } else {
                    List {
                        if !query.isEmpty && filtered.isEmpty {
                            Section {
                                Button {
                                    pickTypedID()
                                } label: {
                                    Label("use “\(query)” as model id", systemImage: "plus.circle")
                                        .textCase(.lowercase)
                                }
                            } footer: {
                                Text("no catalog match — sends the typed id as-is.")
                                    .textCase(.lowercase)
                            }
                        }
                        Section {
                            ForEach(filtered) { model in
                                Button {
                                    onSelect(model)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(model.displayName)
                                            .foregroundStyle(.primary)
                                            .textCase(.lowercase)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(model.vendor)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textCase(.lowercase)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text(query.isEmpty ? "models" : "results")
                                .textCase(.lowercase)
                        } footer: {
                            Text("search-first for large catalogs (e.g. openrouter). same pick action as the standard model browser.")
                                .textCase(.lowercase)
                        }
                    }
                    .groupedListStyle()
                }
            }
            .searchable(text: $query, prompt: "search models")
            .navigationTitle("browse \(provider.name.lowercased())")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                        .textCase(.lowercase)
                }
            }
            .task { await load() }
        }
    }

    private func pickTypedID() {
        let id = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let known = KnownModel(
            id: id,
            displayName: id.split(separator: "/").last.map(String.init) ?? id,
            vendor: provider.name,
            price: ""
        )
        onSelect(known)
        dismiss()
    }

    private func load() async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }

        guard let base = provider.openAIBaseURL else {
            loadFailed = true
            return
        }

        let result = await EndpointModelCatalog.probe(
            baseURL: base,
            authHeaderName: provider.authHeaderName,
            apiKey: apiKey
        )
        switch result {
        case .connected(let list):
            models = list.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .failed:
            loadFailed = true
            models = []
        }
    }
}
