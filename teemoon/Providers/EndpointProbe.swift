//
//  EndpointProbe.swift
//  teemoon
//
//  What the add/edit provider form learns from one probe: kind, models, warm
//  set, selected id, connection. The view applies the result; it does not
//  decide 401-without-key vs rejected key. See EndpointProbeTests.
//

import Foundation

enum EndpointProbe {

    struct Request: Equatable {
        var baseURL: URL
        var host: String?
        var apiKey: String
        var authHeaderName: String?
        var isSelfHosted: Bool
        /// Already-detected kind. Non-`.unknown` skips re-detection so a timeout
        /// mid-pull cannot hide Ollama's download button.
        var stickyKind: LocalServerKind
        var currentModel: String
        var preferredModel: String?
        var userInitiated: Bool
        var existingModels: [KnownModel]
        var defaultModelRule: ModelDefaultRule?
        var keyValidationEndpoint: ProviderKeyValidator.Endpoint?
    }

    enum Outcome: Equatable {
        case idle
        case connected
        case failed(EndpointModelCatalog.FailureKind)
    }

    struct Result: Equatable {
        var outcome: Outcome
        var models: [KnownModel]
        var kind: LocalServerKind
        var loaded: Set<String>
        var selectedModel: String
        var authNeeded: Bool
        var dismissEndpointFocus: Bool
        var shouldAutofillLabel: Bool
    }

    /// Network surfaces the probe calls. Production uses `.live`; tests inject.
    struct Catalog: Sendable {
        var detectKind: @Sendable (URL) async -> LocalServerKind
        var listOllama: @Sendable (URL) async -> EndpointModelCatalog.ProbeResult
        var listLMStudio: @Sendable (URL) async -> EndpointModelCatalog.ProbeResult
        var liveCatalog: @Sendable (String?, URL, String, String?) async -> EndpointModelCatalog.ProbeResult
        var loadedOllama: @Sendable (URL) async -> Set<String>
        var loadedLMStudio: @Sendable (URL) async -> Set<String>
        var validateKey: @Sendable (String, ProviderKeyValidator.Endpoint) async -> ProviderKeyValidator.ValidationResult

        static let live = Catalog(
            detectKind: { await LocalServerKind.detect(baseURL: $0) },
            listOllama: { await OllamaAdapter.listModels(baseURL: $0) },
            listLMStudio: { await LMStudioAdapter.listModels(baseURL: $0) },
            liveCatalog: { host, base, key, header in
                await ModelCatalog.liveCatalog(
                    for: .resolve(host: host),
                    baseURL: base,
                    apiKey: key,
                    authHeaderName: header
                )
            },
            loadedOllama: { await OllamaAdapter.loadedModels(baseURL: $0) },
            loadedLMStudio: { await LMStudioAdapter.loadedModels(baseURL: $0) },
            validateKey: { await ProviderKeyValidator.validate(key: $0, endpoint: $1) }
        )
    }

    /// True when the view should show `.testing` before `run` returns.
    static func needsNetwork(_ request: Request) -> Bool {
        if case .fixed = request.defaultModelRule {
            let key = request.apiKey.trimmingCharacters(in: .whitespaces)
            return request.keyValidationEndpoint != nil && !key.isEmpty
        }
        return true
    }

    static func failureMessage(_ kind: EndpointModelCatalog.FailureKind) -> String {
        switch kind {
        case .nothingListening: return "nothing listening there — is the server running?"
        case .noModelsEndpoint: return "reachable, but no /v1/models — check the path"
        case .httpBlocked:      return "ios blocked http — use https, or a tailscale name"
        case .unauthorized:     return "key rejected — check your api key"
        case .forbidden:        return "server refused the request — ollama rejects a proxied host header; set your proxy to rewrite Host to localhost"
        case .paymentRequired:  return "no credits on this account"
        case .rateLimited:      return "rate limited — try again shortly"
        case .badResponse:      return "connected, but no models were returned"
        case .offline:          return "couldn't reach that endpoint"
        }
    }

    static func run(_ request: Request, catalog: Catalog = .live) async -> Result {
        if case .fixed(let id) = request.defaultModelRule {
            return await runFixed(id: id, request: request, catalog: catalog)
        }
        return await runCatalog(request, catalog: catalog)
    }

