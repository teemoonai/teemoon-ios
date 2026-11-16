//
//  OnDeviceImageTests.swift
//  teemoonTests
//
//  docs/IMAGES.md §4b: Gemma on the phone gets one image per message, as teemoon's own JPEG at 768 px on the
//  long side; earlier images in the chat become a line; a vision engine is built only when a turn has an image
//  and then serves text turns too; an image turn's conversation is never kept for reuse.
//

import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import teemoon

@MainActor
@Suite("Images — on device", .serialized)
struct OnDeviceImageTests {

    static func jpeg(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    static func size(_ data: Data) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    // MARK: What reaches LiteRT

    @Test func aLargeImageIsScaledTo768OnItsLongSide() throws {
        let prepared = try #require(OnDeviceImage.prepared(try Self.jpeg(width: 2048, height: 1536)))
        let (w, h) = try Self.size(prepared)
        #expect(w == 768 && h == 576)
    }

    @Test func aSmallImageIsNotScaledUp() throws {
        let prepared = try #require(OnDeviceImage.prepared(try Self.jpeg(width: 400, height: 300)))
        let (w, h) = try Self.size(prepared)
        #expect(w == 400 && h == 300)
    }

    @Test func notAnImageIsRefused() {
        #expect(OnDeviceImage.prepared(Data("not an image".utf8)) == nil)
    }

    @Test func theLastMessageSplitsIntoTextAndImageBytes() throws {
        let image = ImageSendTests.image(3)
        let content = GenerationEngine.content("what is this?", [image])
        let parts = OnDeviceImage.parts(of: content)
        #expect(parts.text == "what is this?")
        #expect(parts.images == [image.data])
        let plain = OnDeviceImage.parts(of: "just text")
        #expect(plain.text == "just text" && plain.images.isEmpty)
        #expect(OnDeviceImage.parts(of: nil).text.isEmpty)
    }

    // MARK: The transcript

    /// the maintainer 2026-11-12 (his Pixel's E2B forgot photo 1 and 2): a phone turn resends the chat's earlier images like a
    /// cloud one, up to the model's per-request number, and any image in the request bypasses conversation reuse.
    @Test func phoneTurnsResendEarlierImagesLikeCloud() throws {
        guard let f = try PhoneImageMemoryTests.fixture() else { return }
        #expect(ChatGeneration.requestImageBudget(localModelID: "litert-community/gemma-4-E2B-it-litert-lm") == 10)
        #expect(ChatGeneration.requestImageBudget(localModelID: "litert-community/gemma-4-E4B-it-litert-lm") == 4)
        #expect(ChatGeneration.requestImageBudget(localModelID: nil) == ChatGeneration.maxImagesPerRequest)
        for c in f.history.cases {
            let context = try ImageSendTests.store()
            let thread = ChatThread()
            context.insert(thread)
            var messages: [Message] = []
            var n = 0
            for (t, turn) in c.turns.dropLast().enumerated() {
                let q = Message(role: .user, content: "q\(t)", thread: thread)
                q.timestamp = Date(timeIntervalSince1970: Double(1000 + t * 10))
                let a = Message(role: .assistant, content: "a\(t)", thread: thread)
                a.timestamp = Date(timeIntervalSince1970: Double(1001 + t * 10))
                [q, a].forEach(context.insert)
                for i in 0..<turn.images {
                    n += 1
                    context.insert(ImageAttachment(id: UUID(), messageID: q.id, index: i, mimeType: "image/jpeg", width: 4,
                                                   height: 3, data: Data(repeating: UInt8(n), count: 100), thumbnail: Data([1])))
                }
                messages += [q, a]
            }
            let last = Message(role: .user, content: "about both?", thread: thread)
            last.timestamp = Date(timeIntervalSince1970: 99_999)
            context.insert(last)
            try context.save()
            let prompt = (0..<(c.turns.last?.images ?? 0)).map { ImageSendTests.image(200 + $0, bytes: 100) }

            let t = ChatGeneration.buildTranscript(
                from: messages + [last], systemPrompt: "s", maxMessages: nil, seesImages: true,
                maxImages: c.maxImages, promptImages: prompt,
                images: { ImageAttachment.images(of: $0).map(WireImage.init) })
            let sent = prompt.count + t.messages.flatMap(\.images).count
            #expect(sent == c.expectSentOnLastTurn, "\(c.name): sent \(sent)")
            #expect(t.imagesLeftOutForSize == c.expectLines, "\(c.name): lines \(t.imagesLeftOutForSize)")

            // The phone transport keeps them: the history it seeds carries the images, not just the text.
            let wire: [[String: Any]] = t.messages.dropFirst().map {
                ["role": $0.role, "content": GenerationEngine.content($0.content, $0.images)]
            }
            let history = LiteRTTransport.historyTurns(wire, budgetTokens: 100_000)
            #expect(history.flatMap(\.images).count + prompt.count == c.expectSentOnLastTurn, "\(c.name): seeded")
            #expect(LiteRTConversationReuse.reusable(requestImages: sent) == c.expectReuse, "\(c.name): reuse")
        }
    }

    /// E2B answered 10 images on the iPhone 16 Pro, E4B was measured to 4 (IMAGES.md §4b, 2026-11-12).
    @Test func thePhoneModelsTakeWhatWasMeasured() {
        let e2b = "litert-community/gemma-4-E2B-it-litert-lm", e4b = "litert-community/gemma-4-E4B-it-litert-lm"
        #expect(PhoneImageMemory.maxImages(modelID: e2b) == 10)
        #expect(PhoneImageMemory.maxImages(modelID: e4b) == 4)
        #expect(ChatGeneration.imageRefusal(count: 0, seesImages: false, onDeviceMax: 4) == nil)
        #expect(ChatGeneration.imageRefusal(count: 1, seesImages: false, onDeviceMax: 4) == ChatGeneration.cantSeeImagesMessage)
        #expect(ChatGeneration.imageRefusal(count: 4, seesImages: true, onDeviceMax: 4) == nil)
        #expect(ChatGeneration.imageRefusal(count: 5, seesImages: true, onDeviceMax: 4, model: "gemma 4 e4b")
                == "gemma 4 e4b takes up to 4 images per message. remove the others.")
        // The composer's own cap is the same number, so E2B can reach its 10.
        #expect(ChatViewModel.imagesPerSend(localModelID: e2b) == 10)
        #expect(ChatViewModel.imagesPerSend(localModelID: e4b) == 4)
        #expect(ChatViewModel.imagesPerSend(localModelID: nil) == ChatViewModel.cloudImagesPerSend)
        #expect(ChatGeneration.imageRefusal(count: 10, seesImages: true, onDeviceMax: nil) == nil)
    }

