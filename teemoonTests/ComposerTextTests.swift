//
//  ComposerTextTests.swift
//  teemoonTests
//
//  docs/IMAGES.md §4d (the maintainer 2026-11-11, "A"): the composer holds plain text. A Genmoji, memoji or sticker from the
//  keyboard becomes its description where it was typed; an attachment never reaches the draft. A real Genmoji can't be
//  made in a test, so a stand-in object sits under the glyph attribute and `describe` reads it.
//

#if os(iOS)

import Foundation
import Testing
import UIKit
@testable import teemoon

@MainActor
@Suite("Composer text")
struct ComposerTextTests {

    /// A stand-in under the glyph attribute: a glyph built from plain image bytes is invalid, and Swift receives a
    /// null object for it that crashes the first cast (seen 2026-11-11).
    static let standIn = "GLYPH" as NSString

    static func glyphRun() -> NSAttributedString {
        NSAttributedString(string: "\u{FFFC}", attributes: [.adaptiveImageGlyph: standIn])
    }

    static func describe(_ said: String) -> (Any) -> String? {
        { ($0 as? NSString) == standIn ? said : nil }
    }

    @Test func aGlyphBecomesItsDescriptionWhereItWasTyped() {
        let text = NSMutableAttributedString(string: "hi  there")
        text.insert(Self.glyphRun(), at: 3)
        #expect(ComposerText.plain(text, describe: Self.describe("a cat in a hat")) == "hi a cat in a hat there")
    }

    @Test func aGlyphWithNoDescriptionLeavesNothing() {
        let text = NSMutableAttributedString(string: "hi")
        text.append(Self.glyphRun())
        #expect(ComposerText.plain(text, describe: Self.describe("")) == "hi")
    }

    @Test func anAttachmentNeverReachesTheDraft() {
        let text = NSMutableAttributedString(string: "look ")
        text.append(NSAttributedString(attachment: NSTextAttachment(image: UIImage(systemName: "star")!)))
        text.append(NSAttributedString(string: " here"))
        #expect(ComposerText.plain(text) == "look  here")
    }

    @Test func plainTextIsUnchanged() {
        let text = NSAttributedString(string: "plain text stays", attributes: [.font: UIFont.boldSystemFont(ofSize: 17)])
        #expect(ComposerText.plain(text) == "plain text stays")
    }

    /// An object character with nothing behind it (what UIKit inserts for a glyph it can't read) is not text.
    @Test func aBareObjectCharacterGoes() {
        #expect(ComposerText.plain(NSAttributedString(string: "a\u{FFFC}b")) == "ab")
    }
}

#endif

#if os(iOS)
@MainActor
@Suite("Composer paste reader", .serialized)
struct ComposerPasteReaderTests {
    /// An app's UIImage alone: the pasteboard's own bytes for com.apple.uikit.image decode to one image.
    @Test func anAppsUIImageAloneReadsAsOneImage() async {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).pngData { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        UIPasteboard.general.setItems([["com.apple.uikit.image": UIImage(data: png)!]])
        let results = await withCheckedContinuation { done in
            PastedImage.load(from: .general) { done.resume(returning: $0) }
        }
        #expect(results.count == 1)
        #expect((try? results.first?.get()) != nil, "\(results)")
    }
}
#endif
