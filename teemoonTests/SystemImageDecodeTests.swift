//
//  SystemImageDecodeTests.swift
//  teemoonTests
//
//  docs/IMAGES.md §2b: a pasted HEIC, WebP, AVIF, TIFF or BMP attaches like Messages (the maintainer 2026-11-11), through
//  a sniff, header caps and a downsampled system decode, and comes out as teemoon's own JPEG/PNG with no metadata.
//  The WebP and AVIF fixtures are 32×24, top-left quadrant blue, the rest red (cwebp 1.x, sips).
//

import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import teemoon

@Suite("Images — system decode")
struct SystemImageDecodeTests {

    static let webpLossless = Data(base64Encoded: "UklGRiwAAABXRUJQVlA4TB8AAAAvH8AFAA9wBZRTSL+He/6jBWLBZP7S/RFE9H8CqNcfAA==")!
    static let webpLossy = Data(base64Encoded: "UklGRnQAAABXRUJQVlA4IGgAAADQBQCdASogABgAPm0skkWkIqGYBABABsSgCxG4H4B+MH4zcgD4AfwD8ALv/uwD+AAYGs0THqyAAP75CmWOH/3BsWPrWmCewT3L/xUwpYtBIGGaDQ/EkglJIhojS0ZexX3MG2Ge8AAAAA==")!
    static let avif = Data(base64Encoded: "AAAAIGZ0eXBhdmlmAAAAAE1pUHJhdmlmbWlhZm1pZjEAAAEhbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAAOcGl0bQAAAAAAAQAAACNpaW5mAAAAAAABAAAAFWluZmUCAAAAAAEAAGF2MDEAAAAAgWlwcnAAAABgaXBjbwAAABNjb2xybmNseAACAAIABoAAAAAMY2xsaQDLAEAAAAAUaXNwZQAAAAAAAAAgAAAAGAAAAAlpcm90AAAAABBwaXhpAAAAAAMICAgAAAAMYXYxQ4EADAAAAAAZaXBtYQAAAAAAAAABAAEGgQIDBYaEAAAAHmlsb2MAAAAARAAAAQABAAAAAQAAAVEAAABFAAAAAW1kYXQAAAAAAAAAVRIACg0AAAACJ+5//AgQEDQgMjIUAGSAAgggiM8J193itv64Aen7JU8ufehdri6ZbxDfpu5t5mts0hM+j+eNPqdbnv2NuQ==")!

