//
//  ComposerImageTests.swift
//  teemoonTests
//
//  docs/IMAGES.md §4, §4a: what the composer may hold and send, and the picker contract audit asked
//  for — teemoon only ever asks the picker for a JPEG (or PNG) representation, never the original
//  HEIC / Live Photo / RAW container, and a picked photo's GPS does not survive.
//

import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif
@testable import teemoon

@MainActor
@Suite("Images — composer and picker")
struct ComposerImageTests {

    static func kept(_ n: Int = 1) -> ImageIntake.Image {
        ImageIntake.Image(mimeType: "image/jpeg", width: 4, height: 3, data: Data(repeating: UInt8(n), count: 10),
                          thumbnail: Data([UInt8(n)]))
    }

    @Test func tenToTheCloudFourOnDeviceAndAnUnreadableOneSaysSo() {
        #expect(ChatViewModel.imagesPerSend(localModelID: nil) == 10)
        #expect(ChatViewModel.imagesPerSend(localModelID: "litert-community/gemma-4-E4B-it-litert-lm") == 4)
        #expect(ChatGeneration.maxImagesPerRequest == 10 && ChatGeneration.maxImageBytesPerRequest == 8 * 1024 * 1024)
        let cloud = ChatViewModel()
        cloud.addImages((1...11).map { .success(Self.kept($0)) }, limit: 10)
        #expect(cloud.pendingImages.count == 10)
        #expect(cloud.imageNote == "up to 10 images per message")

        let vm = ChatViewModel()
        vm.addImages([.success(Self.kept(1)), .success(Self.kept(2)), .success(Self.kept(3))], limit: 4)
        #expect(vm.pendingImages.count == 3 && vm.imageNote == nil)
        vm.addImages([.success(Self.kept(4)), .success(Self.kept(5))], limit: 4)
        #expect(vm.pendingImages.count == 4)
        #expect(vm.imageNote == "up to 4 images per message")
        vm.removePendingImage(at: 0)
        vm.addImages([.failure(.corrupt)], limit: 4)
        #expect(vm.pendingImages.count == 3 && vm.imageNote == ChatViewModel.unreadableImageMessage)
        vm.removePendingImage(at: 99)   // out of range: nothing happens
        #expect(vm.pendingImages.count == 3)
    }

