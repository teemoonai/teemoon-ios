//
//  MarkdownStreamSplitter.swift
//  teemoon
//
//  Splits a partially-streamed markdown document into blocks that are FINISHED
//  and a tail that is still being written.
//
//  The point is SwiftUI identity. `StructuredText` re-parses whenever its
//  `markup` string changes, and hands every block a fresh `AttributedSubstring`
//  off a brand-new `AttributedString` — so one growing document means the whole
//  message re-parses and re-lays-out on every pacer tick. Feed the settled
//  blocks in as separate, unchanging strings and SwiftUI can skip them
//  entirely; only the tail pays per frame.
//
//  The critical property is that the settled list is APPEND-ONLY: a block, once
//  settled, must never change, or its view identity breaks and the saving is
//  lost. That is why a block is only settled once the NEXT block has visibly
//  started — see `isHardBlockStart`.
//

import Foundation

enum MarkdownStreamSplitter {
    struct Split: Equatable {
        /// Blocks that can no longer change. Stable across ticks, append-only.
        var settled: [String]
        /// The block still being written.
        var tail: String
    }

    /// Lines that can only mean "a new top-level block starts here".
    ///
    /// A blank line is NOT enough on its own. `1. a\n\n2. b` is one loose list,
    /// and splitting it in two would restart the numbering at 1 — so a
    /// continuation marker keeps the current block open until something
    /// unambiguous arrives.
    private static func isHardBlockStart(_ line: Substring) -> Bool {
        let trimmed = line.drop { $0 == " " }
        // A 4-space indent is a code continuation, not a new block.
        if line.prefix(4) == "    " { return false }
        if trimmed.isEmpty { return false }

        switch trimmed.first {
        // A blank line ends a block quote and ends a table, so anything after
        // one genuinely starts a new block. Only lists survive a blank line,
        // which is why they are the conservative case below.
        case ">":  return true
        case "|":  return true
        case "-", "*", "+":
            // "- x" is a list item; "---" is a thematic break, which is a real
            // block start.
            let rest = trimmed.dropFirst()
            if rest.first == " " { return false }
            return true
        case "#":  return true              // heading
        case "`", "~": return true          // fence
        default:
            // "1. x" / "1) x" continue an ordered list.
            if trimmed.first?.isNumber == true {
                let afterDigits = trimmed.drop(while: \.isNumber)
                if afterDigits.first == "." || afterDigits.first == ")" {
                    return afterDigits.dropFirst().first == " " ? false : true
                }
            }
            return true                     // ordinary paragraph
        }
    }

    /// The space Textual would put above and below a block, as a multiple of the
    /// font size.
    ///
    /// Mirrors the `blockSpacing` values in Textual's default styles
    /// (`DefaultParagraphStyle` and friends). Rendering the settled blocks as
    /// separate `StructuredText` views puts them outside Textual's own
    /// `BlockVStack`, so its CSS-style margin collapsing has to be reproduced
    /// here or the seams show as uneven gaps.
    static func spacingEm(_ block: String) -> (top: CGFloat, bottom: CGFloat) {
        let line = block.drop { $0 == " " || $0 == "\n" }
        switch line.first {
        case "#":  return (1.6, 0.8)    // DefaultHeadingStyle
        case "`", "~": return (0.88, 0) // DefaultCodeBlockStyle
        case "|":  return (1.6, 1.6)    // DefaultTableStyle
        case "-", "*", "_":
            // A thematic break, but only if it isn't a list item.
            let rest = line.dropFirst()
            if rest.first == " " { return (0.8, 0) }
            return (1.6, 1.6)           // DividerThematicBreakStyle
        default:   return (0.8, 0)      // DefaultParagraphStyle
        }
    }

    /// The collapsed gap between two adjacent blocks, as a multiple of the font
    /// size. Textual takes the larger of the two margins rather than summing.
    static func collapsedSpacingEm(after previous: String, before next: String) -> CGFloat {
        max(spacingEm(previous).bottom, spacingEm(next).top)
    }

    /// Splits `markdown` at blank lines that are outside a fenced code block and
    /// are followed by an unambiguous new block.
    static func split(_ markdown: String) -> Split {
        guard !markdown.isEmpty else { return Split(settled: [], tail: "") }

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        var settled: [String] = []
        var current: [Substring] = []
        var inFence = false
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let fenceMarker = line.drop { $0 == " " }.prefix(3)
            if fenceMarker == "```" || fenceMarker == "~~~" {
                inFence.toggle()
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty, !inFence, !current.isEmpty {
                // Find the next non-blank line. Without one, more text may still
                // be coming that changes what this block is — so don't settle.
                var lookahead = index + 1
                while lookahead < lines.count,
                      lines[lookahead].trimmingCharacters(in: .whitespaces).isEmpty {
                    lookahead += 1
                }
                // The final line is still being typed, and one more character can
                // change what it is — "-" reads as a thematic break until the
                // space arrives and makes it a list item. Only a line with a
                // newline after it (index < count - 1) is safe to judge.
                if lookahead < lines.count - 1, isHardBlockStart(lines[lookahead]) {
                    settled.append(current.joined(separator: "\n"))
                    current.removeAll()
                    index = lookahead
                    continue
                }
            }

            current.append(line)
            index += 1
        }

        return Split(settled: settled, tail: current.joined(separator: "\n"))
    }

