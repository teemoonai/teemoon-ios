//
//  ImageIntake.swift
//  teemoon
//
//  The only way image bytes teemoon did not make become an image it keeps (docs/IMAGES.md §2):
//  gates first (size, magic bytes, declared type), then Wuffs to pixels, then teemoon's own
//  bitmap is rotated, scaled and re-encoded. Untrusted bytes never reach UIImage(data:),
//  CGImageSource or ImageIO decoding; only the encoder sees pixels, and it sees teemoon's.
//  Nothing here throws or traps on bad input: every outcome is a value.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WuffsDecode

enum ImageIntake {

    static let maxEncodedBytes = 20 * 1024 * 1024
    static let maxPixels = 50_000_000
    static let maxDimension = 16_384
    static let longSide = 2048
    static let thumbnailLongSide = 256

    /// What teemoon keeps: its own re-encoding, with no metadata.
    struct Image: Equatable, Sendable {
        let mimeType: String
        let width: Int
        let height: Int
        let data: Data
        let thumbnail: Data
    }

    enum Failure: Error, Equatable, Sendable {
        case notAnImage          // a data URL that is not `data:image/…;base64,…`, or bad base64
        case unsupportedFormat   // not JPEG, PNG or GIF, or the bytes are not the declared type
        case tooLarge            // over a byte, dimension or pixel cap
        case corrupt             // truncated or malformed
    }

    enum Format: Equatable, Sendable {
        case jpeg, png, gif

        var wuffs: WuffsDecode.Format {
            switch self {
            case .jpeg: .jpeg
            case .png: .png
            case .gif: .gif
            }
        }

        init?(mimeType: String) {
            switch mimeType.lowercased() {
            case "image/jpeg", "image/jpg": self = .jpeg
            case "image/png": self = .png
            case "image/gif": self = .gif
            default: return nil
            }
        }

        /// From the bytes alone.
        init?(sniffing data: Data) {
            if data.starts(with: [0xFF, 0xD8, 0xFF]) { self = .jpeg }
            else if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { self = .png }
            else if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) { self = .gif }
            else { return nil }
        }
    }

    // MARK: Entry points

    /// A `data:` URL from an import. A non-data URL is never fetched: it is not an image here.
    static func fromDataURL(_ url: String) -> Result<Image, Failure> {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return .failure(.notAnImage) }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma].lowercased()
        let parts = header.split(separator: ";")
        guard parts.count == 2, parts[1] == "base64", parts[0].hasPrefix("image/") else { return .failure(.notAnImage) }
        guard let declared = Format(mimeType: String(parts[0])) else { return .failure(.unsupportedFormat) }
        let payload = url[url.index(after: comma)...]
        // Base64 is 4/3 the size: refuse before decoding anything too large to be under the cap.
        guard payload.utf8.count <= maxEncodedBytes / 3 * 4 + 4 else { return .failure(.tooLarge) }
        guard let bytes = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters) else {
            return .failure(.notAnImage)
        }
        return fromBytes(bytes, declared: declared)
    }

    /// Bytes whose type was declared by their source (a data URL, or the picker's JPEG representation).
    static func fromBytes(_ bytes: Data, declared: Format) -> Result<Image, Failure> {
        guard !bytes.isEmpty else { return .failure(.corrupt) }
        guard bytes.count <= maxEncodedBytes else { return .failure(.tooLarge) }
        guard let sniffed = Format(sniffing: bytes) else { return .failure(.unsupportedFormat) }
        guard sniffed == declared else { return .failure(.unsupportedFormat) }
        let decoded: WuffsDecode.Image
        switch WuffsDecode.decode(bytes, as: sniffed.wuffs, maxDimension: maxDimension, maxPixels: maxPixels) {
        case .success(let image): decoded = image
        case .failure(.tooLarge): return .failure(.tooLarge)
        case .failure(.unsupported): return .failure(.unsupportedFormat)
        case .failure: return .failure(.corrupt)
        }
        let orientation = sniffed == .jpeg ? JPEGOrientation.read(bytes) : 1
        return finish(rgba: decoded.rgba, width: decoded.width, height: decoded.height, orientation: orientation)
    }

    /// Pixels teemoon already holds (the camera's image drawn into teemoon's own bitmap).
    static func fromPixels(_ image: CGImage) -> Result<Image, Failure> {
        guard let (rgba, w, h) = bitmap(of: image) else { return .failure(.corrupt) }
        return finish(rgba: rgba, width: w, height: h, orientation: 1)
    }

    // MARK: Rotate, scale, encode

    /// The size after `longSide` scaling: long side capped, short side rounded half up.
    static func scaled(width: Int, height: Int, longSide cap: Int) -> (Int, Int) {
        let long = max(width, height), short = min(width, height)
        guard long > cap, long > 0 else { return (width, height) }
        let s = Int((Double(short) * Double(cap) / Double(long) + 0.5).rounded(.down))
        let scaledShort = max(1, s)
        return width >= height ? (cap, scaledShort) : (scaledShort, cap)
    }

    private static func finish(rgba: Data, width: Int, height: Int, orientation: Int) -> Result<Image, Failure> {
        guard width > 0, height > 0, rgba.count == width * height * 4,
              let source = cgImage(rgba: rgba, width: width, height: height) else { return .failure(.corrupt) }
        let swaps = (5...8).contains(orientation)
        let (uprightW, uprightH) = swaps ? (height, width) : (width, height)
        let opaque = !hasTransparency(rgba)
        guard let (full, fw, fh) = render(source, orientation: orientation, uprightWidth: uprightW, uprightHeight: uprightH,
                                          cap: longSide),
              let (thumb, _, _) = render(source, orientation: orientation, uprightWidth: uprightW, uprightHeight: uprightH,
                                         cap: thumbnailLongSide),
              let data = encode(full, png: !opaque),
              let thumbnail = encode(thumb, png: false)
        else { return .failure(.corrupt) }
        return .success(Image(mimeType: opaque ? "image/jpeg" : "image/png", width: fw, height: fh,
                              data: data, thumbnail: thumbnail))
    }

    private static func cgImage(rgba: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Draws `source` upright and scaled into a fresh sRGB bitmap.
    private static func render(_ source: CGImage, orientation: Int, uprightWidth: Int, uprightHeight: Int,
                               cap: Int) -> (CGImage, Int, Int)? {
        let (w, h) = scaled(width: uprightWidth, height: uprightHeight, longSide: cap)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        let W = CGFloat(w), H = CGFloat(h)
        // EXIF orientation 1–8 as an affine map from the stored image to the upright canvas
        // (Core Graphics, y up): x' = a·x + c·y + tx, y' = b·x + d·y + ty.
        let t: CGAffineTransform
        switch orientation {
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: W, ty: 0)
        case 3: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: W, ty: H)
        case 4: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        case 5: t = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: W, ty: H)
        case 6: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: H)
        case 7: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: W, ty: 0)
        default: t = .identity
        }
        ctx.concatenate(t)
        let swaps = (5...8).contains(orientation)
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: swaps ? H : W, height: swaps ? W : H))
        guard let out = ctx.makeImage() else { return nil }
        return (out, w, h)
    }

    /// teemoon's own pixels, encoded. Nothing to copy: the bitmap has no metadata.
    private static func encode(_ image: CGImage, png: Bool) -> Data? {
        let out = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        let options: [CFString: Any] = png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func hasTransparency(_ rgba: Data) -> Bool {
        rgba.withUnsafeBytes { raw in
            var i = 3
            while i < raw.count {
                if raw[i] != 0xFF { return true }
                i += 4
            }
            return false
        }
    }

    private static func bitmap(of image: CGImage) -> (Data, Int, Int)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= maxDimension, h <= maxDimension, w * h <= maxPixels,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = Data(count: w * h * 4)
        let ok: Bool = data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (data, w, h) : nil
    }
}

