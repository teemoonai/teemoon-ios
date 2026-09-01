//
//  WhereRow.swift
//  teemoon
//
//  One geometry for every Where sheet row. Split out of WhereSheetView so
//  the picker coordinator and the row no longer share a file.
//

import SwiftUI

// MARK: - Shared row

/// One geometry for every row in this sheet, in every state.
///
/// The states were previously hand-built where they were used, so nothing lined
/// up: the glyph centred against a two-line block while the neighbouring row
/// centred against one, the percentage and the cancel button sat at two
/// different right margins, and the row height changed by several points
/// depending on whether a progress bar was present. Four small decisions, each
/// locally reasonable, adding up to a row that looks assembled by accident.
///
/// The rules, in one place:
/// - **Glyph column** is a fixed 24pt wide box, the height of one title line, so
///   the glyph optically centres on the TITLE rather than on however many lines
///   the row happens to have. This is what list rows do everywhere in iOS.
/// - **One trailing margin.** Trailing metadata (size, percent) and the cancel
///   button end at the same edge, because a ragged right edge is the single most
///   visible symptom of a row that wasn't designed.
/// - **The selection tick is a row accessory**, not title-line metadata: it sits
///   outside the text block and centres against the whole row, like the leading
///   glyph. Nothing else may share that slot — warmth did, and the two fought
///   over the same 21pt.
/// - **The second line is one slot**, occupied by a description OR a progress
///   bar. Both are 1 line tall, so the row does not resize when a download
///   starts — a list that reflows as bars appear reads as broken.
/// - **Notes come third**, and only when they exist.
/// NOTE ON THE MARK USED HERE: the browse row renders `confidentialityTag`
/// from AddEditProviderView — the SAME green shield the near.ai model browser
/// and the inline add-provider rows use. That function is file-level for
/// exactly this reason ("so the browser and the inline add-provider rows render
/// it identically"), and a second component would have made the sheet disagree
/// with the screen it hands you to.
///
/// An earlier pass invented a separate neutral-plate tag here. It was wrong for
/// a reason worth keeping: a user meets this mark on the browse row and then
/// meets it again on every model inside, and two different shapes for one fact
/// teaches that they are two facts.

/// One row's identity for the detail sheet: the place AND the model, because
/// the same model id can be equipped on more than one place.
struct ModelDetailTarget: Identifiable {
    let provider: Provider
    let model: KnownModel
    var id: String { provider.id.uuidString + "|" + model.id }
}

struct WhereRow: View {
    let glyph: String
    var glyphTint: Color = .secondary
    let title: String
    var titleTint: Color = .primary
    var titleWeight: Font.Weight = .medium
    /// Marks the row's provider as end-to-end encrypted, inline after the
    /// title. Set from the provider's own capability, never hardcoded per
    /// vendor — a second e2ee provider gets the mark for free.
    var showsE2EETag: Bool = false
    /// Right-aligned on the title line: a size before a download, a percentage
    /// during one.
    var trailingText: String?
    var trailingMonospaced: Bool = false
    /// Accessory after `trailingText` — the download affordance, in the same
    /// slot the checkmark uses. It lives on the RIGHT so the leading glyph
    /// column can stay one symbol per tier: `iphone` next to
    /// `arrow.down.circle` centred in the same box put their ink at different
    /// left edges, and a column of symbols with ragged left edges is the thing
    /// that reads as unaligned no matter how exact the frames are.
    var trailingGlyph: String?
    /// Second line, when not showing progress.
    var caption: String?
    var captionTint: Color = .secondary
    /// One line by default, so a row's height can't change when a download
    /// starts and a list of them doesn't reflow. Raised only where the caption
    /// is a WARNING rather than a description — a truncated description costs
    /// the reader a detail, a truncated warning costs them the warning.
    var captionLineLimit: Int = 1
    /// Second line, when downloading. Takes the caption's slot.
    var progress: Double?
    var onCancel: (() -> Void)?
    /// Third line, orange: a memory warning or a failure.
    var note: String?
    /// The selection tick, centred against the whole row at the trailing edge.
    var isSelected: Bool = false
    /// "warm" or "cold" for a home model, joined onto the caption's metadata run
    /// — `ollama · warm`.
    ///
    /// It used to be `trailingText`, which put it in the tick's slot: on the
    /// selected row the word was shoved left, so `warm` ended 21pt inside the
    /// `cold` above it and the tick read as belonging to the word rather than to
    /// the row. The caption line is where this belongs anyway — it is metadata
    /// about the server, exactly like the `near.ai · end-to-end encrypted` it now
    /// sits in a column with, and the title line goes back to carrying one thing:
    /// which model answers your next message.
    var warmth: String?

    /// One title line at `.body`. The reason this row's height is stable.
    private let titleLineHeight: CGFloat = ControlMetrics.sheetRowTitleLineHeight

    /// Caption and warmth are one metadata run. Handles the caption-less case —
    /// filtered to a single home machine the server name is suppressed, and
    /// warmth still has to appear somewhere.
    private var resolvedCaption: String? {
        WhereProviderPresentation.metadataRun(caption, warmth)
    }

