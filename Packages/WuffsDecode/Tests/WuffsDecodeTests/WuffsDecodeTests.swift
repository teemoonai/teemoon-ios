import Foundation
import Testing
@testable import WuffsDecode

@Suite("WuffsDecode")
struct WuffsDecodeTests {
    /// A 1×1 red PNG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!

    @Test func decodesAPNG() throws {
        let image = try WuffsDecode.decode(Self.png, as: .png, maxDimension: 16384, maxPixels: 50_000_000).get()
        #expect(image.width == 1 && image.height == 1 && image.rgba.count == 4)
    }

    @Test func refusesBytesThatAreNotTheDeclaredFormat() {
        #expect(throws: WuffsDecode.Failure.unsupported) {
            try WuffsDecode.decode(Self.png, as: .jpeg, maxDimension: 16384, maxPixels: 50_000_000).get()
        }
    }

    @Test func refusesATruncatedFile() {
        let cut = Self.png.prefix(30)
        #expect(throws: WuffsDecode.Failure.self) {
            try WuffsDecode.decode(cut, as: .png, maxDimension: 16384, maxPixels: 50_000_000).get()
        }
    }

    /// A PNG header declaring 100,000 × 100,000: refused from the header, no buffer allocated.
    @Test func refusesAPixelBombFromItsHeader() {
        var bomb = Self.png
        bomb.replaceSubrange(16..<24, with: [0x00, 0x01, 0x86, 0xA0, 0x00, 0x01, 0x86, 0xA0])
        #expect(throws: WuffsDecode.Failure.self) {
            try WuffsDecode.decode(bomb, as: .png, maxDimension: 16384, maxPixels: 50_000_000).get()
        }
    }

    @Test func emptyAndGarbageAreFailuresNotCrashes() {
        for bytes in [Data(), Data([0xFF, 0xD8, 0xFF]), Data(repeating: 0xAB, count: 4096)] {
            for format: WuffsDecode.Format in [.jpeg, .png, .gif] {
                #expect((try? WuffsDecode.decode(bytes, as: format, maxDimension: 16384, maxPixels: 50_000_000).get()) == nil)
            }
        }
    }
}
