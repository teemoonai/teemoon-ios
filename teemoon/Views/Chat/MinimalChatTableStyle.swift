//
//  MinimalChatTableStyle.swift
//  teemoon
//
//  The chat transcript's table styling, shared by both transcripts and the
//  preview below. Moved out of ConversationView.swift unchanged.
//

import SwiftUI
import Textual

struct MinimalChatTableStyle: StructuredText.TableStyle {
    #if os(iOS) || os(visionOS)
    private let borderColor = Color(UIColor.separator)
    #else
    private let borderColor = Color(NSColor.separatorColor)
    #endif
    // primary-relative opacity works in both light and dark mode.
    private let headerFill = Color.primary.opacity(0.12)

    func makeBody(configuration: Configuration) -> some View {
        // Overflow is Textual's horizontal scroll container. Unlike a raw
        // ScrollView(.horizontal), it propagates a gesture exclusion area so
        // horizontal drags reach the inner scroll view even when nested inside
        // ConversationView's vertical ScrollView.
        // fixedSize(horizontal: true) gives each Grid column its natural
        // (non-wrapping) width so narrow columns stay narrow and wide columns
        // ("Conditions", long descriptions) get all the space they need.
        Overflow { _ in
            configuration.label
                // Apply background/overlay before fixedSize so preference reads
                // happen directly on configuration.label's subtree.
                // Header row fill only.
                .textual.tableBackground { layout in
                    Canvas { context, _ in
                        if let first = layout.rowIndices.first {
                            context.fill(Path(layout.rowBounds(first)), with: .color(headerFill))
                        }
                    }
                }
                // 1pt dividers drawn at exact cell-boundary coordinates.
                .textual.tableOverlay { layout in
                    Canvas { context, _ in
                        let shading = GraphicsContext.Shading.color(borderColor)
                        for row in layout.rowIndices.dropLast() {
                            let y = layout.rowBounds(row).maxY
                            context.fill(Path(CGRect(x: layout.bounds.minX, y: y, width: layout.bounds.width, height: 1)), with: shading)
                        }
                        for col in layout.columnIndices.dropLast() {
                            let x = layout.columnBounds(col).maxX
                            context.fill(Path(CGRect(x: x, y: layout.bounds.minY, width: 1, height: layout.bounds.height)), with: shading)
                        }
                    }
                }
                // BOTH axes. Horizontal true keeps columns at natural width.
                // Vertical true reports the Grid's intrinsic height on the
                // FIRST pass. `vertical: false` took Overflow's still-nil
                // ScrollView proposal, so paragraphs painted and the table
                // popped in a frame later — the flash when scrolling a
                // table back on screen.
                .fixedSize(horizontal: true, vertical: true)
                .padding(1)
                .border(borderColor, width: 1)
        }
        // Overflow's horizontal ScrollView otherwise sizes to a later
        // onGeometryChange. Pin the wrapper so the hosting cell measures
        // the table in the same pass as the text above it.
        .fixedSize(horizontal: false, vertical: true)
        .textual.blockSpacing(.init(top: 12, bottom: 16))
    }
}

#Preview("Table Style") {
    let markdown = """
    Here's the 7-day forecast:

    | Day | Date   | High | Low  | Conditions                           | Rain % |
    |-----|--------|------|------|--------------------------------------|--------|
    | Mon | Apr 6  | 66°F | 32°F | T-storms; windy evening              | 100%   |
    | Tue | Apr 7  | 42°F | 24°F | Breezy and cooler; clearing          | 7%     |
    | Wed | Apr 8  | 40°F | 24°F | Some sun, then clouds                | 15%    |
    | Thu | Apr 9  | 51°F | 32°F | Mostly cloudy                        | 20%    |
    | Fri | Apr 10 | 59°F | 39°F | Mostly cloudy; slight chance of rain | 35%    |
    | Sat | Apr 11 | 58°F | 38°F | Sun & clouds; slight chance of rain  | 25%    |
    | Sun | Apr 12 | 56°F | 30°F | Rain/drizzle at times                | 65%    |

    **Outlook:** After tonight's storms, Tuesday through Thursday will be much cooler and quieter.
    """

    ScrollView {
        StructuredText.cached(markdown)
            .padding()
            .textual.tableStyle(MinimalChatTableStyle())
            .textual.tableCellStyle(MinimalChatTableCellStyle())
    }
    .preferredColorScheme(.dark)
}