    var body: some View {
        // `.firstTextBaseline`, with the glyph rendered as TEXT.
        //
        // Centring an `Image` inside a fixed-height box looks right for one
        // glyph and wrong for the next: `iphone` is tall and narrow,
        // `arrow.down.circle` is a wide circle, and their ink sits differently
        // inside the same box — so consecutive rows appeared misaligned even
        // though their frames matched exactly. `Text(Image(...))` participates
        // in baseline alignment, which pins every glyph's baseline to the
        // title's baseline. That is what makes a column of mismatched symbols
        // read as a column.
        // Settings' convention: a larger glyph, centred against the whole row.
        //
        // These were baseline-aligned at 15pt, which fixed a real problem —
        // glyphs of different widths centred in a fixed box read as a ragged
        // column. But settings sizes its row icons around 20pt and centres them
        // vertically, and two sheets a tap apart should not align their rows
        // differently. Consistency with the app beats the tidier rule.
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: glyph)
                .font(.system(size: 20))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(glyphTint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if showsE2EETag {
                        // The tag rides WITH the title, so a long name truncates
                        // before the mark is pushed off the row.
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(size: ControlMetrics.sheetRowTitleSize, weight: titleWeight))
                                .foregroundStyle(titleTint)
                                .textCase(.lowercase)
                                .lineLimit(1)
                                .layoutPriority(1)
                            confidentialityTag(.teeOwn)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                    Text(title)
                        // 16pt, the design's figure, not `.body`.
                        //
                        // `.body` is 17pt at default and Dynamic Type scales it
                        // — at a larger text setting the rows grew until three
                        // filled a screen the design sizes for seven. A picker
                        // is a density instrument: it exists to show what you
                        // have, and it stops working when it shows three.
                        .font(.system(size: ControlMetrics.sheetRowTitleSize, weight: titleWeight))
                        .foregroundStyle(titleTint)
                        .textCase(.lowercase)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    // ONLY while downloading. The percentage has to stay on the
                    // title line then, because the bar below is sized to end
                    // exactly where the percentage above it does — moving it out
                    // of this text block narrows the block and breaks that
                    // alignment. Every other trailing value is centred against
                    // the row instead; see the accessory slot below.
                    if progress != nil, let trailingText {
                        Text(trailingText)
                            .font(.system(size: 13, design: trailingMonospaced ? .monospaced : .default))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: titleLineHeight)

                if let progress {
                    // The bar spans the WHOLE text block, so it ends exactly
                    // under the percentage on the line above. Cancel used to
                    // sit here in an HStack with it, which cost the bar 26pt
                    // (16 glyph + 10 spacing) and left the row with three
                    // different right edges: percentage at the block edge,
                    // cancel inside that, bar shortest of all. The comment on
                    // that HStack claimed the bar ended where the percentage
                    // did — it could not, being in the same row as the button.
                    // Cancel now lives in the accessory slot below.
                    ProgressView(value: progress)
                        .tint(.accentColor)
                        .frame(height: 18)
                } else if let caption = resolvedCaption {
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundStyle(captionTint)
                        .textCase(.lowercase)
                        .lineLimit(captionLineLimit)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                        // Fixed height only for the single-line case, which is
                        // what keeps a row from resizing mid-download. A row
                        // allowed two lines has opted out of that guarantee.
                        .frame(minHeight: captionLineLimit == 1 ? ControlMetrics.sheetRowCaptionLineHeight : nil,
                               alignment: .leading)
                }

                if let note {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                        .textCase(.lowercase)
                        .lineLimit(2)
                }
            }

            // THE ACCESSORY SLOT. Everything in here sits OUTSIDE the text block
            // and so centres against the whole row, like the leading glyph — which
            // is what iOS list rows do with a detail value and a disclosure.
            //
            // On the title line these were baseline-aligned with the title, so on
            // a two-line row they parked up near the top: a download arrow, a
            // chevron and a size all floating above the row's centre while the
            // glyph opposite them was centred. The checkmark moved out first and
            // the rest had to follow, or one slot would have had two alignments.
            //
            // Safe for `trailingGlyph` in particular because it and `progress` are
            // mutually exclusive at every call site (the arrow is set only when
            // `fraction == nil`), so nothing that needs the title line ends up
            // here.
            if progress == nil, let trailingText {
                Text(trailingText)
                    .font(.system(size: 13, design: trailingMonospaced ? .monospaced : .default))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let trailingGlyph {
                Image(systemName: trailingGlyph)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
            }
            // Cancel takes the TICK'S slot, which is free by construction: a
            // row with bytes arriving is never the selected one (`isSelected`
            // is `arriving == nil && selected` at the call site). So the two
            // never compete, and cancel lands in the position the eye already
            // reads as "this row's control".
            if progress != nil, let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                // Tap target grown with contentShape, not padding, so the
                // accessory column's width is still the glyph's.
                .contentShape(Rectangle().inset(by: -8))
                .accessibilityLabel("cancel download")
            }
            if isSelected {
                // Accent, not primary. The design uses the accent for the one
                // row that answers your next message — the same colour every
                // actionable thing in the sheet uses, so "this is the live one"
                // reads as a state and not as a heavier tick.
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}
