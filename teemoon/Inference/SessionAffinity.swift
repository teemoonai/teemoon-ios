//
//  SessionAffinity.swift
//  teemoon
//
//  Providers keep a prompt cache per server; a routing id sends a chat's turns
//  to one server so the cached prefix is found. Fireworks `x-session-affinity`
//  (docs.fireworks.ai/guides/prompt-caching), xAI `x-grok-conv-id`
//  (docs.x.ai, prompt caching), OpenRouter `x-session-id` (its sticky routing;
//  ignored there if `provider.order` is ever set). Send it only where the
//  provider documents it.
//
//  The value is HMAC-SHA256(per-install secret, thread id): the same chat
//  keeps its id across relaunches, two chats never share one, and nobody
//  without the secret can tie it to the thread or to another install.
//

import CryptoKit
import Foundation

@MainActor
enum SessionAffinity {
    private static var ids: [UUID: String] = [:]
    static let secretAccount = "sessionAffinity.secret"

    static func id(for threadID: UUID) -> String {
        if let id = ids[threadID] { return id }
        // No secret (Keychain locked or failing): a random id for this launch only.
        let id = installSecret().map { derive(threadID: threadID, secret: $0) } ?? UUID().uuidString.lowercased()
        ids[threadID] = id
        return id
    }

    nonisolated static func derive(threadID: UUID, secret: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(threadID.uuidString.lowercased().utf8),
                                                  using: SymmetricKey(data: secret))
        return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func installSecret() -> Data? {
        if let stored = Keychain.load(for: secretAccount), let data = Data(base64Encoded: stored), data.count == 32 {
            return data
        }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        guard (try? Keychain.save(fresh.base64EncodedString(), for: secretAccount)) != nil else { return nil }
        return fresh
    }

    /// The header to send, or nil where the provider documents none.
    nonisolated static func header(for provider: Provider) -> String? {
        switch provider.openAIBaseURL?.host?.lowercased() {
        case "api.fireworks.ai": return "x-session-affinity"
        case "api.x.ai": return "x-grok-conv-id"
        case "openrouter.ai": return "x-session-id"
        default: return nil
        }
    }
}
