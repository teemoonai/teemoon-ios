//
//  ChatSearchHighlight.swift
//  teemoon
//
//  Turns `snippet()`'s delimited output into an `AttributedString` with the
//  matched terms emphasised.
//
//  The delimiters are U+0001/U+0002 and they are safe by construction, not by
//  luck: `ChatSearchIndex.sanitizeForStorage` removes them from message text on
//  the way in, so any delimiter in a snippet was put there by sqlite. Parse
//  defensively anyway — an unpaired opener must render as text, not swallow the
//  rest of the line.
//

import Foundation
import SwiftUI

enum ChatSearchHighlight {

    /// Splits a snippet into plain and matched runs, in order.
    ///
    /// Kept separate from the `AttributedString` build so the segmentation can
    /// be tested without asserting on attribute containers.
    static func segments(_ snippet: String) -> [(text: String, isMatch: Bool)] {
        var segments: [(String, Bool)] = []
        var current = ""
        var inMatch = false

        for character in snippet {
            switch String(character) {
            case ChatSearchIndex.highlightOpen:
                if inMatch { continue }          // stray opener inside a match
                if !current.isEmpty { segments.append((current, false)); current = "" }
                inMatch = true
            case ChatSearchIndex.highlightClose:
                if !inMatch { continue }         // unpaired closer is not a run
                if !current.isEmpty { segments.append((current, true)); current = "" }
                inMatch = false
            default:
                current.append(character)
            }
        }
        // An unterminated match still has to render; dropping it would silently
        // truncate the snippet.
        if !current.isEmpty { segments.append((current, inMatch)) }
        return segments.map { (text: $0.0, isMatch: $0.1) }
    }

    /// The snippet with its delimiters removed and nothing else changed.
    static func plainText(_ snippet: String) -> String {
        segments(snippet).map(\.text).joined()
    }

    /// Re-centres a snippet so the first highlighted run is near the start.
    ///
    /// THE TOKEN BUDGET AND THE LINE BUDGET NEVER AGREED. `snippet()` is given a
    /// budget in TOKENS (18) and picks its window around the document; the row
    /// renders with a budget in LINES (2). When the match lands late in SQLite's
    /// window it is truncated off the end of the second line, so the string is
    /// correct, the delimiters are present, and the row still shows unhighlighted
    /// text that looks like a false positive. Reproduced in the 4th row of
    /// `#Preview("search results")`; keep that case.
    ///
    /// No string-level assertion catches this — `contains(highlightOpen)` passes
    /// on the broken output. The test for it is a rendered screenshot.
    static func centred(_ snippet: String, lead: Int = 24) -> String {
        guard let openRange = snippet.range(of: highlightOpenString) else { return snippet }
        let prefixLength = snippet.distance(from: snippet.startIndex, to: openRange.lowerBound)
        guard prefixLength > lead else { return snippet }

        // Cut on a word boundary so the excerpt does not begin mid-word.
        let hardStart = snippet.index(openRange.lowerBound, offsetBy: -lead)
        let searchSpace = snippet[hardStart..<openRange.lowerBound]
        let start = searchSpace.firstIndex(where: { $0 == " " }).map { snippet.index(after: $0) } ?? hardStart
        let ellipsis = snippet.hasPrefix("…") || snippet[start...].hasPrefix("…") ? "" : "…"
        return ellipsis + String(snippet[start...])
    }

    private static var highlightOpenString: String { ChatSearchIndex.highlightOpen }

    /// A snippet built in Swift for the degraded path, when the index could not
    /// answer and the in-memory filter produced the row instead.
    ///
    /// Exists so that EVERY result row shows why it matched. Without it a
    /// fallback row falls through to the assistant preview, which looks
    /// identical to a result whose keyword appears nowhere in it — the exact
    /// symptom that makes search feel broken rather than slow.
    static func excerpt(matching query: String, in contents: [String], window: Int = 60) -> String? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        for content in contents {
            guard let found = content.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
            else { continue }
            let start = content.index(found.lowerBound,
                                      offsetBy: -window,
                                      limitedBy: content.startIndex) ?? content.startIndex
            let end = content.index(found.upperBound,
                                    offsetBy: window,
                                    limitedBy: content.endIndex) ?? content.endIndex
            let lead = start == content.startIndex ? "" : "…"
            let trail = end == content.endIndex ? "" : "…"
            let before = content[start..<found.lowerBound]
            let match = content[found]
            let after = content[found.upperBound..<end]
            return "\(lead)\(before)\(ChatSearchIndex.highlightOpen)\(match)\(ChatSearchIndex.highlightClose)\(after)\(trail)"
        }
        return nil
    }

    /// Matched runs in semibold, everything else inherited.
    static func attributed(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        for segment in segments(snippet) {
            var run = AttributedString(segment.text)
            if segment.isMatch { run.inlinePresentationIntent = .stronglyEmphasized }
            result.append(run)
        }
        return result
    }
}
