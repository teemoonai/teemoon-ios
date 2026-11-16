//
//  WhereGetPolicy.swift
//  teemoon
//
//  Who appears in Where's `get` list. The sheet draws rows; this decides the
//  lists. See WhereGetPolicyTests.
//

import Foundation

/// A where row's second line. `.attention` only for a row the user must act on; trust facts stay `.muted`.
enum WhereCaptionTone: Equatable { case muted, attention }

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
    /// How many models this server last answered with. Injected so the policy
    /// stays testable and there is one number: the saved live list's length.
    var catalogCount: (Provider) -> Int? = { _ in nil }
    var catalog: [LocalModel] = LocalModelCatalog.all
    /// The "show only" row's filters (§4e): they narrow `get` too.
    var show = WhereFilterPolicy()
    /// The server's saved list, so a filtered row can say "k of n". nil when none is saved.
    var catalogModels: (Provider) -> [KnownModel]? = { _ in nil }
    /// Whether a phone model's image turn fits this phone (PhoneImageMemory).
    var phoneReadsImages: (String) -> Bool = { PhoneImageMemory.reads(modelID: $0) }

    var filteredProviders: [Provider] {
        providers.filter { p in
            if !networkSatisfied { return WhereLocality.of(p) == .phone }
            guard let filter else { return true }
            return WhereLocality.of(p) == filter
        }
    }

    var downloadableModels: [LocalModel] {
        guard show.showsDownload else { return [] }
        let owned = Set(providers.compactMap(\.localModelID))
        return catalog.filter {
            !owned.contains($0.id) && show.showsDownload(readsImages: show.imagesOnDevice && phoneReadsImages($0.id))
        }
    }

    /// In `all`, only the catalog leader (E2B). E4B is not a fallback.
    var recommendedDownload: LocalModel? {
        guard show.showsDownload, let recommended = catalog.first,
              show.showsDownload(readsImages: show.imagesOnDevice && phoneReadsImages(recommended.id)),
              !providers.contains(where: { $0.localModelID == recommended.id })
        else { return nil }
        return recommended
    }

    var getSectionIsEmpty: Bool {
        (filter == .phone && downloadableModels.isEmpty && browseableProviders.isEmpty)
            || (filter == .home && !show.showsHomeGetRows)
    }

    var pullableProviders: [Provider] {
        guard show.showsHomeGetRows else { return [] }
        return filteredProviders.filter { home[$0.id]?.kind == .ollama }
    }

    var browseableProviders: [Provider] {
        filteredProviders.filter(canBrowse)
    }

    /// The trailing text on a `get` row: "add key" until there is one, then
    /// the model count. Nothing at all when the server has not answered yet —
    /// a made-up number is worse than no number.
    func presetTrailingText(for provider: Provider, keyed: Bool) -> String? {
        guard keyed else { return "add key" }
        return catalogCount(provider).map(String.init)
    }

    /// A preset or browse row under the "show only" filters: hidden, or its trailing text.
    func serverRow(for provider: Provider, keyed: Bool) -> WhereFilterPolicy.ServerRow {
        let models = keyed ? catalogModels(provider).flatMap { $0.isEmpty ? nil : $0 } : nil
        return show.serverRow(keyed: keyed, claimsEndToEnd: provider.claimsEndToEndEncryption,
                              total: models?.count,
                              matching: models.map { WhereFilterPolicy.matching($0, filters: show.filters,
                                                                                 tiered: provider.isNearAI) })
    }

    /// Whether `get` offers a model under the "show only" filters: a download or a server row. Not the
    /// add / connect / pull rows, which are always there. Decides the filter's empty line.
    func getOffers(hasKey: (Provider) -> Bool) -> Bool {
        guard networkSatisfied else { return false }
        func serverOffers() -> Bool {
            let custom = filter == .cloud ? browseableProviders.filter(isCustom) : []
            let presets = Provider.presets.filter { !$0.isFixedAnswerService }
                .map { preset in providers.first { $0.sameEndpoint(as: preset) } ?? preset }
            return custom.contains { serverRow(for: $0, keyed: true) != .hidden }
                || presets.contains { serverRow(for: $0, keyed: hasKey($0)) != .hidden }
        }
        switch filter {
        case .none:  return recommendedDownload != nil || serverOffers()
        case .phone: return !downloadableModels.isEmpty
        case .home:  return false
        case .cloud: return serverOffers()
        }
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
        // A known catalogue is browsable; a custom endpoint only when its
        // setup says so, since its `/models` may not exist and a 401 there
        // reads as a bad key.
        let source = WhereProviderPresentation.liveCatalogSource(for: provider)
        return provider.supportsModelBrowsing || (source != nil && source != .generic)
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
        if show.isFiltering, case .shown(let count?) = serverRow(for: provider, keyed: true) {
            return "\(count) models on this setup"
        }
        if let count = home[provider.id]?.modelCount {
            return count == 1 ? "1 model on this server" : "\(count) models on this server"
        }
        if let count = catalogCount(provider) {
            return count == 1 ? "1 model on this setup" : "\(count) models on this setup"
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

    /// Catalog leader unless the phone is below its RAM floor; nil means do not hero a download that would fail.
    /// The same rule as the "may not fit" label, never free memory at the moment the sheet draws.
    static func recommendedPhoneModel(
        catalog: [LocalModel] = LocalModelCatalog.all,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> LocalModel? {
        guard let model = catalog.first else { return nil }
        return LocalMemory.belowFloor(model, physicalBytes: physicalBytes) ? nil : model
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
        if !provider.claimsEndToEndEncryption,
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

    /// Never `.attention` for a trust fact: "not end-to-end encrypted" is information, not a fault.
    func captionTone(for provider: Provider, missingWeights: Bool, pullFailed: Bool) -> WhereCaptionTone {
        missingWeights || pullFailed ? .attention : .muted
    }
}
