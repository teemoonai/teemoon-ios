//
//  SupersededReplyDimming.swift
//  teemoon
//

import SwiftUI

/// Think Harder's old reply, dimmed in place while the new one has no text
/// (`ReplySupersession`). Opacity only: the row keeps its size, so nothing below it moves.
struct SupersededReplyDimming: ViewModifier {
    let messageID: UUID
    @Environment(ChatGeneration.self) private var llm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(llm.superseding.isDimmed(messageID) ? 0.45 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: llm.superseding.isDimmed(messageID))
    }
}
