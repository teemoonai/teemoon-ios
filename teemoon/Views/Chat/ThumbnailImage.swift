//
//  ThumbnailImage.swift
//  teemoon
//
//  Shows image bytes teemoon itself encoded (ImageAttachment.thumbnail / .data, ImageIntake output).
//  The one place the app hands bytes to UIImage: never received bytes, which only ImageIntake reads.
//

import ImageIO
import SwiftUI

struct ThumbnailImage: View {
    let data: Data
    /// Decode no larger than this many pixels on the long side (a big tile drawn from the full image); nil: as stored.
    var maxPixels: Int? = nil

    /// The image for teemoon's own bytes, or nil.
    static func image(_ data: Data) -> Image? {
        #if os(iOS) || os(visionOS)
        UIImage(data: data).map { Image(uiImage: $0) }
        #elseif os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }

    #if os(iOS) || os(visionOS)
    /// teemoon's own stored bytes, decoded at display size (ImageIO thumbnail), not at the stored 2048 px.
    static func downsampled(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map { UIImage(cgImage: $0) }
    }
    #endif

    var body: some View {
        #if os(iOS) || os(visionOS)
        if let image = maxPixels.flatMap({ Self.downsampled(data, maxPixels: $0) }) ?? UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color.secondary.opacity(0.2)
        }
        #elseif os(macOS)
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Color.secondary.opacity(0.2)
        }
        #endif
    }
}
