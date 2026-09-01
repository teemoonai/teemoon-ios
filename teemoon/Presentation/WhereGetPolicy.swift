//
//  WhereGetPolicy.swift
//  teemoon
//
//  Who appears in Where's `get` list. The sheet draws rows; this decides the
//  lists. See WhereGetPolicyTests.
//

import Foundation

struct WhereGetPolicy {
    struct HomeInfo: Equatable {
        var kind: LocalServerKind
        var modelCount: Int?
        var warm: Set<String> = []
    }

    var filter: WhereLocality?
    var providers: [Provider]
    var networkSatisfied: Bool
    var home: [UUID: HomeInfo]
    var credentialFor: (Provider) -> String
    var credentialForEndpoint: (String) -> String
    var catalog: [LocalModel] = LocalModelCatalog.all

    var filteredProviders: [Provider] {
        providers.filter { p in
            if !networkSatisfied { return WhereLocality.of(p) == .phone }
            guard let filter else { return true }
            return WhereLocality.of(p) == filter
        }
    }

    var downloadableModels: [LocalModel] {
        let owned = Set(providers.compactMap(\.localModelID))
        return catalog.filter { !owned.contains($0.id) }
    }

    /// In `all`, only the catalog leader (E2B). E4B is not a fallback.
    var recommendedDownload: LocalModel? {
        guard let recommended = catalog.first,
              !providers.contains(where: { $0.localModelID == recommended.id })
        else { return nil }
        return recommended
    }

    var getSectionIsEmpty: Bool {
        filter == .phone && downloadableModels.isEmpty && browseableProviders.isEmpty
    }

    var pullableProviders: [Provider] {
        filteredProviders.filter { home[$0.id]?.kind == .ollama }
    }

    var browseableProviders: [Provider] {
        filteredProviders.filter(canBrowse)
    }

    func canDeleteFromServer(_ provider: Provider) -> Bool {
        WhereLocality.of(provider) == .home && home[provider.id]?.kind == .ollama
    }

    func hasKey(_ provider: Provider) -> Bool {
        guard provider.requiresAPIKey else { return true }
        if !credentialFor(provider).trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        return !credentialForEndpoint(provider.endpoint)
            .trimmingCharacters(in: .whitespaces).isEmpty
    }

    func canBrowse(_ provider: Provider) -> Bool {
        guard WhereLocality.of(provider) != .home else { return false }
        guard !provider.isFixedAnswerService else { return false }
        guard hasKey(provider) else { return false }
        return provider.supportsModelBrowsing
            || provider.prefersSearchFirstBrowse
            || !WhereProviderPresentation.browseModels(for: provider).isEmpty
    }

    var addProviderLabel: String {
        switch filter {
        case .home:  return "connect a computer"
        case .cloud: return "add a cloud key"
        default:     return "add a provider"
        }
    }

    var addProviderGlyph: String {
        switch filter {
        case .home:  return WhereLocality.home.systemImage
        case .cloud: return "key"
        default:     return "plus"
        }
    }

    var addProviderCaption: String? {
        switch filter {
        case .cloud: return "configures an api key for any provider"
        case .home:  return "ollama, lm studio, or any openai-compatible server"
        default:     return nil
        }
    }

    /// Server product name, not the user's nickname.
    func browseName(for provider: Provider) -> String {
        home[provider.id]?.kind.displayName ?? provider.name.lowercased()
    }

    func browseCaption(for provider: Provider) -> String {
        if let count = home[provider.id]?.modelCount {
            return count == 1 ? "1 model on this server" : "\(count) models on this server"
        }
        if provider.prefersSearchFirstBrowse {
            return "search-first · large catalog"
        }
        return "equip another model on this setup"
    }

    func isCustom(_ provider: Provider) -> Bool {
        !Provider.presets.contains { $0.sameEndpoint(as: provider) }
    }

