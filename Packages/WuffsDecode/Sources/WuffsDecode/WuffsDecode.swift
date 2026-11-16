//
//  WuffsDecode.swift
//  WuffsDecode
//
//  Untrusted image bytes → RGBA pixels, through Wuffs (memory-safe by construction). The only
//  way such bytes become pixels in teemoon (docs/IMAGES.md §2). Nothing here throws or traps:
//  every outcome is a value.
//

import CWuffs
import Foundation

public enum WuffsDecode {

    public enum Format: Sendable {
        case jpeg, png, gif

        var c: tw_format {
            switch self {
            case .jpeg: TW_FORMAT_JPEG
            case .png: TW_FORMAT_PNG
            case .gif: TW_FORMAT_GIF
            }
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The bytes are not the declared format.
        case unsupported
        /// Over the dimension or pixel cap, known from the header before any pixel buffer exists.
        case tooLarge
        /// Truncated or malformed, including a partial decode.
        case corrupt
        case noMemory
    }

    /// Tightly packed RGBA, premultiplied alpha, 8 bits per channel, row stride `width * 4`.
    public struct Image: Sendable {
        public let width: Int
        public let height: Int
        public let rgba: Data
    }

    /// The first frame of `data` decoded as `format`, or why not.
    public static func decode(_ data: Data, as format: Format, maxDimension: Int, maxPixels: Int) -> Result<Image, Failure> {
        guard !data.isEmpty, maxDimension > 0, maxPixels > 0 else { return .failure(.corrupt) }
        var image = tw_image(pixels: nil, width: 0, height: 0)
        let status: tw_status = data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return TW_CORRUPT }
            return tw_decode(base, raw.count, format.c,
                             UInt32(clamping: maxDimension), UInt64(clamping: maxPixels), &image)
        }
        guard status == TW_OK, let pixels = image.pixels else {
            if let pixels = image.pixels { tw_free(pixels) }
            switch status {
            case TW_UNSUPPORTED: return .failure(.unsupported)
            case TW_TOO_LARGE: return .failure(.tooLarge)
            case TW_NO_MEMORY: return .failure(.noMemory)
            default: return .failure(.corrupt)
            }
        }
        let width = Int(image.width), height = Int(image.height)
        let (byteCount, overflow) = width.multipliedReportingOverflow(by: height * 4)
        guard !overflow, byteCount > 0 else { tw_free(pixels); return .failure(.corrupt) }
        let rgba = Data(bytesNoCopy: pixels, count: byteCount, deallocator: .custom { pointer, _ in
            tw_free(pointer.assumingMemoryBound(to: UInt8.self))
        })
        return .success(Image(width: width, height: height, rgba: rgba))
    }
}
