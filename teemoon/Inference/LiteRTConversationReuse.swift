//
//  LiteRTConversationReuse.swift
//  teemoon
//
//  Whether the on-device turn may KEEP last turn's LiteRT conversation and
//  send only the new user message, instead of seeding a new one with the
//  system prompt and the whole history. A seeded turn prefills everything
//  again, and on-device prefill is superlinear (see `GroundingBudget`).
//  Ported from Android (teemoon-android-perf 0afe1a5, ConversationReuse.kt).
//
//  The rule is EXACT EQUALITY with what this turn would seed: same system
//  prompt, same tools, and a history that is the kept transcript turn for
//  turn. Anything else rebuilds: an edit, a regenerate, a trimmed history (a
//  filling window), a thread switch, a changed persona.
//
//  Never kept: a turn that ran a tool (the KV holds the call and its result,
//  which the next seed would not carry), and a turn that was stopped,
//  capped, abandoned or failed (the runtime's state is unknown). A raw answer
//  that differs from the stored one (thinking, elided markup) makes the next
//  history differ, so that turn rebuilds by the equality rule.
//

import Foundation

struct KeptConversationState: Equatable, Sendable {
    struct Turn: Equatable, Sendable { let role: String; let text: String }
    let systemMessage: String?
    let toolNames: [String]
    let transcript: [Turn]
}

enum LiteRTConversationReuse {

    /// A thinking turn never reuses: kept conversations are thinking-off ones (`afterTurn`).
    static func canReuse(_ kept: KeptConversationState?, systemMessage: String?, toolNames: [String],
                         history: [KeptConversationState.Turn], thinking: Bool = false) -> Bool {
        guard let kept, !thinking else { return false }
        return kept.systemMessage == systemMessage && kept.toolNames == toolNames && kept.transcript == history
    }

    /// What the conversation holds after a completed turn, or nil when it must not be kept.
    static func afterTurn(systemMessage: String?, toolNames: [String], history: [KeptConversationState.Turn],
                          userText: String, rawAnswer: String, toolsRan: Int, completed: Bool,
                          thinking: Bool = false) -> KeptConversationState? {
        // A thinking turn's KV holds the thought, which no seed carries.
        guard completed, toolsRan == 0, !thinking, !rawAnswer.isEmpty else { return nil }
        return KeptConversationState(
            systemMessage: systemMessage, toolNames: toolNames,
            transcript: history + [.init(role: "user", text: userText),
                                   .init(role: "assistant", text: rawAnswer)])
    }
}