    @Test func anImageAloneIsSomethingToSendButNotToAModelThatCantSeeIt() {
        let vm = ChatViewModel()
        #expect(vm.hasNothingToSend)
        vm.addImages([.success(Self.kept())], limit: 10)
        #expect(!vm.hasNothingToSend)
        #expect(vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: false, trust: .allow, seesImages: true) == .ready)
        #expect(vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: false, trust: .allow, seesImages: false)
                == .blockedImagesUnsupported)
        vm.removePendingImage(at: 0)
        vm.prompt = "text only"
        #expect(vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: false, trust: .allow, seesImages: false) == .ready)
    }

    /// Android 888d0c88 cleared the draft before refusing, so "choose an image-capable model" carried nothing.
    @Test func aRefusedSendLeavesTheTextAndImagesExactlyAsTheyWere() {
        let vm = ChatViewModel()
        vm.prompt = "what is this"
        vm.addImages([.success(Self.kept()), .success(Self.kept())], limit: 10)
        let before = vm.pendingImages.map(\.data)
        #expect(vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: false, trust: .allow, seesImages: false)
                == .blockedImagesUnsupported)
        #expect(vm.prompt == "what is this")
        #expect(vm.pendingImages.map(\.data) == before)
        #expect(ComposerImageMachine.next(.attached, .sendBlind).1 == [.showRefusedAlert])
        #expect(!ComposerImageMachine.next(.attached, .alertChooseModel).1.contains(.removeAll))
    }

    @Test func sendingStoresTheImagesWithTheMessageAndClearsTheComposer() async throws {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ProviderStore(inMemory: true)
        var provider = Provider(name: "p", endpoint: "http://127.0.0.1:9/v1", model: "m", requiresAPIKey: false)
        provider.modelCapabilities = [.vision]
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: Echo(), priorMessages: prior, events: events)
        }
        let vm = ChatViewModel()
        vm.prompt = "what is this?"
        vm.addImages([.success(Self.kept(1)), .success(Self.kept(2))], limit: 10)
        var thread: ChatThread?
        vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                    providers: store, session: ConfidentialSession(providers: store), llm: llm)
        #expect(vm.pendingImages.isEmpty && vm.prompt.isEmpty)
        let question = try #require(thread?.sortedMessages.first { $0.role == .user })
        let images = ImageAttachment.images(of: question)
        #expect(images.map(\.index) == [0, 1])
        #expect(images.map(\.data) == [Self.kept(1).data, Self.kept(2).data])
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// A photo still loading when send was tapped: the text went alone and the photo landed in the emptied composer.
    @Test func aPhotoStillLoadingHoldsTheSendAndThenGoesWithTheText() async throws {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ProviderStore(inMemory: true)
        var provider = Provider(name: "p", endpoint: "http://127.0.0.1:9/v1", model: "m", requiresAPIKey: false)
        provider.modelCapabilities = [.vision]
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: Echo(), priorMessages: prior, events: events)
        }
        let vm = ChatViewModel()
        vm.prompt = "hi"
        var finish: (([Result<ImageIntake.Image, ImageIntake.Failure>]) -> Void)?
        vm.loadImages(count: 1, limit: 10) { finish = $0 }
        #expect(vm.imagesLoading == 1)
        #expect(!vm.canSend)
        #expect(vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: false, trust: .allow) == .blockedImagesLoading)

        var thread: ChatThread?
        func send() {
            vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                        providers: store, session: ConfidentialSession(providers: store), llm: llm)
        }
        send()
        #expect(thread == nil, "nothing went out while the photo loaded")
        #expect(vm.prompt == "hi")

        let done = try #require(finish)
        done([.success(Self.kept(1))])
        #expect(vm.imagesLoading == 0 && vm.pendingImages.count == 1)
        #expect(vm.canSend)
        send()
        #expect(vm.pendingImages.isEmpty && vm.prompt.isEmpty)
        let question = try #require(thread?.sortedMessages.first { $0.role == .user })
        #expect(question.content == "hi")
        #expect(ImageAttachment.images(of: question).map(\.data) == [Self.kept(1).data])
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aFailedLoadDropsItsPlaceholderAndSaysItCouldNotBeRead() throws {
        let vm = ChatViewModel()
        vm.prompt = "hi"
        var finish: (([Result<ImageIntake.Image, ImageIntake.Failure>]) -> Void)?
        vm.loadImages(count: 2, limit: 10) { finish = $0 }
        #expect(vm.imagesLoading == 2)
        let done = try #require(finish)
        done([.success(Self.kept(1)), .failure(.corrupt)])
        #expect(vm.imagesLoading == 0)
        #expect(vm.pendingImages.count == 1)
        #expect(vm.imageNote == ChatViewModel.unreadableImageMessage)
        #expect(vm.prompt == "hi" && vm.canSend)
    }

    #if os(iOS)
    /// A data: URL paste counts from the moment it is taken, before its decode starts.
    @Test func aPastedDataURLCountsAsLoadingUntilItDecodes() async throws {
        let vm = ChatViewModel()
        vm.prompt = "hi data:image/png;base64,AAAA"
        let task = vm.takeDataURLPaste(before: "hi ", limit: 10)
        #expect(task != nil)
        #expect(vm.imagesLoading == 1 && !vm.canSend)
        await task?.value
        #expect(vm.imagesLoading == 0)
        #expect(vm.imageNote == ChatViewModel.unreadableImageMessage)
    }
    #endif

    #if os(iOS)
    /// the maintainer 2026-11-14 (Claude dims send while a photo loads): with text typed, a send during a pasted photo's decode
    /// went out as the text alone and the photo landed afterwards in the emptied composer.
    @Test func aSendDuringAPhotosDecodeNeverGoesWithoutIt() async throws {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ProviderStore(inMemory: true)
        var provider = Provider(name: "p", endpoint: "http://127.0.0.1:9/v1", model: "m", requiresAPIKey: false)
        provider.modelCapabilities = [.vision]
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: Echo(), priorMessages: prior, events: events)
        }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).pngData { ctx in
            UIColor.systemOrange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let vm = ChatViewModel()
        vm.prompt = "hi data:image/png;base64," + png.base64EncodedString()
        let decoding = try #require(vm.takeDataURLPaste(before: "hi", limit: 10))
        var thread: ChatThread?
        func send() {
            vm.generate(currentThread: &thread, modelContext: container.mainContext, settings: AppSettings(),
                        providers: store, session: ConfidentialSession(providers: store), llm: llm)
        }
        send()
        await decoding.value
        if thread == nil { send() }
        let question = try #require(thread?.sortedMessages.first { $0.role == .user })
        #expect(question.content == "hi")
        #expect(ImageAttachment.images(of: question).count == 1, "the text went out without the photo")
        #expect(vm.pendingImages.isEmpty, "the photo landed in the emptied composer")
        for _ in 0..<200 where vm.generatingThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
    }

    #endif

    private struct Echo: GenerationTransport {
        func runTurn(messages: [[String: Any]], includeTools: Bool,
                     onPartialContent: @escaping @Sendable (String) -> Void) async throws -> TurnOutput {
            onPartialContent("ok"); return TurnOutput(content: "ok")
        }
    }

    // MARK: The picker contract

    /// Only JPEG or PNG is ever requested: a HEIC, Live Photo or RAW item is asked for its JPEG
    /// representation (the system transcodes it outside teemoon), never its own type.
    @Test func thePickerOnlyEverRequestsJPEGOrPNG() {
        let heic = PickedImageTypes.choice(registered: ["public.heic", "com.apple.live-photo-bundle"])
        #expect(heic?.0 == .jpeg && heic?.1 == .jpeg)
        let raw = PickedImageTypes.choice(registered: ["com.adobe.raw-image", "public.camera-raw-image"])
        #expect(raw?.0 == .jpeg)
        #expect(PickedImageTypes.choice(registered: ["public.png"])?.0 == .png)
        #expect(PickedImageTypes.choice(registered: ["public.jpeg", "public.heic"])?.0 == .jpeg)
        #expect(PickedImageTypes.choice(registered: []) == nil)
        for registered in [["public.heic"], ["public.png"], ["com.adobe.raw-image"], ["org.webmproject.webp"]] {
            let t = PickedImageTypes.choice(registered: registered)?.0
            #expect(t == .jpeg || t == .png, "\(registered) requested \(String(describing: t))")
        }
    }

    /// The picker's JPEG keeps EXIF, GPS included (audit, 2026-10-25): it must not survive intake.
    @Test func aPickedPhotoWithGPSKeepsNoLocation() throws {
        let ctx = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let picked = NSMutableData()
        let dest = CGImageDestinationCreateWithData(picked, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 2.35, kCGImagePropertyGPSLongitudeRef: "E",
                                            kCGImagePropertyGPSAltitude: 35.0],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 16 Pro"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let kept = try ImageIntake.fromBytes(picked as Data, declared: .jpeg).get()
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(kept.data as CFData, nil)!, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyGPSDictionary] == nil, "the location survived")
        #expect((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil)
        #expect(!kept.data.contains(Data("iPhone 16 Pro".utf8)))
        for thumb in [kept.thumbnail] {
            let p = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(thumb as CFData, nil)!, 0, nil) as! [CFString: Any]
            #expect(p[kCGImagePropertyGPSDictionary] == nil)
        }
    }
}
