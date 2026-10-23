//
//  ReplySupersession.swift
//  teemoon
//
//  Think Harder's old reply, while the new one is on its way. In memory only:
//  the old reply stays in the store until the new one is saved, so a failed,
//  stopped or killed Think Harder leaves the chat as it was.
//

import Foundation

struct ReplySupersession: Equatable, Sendable {
    /// The replies after the question being re-asked.
    var replyIDs: Set<UUID> = []
    /// The new reply has shown text: the old one leaves the transcript.
    var swapped = false

    var isActive: Bool { !replyIDs.isEmpty }

    /// Shown at reduced opacity while the new reply has no text yet.
    func isDimmed(_ id: UUID) -> Bool { !swapped && replyIDs.contains(id) }

    /// The transcript's rows: the old reply until the swap, then not.
    func visible(_ messages: [Message]) -> [Message] {
        swapped ? messages.filter { !replyIDs.contains($0.id) } : messages
    }

    /// What the model is sent: never the reply it is replacing.
    func history(_ messages: [Message]) -> [Message] {
        isActive ? messages.filter { !replyIDs.contains($0.id) } : messages
    }

    /// The first visible text of the new reply.
    mutating func noteText(_ text: String) {
        guard isActive, !swapped, !text.isEmpty else { return }
        swapped = true
    }

    enum Outcome: Equatable {
        /// Delete these and save the new reply in the same save.
        case replace(Set<UUID>)
        /// Keep the old reply as it is; do not save a partial new one.
        case restore
    }

    /// nil when no Think Harder was in flight.
    func outcome(failed: Bool, cancelled: Bool, output: String) -> Outcome? {
        guard isActive else { return nil }
        if failed || cancelled || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .restore
        }
        return .replace(replyIDs)
    }
}
