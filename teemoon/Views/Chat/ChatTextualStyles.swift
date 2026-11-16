//
//  ChatTextualStyles.swift
//  teemoon
//
//  The Textual styles both transcripts draw replies with. Apply them through `chatTextualStyles()` only,
//  so the streaming view, the saved row and the tests cannot disagree.
//

import SwiftUI
import Textual

extension View {
    func chatTextualStyles() -> some View {
        self
            .textual.tableStyle(MinimalChatTableStyle())
            .textual.tableCellStyle(MinimalChatTableCellStyle())
            .textual.codeBlockStyle(ChatCodeBlockStyle())
    }
}

/// Textual's default code block with long lines wrapped. Tables keep scrolling: set `.wrap` here, never
/// on the whole transcript.
struct ChatCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        StructuredText.DefaultCodeBlockStyle().makeBody(configuration: configuration)
            .textual.overflowMode(.wrap)
    }
}
