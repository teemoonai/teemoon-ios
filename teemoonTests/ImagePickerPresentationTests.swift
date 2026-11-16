//
//  ImagePickerPresentationTests.swift
//  teemoonTests
//
//  The camera closes itself from UIKit (`picker.dismiss`); the cover's binding must still clear so the next
//  "take photo" opens it (pm's first suspect for the maintainer's 2026-11-11 stall; it holds, the stall was the composer's
//  interactive glass, ChatImageActionsUITests). Each round opens through the binding and closes through the delegate.
//

#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import teemoon

@MainActor
@Suite("Image pickers — open again after closing", .serialized)
struct ImagePickerPresentationTests {

    @Observable @MainActor final class Shown {
        var camera = false
    }

    struct Host: View {
        @Bindable var shown: Shown
        var body: some View {
            Color.clear
                .fullScreenCover(isPresented: $shown.camera) {
                    CameraPicker(source: .photoLibrary) { _ in }
                }
        }
    }

    private func host() -> (UIWindow, Shown) {
        let shown = Shown()
        // In the app's scene: a window with none does not finish UIKit presentations.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Host(shown: shown))
        window.makeKeyAndVisible()
        return (window, shown)
    }

    private func wait(_ seconds: Double = 5, until done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    private func find<T: UIViewController>(_ type: T.Type, in window: UIWindow) -> T? {
        func search(_ vc: UIViewController?) -> T? {
            guard let vc else { return nil }
            if let hit = vc as? T { return hit }
            for child in vc.children { if let hit = search(child) { return hit } }
            return search(vc.presentedViewController)
        }
        return search(window.rootViewController)
    }

    @Test func theCameraOpensEveryTimeAfterItClosesItself() async throws {
        let (window, shown) = host()
        defer { window.isHidden = true }
        for round in 1...3 {
            shown.camera = true
            let opened = await wait { find(UIImagePickerController.self, in: window) != nil }
            #expect(opened, "round \(round): take photo did not open the camera")
            guard let picker = find(UIImagePickerController.self, in: window) else { return }
            picker.delegate?.imagePickerControllerDidCancel?(picker)
            let closed = await wait { window.rootViewController?.presentedViewController == nil }
            #expect(closed, "round \(round): the camera did not close")
            #expect(await wait { !shown.camera }, "round \(round): the cover's binding is still set after the camera closed")
        }
    }
}
#endif
