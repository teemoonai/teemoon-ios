//
//  SystemImageDecode.swift
//  teemoon
//
//  Pasted images Wuffs does not decode (HEIC/HEIF, WebP, AVIF, TIFF, BMP), the Signal way (the maintainer 2026-11-11,
//  docs/IMAGES.md §2b): sniffed, capped from the header, decoded downsampled by ImageIO, then redrawn and
//  re-encoded by ImageIntake with no metadata. Never route an import or a data: URL here: those stay Wuffs-only.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SystemImageDecode {

    enum Kind: Equatable, Sendable {
        case heif, webp, avif, tiff, bmp

        init?(_ type: UTType) {
            if type.conforms(to: .heif) || type.conforms(to: .heic) { self = .heif }
            else if type.conforms(to: .webP) { self = .webp }
            else if let avif = UTType("public.avif"), type.conforms(to: avif) { self = .avif }
            else if type.conforms(to: .tiff) { self = .tiff }
            else if type.conforms(to: .bmp) { self = .bmp }
            else { return nil }
        }

        /// From the bytes alone.
        init?(sniffing data: Data) {
            let b = [UInt8](data.prefix(12))
            guard b.count >= 4 else { return nil }
            if b.count >= 12, b[0..<4].elementsEqual("RIFF".utf8), b[8..<12].elementsEqual("WEBP".utf8) { self = .webp }
            else if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { self = .tiff }
            else if b.starts(with: [0x42, 0x4D]) { self = .bmp }
            else if b.count >= 12, b[4..<8].elementsEqual("ftyp".utf8) {
                switch String(decoding: b[8..<12], as: UTF8.self) {
                case "avif", "avis": self = .avif
                case "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1": self = .heif
                default: return nil
                }
            }
            else { return nil }
        }
    }

    /// Whether a pasteboard type is one this path reads.
    static func reads(_ identifier: String) -> Bool {
        UTType(identifier).flatMap(Kind.init) != nil
    }

    static func decode(_ bytes: Data) -> Result<ImageIntake.Image, ImageIntake.Failure> {
        guard !bytes.isEmpty else { return .failure(.corrupt) }
        guard bytes.count <= ImageIntake.maxEncodedBytes else { return .failure(.tooLarge) }
        guard let kind = Kind(sniffing: bytes) else { return .failure(.unsupportedFormat) }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(bytes as CFData, options),
              CGImageSourceGetCount(source) >= 1 else { return .failure(.corrupt) }
        // ImageIO must read the container the bytes claim: no format confusion past the sniff.
        guard let found = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }), Kind(found) == kind else {
            return .failure(.unsupportedFormat)
        }
        // Caps from the header, before any pixel is decoded.
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return .failure(.corrupt) }
        guard w <= ImageIntake.maxDimension, h <= ImageIntake.maxDimension, w * h <= ImageIntake.maxPixels else {
            return .failure(.tooLarge)
        }
        let thumbnail = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ImageIntake.longSide,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail) else { return .failure(.corrupt) }
        return ImageIntake.fromPixels(image)
    }
}
