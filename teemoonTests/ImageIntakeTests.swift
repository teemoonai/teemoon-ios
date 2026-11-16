//
//  ImageIntakeTests.swift
//  teemoonTests
//
//  docs/IMAGES.md §2: untrusted bytes become pixels only through Wuffs, behind gates, and only
//  teemoon's re-encoding is kept. ImageIO appears here only on bytes the test made itself, as the
//  reference for orientation and to read back teemoon's own output.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import teemoon

@Suite("Images — intake")
struct ImageIntakeTests {

    // MARK: Fixtures made here

    /// A 64×32 image: red top-left, green top-right, blue bottom-left, white bottom-right.
    static func quadrants(width: Int = 64, height: Int = 32) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        for (color, rect) in [((1.0, 0.0, 0.0), CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2)),
                              ((0.0, 1.0, 0.0), CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2)),
                              ((0.0, 0.0, 1.0), CGRect(x: 0, y: 0, width: w / 2, height: h / 2)),
                              ((1.0, 1.0, 1.0), CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))] {
            ctx.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
            ctx.fill(rect)
        }
        return ctx.makeImage()!
    }

    static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// The color at a fractional point of an image, read back with ImageIO (test-made or teemoon-made bytes only).
    static func color(_ data: Data, at x: Double, _ y: Double, upright: Bool = false) -> (Int, Int, Int) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image: CGImage = upright
            ? CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailWithTransform: true,
                                                              kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                              kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary)!
            : CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let w = image.width, h = image.height
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw so the wanted pixel (x from the left, y from the top) lands on the 1×1 canvas.
        ctx.draw(image, in: CGRect(x: -x * Double(w), y: -(1 - y) * Double(h), width: Double(w), height: Double(h)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    static func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
        abs(a.0 - b.0) < 60 && abs(a.1 - b.1) < 60 && abs(a.2 - b.2) < 60
    }

    // MARK: Orientation

    /// Every EXIF orientation lands upright, exactly as ImageIO's own transform would place it.
    @Test(arguments: 1...8)
    func orientationMatchesTheReference(_ orientation: Int) throws {
        let jpeg = Self.encode(Self.quadrants(), as: .jpeg,
                               properties: [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1.0])
        #expect(JPEGOrientation.read(jpeg) == orientation)
        let kept = try ImageIntake.fromBytes(jpeg, declared: .jpeg).get()
        let swaps = (5...8).contains(orientation)
        #expect((kept.width, kept.height) == (swaps ? (32, 64) : (64, 32)))
        for (x, y) in [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)] {
            let want = Self.color(jpeg, at: x, y, upright: true)
            let got = Self.color(kept.data, at: x, y)
            #expect(Self.near(want, got), "orientation \(orientation) at (\(x), \(y)): want \(want), got \(got)")
        }
    }

    // MARK: Metadata

    @Test func noMetadataSurvives() throws {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 38.7, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 9.1, kCGImagePropertyGPSLongitudeRef: "W"]
        let exif: [CFString: Any] = [kCGImagePropertyExifUserComment: "secret comment", kCGImagePropertyExifLensModel: "LensX"]
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let image = Self.quadrants().copy(colorSpace: p3)!
        let jpeg = Self.encode(image, as: .jpeg, properties: [kCGImagePropertyGPSDictionary: gps,
                                                               kCGImagePropertyExifDictionary: exif,
                                                               kCGImagePropertyOrientation: 6])
        let kept = try ImageIntake.fromBytes(jpeg, declared: .jpeg).get()
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(kept.data as CFData, nil)!, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyGPSDictionary] == nil, "GPS survived")
        #expect((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] == nil)
        #expect((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel] == nil)
        #expect(props[kCGImagePropertyOrientation] == nil || props[kCGImagePropertyOrientation] as? Int == 1)
        #expect(props[kCGImagePropertyProfileName] as? String != "Display P3", "the source's ICC profile survived")
        #expect(!kept.data.contains(Data("secret comment".utf8)) && !kept.data.contains(Data("LensX".utf8)))
    }

    // MARK: Size

    @Test func theLongSideIs2048AndTheShortSideRoundsHalfUp() {
        #expect(ImageIntake.scaled(width: 3000, height: 2000, longSide: 2048) == (2048, 1365))   // 1365.33
        #expect(ImageIntake.scaled(width: 2000, height: 3001, longSide: 2048) == (1365, 2048))   // 1364.88 → 1365
        #expect(ImageIntake.scaled(width: 4096, height: 1, longSide: 2048) == (2048, 1))          // never 0
        #expect(ImageIntake.scaled(width: 4096, height: 3, longSide: 2048) == (2048, 2))          // 1.5 → 2
        #expect(ImageIntake.scaled(width: 2048, height: 1000, longSide: 2048) == (2048, 1000))   // untouched
        #expect(ImageIntake.scaled(width: 640, height: 480, longSide: 256) == (256, 192))
    }

    // MARK: Gates

    @Test func theGatesRefuseBeforeDecoding() {
        let png = Self.encode(Self.quadrants(), as: .png)
        let jpeg = Self.encode(Self.quadrants(), as: .jpeg)
        #expect(throws: ImageIntake.Failure.unsupportedFormat) { try ImageIntake.fromBytes(png, declared: .jpeg).get() }
        #expect(throws: ImageIntake.Failure.tooLarge) {
            try ImageIntake.fromBytes(jpeg + Data(count: 21 * 1024 * 1024), declared: .jpeg).get()
        }
        #expect(throws: ImageIntake.Failure.corrupt) { try ImageIntake.fromBytes(jpeg.prefix(jpeg.count / 2), declared: .jpeg).get() }
        #expect(throws: ImageIntake.Failure.notAnImage) { try ImageIntake.fromDataURL("https://example.com/cat.png").get() }
        #expect(throws: ImageIntake.Failure.notAnImage) { try ImageIntake.fromDataURL("data:text/html;base64,PGgxPg==").get() }
        #expect(throws: ImageIntake.Failure.notAnImage) { try ImageIntake.fromDataURL("data:image/png;base64,***").get() }
        #expect(throws: ImageIntake.Failure.unsupportedFormat) { try ImageIntake.fromDataURL("data:image/webp;base64,UklGRg==").get() }
        #expect(throws: ImageIntake.Failure.unsupportedFormat) { try ImageIntake.fromDataURL("data:image/svg+xml;base64,PHN2Zz4=").get() }
    }

    @Test func aDataURLImageIsKeptAsTeemoonsOwnJPEG() throws {
        let png = Self.encode(Self.quadrants(), as: .png)
        let kept = try ImageIntake.fromDataURL("data:image/png;base64," + png.base64EncodedString()).get()
        #expect(kept.mimeType == "image/jpeg" && kept.width == 64 && kept.height == 32)
        #expect(kept.data.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(kept.data != png)
    }

    /// A transparent PNG stays PNG so its alpha survives; an animated GIF keeps its first frame.
    @Test func transparencyKeepsPNG() throws {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 0.5); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let kept = try ImageIntake.fromBytes(Self.encode(ctx.makeImage()!, as: .png), declared: .png).get()
        #expect(kept.mimeType == "image/png")
    }

    // MARK: No untrusted bytes reach a platform decoder

    /// Platform image *decoding* appears nowhere in the app outside the files allowed to read teemoon's
    /// own re-encoded images: ThumbnailImage, and OnDeviceImage (a stored ImageAttachment, scaled for LiteRT);
    /// and SystemImageDecode, the one path for pasted formats Wuffs lacks (the maintainer 2026-11-11, sniffed and capped first).
    /// ImageIntake may encode (CGImageDestination), never decode.
    @Test func platformDecodersAreUsedOnlyWhereAllowed() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("teemoon")
        let allowed: Set<String> = ["ThumbnailImage.swift", "OnDeviceImage.swift", "SystemImageDecode.swift"]
        let banned = ["UIImage(data:", "UIImage(contentsOfFile", "NSImage(data:", "CIImage(data", "CGImageSourceCreate",
                      "Image(uiImage: UIImage(data"]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 100)
        for file in files where !allowed.contains(file.lastPathComponent) {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for b in banned { #expect(!code.contains(b), "\(file.lastPathComponent) uses \(b)") }
        }
    }

    // MARK: Garbage never traps

    @Test func garbageIsAValueNeverATrap() {
        var rng = SystemRandomNumberGenerator()
        let seeds: [Data] = [Data([0xFF, 0xD8, 0xFF]), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), Data("GIF89a".utf8)]
        for _ in 0..<300 {
            for seed in seeds {
                var bytes = seed
                bytes.append(contentsOf: (0..<Int.random(in: 0...2048, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
                let format = ImageIntake.Format(sniffing: bytes)!
                _ = ImageIntake.fromBytes(bytes, declared: format)
            }
        }
        // A real image with random bytes flipped.
        let jpeg = Self.encode(Self.quadrants(width: 256, height: 128), as: .jpeg)
        for _ in 0..<200 {
            var bytes = jpeg
            for _ in 0..<8 { bytes[Int.random(in: 3..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = ImageIntake.fromBytes(bytes, declared: .jpeg)
            _ = JPEGOrientation.read(bytes)
        }
    }
}