    /// Free memory short right now: the "now" line, never a send (§4b turn order).
    @Test func aShortMemoryLineStopsThePhoneTurn() {
        let line = "gemma 4 e4b needs about 3.4 GB free for images; this phone has 2.0 GB free right now. close some apps and try again."
        #expect(ChatGeneration.imageRefusal(count: 1, seesImages: true, onDeviceMax: 4, memoryLine: line) == line)
        #expect(ChatGeneration.imageRefusal(count: 0, seesImages: true, onDeviceMax: 4, memoryLine: line) == nil)
    }

    // MARK: The engine and the kept conversation

    @Test func aVisionEngineIsBuiltOnlyForAnImageAndServesTextAfter() {
        #expect(LiteRTTransport.residentServes(residentVision: false, wantsVision: false))
        #expect(LiteRTTransport.residentServes(residentVision: true, wantsVision: false))
        #expect(LiteRTTransport.residentServes(residentVision: true, wantsVision: true))
        #expect(!LiteRTTransport.residentServes(residentVision: false, wantsVision: true))
    }

    @Test func anImageTurnIsNeverKeptForReuse() {
        let kept = LiteRTConversationReuse.afterTurn(systemMessage: "s", toolNames: [], history: [],
                                                     userText: "what is this?", rawAnswer: "a cat", toolsRan: 0,
                                                     completed: true, images: 1)
        #expect(kept == nil, "the next seed carries no image, so its KV would not match")
        #expect(LiteRTConversationReuse.afterTurn(systemMessage: "s", toolNames: [], history: [],
                                                  userText: "hi", rawAnswer: "hello", toolsRan: 0,
                                                  completed: true, images: 0) != nil)
    }

    // MARK: The card

    @Test func theCardShowsTheImageNotItsBytes() throws {
        let image = ImageSendTests.image(4, bytes: 4096)
        let messages: [[String: Any]] = [["role": "user", "content": GenerationEngine.content("look", [image])]]
        let body = try #require(LiteRTTransport.prettyRequest(messages, tools: []))
        #expect(body.contains("image · jpeg · 4 KB · 14×10"))
        #expect(!body.contains(image.data.base64EncodedString()))
    }
}
