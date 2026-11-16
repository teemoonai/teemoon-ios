//
//  ImageActionsTests.swift
//  teemoonTests
//
//  docs/IMAGES.md §5: copy puts the stored bytes on the pasteboard as they are, and saving to Photos has its
//  usage string in the built app (without it the system's Save Image fails).
//

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import teemoon

@Suite("Image actions")
struct ImageActionsTests {

    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

    @Test func aJPEGCopiesAsItsOwnBytes() throws {
        let item = try #require(ImageActions.pasteboardItem(Self.jpeg))
        #expect(Array(item.keys) == [UTType.jpeg.identifier])
        #expect(item[UTType.jpeg.identifier] == Self.jpeg)
    }

    @Test func aPNGCopiesAsItsOwnBytes() throws {
        let item = try #require(ImageActions.pasteboardItem(Self.png))
        #expect(Array(item.keys) == [UTType.png.identifier])
        #expect(item[UTType.png.identifier] == Self.png)
    }

    @Test func bytesThatAreNeitherCopyNothing() {
        #expect(ImageActions.pasteboardItem(Data()) == nil)
        #expect(ImageActions.pasteboardItem(Data("GIF89a".utf8)) == nil)
    }

    @Test func theBuiltAppSaysWhyItAddsToPhotos() throws {
        let text = try #require(Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String)
        #expect(text == "teemoon saves the images you choose to Photos.")
    }
}
