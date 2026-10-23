//
//  ReasoningEffort.swift
//  teemoon
//
//  How long the SAME model on the SAME provider thinks. Never a model or
//  provider switch. Chat sends `.fast` (the maintainer, 2026-10-19, after an internal eval:
//  low lost no objective task; an omitted level let GLM 5.3 overthink into
//  the output cap). Never "none": grok-4.3 at none got the hard maths wrong.
//

import Foundation

enum ReasoningEffort: String, Codable, Sendable, CaseIterable {
    case fast
    case thinkHarder

    /// What a chat turn sends unless the person asks for more.
    static let chatDefault: ReasoningEffort = .fast
    /// Output budget on a near.ai Think Harder turn. Fireworks, xAI and OpenRouter
    /// get none: their defaults wrote 11k–13k tokens (measured 2026-10-22).
    static let thinkHarderOutputTokens = 8192

    /// Request-body fields for this effort, or nil where the provider takes no
    /// such parameter. Which field, if any, is `ReasoningControl`'s call.
    func bodyFields(for provider: Provider) -> [String: Any]? {
        guard !Self.refused.value.contains(Self.refusalKey(provider)) else { return nil }
        let high = self == .thinkHarder
        switch ReasoningControl.current(for: provider) {
        case .effort(let cap):
            var fields: [String: Any] = ["reasoning_effort": high ? "high" : "low"]
            if high, let cap { fields["max_tokens"] = cap }
            return fields
        case .openRouter: return ["reasoning": ["effort": high ? "high" : "low"]]
        case .thinkingSwitch: return ["chat_template_kwargs": ["enable_thinking": high]]
        case .onDevice, .none: return nil
        }
    }

    /// Think Harder is offered only where a higher level is known to take effect.
    static func canThinkHarder(_ control: ReasoningControl, provider: Provider) -> Bool {
        control != .none && !refused.value.contains(refusalKey(provider))
    }

    /// The card's label for a request body: "effort low/high" or "thinking off/on"; nil when it sent none.
    static func sentLevel(inBodyJSON json: String?) -> String? {
        guard let data = json?.data(using: .utf8),
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let level = body["reasoning_effort"] as? String { return "effort \(level)" }
        if let level = (body["reasoning"] as? [String: Any])?["effort"] as? String { return "effort \(level)" }
        if let on = (body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool {
            return on ? "thinking on" : "thinking off"
        }
        return nil
    }

    /// The card's line: the turn's level (the maintainer: no per-round detail).
    /// Every request of a turn sends the same level, so the first one sent stands for it.
    static func cardLine(levels: [String?]) -> String? {
        turnLevel(levels: levels)
    }

    static func turnLevel(levels: [String?]) -> String? {
        levels.lazy.compactMap { $0 }.first
    }

    // MARK: A model that rejects the parameter

    /// Models that answered 400 to the effort field, this launch only: the API
    /// decides support, not a list.
    private static let refused = LockedBox<Set<String>>([])

    private static func refusalKey(_ provider: Provider) -> String {
        "\(provider.openAIBaseURL?.host?.lowercased() ?? "")|\(provider.model)"
    }

    /// True when a 400 names the effort parameter ("Invalid reasoning effort.").
    static func isRefusal(status: Int, body: Data) -> Bool {
        guard status == 400 else { return false }
        // xAI names fields in camel case ("parameter reasoningEffort"), so match with separators removed.
        let text = String(decoding: body, as: UTF8.self).lowercased()
            .replacingOccurrences(of: "_", with: "").replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
        return text.contains("reasoningeffort") || text.contains("chattemplatekwargs")
            || text.contains("enablethinking")
    }

    static func noteRefused(by provider: Provider) {
        refused.value.insert(refusalKey(provider))
    }

    static func forgetRefusals() { refused.value = [] }
}

/// How a provider's model is told how hard to think, from what is known about it:
/// a documented host, OpenRouter's `supported_parameters`, or an Ollama server.
/// A server that might silently ignore the field gets nothing, so Think Harder is
/// never a plain re-ask dressed up as more thinking.
enum ReasoningControl: Equatable, Sendable {
    /// `reasoning_effort` low/high; `cap` is Think Harder's max_tokens, nil for none.
    case effort(cap: Int?)
    /// OpenRouter's `reasoning.effort`.
    case openRouter
    /// `chat_template_kwargs.enable_thinking` off/on (NVIDIA: measured, effort is ignored).
    case thinkingSwitch
    /// LiteRT's ThinkingConfig off/on.
    case onDevice
    case none

    static func resolve(provider: Provider, serverKind: LocalServerKind?, modelParameters: [String]?) -> ReasoningControl {
        if provider.isLocal { return .onDevice }
        guard !provider.capabilities.contains(.builtInGrounding),
              let host = provider.openAIBaseURL?.host?.lowercased() else { return .none }
        if Provider.isNearAIHost(host) { return .effort(cap: ReasoningEffort.thinkHarderOutputTokens) }
        if host == "api.fireworks.ai" || host == "api.x.ai" { return .effort(cap: nil) }
        if host == "openrouter.ai" { return modelParameters?.contains("reasoning") == true ? .openRouter : .none }
        if host == "integrate.api.nvidia.com" { return .thinkingSwitch }
        if serverKind == .ollama { return .effort(cap: nil) }
        return .none
    }

    /// Resolved on the main actor where the store is, read by the transport per request.
    private static let known = LockedBox<[String: ReasoningControl]>([:])

    static func note(_ control: ReasoningControl, for provider: Provider) {
        known.value[key(provider)] = control
    }

    static func current(for provider: Provider) -> ReasoningControl {
        known.value[key(provider)] ?? resolve(provider: provider, serverKind: nil, modelParameters: nil)
    }

    private static func key(_ provider: Provider) -> String {
        "\(provider.endpoint)|\(provider.model)"
    }

    /// What the store knows about this provider's server and model.
    @MainActor static func resolve(provider: Provider, store: ProviderStore) -> ReasoningControl {
        let parameters = LiveCatalogStore.shared.allModels(forEndpoint: provider.endpoint)
            .first { $0.id == provider.model }?.samplingParameters
        var kind = store.storedKind(of: provider) ?? (probed[provider.endpoint] == true ? .ollama : nil)
        #if DEBUG
        kind = kind ?? seededKinds[provider.endpoint]
        #endif
        return resolve(provider: provider, serverKind: kind, modelParameters: parameters)
    }

    /// This launch's first-send answers, by endpoint: true = Ollama. A false is not asked again.
    @MainActor private static var probed: [String: Bool] = [:]

    /// A self-hosted server nothing has classified yet (added before 1.0.6, or never opened in
    /// Where) is asked once whether it is Ollama, before the first send. One request, ~2 s at most.
    @MainActor static func classifyIfNeeded(_ provider: Provider, store: ProviderStore,
                                            isOllama: (URL) async -> Bool = { await OllamaAdapter.isOllama(baseURL: $0, timeout: 2) }) async {
        guard !provider.isLocal, provider.isSelfHosted, store.storedKind(of: provider) == nil,
              probed[provider.endpoint] == nil, let base = provider.openAIBaseURL else { return }
        let answer = await isOllama(base)
        probed[provider.endpoint] = answer
        if answer { store.recordProbe(of: provider, kind: .ollama, servedModels: nil) }
    }

    #if DEBUG
    @MainActor static func forgetProbesForTesting() { probed = [:] }

    /// DEBUG + --uitesting only (ContentView's seed): the kind a probe would have stored.
    @MainActor static var seededKinds: [String: LocalServerKind] = [:]
    #endif
}