    // MARK: - Fixed (Brave: no /models)

    private static func runFixed(
        id: String,
        request: Request,
        catalog: Catalog
    ) async -> Result {
        let key = request.apiKey.trimmingCharacters(in: .whitespaces)
        let empty = Result(
            outcome: key.isEmpty ? .idle : .connected,
            models: [],
            kind: .unknown,
            loaded: [],
            selectedModel: id,
            authNeeded: false,
            dismissEndpointFocus: false,
            shouldAutofillLabel: false
        )
        guard let validation = request.keyValidationEndpoint, !key.isEmpty else {
            return empty
        }
        let result = await catalog.validateKey(key, validation)
        var out = empty
        out.outcome = .connected
        switch result {
        case .success:         out.outcome = .connected
        case .unauthorized:    out.authNeeded = true; out.outcome = .failed(.unauthorized)
        case .paymentRequired: out.outcome = .failed(.paymentRequired)
        case .rateLimited:     out.outcome = .failed(.rateLimited)
        case .otherFailure:    out.outcome = .failed(.offline)
        }
        return out
    }

    // MARK: - Live catalogue

    private static func runCatalog(_ request: Request, catalog: Catalog) async -> Result {
        let kind: LocalServerKind
        if request.stickyKind != .unknown {
            kind = request.stickyKind
        } else if request.isSelfHosted {
            kind = await catalog.detectKind(request.baseURL)
        } else {
            kind = .unknown
        }

        let listed: EndpointModelCatalog.ProbeResult
        switch kind {
        case .ollama:
            listed = await catalog.listOllama(request.baseURL)
        case .lmStudio:
            listed = await catalog.listLMStudio(request.baseURL)
        case .unknown:
            listed = await catalog.liveCatalog(
                request.host, request.baseURL, request.apiKey, request.authHeaderName)
        }

        let loaded: Set<String>
        switch kind {
        case .ollama:   loaded = await catalog.loadedOllama(request.baseURL)
        case .lmStudio: loaded = await catalog.loadedLMStudio(request.baseURL)
        case .unknown:  loaded = []
        }

        switch listed {
        case .connected(let models):
            return Result(
                outcome: .connected,
                models: models,
                kind: kind,
                loaded: loaded,
                selectedModel: pickModel(from: models, request: request),
                authNeeded: false,
                dismissEndpointFocus: true,
                shouldAutofillLabel: true
            )
        case .failed(let failure):
            return interpretFailure(failure, kind: kind, loaded: loaded, request: request)
        }
    }

    /// 401 with no key on an automatic probe is a missing key, not a rejected one.
    /// Do not skip the probe when the key is empty — near.ai's list is public.
    private static func interpretFailure(
        _ failure: EndpointModelCatalog.FailureKind,
        kind: LocalServerKind,
        loaded: Set<String>,
        request: Request
    ) -> Result {
        let keyEntered = !request.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        let authNeeded = failure == .unauthorized
        let idleMissingKey = failure == .unauthorized && !keyEntered && !request.userInitiated
        let outcome: Outcome
        if idleMissingKey {
            outcome = .idle
        } else if request.existingModels.isEmpty || failure == .unauthorized {
            outcome = .failed(failure)
        } else {
            outcome = .connected
        }
        return Result(
            outcome: outcome,
            models: request.existingModels,
            kind: kind,
            loaded: loaded,
            selectedModel: request.currentModel,
            authNeeded: authNeeded,
            dismissEndpointFocus: false,
            shouldAutofillLabel: false
        )
    }

    private static func pickModel(from models: [KnownModel], request: Request) -> String {
        if let preferred = request.preferredModel?.lowercased(),
           let match = models.first(where: { $0.id.lowercased() == preferred })
                        ?? models.first(where: { $0.id.lowercased().hasPrefix(preferred) }) {
            return match.id
        }
        if let rule = request.defaultModelRule,
           !models.contains(where: { $0.id == request.currentModel }),
           let picked = rule.resolve(from: models) {
            return picked
        }
        if request.currentModel.trimmingCharacters(in: .whitespaces).isEmpty {
            return models.first?.id ?? request.currentModel
        }
        return request.currentModel
    }
}