    func getFooter(openToGet: Bool, memoryFigure: String?) -> String {
        if openToGet {
            return "start here — add a key or connect a computer, then pick it under your setups."
        }
        if filter == .phone {
            guard let free = memoryFigure else { return "" }
            return "\(free) of memory free — memory, not storage, decides what can run."
        }
        return ""
    }

    /// What a swipe / context-menu may destroy. Home servers teemoon cannot
    /// delete on (LM Studio, llama.cpp) get `.none` — unequip would bounce back
    /// on the next probe.
    enum RowDestruction: Equatable {
        case deleteLocalWeights
        case deleteFromServer
        case unequipCloud
        case none
    }

    func destruction(for provider: Provider) -> RowDestruction {
        if provider.isLocal { return .deleteLocalWeights }
        if canDeleteFromServer(provider) { return .deleteFromServer }
        if WhereLocality.of(provider) == .home, provider.equipped.count > 1 {
            return .none
        }
        return .unequipCloud
    }

    /// Catalog leader if it fits; nil means do not hero a download that would fail.
    /// `availableMB == 0` is "API silent" — do not block (previews, simulator).
    static func recommendedPhoneModel(
        catalog: [LocalModel] = LocalModelCatalog.all,
        availableMB: Int
    ) -> LocalModel? {
        guard let model = catalog.first else { return nil }
        guard availableMB > 0 else { return model }
        return availableMB >= model.sizeMB + LocalMemory.headroomMB ? model : nil
    }

    func showsFirstRun(loadFailed: Bool, recommended: LocalModel?) -> Bool {
        providers.isEmpty
            && filter == nil
            && !loadFailed
            && networkSatisfied
            && recommended != nil
    }

    var emptyTitle: String {
        switch filter {
        case .none:  return "no setups yet"
        case .phone: return "nothing downloaded"
        case .home:  return "no computers connected"
        case .cloud: return "no cloud keys"
        }
    }

    var emptyGlyph: String { filter?.systemImage ?? "arrow.triangle.branch" }

    func emptyDescription(openToGet: Bool) -> String {
        switch filter {
        case .none:
            return openToGet
                ? "download a model to this phone, connect a computer, or add a cloud key in get below."
                : "download a model to this phone, connect a computer, or add a cloud key below."
        case .phone:
            return "download a model below to run it here — no key, no network."
        case .home:
            return "point teemoon at ollama on your laptop or home server."
        case .cloud:
            return "add a key to use a hosted model."
        }
    }

    func readyCaption(for provider: Provider) -> String? {
        if filter == .phone,
           let description = WhereProviderPresentation.modelDescription(for: provider) {
            return description
        }
        if WhereLocality.of(provider) == .home {
            guard let info = home[provider.id] else {
                return WhereProviderPresentation.placeCaption(for: provider)
            }
            guard let name = info.kind.displayName else {
                let host = WhereProviderPresentation.placeCaption(for: provider)
                return info.modelCount == nil
                    ? "\(host) · couldn't reach this server"
                    : host
            }
            let machines = Set(providers.filter { WhereLocality.of($0) == .home }.map(\.id))
            return (filter == .home && machines.count < 2) ? nil : name
        }
        let caption = WhereProviderPresentation.placeCaption(for: provider)
        if !provider.capabilities.contains(.endToEndEncryption),
           !provider.isFixedAnswerService,
           caption == WhereProviderPresentation.canonicalName(for: provider) {
            return "\(caption) · not end-to-end encrypted"
        }
        return caption
    }

    /// nil = unmeasured, not cold. Unknown servers have no warmth for any model.
    func isWarm(provider: Provider, modelID: String) -> Bool? {
        guard WhereLocality.of(provider) == .home else { return nil }
        guard let info = home[provider.id], info.kind != .unknown else { return nil }
        return info.warm.contains(modelID)
    }

    /// Orange caption: a near.ai model that is proxied, not enclave.
    func warnsUnencryptedNear(_ provider: Provider) -> Bool {
        provider.endpoint.contains("near.ai")
            && !provider.capabilities.contains(.endToEndEncryption)
    }
}
