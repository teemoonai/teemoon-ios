//
//  ThinkingClock.swift
//  teemoon
//
//  "thought for Ns" is turn start → the first `</think>`, stamped where the text arrives, never in a view.
//  ThinkingClockTests pins it.
//

import Foundation

enum ThinkingClock {
    /// The thinking time once `output` has closed its think block, else `current`.
    static func stamp(_ current: TimeInterval?, output: String, elapsed: TimeInterval?) -> TimeInterval? {
        guard current == nil, let elapsed else { return current }
        let parse = ThinkingContentParser.parse(output)
        return parse.thinking != nil && output.contains("</think>") ? elapsed : nil
    }

    /// Whether the drawn text is still inside its think block.
    static func isStillThinking(_ shown: String) -> Bool {
        shown.contains("<think>") && !shown.contains("</think>")
    }

    /// What the saved reply keeps: its thinking time, or the whole turn when it did not think.
    static func savedTime(thinking: TimeInterval?, turn: TimeInterval?) -> TimeInterval? {
        thinking ?? turn
    }

    /// The live label, shared by the activity chip and an open think block's header.
    static func liveLabel(elapsed: TimeInterval?) -> String {
        guard let elapsed, elapsed >= 1 else { return "thinking…" }
        return "thinking… \(Int(elapsed))s"
    }
}
