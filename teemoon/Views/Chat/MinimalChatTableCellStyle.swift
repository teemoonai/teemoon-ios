//
//  MinimalChatTableCellStyle.swift
//  teemoon
//
//  The chat transcript's table cell styling, shared by both transcripts and
//  the table-style preview. Moved out of ConversationView.swift unchanged.
//

import SwiftUI
import Textual

/// Smaller font + tighter padding for table cells. Body-size text in a table
/// is too large — .callout saves ~12% horizontal width per column and keeps
/// the table from scrolling unnecessarily on narrow screens.
struct MinimalChatTableCellStyle: StructuredText.TableCellStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .fontWeight(configuration.row == 0 ? .semibold : .regular)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
    }
}
