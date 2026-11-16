//
//  ComposerText.swift
//  teemoon
//
//  What the composer's text view may hold: plain text. A Genmoji, memoji or sticker becomes its own description where
//  it was typed, an inline attachment goes, attributes go (docs/IMAGES.md §4d, the maintainer 2026-11-11 "A").
//

#if os(iOS)

import Foundation
import UIKit

enum ComposerText {
    /// The glyph attribute's value to its description; nil when the value is not a glyph.
    static func glyphDescription(_ value: Any) -> String? {
        (value as? NSAdaptiveImageGlyph)?.contentDescription
    }

    static func plain(_ text: NSAttributedString, describe: (Any) -> String? = glyphDescription) -> String {
        var out = ""
        let whole = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let run = whole.substring(with: range)
            if let value = attrs[.adaptiveImageGlyph], let description = describe(value) {
                // One object character per glyph; equal glyphs side by side share a run.
                for _ in run.utf16 { out += description }
            } else {
                // An attachment's character, or one left with nothing behind it: not text.
                out += run.replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }
        return out
    }
}

#endif