    /// Rewrites a still-growing tail so incomplete markup does not paint as
    /// raw characters and then shrink when it closes.
    ///
    /// CommonMark will not parse `[docs](https://example.com/x` as a link
    /// until the closing `)` arrives, so the tail first lays out the whole
    /// syntax (often wrapping extra lines) and then collapses to the label.
    /// A GFM table without a separator row is the same shape: a paragraph of
    /// pipes, then a compact grid. Both are vertical resizes under a reader
    /// who is following the stream.
    ///
    /// Settled blocks must be passed through unchanged — they are already
    /// complete, and rewriting them would break view identity.
    static func displayTail(_ tail: String) -> String {
        guard !tail.isEmpty else { return tail }
        // Fenced code can contain `|`, `[`, and backticks that are not
        // markup. An unclosed fence means the whole tail is still code.
        if isInsideUnclosedFence(tail) { return tail }
        var result = stabilizeIncompleteTable(tail)
        result = stabilizeIncompleteLink(result)
        return result
    }

    private static func isInsideUnclosedFence(_ markdown: String) -> Bool {
        var inFence = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let marker = line.drop { $0 == " " }.prefix(3)
            if marker == "```" || marker == "~~~" { inFence.toggle() }
        }
        return inFence
    }

    /// A GFM table is not a table until the delimiter row exists. Until then
    /// the header paints as a wrapping paragraph. Inject a delimiter after
    /// the first complete header line so the first paint is already a grid;
    /// when the real delimiter arrives it replaces this one and the height
    /// stays put. An incomplete last line (still being typed) is held back
    /// so it never flashes as prose.
    private static func stabilizeIncompleteTable(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var end = lines.endIndex
        while end > lines.startIndex,
              lines[lines.index(before: end)].trimmingCharacters(in: .whitespaces).isEmpty {
            end = lines.index(before: end)
        }
        var start = end
        while start > lines.startIndex {
            let prev = lines.index(before: start)
            if !isTableLine(lines[prev]) { break }
            start = prev
        }
        let table = Array(lines[start..<end])
        guard !table.isEmpty else { return markdown }
        if table.contains(where: isSeparatorRow) { return markdown }

        var working = table
        // Hold a header that is still being typed on the last line.
        if end == lines.endIndex, let last = working.last, !isCompleteTableRow(last) {
            working.removeLast()
        }
        guard let headerIndex = working.firstIndex(where: isCompleteTableRow) else {
            return (lines[..<start] + working + lines[end...]).joined(separator: "\n")
        }
        let columns = tableColumnCount(working[headerIndex])
        working.insert(separatorRow(columns: columns), at: working.index(after: headerIndex))
        return (lines[..<start] + working + lines[end...]).joined(separator: "\n")
    }

    private static func isTableLine(_ line: String) -> Bool {
        line.drop { $0 == " " }.first == "|"
    }

    private static func isCompleteTableRow(_ line: String) -> Bool {
        isTableLine(line) && line.filter { $0 == "|" }.count >= 2
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        guard isTableLine(line) else { return false }
        let body = line.filter { $0 != "|" && $0 != " " && $0 != ":" }
        return !body.isEmpty && body.allSatisfy { $0 == "-" }
    }

    private static func tableColumnCount(_ header: String) -> Int {
        var parts = header.split(separator: "|", omittingEmptySubsequences: false)
        if parts.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            parts.removeFirst()
        }
        if parts.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            parts.removeLast()
        }
        return max(parts.count, 1)
    }

    private static func separatorRow(columns: Int) -> String {
        "|" + Array(repeating: " --- ", count: columns).joined(separator: "|") + "|"
    }

    /// Incomplete `[label](url` paints the syntax, then collapses to `label`.
    /// Show the label as soon as we have it; hide a half-typed image.
    private static func stabilizeIncompleteLink(_ markdown: String) -> String {
        guard let opener = lastLinkOpener(in: markdown) else { return markdown }
        var from = opener
        var isImage = false
        if from > markdown.startIndex {
            let prev = markdown.index(before: from)
            if markdown[prev] == "!" {
                from = prev
                isImage = true
            }
        }
        let afterOpen = markdown[markdown.index(after: opener)...]
        guard let closeLabel = afterOpen.firstIndex(of: "]") else {
            // `[partial` — show the partial label; `![partial` — hide.
            if isImage { return String(markdown[..<from]) }
            return String(markdown[..<from]) + afterOpen
        }
        let label = afterOpen[..<closeLabel]
        let afterLabel = afterOpen[afterOpen.index(after: closeLabel)...]
        guard afterLabel.first == "(" else { return markdown }
        if linkDestinationClosed(afterLabel) { return markdown }
        if isImage { return String(markdown[..<from]) }
        return String(markdown[..<from]) + label
    }

    /// Last `[` that is not escaped and not inside a code span. `nil` if
    /// the scan ends inside an unclosed code span — those backticks are
    /// still being typed, so nothing here is a link.
    private static func lastLinkOpener(in s: String) -> String.Index? {
        var last: String.Index?
        var i = s.startIndex
        var codeRun = 0
        while i < s.endIndex {
            if s[i] == "\\" && codeRun == 0 {
                s.formIndex(after: &i)
                if i < s.endIndex { s.formIndex(after: &i) }
                continue
            }
            if s[i] == "`" {
                var n = 0
                while i < s.endIndex && s[i] == "`" {
                    n += 1
                    s.formIndex(after: &i)
                }
                if codeRun == 0 {
                    codeRun = n
                } else if codeRun == n {
                    codeRun = 0
                }
                continue
            }
            if codeRun == 0, s[i] == "[" {
                last = i
            }
            s.formIndex(after: &i)
        }
        if codeRun != 0 { return nil }
        return last
    }

    private static func linkDestinationClosed(_ afterOpenParen: Substring) -> Bool {
        var depth = 0
        var inAngles = false
        for ch in afterOpenParen {
            if inAngles {
                if ch == ">" { inAngles = false }
                continue
            }
            switch ch {
            case "<": inAngles = true
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return true }
            case "\n": return false
            default: break
            }
        }
        return false
    }
}
