//
//  ThinkingContentParser.swift
//  teemoon

import Foundation

enum ThinkingContentParser {
    /// Splits content containing `<think>…</think>` tags into a thinking portion and an answer portion.
    ///
    /// - Returns: A tuple where `thinking` is the text inside the think tags (nil if no `<think>` tag),
    ///   and `answer` is the text after the closing tag (nil if still thinking or empty).
    static func parse(_ content: String) -> (thinking: String?, answer: String?) {
        guard let startRange = content.range(of: "<think>") else {
            return (nil, content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let endRange = content.range(of: "</think>") else {
            let thinking = String(content[startRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (thinking, nil)
        }

        let thinking = String(content[startRange.upperBound ..< endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let afterThink = String(content[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        return (thinking, afterThink.isEmpty ? nil : afterThink)
    }
}
