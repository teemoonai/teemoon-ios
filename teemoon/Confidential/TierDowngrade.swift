//
//  TierDowngrade.swift
//  teemoon
//
//  Ask before the first plain send to a near.ai model a send once went to sealed (docs/TIER_DOWNGRADE.md, 1.1.0
//  audit LOW). the maintainer approved 2026-11-18: UserDefaults, model ids only, no SwiftData change.
//

import Foundation

/// The near.ai model ids a request went out sealed to (`nearai.sealedModels`). Ids only: no content, key or chat.
struct SealedModels: Sendable {
    static let key = "nearai.sealedModels"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var ids: Set<String> { Set(defaults.stringArray(forKey: Self.key) ?? []) }

    /// A sealed request to `modelID` reached the wire (rule 1); a later downgrade asks again (rule 4).
    func arm(_ modelID: String) { write(ids.union([modelID.lowercased()])) }

    /// "send without encryption": the consent is the removal, so later plain sends to it don't ask (rule 3).
    func accept(_ modelID: String) { write(ids.subtracting([modelID.lowercased()])) }

    /// "delete provider" for near.ai.
    func clear() { defaults.removeObject(forKey: Self.key) }

    private func write(_ set: Set<String>) {
        if set.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(set.sorted(), forKey: Self.key) }
    }
}

enum TierDowngrade {
    /// Rule 2: near.ai, no `.attestation` now, and once sealed. Never for any other provider.
    static func owed(provider: Provider?, sealed: Set<String>) -> Bool {
        guard let provider, provider.isNearAI, !provider.capabilities.contains(.attestation) else { return false }
        return sealed.contains(provider.model.lowercased())
    }

    /// Card tier-downgrade-ask v4, approved 2026-11-19: the model is named once, in the title. Don't reword without the maintainer.
    static func title(model: String) -> String { "\(model) isn't end-to-end encrypted anymore" }
    static let message = "near.ai now lists it as running outside its own enclaves, so this message would reach near.ai over ordinary TLS. your earlier messages to it were sealed."
}

extension ConfidentialSession {
    /// Rule 2: the active near.ai model was sent to sealed and now reads third-party or proxied.
    var sealedModelWentPlain: Bool { TierDowngrade.owed(provider: activeProvider, sealed: sealedModels.ids) }

    /// The approved sheet, or nil when no downgrade ask is owed. The view shows this before `E2EEAsk.make`.
    var e2eeAskTierDowngrade: E2EEAsk? {
        guard sealedModelWentPlain, let provider = activeProvider else { return nil }
        let name = ModelCatalog.compactName(forID: provider.model)
        return E2EEAsk(title: TierDowngrade.title(model: name), message: TierDowngrade.message,
                       choices: [.sendAnyway(stillEncrypted: false), .dontSend], kind: .tierDowngrade)
    }
}
