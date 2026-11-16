//
//  ComposerFieldTests.swift
//  teemoonTests
//
//  The composer's field as the person typing meets it, pinned on the SwiftUI TextField (2026-11-07) before it became
//  a UITextView for image paste: these values are what that field had, and the replacement must keep them.
//  Focus, growth, the edit menu and Return are pinned through the simulator in ComposerBehaviourUITests.
//

#if os(iOS)

import SwiftUI
import Testing
import UIKit
@testable import teemoon

@MainActor
@Suite("Composer field", .serialized)
struct ComposerFieldTests {

    private func withField(_ size: DynamicTypeSize = .large,
                           _ body: (ComposerHost, UITextView) throws -> Void) throws {
        let host = ComposerHost(dynamicTypeSize: size)
        defer { host.tearDown() }
        let field = try #require(host.field, "no text view draws the composer")
        try body(host, field)
    }

    @Test func itsKeyboardIsTheDefaultOneWithSentenceCapsAutocorrectAndSmartPunctuation() throws {
        try withField { _, field in
            #expect(field.keyboardType == .default)
            #expect(field.returnKeyType == .default)
            #expect(field.autocapitalizationType == .sentences)
            #expect(field.autocorrectionType == .default)
            #expect(field.spellCheckingType == .default)
            #expect(field.smartQuotesType == .default)
            #expect(field.smartDashesType == .default)
            #expect(field.smartInsertDeleteType == .default)
            #expect(field.inlinePredictionType == .default)
            #expect(field.textContentType == nil)
            #expect(field.keyboardAppearance == .default)
            #expect(field.writingToolsBehavior == .default)
        }
    }

    /// Colour spaces differ between equal colours; the components don't.
    static func rgba(_ color: UIColor?) -> [Double]? {
        guard let color else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return [r, g, b, a].map { ($0 * 255).rounded() }
    }

    @Test func itsTextIsBodyInTheLabelColourAndScalesWithDynamicType() throws {
        try withField { _, field in
            #expect(field.font?.pointSize == 17)
            #expect(field.font?.fontDescriptor.object(forKey: .textStyle) as? UIFont.TextStyle == .body)
            let traits = field.traitCollection
            // The app is dark-only (UIUserInterfaceStyle), so the label colour it shows is the dark one: white.
            let dark = UITraitCollection(userInterfaceStyle: .dark)
            #expect(Self.rgba(field.textColor?.resolvedColor(with: traits)) == Self.rgba(UIColor.label.resolvedColor(with: dark)))
            // docs/COMPOSER_PANEL.md: the 17 above the text is the field's own inset, so it scrolls with the text; the
            // 16 sides and the 17 down to the row are the panel's padding.
            #expect(field.textContainerInset == UIEdgeInsets(top: 17, left: 0, bottom: 0, right: 0))
            #expect(field.textContainer.lineFragmentPadding == 0)
        }
        try withField(.accessibility5) { _, field in
            #expect(field.font?.pointSize == 53)
            #expect(field.frame.height > 60, "one line at AX5 is \(field.frame.height) tall")
        }
    }

    /// The keyboard bar's copied photo calls paste: only on a rich-capable view (device probe, iOS 27.2, 2026-11-07).
    @Test func theFieldTakesImageGlyphsSoTheKeyboardBarCanPaste() throws {
        try withField { _, field in
            #expect(field.supportsAdaptiveImageGlyph)
            #expect(field.allowsEditingTextAttributes)
        }
    }

    /// An app's UIImage alone (com.apple.uikit.image, no PNG/JPEG copy, no text) attaches: the gap SwiftUI's paste
    /// destination left (§4c). Async: the decode lands on the main queue, which a blocking settle never drains.
    @Test func anAppsUIImageAlonePastesAsAnImage() async throws {
        let host = ComposerHost()
        defer { host.tearDown() }
        let field = try #require(host.field, "no text view draws the composer")
        let png = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).pngData { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        UIPasteboard.general.setItems([["com.apple.uikit.image": UIImage(data: png)!]])
        field.becomeFirstResponder()
        field.paste(nil)
        for _ in 0..<40 where host.viewModel.pendingImages.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(host.viewModel.pendingImages.count == 1, "note \(String(describing: host.viewModel.imageNote))")
        #expect(host.viewModel.prompt == "")
    }

