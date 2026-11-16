//
//  ImageActions.swift
//  teemoon
//
//  Copy and save of a chat image (docs/IMAGES.md §5). Stored bytes are teemoon's own re-encoded JPEG or PNG;
//  they go out as they are. Do not re-encode or decode them here.
//

import Foundation
import UniformTypeIdentifiers
#if canImport(Photos)
import Photos
#endif
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum ImageActions {

    /// The pasteboard item for stored bytes, keyed by their own type; nil for anything not JPEG or PNG.
    static func pasteboardItem(_ data: Data) -> [String: Data]? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return [UTType.jpeg.identifier: data] }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return [UTType.png.identifier: data] }
        return nil
    }

    static func copy(_ data: Data) {
        guard let item = pasteboardItem(data) else { return }
        #if os(iOS) || os(visionOS)
        UIPasteboard.general.setItems([item])
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        for (type, bytes) in item { NSPasteboard.general.setData(bytes, forType: NSPasteboard.PasteboardType(type)) }
        #endif
    }

    #if os(iOS)
    /// The share sheet for the stored bytes, from the frontmost screen.
    @MainActor
    static func share(_ data: Data) {
        guard let item = pasteboardItem(data), let (type, bytes) = item.first,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let window = scene.keyWindow, var top = window.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let sheet = UIActivityViewController(activityItems: [NSItemProvider(item: bytes as NSData, typeIdentifier: type)],
                                             applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = window
        sheet.popoverPresentationController?.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
        top.present(sheet, animated: true)
    }

    /// The transcript's long-press items for one image; `denied` runs when Photos access is refused.
    @MainActor
    static func menu(_ data: Data, denied: @escaping @MainActor () -> Void) -> [ReplyAction] {
        [ReplyAction(id: "image.copy", title: "copy", systemImage: "doc.on.doc") { copy(data) },
         ReplyAction(id: "image.save", title: "save", systemImage: "square.and.arrow.down") {
             Task { @MainActor in if await save(data) == .denied { denied() } }
         },
         ReplyAction(id: "image.share", title: "share", systemImage: "square.and.arrow.up") {
             MainActor.assumeIsolated { share(data) }   // UIKit runs menu actions on main
         }]
    }
    #endif

    enum Saved: Equatable { case saved, denied, failed }

    /// Shown when Photos access is refused (review page "images-like-messages", draft).
    static let deniedMessage = "teemoon can't save to Photos. allow it in Settings."

    /// Adds the bytes to Photos with add-only access.
    static func save(_ data: Data) async -> Saved {
        #if canImport(Photos)
        guard pasteboardItem(data) != nil else { return .failed }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return .saved
        } catch {
            return .failed
        }
        #else
        return .failed
        #endif
    }
}