    static let gps: [CFString: Any] = [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.8566,
                                                                      kCGImagePropertyGPSLatitudeRef: "N",
                                                                      kCGImagePropertyGPSLongitude: 2.3522,
                                                                      kCGImagePropertyGPSLongitudeRef: "E"],
                                       kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "iPhone 16 Pro"],
                                       kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:09 10:00:00"]]

    private func kept(_ result: Result<ImageIntake.Image, ImageIntake.Failure>, _ name: String) throws -> ImageIntake.Image {
        let image = try #require(try? result.get(), "\(name): \(result)")
        #expect(image.mimeType == "image/jpeg", "\(name)")
        #expect(ImageIntake.Format(sniffing: image.data) == .jpeg, "\(name): stored bytes are teemoon's own JPEG")
        return image
    }

    @Test func eachFormatWuffsLacksAttachesAsTeemoonsOwnJPEG() throws {
        let heic = ImageIntakeTests.encode(ImageIntakeTests.quadrants(), as: .heic)
        let tiff = ImageIntakeTests.encode(ImageIntakeTests.quadrants(), as: .tiff)
        let bmp = ImageIntakeTests.encode(ImageIntakeTests.quadrants(), as: .bmp)
        // quadrants(): top-left red; the WebP and AVIF fixtures: top-left blue.
        for (name, bytes, type, blue) in [("heic", heic, UTType.heic, false), ("tiff", tiff, .tiff, false), ("bmp", bmp, .bmp, false),
                                          ("webp lossless", Self.webpLossless, .webP, true), ("webp lossy", Self.webpLossy, .webP, true),
                                          ("avif", Self.avif, UTType("public.avif")!, true)] {
            let image = try kept(PastedImage.imported(bytes, as: type).result, name)
            let (r, _, b) = ImageIntakeTests.color(image.data, at: 0.1, 0.1)
            #expect(blue ? (b > 150 && r < 100) : (r > 150 && b < 100), "\(name): top-left is (\(r), \(b))")
            // The same bytes offered as a generic image are sniffed to the same path.
            #expect(PastedImage.imported(bytes, as: .image).result == PastedImage.imported(bytes, as: type).result, "\(name)")
        }
    }

    @Test func locationCameraAndTimeAreGone() throws {
        for type in [UTType.heic, .tiff] {
            let bytes = ImageIntakeTests.encode(ImageIntakeTests.quadrants(), as: type, properties: Self.gps)
            let source = CGImageSourceCreateWithData(bytes as CFData, nil)!
            let before = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
            #expect(before[kCGImagePropertyGPSDictionary] != nil, "the fixture carries GPS")
            let image = try kept(SystemImageDecode.decode(bytes), type.identifier)
            let after = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(image.data as CFData, nil)!, 0, nil)
                as! [CFString: Any]
            #expect(after[kCGImagePropertyGPSDictionary] == nil, "\(type.identifier): GPS kept")
            #expect((after[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil, "camera kept")
            #expect((after[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil,
                    "time kept")
        }
    }

    @Test func bytesThatAreNotTheirClaimedContainerAreRefused() {
        // Sniffed as WebP by the header, but not a WebP ImageIO can read: no image.
        var lying = Data("RIFF".utf8) + Data([0x10, 0, 0, 0]) + Data("WEBP".utf8)
        lying.append(Data(repeating: 0x41, count: 32))
        #expect((try? SystemImageDecode.decode(lying).get()) == nil)
        // A PNG is not this path's: the sniff refuses it here (Wuffs reads it).
        #expect(SystemImageDecode.decode(ImageIntakeTests.encode(ImageIntakeTests.quadrants(), as: .png)) == .failure(.unsupportedFormat))
        #expect(SystemImageDecode.decode(Data()) == .failure(.corrupt))
        #expect(SystemImageDecode.decode(Data("hello world, not an image".utf8)) == .failure(.unsupportedFormat))
    }

    @Test func theCapsHoldBeforeAnyPixelIsDecoded() {
        #expect(SystemImageDecode.decode(Data(repeating: 0x42, count: ImageIntake.maxEncodedBytes + 1)) == .failure(.tooLarge))
        // A real BMP whose header is rewritten to declare 20,000 × 20,000 (over the dimension cap).
        var bmp = ImageIntakeTests.encode(ImageIntakeTests.quadrants(), as: .bmp)
        bmp.replaceSubrange(18..<26, with: le32(20_000) + le32(20_000))
        #expect(SystemImageDecode.decode(bmp) == .failure(.tooLarge))
    }

    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    @Test func garbageAfterEachMagicIsAValueNeverATrap() {
        var rng = SystemRandomNumberGenerator()
        let seeds = [Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBP".utf8), Data([0x49, 0x49, 0x2A, 0x00]), Data([0x42, 0x4D]),
                     Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8), Data([0, 0, 0, 0x18]) + Data("ftypavif".utf8)]
        for _ in 0..<100 {
            for seed in seeds {
                var bytes = seed
                bytes.append(contentsOf: (0..<Int.random(in: 0...2048, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
                _ = SystemImageDecode.decode(bytes)
            }
        }
    }

    /// The import and data: URLs stay Wuffs-only: a WebP data URL is still refused.
    @Test func aDataURLNeverReachesTheSystemDecoder() {
        let url = "data:image/webp;base64," + Self.webpLossless.base64EncodedString()
        #expect(ImageIntake.fromDataURL(url) == .failure(.unsupportedFormat))
    }
}
