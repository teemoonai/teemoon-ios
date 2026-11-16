//
//  ComposerHost.swift
//  teemoonTests
//
//  The shipping ChatComposer in a real window, with the UITextView that draws its field. The field's view type
//  is not named here, so the same cases pin whichever view draws it.
//

#if os(iOS)

import SwiftUI
import UIKit
@testable import teemoon

@MainActor
final class ComposerHost {
    let viewModel: ChatViewModel
    let window: UIWindow
    private let focus = FocusBox()

    /// Drives the composer's `isPromptFocused` from the test, as ContentView does.
    @Observable final class FocusBox { var wanted: Bool? }

    private struct Root: View {
        let viewModel: ChatViewModel
        let focus: FocusBox
        let llm: ChatGeneration
        @FocusState private var focused: Bool
        var body: some View {
            ChatComposer(viewModel: viewModel, isPromptFocused: $focused, onSend: {})
                .environment(llm)
                .frame(width: 393)
                .onChange(of: focus.wanted) { _, wanted in if let wanted { focused = wanted } }
        }
    }

    init(viewModel: ChatViewModel? = nil, dynamicTypeSize: DynamicTypeSize = .large) {
        let viewModel = viewModel ?? ChatViewModel()
        self.viewModel = viewModel
        let root = Root(viewModel: viewModel, focus: focus, llm: ChatGeneration()).environment(\.dynamicTypeSize, dynamicTypeSize)
        let controller = UIHostingController(rootView: root)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        settle()
    }

    func settle(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    /// The field's text view. Fails the caller's expectations by returning nil when there is none.
    var field: UITextView? { Self.find(UITextView.self, in: window) }

    func setFocused(_ wanted: Bool) {
        focus.wanted = nil
        settle(0.05)
        focus.wanted = wanted
        settle(0.4)
    }

    func tearDown() {
        field?.resignFirstResponder()
        window.isHidden = true
        window.rootViewController = nil
        settle(0.05)
    }

    static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews { if let hit = find(type, in: sub) { return hit } }
        return nil
    }
}

#endif
