//
//  ReplyActionsMenu.swift
//  teemoon
//

import SwiftUI

/// A reply's long-press actions: "think harder" (newest reply only) and "copy".
struct ReplyAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// Read when the menu opens, so an item follows what the app learned since the reply was drawn.
    var isAvailable: () -> Bool = { true }
    let perform: () -> Void
}

#if os(iOS)
import UIKit

/// The actions in a small menu anchored where the finger is. Nothing lifts, dims or
/// moves (the maintainer, reply-menu-short-preview): `.contextMenu` lifts its source and dims
/// the screen, which on a long reply is a big animation just to reach two items.
struct ReplyActionsMenu: ViewModifier {
    let actions: [ReplyAction]

    func body(content: Content) -> some View {
        content
            .background(ReplyMenuAnchor(actions: actions))
            .accessibilityActions {
                ForEach(actions.filter { $0.isAvailable() }) { action in
                    Button(action.title, action: action.perform)
                }
            }
    }
}

private struct ReplyMenuAnchor: UIViewRepresentable {
    let actions: [ReplyAction]

    func makeUIView(context: Context) -> AnchorView { AnchorView() }

    func updateUIView(_ view: AnchorView, context: Context) { view.actions = actions }

    static func dismantleUIView(_ view: AnchorView, coordinator: ()) { view.detach() }

    /// Sits behind the reply. The press is heard on the transcript cell above it, because
    /// SwiftUI content is drawn into the hosting view and never reaches a background UIView.
    final class AnchorView: UIView, UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
        var actions: [ReplyAction] = []
        private lazy var menu = UIEditMenuInteraction(delegate: self)
        private lazy var press: UILongPressGestureRecognizer = {
            let r = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            r.cancelsTouchesInView = false
            r.delegate = self
            return r
        }()
        private weak var host: UIView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            addInteraction(menu)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, host == nil else { return }
            var cell: UIView? = superview
            while let v = cell, !(v is UICollectionViewCell) { cell = v.superview }
            let parent = cell ?? window
            parent.addGestureRecognizer(press)
            host = parent
        }

        func detach() {
            host?.removeGestureRecognizer(press)
            host = nil
        }

        @objc private func pressed(_ r: UILongPressGestureRecognizer) {
            guard r.state == .began, !actions.isEmpty else { return }
            let point = r.location(in: self)
            guard bounds.contains(point) else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// The reply text's own long-press (the selection loupe) waits on the menu's, so a
        /// long-press is always the menu. Double-tap and the handles stay native selection.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard other is UILongPressGestureRecognizer, other !== g,
                  let view = other.view, view is UITextInput, let host else { return false }
            return view.isDescendant(of: host)
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                 suggestedActions: [UIMenuElement]) -> UIMenu? {
            UIMenu(children: actions.filter { $0.isAvailable() }.map { action in
                let item = UIAction(title: action.title, image: UIImage(systemName: action.systemImage)) { _ in
                    action.perform()
                }
                item.accessibilityIdentifier = action.id
                return item
            })
        }
    }
}
#endif
