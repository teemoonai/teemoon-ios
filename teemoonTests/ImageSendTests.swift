//
//  ImageSendTests.swift
//  teemoonTests
//
//  docs/IMAGES.md §4: images go only to a model whose catalogue says it takes them, as image_url
//  parts after the text; earlier images share one budget per request (10, 8 MiB, newest first) and
//  leave a line when not sent; a message with images to a model that can't see them is refused.
//

import AnyLanguageModel
import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftData
import Testing
@testable import teemoon

@MainActor
@Suite("Images — sending", .serialized)
struct ImageSendTests {

    static func image(_ n: Int, bytes: Int = 1000) -> WireImage {
        WireImage(mimeType: "image/jpeg", data: Data(repeating: UInt8(n), count: bytes), width: 10 + n, height: 10)
    }

    static func store() throws -> ModelContext {
        ModelContext(try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    /// A thread of `turns` user/assistant pairs; user turn i carries `imagesPerTurn` images.
    static func thread(_ context: ModelContext, turns: Int, imagesPerTurn: Int, bytes: Int = 1000) throws -> [Message] {
        let thread = ChatThread()
        context.insert(thread)
        var all: [Message] = []
        for t in 0..<turns {
            let q = Message(role: .user, content: "question \(t)", thread: thread)
            q.timestamp = Date(timeIntervalSince1970: Double(1000 + t * 10))
            let a = Message(role: .assistant, content: "answer \(t)", thread: thread)
            a.timestamp = Date(timeIntervalSince1970: Double(1001 + t * 10))
            [q, a].forEach(context.insert)
            for i in 0..<imagesPerTurn {
                context.insert(ImageAttachment(id: UUID(), messageID: q.id, index: i, mimeType: "image/jpeg", width: 4, height: 3,
                                               data: Data(repeating: UInt8(t), count: bytes), thumbnail: Data([1])))
            }
            all += [q, a]
        }
        let next = Message(role: .user, content: "the new question", thread: thread)
        next.timestamp = Date(timeIntervalSince1970: 99_999)
        context.insert(next)
        try context.save()
        return all + [next]
    }

    // MARK: The transcript

    @Test func aModelThatCantSeeImagesGetsALineForEach() throws {
        let messages = try Self.thread(try Self.store(), turns: 2, imagesPerTurn: 2)
        let t = ChatGeneration.buildTranscript(from: messages, systemPrompt: "s", maxMessages: nil, seesImages: false,
                                               images: { ImageAttachment.images(of: $0).map(WireImage.init) })
        #expect(t.messages.allSatisfy { $0.images.isEmpty })
        #expect(t.imagesLeftOutForModel == 4 && t.imagesLeftOutForSize == 0)
        let firstQuestion = try #require(t.messages.first { $0.content.hasPrefix("question 0") })
        #expect(firstQuestion.content == "question 0\n\n[image earlier in this chat]\n\n[image earlier in this chat]")
    }

    @Test func theBudgetIsTenImagesNewestFirstWithThePromptFirst() throws {
        let messages = try Self.thread(try Self.store(), turns: 6, imagesPerTurn: 2)
        let t = ChatGeneration.buildTranscript(from: messages, systemPrompt: "s", maxMessages: nil, seesImages: true,
                                               promptImages: [Self.image(9)],
                                               images: { ImageAttachment.images(of: $0).map(WireImage.init) })
        let sent = t.messages.map(\.images.count)
        // system, q0, a0 … q5, a5: the prompt takes 1, q5…q2 get 2 each, q1 gets 1, q0 none.
        #expect(sent == [0, 0, 0, 1, 0, 2, 0, 2, 0, 2, 0, 2, 0])
        #expect(t.imagesLeftOutForSize == 3 && t.imagesLeftOutForModel == 0)
        #expect(t.messages[1].content == "question 0\n\n[image earlier in this chat]\n\n[image earlier in this chat]")
        #expect(t.messages[3].content == "question 1\n\n[image earlier in this chat]")
    }

    @Test func theBudgetIsAlsoEightMebibytes() throws {
        let messages = try Self.thread(try Self.store(), turns: 2, imagesPerTurn: 1, bytes: 5 * 1024 * 1024)
        let t = ChatGeneration.buildTranscript(from: messages, systemPrompt: "s", maxMessages: nil, seesImages: true,
                                               images: { ImageAttachment.images(of: $0).map(WireImage.init) })
        #expect(t.messages.map(\.images.count) == [0, 0, 0, 1, 0])
        #expect(t.imagesLeftOutForSize == 1)
    }

    // MARK: The wire

    @Test func contentBecomesTextThenImageParts() throws {
        let parts = try #require(GenerationEngine.content("look", [Self.image(1), Self.image(2)]) as? [[String: Any]])
        #expect(parts.count == 3)
        #expect(parts[0]["type"] as? String == "text" && parts[0]["text"] as? String == "look")
        let url = try #require((parts[1]["image_url"] as? [String: Any])?["url"] as? String)
        #expect(url.hasPrefix("data:image/jpeg;base64,") && url == Self.image(1).dataURL)
        #expect(GenerationEngine.content("just text", []) as? String == "just text")
        let imageOnly = try #require(GenerationEngine.content("", [Self.image(1)]) as? [[String: Any]])
        #expect(imageOnly.count == 1, "an image-only message sends no empty text part")
    }

    /// Through the real transport: the body carries the prompt's and history's images, and the same
    /// turn twice is the same bytes (the prompt cache relies on it).
    @Test func theRequestBodyCarriesImagesAsStableBytes() async throws {
        let prior = [WireMessage(role: "system", content: "s"),
                     WireMessage(role: "user", content: "earlier", images: [Self.image(3)]),
                     WireMessage(role: "assistant", content: "ok")]
        func body() async throws -> [String: Any] {
            BodyCapture.bodies.value = []
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [BodyCapture.self]
            var provider = Provider(name: "p", endpoint: "https://api.example.com/v1", model: "vision-model", requiresAPIKey: true)
            provider.modelCapabilities = [.vision, .tools]
            let model = ConfidentialLanguageModel(provider: provider, apiKey: "k", priorMessages: prior,
                                                  events: StreamCallbacks(onSourcesFound: { _ in }, onQueriesFound: { _ in },
                                                                         onToolExecutionEnded: {}, onSuccess: { _ in }),
                                                  urlSession: URLSession(configuration: config),
                                                  promptImages: [Self.image(4)])
            let session = LanguageModelSession(model: model, tools: [])
            _ = try? await model.respond(within: session, to: Prompt("what is this?"), generating: String.self,
                                         includeSchemaInPrompt: false, options: GenerationOptions())
            let raw = try #require(BodyCapture.bodies.value.first)
            return try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        }
        let first = try await body()
        let messages = try #require(first["messages"] as? [[String: Any]])
        let last = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(last.first?["text"] as? String == "what is this?")
        #expect(((last.last?["image_url"] as? [String: Any])?["url"] as? String) == Self.image(4).dataURL)
        let earlier = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(((earlier.last?["image_url"] as? [String: Any])?["url"] as? String) == Self.image(3).dataURL)
        let again = try await body()
        #expect(try JSONSerialization.data(withJSONObject: first, options: .sortedKeys)
                == JSONSerialization.data(withJSONObject: again, options: .sortedKeys))
    }

    /// A home model (Ollama's OpenAI-compatible endpoint, as a15f0cec marks vision from /api/show) gets the photo the
    /// way a server does: an image_url part after the text, a JPEG data URL of the re-encoded bytes, no EXIF or GPS.
    @Test func aHomeModelGetsTheReencodedJPEGWithNoLocation() async throws {
        let width = 64, height = 48
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 48.86, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 2.35, kCGImagePropertyGPSLongitudeRef: "E"]
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()),
                                   [kCGImagePropertyGPSDictionary: gps,
                                    kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let original = out as Data
        #expect(original.range(of: Data("Exif".utf8)) != nil, "precondition: the original carries EXIF")
        guard case .success(let kept) = ImageIntake.fromBytes(original, declared: .jpeg) else {
            Issue.record("intake refused the photo"); return
        }

        BodyCapture.bodies.value = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BodyCapture.self]
        var provider = Provider(name: "ollama", endpoint: "http://localhost:11434/v1", model: "gemma4:e4b", requiresAPIKey: false)
        provider.modelCapabilities = [.vision, .tools]
        let model = ConfidentialLanguageModel(provider: provider, apiKey: "", priorMessages: [],
                                              events: StreamCallbacks(onSourcesFound: { _ in }, onQueriesFound: { _ in },
                                                                     onToolExecutionEnded: {}, onSuccess: { _ in }),
                                              urlSession: URLSession(configuration: config),
                                              promptImages: [WireImage(mimeType: kept.mimeType, data: kept.data,
                                                                       width: kept.width, height: kept.height)])
        let session = LanguageModelSession(model: model, tools: [])
        _ = try? await model.respond(within: session, to: Prompt("what colour is this?"), generating: String.self,
                                     includeSchemaInPrompt: false, options: GenerationOptions())
        let raw = try #require(BodyCapture.bodies.value.first, "nothing reached the home model")
        let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let last = try #require((body["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        #expect(last.first?["text"] as? String == "what colour is this?")
        let url = try #require((last.last?["image_url"] as? [String: Any])?["url"] as? String)
        #expect(url.hasPrefix("data:image/jpeg;base64,"))
        let sent = try #require(Data(base64Encoded: String(url.dropFirst("data:image/jpeg;base64,".count))))
        #expect(sent.starts(with: [0xFF, 0xD8]), "not a JPEG")
        // ImageIO writes a small block of its own; an allowlist, so any tag about the person or camera fails (§1).
        #expect(sent.range(of: Data("secret".utf8)) == nil, "the photo's EXIF comment went to the home model")
        let source = try #require(CGImageSourceCreateWithData(sent as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = Set(((props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]).keys.map { $0 as String })
        #expect(exif.isSubset(of: [kCGImagePropertyExifPixelXDimension as String, kCGImagePropertyExifPixelYDimension as String,
                                   kCGImagePropertyExifColorSpace as String]), "Exif tags beyond size: \(exif)")
        for dict in [kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyExifAuxDictionary,
                     kCGImagePropertyMakerAppleDictionary] {
            #expect(props[dict] == nil, "\(dict) went to the home model")
        }
        let iptc = (props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
        #expect(iptc.isEmpty, "IPTC carries \(iptc)")
    }

    /// The card and its copy show each image as type, size and dimensions, never base64.
    @Test func aShownBodySummarisesImages() throws {
        let image = Self.image(5, bytes: 300 * 1024)
        let parts = try #require(GenerationEngine.content("look", [image]) as? [[String: Any]])
        let body = String(data: try JSONSerialization.data(withJSONObject: ["messages": [["role": "user", "content": parts]]]),
                          encoding: .utf8)!
        let shown = prettyPrintedJSON(body)
        #expect(!shown.contains("base64"))
        #expect(shown.contains("image · jpeg · 300 KB · 15×10"))
        let history = try #require(prettyMessages(from: Data(body.utf8)))
        #expect(!history.contains("base64") && history.contains("image · jpeg · 300 KB · 15×10"))
    }

    @Test func theCardSaysHowManyEarlierImagesWereNotSentAndWhy() {
        var info = LastRequestDebugInfo(providerName: "p", url: nil, requestHeaders: nil, requestBodyJSON: nil,
                                        responseBody: nil, toolCalls: [], threadID: UUID(), totalDuration: nil,
                                        timeToFirstToken: nil, outputTokens: nil, isE2EEActive: false)
        #expect(info.imageLines.isEmpty)
        info.imagesLeftOutForModel = 1
        info.imagesLeftOutForSize = 3
        #expect(info.imageLines == ["1 earlier image wasn't sent: this model can't see images",
                                    "3 earlier images weren't sent, to keep the request small"])
    }

    /// Through a whole generation: the finished turn's card still carries the counts (it is rebuilt
    /// after the turn; a rebuild that dropped them left the card silent, seen in the 1.1 screenshots).
    @Test func aFinishedTurnsCardSaysEarlierImagesWereLeftOut() async throws {
        let context = try Self.store()
        let messages = try Self.thread(context, turns: 6, imagesPerTurn: 2)
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: Answer(), priorMessages: prior, events: events)
        }
        var provider = Provider(name: "p", endpoint: "http://127.0.0.1:9/v1", model: "vision", requiresAPIKey: false)
        provider.modelCapabilities = [.vision]
        _ = await llm.generate(provider: provider, thread: try #require(messages.last?.thread), systemPrompt: "s",
                               groundingAPIKey: nil, apiKey: "")
        #expect(llm.lastRequestDebugInfo?.imageLines == ["2 earlier images weren't sent, to keep the request small"])
    }

    private struct Answer: GenerationTransport {
        func runTurn(messages: [[String: Any]], includeTools: Bool,
                     onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
            onPartialContent("a cat"); return TurnOutput(content: "a cat")
        }
    }

    // MARK: The gate

    @Test func aMessageWithImagesToAModelThatCantSeeThemIsRefusedAndNothingIsSent() async throws {
        let context = try Self.store()
        let messages = try Self.thread(context, turns: 0, imagesPerTurn: 0)
        let question = try #require(messages.last)
        context.insert(ImageAttachment(id: UUID(), messageID: question.id, index: 0, mimeType: "image/jpeg", width: 1, height: 1,
                                       data: Data([1]), thumbnail: Data([1])))
        try context.save()
        let llm = ChatGeneration()
        let built = LockedBox(false)
        llm.makeLanguageModel = { _, _, prior, _, events in
            built.value = true
            return TransportLanguageModel(transport: Never(), priorMessages: prior, events: events)
        }
        let provider = Provider(name: "p", endpoint: "http://127.0.0.1:9/v1", model: "text-only", requiresAPIKey: false)
        let out = await llm.generate(provider: provider, thread: try #require(question.thread), systemPrompt: "s",
                                     groundingAPIKey: nil, apiKey: "")
        #expect(out.isEmpty)
        #expect(llm.lastError?.userMessage == ChatGeneration.cantSeeImagesMessage)
        #expect(!built.value, "no model was built, so nothing could be sent")
    }

    private struct Never: GenerationTransport {
        func runTurn(messages: [[String: Any]], includeTools: Bool,
                     onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
            Issue.record("a request was made"); return TurnOutput(content: "")
        }
    }
}

private final class BodyCapture: URLProtocol {
    static let bodies = LockedBox<[Data]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        }
        Self.bodies.value.append(data)
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
