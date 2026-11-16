//
//  ComposerTextView.swift
//  teemoon
//
//  The composer's field as a UIKit text view (docs/IMAGES.md §4d, S44b), so the keyboard bar's copied photo, Paste
//  and ⌘V all reach `paste(_:)`. ComposerFieldTests pins everything the SwiftUI TextField it replaced did.
//

#if os(iOS)

import SwiftUI
import UIKit

/// The app's requests for the composer's keyboard, as a count: each new one raises it (if nothing covers it).
@MainActor @Observable
final class ComposerFocus {
    private(set) var requests = 0
    func request() { requests += 1 }
}

struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    /// The app's focus requests (ComposerFocus, or its FocusState turning true). The field is outside SwiftUI's
    /// focus system: a SwiftUI focus target took first responder from the text view.
    let focusRequest: Bool
    let focusRequests: Int
    /// Bumped to drop the keyboard (a send).
    let resignToken: Int
    /// Whether the text view really has the keyboard, for the composer's paste rules.
    let onFocusChange: (Bool) -> Void
    /// Bumped to put the caret at the start (a returned question).
    let caretToStart: Int
    /// An image-only paste: the pasteboard, read by PastedImage.load(from:). Text pastes go in as plain text.
    let onPasteImages: (UIPasteboard) -> Void
    /// Grows to this many lines, then scrolls inside (docs/COMPOSER_PANEL.md).
    var maxLines = 6

    /// Ends editing wherever the keyboard is, for the app's "composer, let go" moments that FocusState can't carry.
    static func dropKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.onPasteImages = onPasteImages
        field.backgroundColor = .clear
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        // The panel's 17 above the text scrolls with it, so scrolled lines slide under the panel's edge instead of
        // being cut at a padding line (both apps, docs/COMPOSER_PANEL.md); the 17 below stays outside the scroll.
        field.textContainerInset = UIEdgeInsets(top: 17, left: 0, bottom: 0, right: 0)
        field.textContainer.lineFragmentPadding = 0
        field.isScrollEnabled = false
        // Scrolled lines must stay inside the field, not draw up under the photos strip.
        field.clipsToBounds = true
        // Rich-capable, or the keyboard bar's photo never calls paste: (device probe 2026-11-07). The text stays plain.
        field.allowsEditingTextAttributes = true
        field.supportsAdaptiveImageGlyph = true
        field.accessibilityIdentifier = "chat.composer"
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.text = text
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.onPasteImages = onPasteImages
        field.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        // Never while composing (CJK marked text): replacing the text would end the composition.
        if field.markedTextRange == nil, field.text != text {
            field.text = text
            field.refreshPlaceholder()
            field.invalidateIntrinsicContentSize()
        }
        if context.coordinator.caretToStart != caretToStart {
            context.coordinator.caretToStart = caretToStart
            field.selectedRange = NSRange(location: 0, length: 0)
            field.scrollRangeToVisible(field.selectedRange)
        }
        // Only when a request ARRIVES: re-asserting it on every update took the keyboard from a sheet's field.
        if focusRequest, !context.coordinator.lastRequest, !field.isFirstResponder {
            DispatchQueue.main.async { if field.isUncovered { field.becomeFirstResponder() } }
        }
        context.coordinator.lastRequest = focusRequest
        if context.coordinator.focusRequests != focusRequests {
            context.coordinator.focusRequests = focusRequests
            if !field.isFirstResponder {
                DispatchQueue.main.async { if field.isUncovered { field.becomeFirstResponder() } }
            }
        }
        if context.coordinator.resignToken != resignToken {
            context.coordinator.resignToken = resignToken
            if field.isFirstResponder { DispatchQueue.main.async { field.resignFirstResponder() } }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: Field, context: Context) -> CGSize? {
        let width = proposal.width ?? field.bounds.width
        guard width > 0, width.isFinite else { return nil }
        let fitted = field.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = field.font?.lineHeight ?? 22
        let cap = ceil(lineHeight * CGFloat(maxLines) + field.textContainerInset.top + field.textContainerInset.bottom)
        let scrolls = fitted.height > cap
        // Switched now, not on the next turn: a pass at the cap without scrolling drew the caret line over the photos.
        if field.isScrollEnabled != scrolls { field.isScrollEnabled = scrolls }
        return CGSize(width: width, height: min(ceil(fitted.height), cap))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var caretToStart: Int
        var lastRequest = false
        var focusRequests = 0
        var resignToken: Int

        init(_ parent: ComposerTextView) {
            self.parent = parent
            caretToStart = parent.caretToStart
            resignToken = parent.resignToken
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let field = textView as? Field else { return }
            field.keepPlain()
            field.refreshPlaceholder()
            field.invalidateIntrinsicContentSize()
            if parent.text != field.text { parent.text = field.text }
        }

        func textViewDidBeginEditing(_ textView: UITextView) { parent.onFocusChange(true) }

        /// Never pushed to the app's FocusState: "unfocused" there made SwiftUI resign a sheet's field too.
        func textViewDidEndEditing(_ textView: UITextView) { parent.onFocusChange(false) }
    }

    final class Field: UITextView {
        var onPasteImages: ((UIPasteboard) -> Void)?
        private let placeholder = UILabel()

        init() {
            super.init(frame: .zero, textContainer: nil)
            placeholder.text = "message"
            placeholder.font = .preferredFont(forTextStyle: .body)
            placeholder.adjustsFontForContentSizeCategory = true
            placeholder.textColor = .placeholderText
            placeholder.isAccessibilityElement = false
            addSubview(placeholder)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            // On the first line, below the scrolling top inset.
            placeholder.frame = CGRect(x: 0, y: textContainerInset.top, width: bounds.width,
                                       height: placeholder.intrinsicContentSize.height)
        }

        override var accessibilityValue: String? {
            get { text.isEmpty ? nil : text }
            set {}
        }

        override var accessibilityLabel: String? {
            get { "message" }
            set {}
        }

        func refreshPlaceholder() { placeholder.isHidden = !text.isEmpty }

        /// In a window with no sheet presented over it: a sheet's own field keeps the keyboard, as SwiftUI's did.
        var isUncovered: Bool {
            guard let root = window?.rootViewController else { return false }
            var top = root
            while let next = top.presentedViewController { top = next }
            return top === root || isDescendant(of: top.view)
        }

        /// Plain text only: a Genmoji becomes its description, an attachment goes (ComposerText). Edits only those
        /// ranges, through replace(_:withText:), so undo keeps working; never reassign the whole text here.
        func keepPlain() {
            guard markedTextRange == nil, let stored = attributedText, stored.string.contains("\u{FFFC}") else { return }
            var objects: [NSRange] = []
            (stored.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: stored.length),
                                                           options: .byComposedCharacterSequences) { sub, range, _, _ in
                if sub == "\u{FFFC}" { objects.append(range) }
            }
            for range in objects.reversed() {
                let replacement = ComposerText.plain(stored.attributedSubstring(from: range))
                guard let start = position(from: beginningOfDocument, offset: range.location),
                      let end = position(from: start, offset: range.length),
                      let textRange = textRange(from: start, to: end) else { continue }
                replace(textRange, withText: replacement)
            }
            typingAttributes = [.font: UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection),
                                .foregroundColor: UIColor.label]
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)) {
                let board = UIPasteboard.general
                return board.hasStrings || board.hasURLs || board.hasImages
                    || board.types.contains { PastedImage.choice(offered: [$0]) != .notAnImage }
            }
            // No Bold / Italic / Underline: the text is plain.
            if action == #selector(toggleBoldface(_:)) || action == #selector(toggleItalics(_:))
                || action == #selector(toggleUnderline(_:)) {
                return false
            }
            return super.canPerformAction(action, withSender: sender)
        }


        /// A rich-capable view may be handed item providers instead of paste(_:): the same rules.
        override func paste(itemProviders: [NSItemProvider]) {
            paste(nil)
        }

        /// An image-only paste attaches; anything with text goes in as plain text, and the composer's text rules
        /// (§4c: an image item's URL, a data: URL) run on the change as before.
        override func paste(_ sender: Any?) {
            let board = UIPasteboard.general
            let hasText = board.hasStrings || board.hasURLs
            if !hasText, (board.types(forItemSet: nil) ?? []).contains(where: { PastedImage.choice(offered: $0) != .notAnImage }) {
                onPasteImages?(board)
                return
            }
            let pasted = board.strings?.joined(separator: "\n") ?? board.urls?.map(\.absoluteString).joined(separator: "\n") ?? ""
            guard !pasted.isEmpty else { return }
            insertText(pasted)
        }
    }
}

#endif
