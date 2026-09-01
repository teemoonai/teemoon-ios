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
    static func buildWireMessages(from messages: [Message], systemPrompt: String, maxMessages: Int?, omitSystemPrompt: Bool = false) -> [WireMessage] {
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
                wire.append(WireMessage(role: "user", content: message.content))
            case .assistant:
                wire.append(WireMessage(role: "assistant", content: message.content))
            case .system:
                break
            }
        }
        return wire
    }

    private static let datetimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        return f
    }()

    static func resolvePromptTemplates(_ prompt: String) -> String {
        return prompt.replacingOccurrences(of: "{{datetime}}", with: datetimeFormatter.string(from: Date()))
    }
}
