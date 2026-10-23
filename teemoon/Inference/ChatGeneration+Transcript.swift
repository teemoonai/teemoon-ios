//
//  ChatGeneration+Transcript.swift
//  teemoon
//
//  How a SwiftData thread becomes wire messages, and how the persona
//  template is filled. Kept off ChatGeneration.swift so orchestration
//  is not also the transcript compiler.
//

import Foundation

extension ChatGeneration {

    /// Builds the prior-turn wire messages for `ConfidentialLanguageModel`:
    /// optional system prompt plus every turn before the one being sent
    /// (the current prompt goes through `session.streamResponse(to:)`).
    /// `timeNotes`: each user turn carries the time IT was sent (`timeNote(sentAt:)`),
    /// so a turn's bytes come from the store and never change between requests.
    static func buildWireMessages(from messages: [Message], systemPrompt: String, maxMessages: Int?,
                                  omitSystemPrompt: Bool = false, timeNotes: Bool = false) -> [WireMessage] {
        var wire: [WireMessage] = []
        if !omitSystemPrompt {
            wire.append(WireMessage(role: "system", content: systemPrompt))
        }

        let prior = messages.dropLast().filter { $0.role != .system }
        let priorToInclude: [Message]
        if let max = maxMessages {
            priorToInclude = Array(prior.suffix(max - 1))
        } else {
            priorToInclude = Array(prior)
        }

        for message in priorToInclude {
            switch message.role {
            case .user:
                let note = timeNotes ? timeNote(sentAt: message.timestamp) : ""
                wire.append(WireMessage(role: "user", content: message.content + note))
            case .assistant:
                wire.append(WireMessage(role: "assistant", content: message.content))
            case .system:
                break
            }
        }
        return wire
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// `{{date}}` (and the older `{{datetime}}`, same meaning) resolves to the
    /// DAY, never the minute: the system prompt opens every request, and a
    /// prefix that changes each minute misses every provider's prompt cache.
    /// The minute rides on each user turn instead (`timeNote(sentAt:)`).
    static func resolvePromptTemplates(_ prompt: String, now: Date = Date()) -> String {
        let day = dateFormatter.string(from: now)
        return prompt.replacingOccurrences(of: "{{datetime}}", with: day)
            .replacingOccurrences(of: "{{date}}", with: day)
    }

    /// Whether the persona asked for the date, and so each turn gets its time.
    static func wantsTimeNotes(systemPrompt: String, omitSystemPrompt: Bool) -> Bool {
        !omitSystemPrompt && (systemPrompt.contains("{{date}}") || systemPrompt.contains("{{datetime}}"))
    }

    /// Appended to a user turn on the wire, never stored: the message's own
    /// timestamp is the source, so the same turn renders the same bytes every time.
    static func timeNote(sentAt date: Date) -> String {
        "\n\n[Sent at \(timeFormatter.string(from: date))]"
    }
}
