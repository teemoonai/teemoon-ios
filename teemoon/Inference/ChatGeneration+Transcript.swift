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
    /// `timeNotes`: each user turn carries the time IT was sent, as the request's `disclosure` renders it,
    /// so a turn's bytes come from the store and never change between requests.
    static func buildWireMessages(from messages: [Message], systemPrompt: String, maxMessages: Int?,
                                  omitSystemPrompt: Bool = false, timeNotes: Bool = false) -> [WireMessage] {
        buildTranscript(from: messages, systemPrompt: systemPrompt, maxMessages: maxMessages,
                        omitSystemPrompt: omitSystemPrompt, timeNotes: timeNotes).messages
    }

    /// The images of one request: at most this many, newest first, prompt included (IMAGES.md §4).
    static let maxImagesPerRequest = ChatViewModel.cloudImagesPerSend
    static let maxImageBytesPerRequest = 8 * 1024 * 1024
    static let earlierImageLine = "[image earlier in this chat]"

    struct Transcript {
        var messages: [WireMessage]
        /// Earlier images not sent because the model can't see images.
        var imagesLeftOutForModel = 0
        /// Earlier images not sent to keep the request small.
        var imagesLeftOutForSize = 0
    }

    /// `buildWireMessages`, with each earlier message's stored images attached while the request's
    /// budget lasts (`promptImages` spend it first). An image not sent leaves a line in its message's
    /// text, so the model knows one was there.
    static func buildTranscript(from messages: [Message], systemPrompt: String, maxMessages: Int?,
                                omitSystemPrompt: Bool = false, timeNotes: Bool = false,
                                seesImages: Bool = false, sendsEarlierImages: Bool = true,
                                maxImages: Int = maxImagesPerRequest,
                                disclosure: DisclosurePolicy = DisclosurePolicy(tier: .private, zone: .current),
                                promptImages: [WireImage] = [],
                                images: (Message) -> [WireImage] = { _ in [] }) -> Transcript {
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

        // Newest first: the budget goes to the images nearest the question.
        var count = promptImages.count
        var bytes = promptImages.reduce(0) { $0 + $1.data.count }
        var leftOutForModel = 0, leftOutForSize = 0
        var sent: [ObjectIdentifier: [WireImage]] = [:]
        var leftOut: [ObjectIdentifier: Int] = [:]
        for message in priorToInclude.reversed() where message.role != .system {
            for image in images(message) {
                if !seesImages {
                    leftOutForModel += 1; leftOut[ObjectIdentifier(message), default: 0] += 1
                } else if sendsEarlierImages, count < maxImages,
                          bytes + image.data.count <= maxImageBytesPerRequest {
                    count += 1; bytes += image.data.count; sent[ObjectIdentifier(message), default: []].append(image)
                } else {
                    leftOutForSize += 1; leftOut[ObjectIdentifier(message), default: 0] += 1
                }
            }
        }

        for message in priorToInclude {
            let id = ObjectIdentifier(message)
            let lines = String(repeating: "\n\n" + earlierImageLine, count: leftOut[id] ?? 0)
            let body = message.content.isEmpty && !lines.isEmpty ? String(lines.dropFirst(2)) : message.content + lines
            switch message.role {
            case .user:
                let note = timeNotes ? disclosure.sentAt(message.timestamp) : ""
                wire.append(WireMessage(role: "user", content: body + note, images: sent[id] ?? []))
            case .assistant:
                wire.append(WireMessage(role: "assistant", content: body, images: sent[id] ?? []))
            case .system:
                break
            }
        }
        return Transcript(messages: wire, imagesLeftOutForModel: leftOutForModel, imagesLeftOutForSize: leftOutForSize)
    }

    /// `{{date}}` (and the older `{{datetime}}`, same meaning) resolves to the DAY, never the minute: the system prompt
    /// opens every request, and a prefix that changes each minute misses every provider's prompt cache. The minute
    /// rides on each user turn instead. What the day says is the destination's (`DisclosurePolicy.dateLine`).
    static func resolvePromptTemplates(_ prompt: String, now: Date = Date(),
                                       disclosure: DisclosurePolicy = DisclosurePolicy(tier: .private)) -> String {
        let day = disclosure.dateLine(now)
        return prompt.replacingOccurrences(of: "{{datetime}}", with: day)
            .replacingOccurrences(of: "{{date}}", with: day)
    }

    /// Whether the persona asked for the date, and so each turn gets its time.
    static func wantsTimeNotes(systemPrompt: String, omitSystemPrompt: Bool) -> Bool {
        !omitSystemPrompt && (systemPrompt.contains("{{date}}") || systemPrompt.contains("{{datetime}}"))
    }

    /// The private tier's note; the transcript asks its request's policy (`DisclosurePolicy.sentAt`).
    static func timeNote(sentAt date: Date) -> String { DisclosurePolicy(tier: .private).sentAt(date) }
}
