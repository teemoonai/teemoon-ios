//
//  EncryptedModelCTA.swift
//  teemoon
//
//  The last button on the not-encrypted proof sheet. What it offers depends
//  on one thing — whether a usable near.ai key exists on this phone — read
//  through the same credential lookup the send gate uses.
//

import Foundation

enum EncryptedModelCTA: Equatable {
    /// A near.ai setup with a key: offer the switch, and say whose models
    /// they are and whose key they use. The chat leaves its current provider.
    case switchToNearAI(Provider)
    /// No usable near.ai key: no setup at all, or a legacy setup whose key
    /// is gone (since 1.0.2 a cloud setup cannot be saved without one, and
    /// deleting a setup removes its key). Both read the same to the user:
    /// offer the key form, editing the legacy setup when there is one.
    case addNearAIKey(existing: Provider?)

    static func resolve(nearAI: Provider?, hasKey: Bool) -> EncryptedModelCTA {
        if let nearAI, hasKey { return .switchToNearAI(nearAI) }
        return .addNearAIKey(existing: nearAI)
    }

    var title: String {
        switch self {
        case .switchToNearAI: return "switch to an end-to-end encrypted model on near.ai"
        case .addNearAIKey:   return "end-to-end encryption is available on near.ai"
        }
    }

    var detail: String {
        switch self {
        case .switchToNearAI: return "near.ai runs these inside sealed hardware · uses your near.ai key"
        case .addNearAIKey:   return "add a near.ai key and the same chats run inside sealed hardware"
        }
    }

    var opensPicker: Bool {
        if case .switchToNearAI = self { return true }
        return false
    }
}
