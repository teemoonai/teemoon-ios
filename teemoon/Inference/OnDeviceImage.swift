//
//  OnDeviceImage.swift
//  teemoon
//
//  What an image becomes before it reaches LiteRT (docs/IMAGES.md §4b). OnDeviceImageTests pins it.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum OnDeviceImage {
    /// Gemma's own preprocessing size; a larger image only costs memory.
    static let longSide = 768
    /// Vision tokens per image, read at engine creation. Tune by measurement, not by guess.
    static let visionTokenBudget: Int32 = 280

    /// teemoon's stored JPEG, re-encoded at `longSide` at most; nil when the bytes are not an image.
    /// Only ever an ImageAttachment's own re-encoded bytes: never pass received bytes to this decoder.
    static func prepared(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: longSide,
              ] as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// A wire message's `content` (GenerationEngine.content): its text, and each image data URL's bytes.
    static func parts(of content: Any?) -> (text: String, images: [Data]) {
        if let text = content as? String { return (text, []) }
        guard let parts = content as? [[String: Any]] else { return ("", []) }
        var text = "", images: [Data] = []
        for part in parts {
            if let t = part["text"] as? String { text += t }
            if let url = (part["image_url"] as? [String: Any])?["url"] as? String,
               let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64"),
               let bytes = Data(base64Encoded: String(url[url.index(after: comma)...])) {
                images.append(bytes)
            }
        }
        return (text, images)
    }
}