    /// Rich text from Notes or Safari lands as plain text, as in today's field.
    @Test func richTextPastesAsPlainText() throws {
        try withField { host, field in
            let bold = NSAttributedString(string: "bold words", attributes: [.font: UIFont.boldSystemFont(ofSize: 30)])
            let rtf = try bold.data(from: NSRange(location: 0, length: bold.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            UIPasteboard.general.setItems([["public.rtf": rtf, "public.utf8-plain-text": "bold words"]])
            field.becomeFirstResponder()
            field.paste(nil)
            host.settle()
            #expect(host.viewModel.prompt == "bold words")
            var bolded = false
            field.attributedText.enumerateAttribute(.font, in: NSRange(location: 0, length: field.attributedText.length)) { v, _, _ in
                if (v as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true { bolded = true }
            }
            #expect(!bolded, "the pasted text kept its bold")
        }
    }

    /// A Genmoji typed from the keyboard: no glyph and no U+FFFC in the draft.
    @Test func aTypedGlyphNeverReachesTheDraft() throws {
        try withField { host, field in
            field.becomeFirstResponder()
            field.insertText("hi ")
            // What UIKit leaves for a glyph it can't read: a bare object character.
            field.insertText("\u{FFFC}")
            host.settle()
            #expect(!host.viewModel.prompt.contains("\u{FFFC}"))
            #expect(!field.text.contains("\u{FFFC}"))
        }
    }

    @Test func typingReachesTheDraftAndTheDraftReachesTheField() throws {
        try withField { host, field in
            field.becomeFirstResponder()
            field.insertText("abc")
            host.settle()
            #expect(host.viewModel.prompt == "abc")
            host.viewModel.prompt = "from the model"
            host.settle()
            #expect(field.text == "from the model")
            host.viewModel.prompt = ""
            host.settle()
            #expect(field.text == "")
        }
    }

    @Test func returnTypesANewline() throws {
        try withField { host, field in
            field.becomeFirstResponder()
            field.insertText("one")
            field.insertText("\n")
            field.insertText("two")
            host.settle()
            #expect(host.viewModel.prompt == "one\ntwo")
        }
    }

    /// CJK input: the composing text is in the draft while it is marked, and a draft update does not end the composition.
    @Test func markedTextIsInTheDraftAndSurvivesTheDraftUpdate() throws {
        try withField { host, field in
            field.becomeFirstResponder()
            field.insertText("xyz")
            field.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
            host.settle()
            #expect(host.viewModel.prompt == "xyzに")
            #expect(field.markedTextRange != nil, "the draft update ended the composition")
            field.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0))
            host.settle()
            #expect(host.viewModel.prompt == "xyzにほ")
            field.unmarkText()
            host.settle()
            #expect(field.markedTextRange == nil)
            #expect(host.viewModel.prompt == "xyzにほ")
        }
    }

    /// Each edit its own undo group, explicitly: UIKit's event grouping depends on run-loop passes a test host
    /// doesn't make the same way twice.
    @Test func undoAndRedoMoveTheDraftWithTheField() throws {
        try withField { host, field in
            field.becomeFirstResponder()
            let undo = try #require(field.undoManager)
            undo.groupsByEvent = false
            defer { undo.groupsByEvent = true }
            undo.beginUndoGrouping(); field.insertText("first"); undo.endUndoGrouping()
            host.settle()
            undo.beginUndoGrouping(); field.insertText(" second"); undo.endUndoGrouping()
            host.settle()
            #expect(undo.canUndo)
            undo.undo()
            host.settle()
            #expect(field.text == "first")
            #expect(host.viewModel.prompt == "first")
            undo.redo()
            host.settle()
            #expect(field.text == "first second")
            #expect(host.viewModel.prompt == "first second")
        }
    }

    @Test func selectAllThenCutEmptiesTheDraftOntoThePasteboard() throws {
        try withField { host, field in
            field.becomeFirstResponder()
            field.insertText("cut me")
            host.settle()
            field.selectAll(nil)
            #expect(field.canPerformAction(#selector(UIResponderStandardEditActions.cut(_:)), withSender: nil))
            #expect(field.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
            field.cut(nil)
            host.settle()
            #expect(host.viewModel.prompt == "")
            #expect(UIPasteboard.general.string == "cut me")
        }
    }
}

#endif