/// The EXIF orientation tag (1–8) of a JPEG, read with bounds checks at every step; 1 when absent
/// or malformed. Wuffs decodes pixels only, so this is the one metadata field teemoon reads.
enum JPEGOrientation {
    static func read(_ data: Data) -> Int {
        let b = [UInt8](data.prefix(256 * 1024))
        func u16(_ i: Int, _ little: Bool) -> Int? {
            guard i >= 0, i + 1 < b.count else { return nil }
            return little ? Int(b[i]) | Int(b[i + 1]) << 8 : Int(b[i]) << 8 | Int(b[i + 1])
        }
        func u32(_ i: Int, _ little: Bool) -> Int? {
            guard let hi = u16(little ? i + 2 : i, little), let lo = u16(little ? i : i + 2, little) else { return nil }
            return hi << 16 | lo
        }
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return 1 }
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return 1 }
            let marker = b[i + 1]
            if marker == 0xDA || marker == 0xD9 { return 1 }          // start of scan / end: no EXIF before it
            guard let length = u16(i + 2, false), length >= 2 else { return 1 }
            if marker == 0xE1, i + 10 <= b.count, Array(b[(i + 4)..<(i + 10)]) == [0x45, 0x78, 0x69, 0x66, 0, 0] {
                let tiff = i + 10
                guard tiff + 8 <= b.count else { return 1 }
                let little: Bool
                switch (b[tiff], b[tiff + 1]) {
                case (0x49, 0x49): little = true
                case (0x4D, 0x4D): little = false
                default: return 1
                }
                guard let ifd = u32(tiff + 4, little), ifd >= 8, ifd < 1 << 20 else { return 1 }
                let entries = tiff + ifd
                guard let count = u16(entries, little), count < 512 else { return 1 }
                for n in 0..<count {
                    let e = entries + 2 + n * 12
                    guard let tag = u16(e, little) else { return 1 }
                    if tag == 0x0112, let value = u16(e + 8, little) { return (1...8).contains(value) ? value : 1 }
                }
                return 1
            }
            i += 2 + length
        }
        return 1
    }
}
