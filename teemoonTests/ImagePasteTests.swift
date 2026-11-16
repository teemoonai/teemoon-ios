//
//  ImagePasteTests.swift
//  teemoonTests
//
//  docs/IMAGES.md §4c: a pasted image takes the picker's road. Its JPEG or PNG goes through
//  ImageIntake.fromBytes exactly as a picked photo's would; any other image (HEIC-only) is refused
//  without its bytes reaching a decoder; and what the composer does with the results is the paperclip's
//  path — addImages and its limit, or the can't-see-images note.
//

import Foundation
import Testing
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif
@testable import teemoon

@MainActor
@Suite("Images — paste")
struct ImagePasteTests {

    static let jpeg = ImageIntakeTests.encode(ImageIntakeTests.quadrants(), as: .jpeg)
    static let png = ImageIntakeTests.encode(ImageIntakeTests.quadrants(), as: .png)

    @Test func aPastedJPEGOrPNGIsReadExactlyAsAPickedOne() throws {
        let jpeg = PastedImage.imported(Self.jpeg, as: .jpeg).result
        #expect(jpeg == ImageIntake.fromBytes(Self.jpeg, declared: .jpeg))
        #expect((try? jpeg.get()) != nil)
        let png = PastedImage.imported(Self.png, as: .png).result
        #expect(png == ImageIntake.fromBytes(Self.png, declared: .png))
        #expect((try? png.get()) != nil)
        // Declared JPEG, PNG bytes: refused by the same magic-byte gate the picker's bytes meet.
        #expect(PastedImage.imported(Self.png, as: .jpeg).result == ImageIntake.fromBytes(Self.png, declared: .jpeg))
    }

    @Test func anImageNeitherPathReadsIsRefusedWithoutItsBytesReachingADecoder() {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg'><script>x</script></svg>".utf8)
        for (bytes, type) in [(svg, UTType.svg), (svg, .image), (Data("%PDF-1.7".utf8), .pdf), (Data([0, 0, 1, 0]), .ico)] {
            var decoded = 0
            let pasted = PastedImage.imported(bytes, as: type, decode: { _, _ in decoded += 1; return .failure(.corrupt) },
                                              system: { _ in decoded += 1; return .failure(.corrupt) })
            #expect(pasted.result == .failure(.unsupportedFormat), "\(type.identifier)")
            #expect(decoded == 0, "\(type.identifier) reached a decoder")
        }
        #expect(PastedImage.choice(offered: ["public.svg-image"]) == .refuse)
        var decoded: [ImageIntake.Format] = []
        _ = PastedImage.imported(Self.png, as: .png) { _, format in decoded.append(format); return .failure(.corrupt) }
        _ = PastedImage.imported(Self.jpeg, as: .jpeg) { _, format in decoded.append(format); return .failure(.corrupt) }
        #expect(decoded == [.png, .jpeg])
    }

    /// A GIF pastes like Messages: Wuffs decodes it (first frame), so paste takes it though the picker never needs to.
    @Test func aPastedGIFIsRead() throws {
        #expect(PastedImage.choice(offered: ["com.compuserve.gif"]) == .read(.gif, .gif))
        #expect(PastedImage.choice(offered: ["com.compuserve.gif", "public.png"]) == .read(.png, .png))
        let gif = ImageIntakeTests.encode(ImageIntakeTests.quadrants(), as: .gif)
        let pasted = PastedImage.imported(gif, as: .gif).result
        #expect(pasted == ImageIntake.fromBytes(gif, declared: .gif))
        #expect((try? pasted.get()) != nil)
        #expect(PickedImageTypes.accepted.map(\.0) == [.jpeg, .png], "the picker asks Photos for JPEG; paste alone adds GIF")
    }

    @Test func pastedImagesGoThroughThePickersLimitAndNotes() {
        let images: [Result<ImageIntake.Image, ImageIntake.Failure>] = (1...5).map { .success(ComposerImageTests.kept($0)) }
        let vm = ChatViewModel()
        vm.pasteImages(images, limit: 4)
        #expect(vm.pendingImages == images.prefix(4).compactMap { try? $0.get() })
        #expect(vm.imageNote == ChatViewModel.tooManyImagesMessage(limit: 4))

        let unreadable = ChatViewModel()
        unreadable.pasteImages([PastedImage.imported(Data([0, 1, 2]), as: .heic).result], limit: 10)
        #expect(unreadable.pendingImages.isEmpty)
        #expect(unreadable.imageNote == ChatViewModel.unreadableImageMessage)
    }

    // MARK: From UIKit: pasteboard type lists and item providers

    @Test func anItemsTypesChooseJPEGThenPNGAndAnyOtherImageIsRefused() {
        // A Photos Copy on iOS 27 (device, 2026-11-07).
        #expect(PastedImage.choice(offered: ["com.apple.uikit.image", "public.heic", "public.png", "public.jpeg"])
                == .read(.jpeg, .jpeg))
        #expect(PastedImage.choice(offered: ["public.png"]) == .read(.png, .png))
        #expect(PastedImage.choice(offered: ["public.heic"]) == .system(.heic))
        #expect(PastedImage.choice(offered: ["org.webmproject.webp", "public.tiff"]) == .system(.webP))
        #expect(PastedImage.choice(offered: ["public.utf8-plain-text"]) == .notAnImage)
        #expect(PastedImage.choice(offered: []) == .notAnImage)
    }

    @Test func itemProvidersBecomeResultsInOrderAndARefusedOneIsNeverLoaded() async {
        func provider(_ items: [(UTType, Data)], loaded: @escaping @Sendable (String) -> Void = { _ in }) -> NSItemProvider {
            let p = NSItemProvider()
            for (type, data) in items {
                p.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { done in
                    loaded(type.identifier)
                    done(data, nil)
                    return nil
                }
            }
            return p
        }
        let loads = LockedBox<[String]>([])
        let providers = [
            provider([(.png, Self.png)]),
            provider([(.ico, Data([1, 2, 3]))]) { id in loads.value.append(id) },
            provider([(.utf8PlainText, Data("hello".utf8))]),
            provider([(.ico, Data([4])), (.jpeg, Self.jpeg)]) { id in loads.value.append(id) },
        ]
        let decoded = LockedBox<[ImageIntake.Format]>([])
        let results = await withCheckedContinuation { done in
            PastedImage.load(providers, decode: { bytes, format in
                decoded.value.append(format)
                return ImageIntake.fromBytes(bytes, declared: format)
            }) { done.resume(returning: $0) }
        }
        #expect(results.count == 3)
        #expect(results.first == ImageIntake.fromBytes(Self.png, declared: .png))
        #expect(results.dropFirst().first == .failure(.unsupportedFormat))
        #expect(results.last == ImageIntake.fromBytes(Self.jpeg, declared: .jpeg))
        #expect(loads.value == [UTType.jpeg.identifier], "an ICO representation was loaded")
        #expect(decoded.value.count == 2 && decoded.value.contains(.png) && decoded.value.contains(.jpeg))
    }

    // MARK: A data: URL pasted as text (Brave on iOS, 2026-11-08: "Copy" of an image gave the composer the URL as text)

    static let jpegURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()

    @Test func aLoneDataURLInsertedIntoTheComposerIsRecognised() {
        let url = Self.jpegURL
        #expect(PastedImage.soleDataURL(before: "", after: url) == url)
        #expect(PastedImage.soleDataURL(before: "", after: " \n" + url + "\n ") == url)
        #expect(PastedImage.soleDataURL(before: "hello world", after: "hello " + url + "world") == url)
        // The caret sat before a "d": the inserted span is found though "d" also starts the URL.
        #expect(PastedImage.soleDataURL(before: "ad", after: "a" + url + "d") == url)
        // Pasted over a selection, also where the selection shares the URL's first or last character.
        #expect(PastedImage.soleDataURL(before: "replace me", after: url) == url)
        #expect(PastedImage.soleDataURL(before: "dummy text" + String(url.last!), after: url) == url)
        #expect(PastedImage.soleDataURL(before: "abcdef", after: url + "def") == url)
        let shouty = "DATA:IMAGE/JPEG;BASE64," + Self.jpeg.base64EncodedString()
        #expect(PastedImage.soleDataURL(before: "", after: shouty) == "data:IMAGE/JPEG;BASE64," + Self.jpeg.base64EncodedString())
        #expect((try? ImageIntake.fromDataURL(PastedImage.soleDataURL(before: "", after: shouty) ?? "").get()) != nil)
        // Any other data: URL is still a data URL here: intake refuses it, it is never text.
        for other in ["data:text/plain,hello", "data:image/png,rawbytes", "data:image/webp;base64,UklGRg==",
                      "data:image/jpeg;base64,!!!!"] {
            #expect(PastedImage.soleDataURL(before: "", after: other) == other, "\(other)")
        }
    }

    @Test func aDataURLAmongOtherWordsOrTypingStaysText() {
        let url = Self.jpegURL
        for after in ["look " + url, url + " and more", url + " " + url, "data:image", "data:no-comma-here",
                      "see data:,x", "the data: part"] {
            #expect(PastedImage.soleDataURL(before: "", after: after) == nil, "\(after.prefix(40))")
        }
        #expect(PastedImage.soleDataURL(before: "dat", after: "data") == nil)
        #expect(PastedImage.soleDataURL(before: url, after: url + "x") == nil)
        #expect(PastedImage.soleDataURL(before: url + "x", after: url) == nil)
        #expect(PastedImage.soleDataURL(before: "look ", after: "look " + url) == url, "the paste alone is the URL")
    }

    @Test func aPastedDataURLGoesThroughIntakeAndLeavesTheComposerAsItWas() async {
        let vm = ChatViewModel()
        vm.prompt = "hi " + Self.jpegURL
        await vm.takeDataURLPaste(before: "hi ", limit: 10)?.value
        #expect(vm.prompt == "hi ")
        #expect(vm.pendingImages == [try? ImageIntake.fromDataURL(Self.jpegURL).get()].compactMap { $0 })
        #expect(vm.pendingImages.count == 1)
        #expect(vm.imageNote == nil)

        vm.prompt = "hi there"
        #expect(vm.takeDataURLPaste(before: "hi ", limit: 10) == nil)
        #expect(vm.prompt == "hi there")
    }

    @Test func anUnreadableOrOversizedDataURLShowsTheNoteAndInsertsNothing() async {
        let huge = "data:image/jpeg;base64," + String(repeating: "A", count: ImageIntake.maxEncodedBytes / 3 * 4 + 8)
        for url in ["data:text/plain,hello", "data:image/png,rawbytes", "data:image/webp;base64,UklGRg==",
                    "data:image/jpeg;base64,!!!!", "data:image/jpeg;base64,", huge] {
            let vm = ChatViewModel()
            vm.prompt = url
            await vm.takeDataURLPaste(before: "", limit: 10)?.value
            #expect(vm.prompt.isEmpty, "\(url.prefix(40))")
            #expect(vm.pendingImages.isEmpty, "\(url.prefix(40))")
            #expect(vm.imageNote == ChatViewModel.unreadableImageMessage, "\(url.prefix(40))")
        }
    }

    @Test func aPastedDataURLKeepsTheLimit() async {
        let full = ChatViewModel()
        full.pendingImages = (1...4).map { ComposerImageTests.kept($0) }
        full.prompt = Self.jpegURL
        await full.takeDataURLPaste(before: "", limit: 4)?.value
        #expect(full.pendingImages.count == 4 && full.prompt.isEmpty)
        #expect(full.imageNote == ChatViewModel.tooManyImagesMessage(limit: 4))

    }

    // MARK: an item that offers an image is an image (Messages-like)

    static let url = "https://example.com/photos/cat.jpg"
    static func image(_ texts: String...) -> PastedImage.ItemText { .init(isImage: true, texts: texts) }
    static func text(_ texts: String...) -> PastedImage.ItemText { .init(isImage: false, texts: texts) }

    @Test func anImageItemsTextComesBackOutWhereverItWent() {
        #expect(PastedImage.keptText(before: "", after: Self.url, items: [Self.image(Self.url)]) == "")
        #expect(PastedImage.keptText(before: "hello world", after: "hello " + Self.url + "world", items: [Self.image(Self.url)]) == "hello world")
        #expect(PastedImage.keptText(before: "replace me", after: Self.url, items: [Self.image(Self.url)]) == "replace me")
        #expect(PastedImage.keptText(before: "", after: "a caption", items: [Self.image("a caption", Self.url)]) == "")
        #expect(PastedImage.keptText(before: "hs", after: "h" + Self.url + "s", items: [Self.image(Self.url)]) == "hs")
    }

    /// Case 6b (the maintainer 2026-11-09, Android 15ede5d1): once images attach, the whole paste comes out, a URL-only item's too.
    @Test func aURLItemBesideAnImageItemComesOutToo() {
        #expect(PastedImage.keptText(before: "", after: Self.url, items: [Self.image(), Self.text(Self.url)]) == "")
        #expect(PastedImage.keptText(before: "hello world", after: "hello " + Self.url + "world",
                                     items: [Self.text(Self.url), Self.image()]) == "hello world")
        for separator in ["\n", " "] {
            #expect(PastedImage.keptText(before: "ab", after: "a" + Self.url + separator + Self.url + "b",
                                         items: [Self.image(Self.url), Self.text(Self.url)]) == "ab")
        }
    }

    @Test func anEditThatIsNotThatPasteIsLeftAlone() {
        #expect(PastedImage.keptText(before: "", after: Self.url, items: [Self.text(Self.url)]) == nil, "text-only stays text")
        #expect(PastedImage.keptText(before: "", after: "typed words", items: [Self.image(Self.url)]) == nil)
        #expect(PastedImage.keptText(before: "", after: Self.url + "x", items: [Self.image(Self.url)]) == nil)
        #expect(PastedImage.keptText(before: "", after: "x", items: [Self.image()]) == nil)
    }

    @Test func onlyAURLPutInMayReadThePasteboard() {
        let data = "data:image/jpeg;base64," + Self.jpeg.base64EncodedString()
        #expect(PastedImage.mayHavePutInAURL(before: "", after: Self.url))
        #expect(PastedImage.mayHavePutInAURL(before: "", after: " HTTPS://EXAMPLE.COM/a.jpg\n"))
        #expect(PastedImage.mayHavePutInAURL(before: "", after: "http://example.com/a.jpg"))
        #expect(PastedImage.mayHavePutInAURL(before: "", after: data))
        #expect(PastedImage.mayHavePutInAURL(before: "replace me", after: Self.url))
        #expect(PastedImage.mayHavePutInAURL(before: "hello world", after: "hello " + Self.url + "world"))
        #expect(PastedImage.mayHavePutInAURL(before: "hs", after: "h" + Self.url + "s"), "the URL starts with the old text's next letter")
        #expect(PastedImage.mayHavePutInAURL(before: "ad", after: "a" + data + "d"))
        #expect(PastedImage.mayHavePutInAURL(before: "hx", after: Self.url), "over a selection that shares its first letter")
        #expect(!PastedImage.mayHavePutInAURL(before: "hell", after: "hello"), "one typed character")
        #expect(!PastedImage.mayHavePutInAURL(before: "hello", after: "hell"))
        #expect(!PastedImage.mayHavePutInAURL(before: "", after: "a caption the copy carried"), "plain text")
        #expect(!PastedImage.mayHavePutInAURL(before: "", after: Self.url + "\nthe words"), "a URL and words")
        #expect(!PastedImage.mayHavePutInAURL(before: "", after: "example.com/a.jpg"), "no scheme")
        #expect(!PastedImage.mayHavePutInAURL(before: Self.url, after: Self.url + "x"), "typing after a URL")
        #expect(PastedImage.mayHoldImageItemText([["public.jpeg", "public.url"]]))
        #expect(!PastedImage.mayHoldImageItemText([["public.url"]]), "no image")
        #expect(!PastedImage.mayHoldImageItemText([["public.png", "public.heic"]]), "no text")
        #expect(PastedImage.mayHoldImageItemText([["public.heic"], ["public.utf8-plain-text"]]))
    }

    @Test func thePasteboardIsNotReadForTypingAutocorrectDictationOrAnUnfocusedComposer() {
        var looked = 0
        let board: () -> PastedImage.Items = { looked += 1; return Self.browserCopy }
        let vm = ChatViewModel()
        // One typed character; autocorrect replacing a word; a suggestion; dictation's phrase; a pasted sentence.
        for (old, new) in [("hell", "hello"), ("i went to teh", "i went to the "), ("see you tom", "see you tomorrow "),
                           ("", "send the photo to my sister please"), ("note: ", "note: http is a protocol")] {
            vm.prompt = new
            #expect(vm.takeImageItemPaste(before: old, focused: true, from: board, limit: 10) == nil, "\(new)")
            #expect(vm.prompt == new)
        }
        vm.prompt = Self.url
        #expect(vm.takeImageItemPaste(before: "", focused: false, from: board, limit: 10) == nil)
        #expect(looked == 0, "the pasteboard was consulted for an edit that is not a URL paste")
        #expect(vm.prompt == Self.url)
    }

    @Test func aURLRepresentationReadsAsItsString() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: [Self.url, ""], format: .binary, options: 0)
        #expect(PastedImage.text(plist) == Self.url)
        let relative = try PropertyListSerialization.data(fromPropertyList: ["cat.jpg", "https://example.com/photos/"], format: .binary, options: 0)
        #expect(PastedImage.text(relative) == Self.url)
        #expect(PastedImage.text(Data("(a, b)".utf8)) == "(a, b)")
        #expect(PastedImage.text(Data(Self.url.utf8)) == Self.url)
    }

    static func board(_ items: [[String: Data]]) -> PastedImage.Items {
        PastedImage.Items(types: items.map { Array($0.keys).sorted() }) { items[$0][$1] }
    }

    static var browserCopy: PastedImage.Items {
        board([["public.jpeg": jpeg, "public.url": try! PropertyListSerialization.data(fromPropertyList: [url, ""], format: .binary, options: 0)]])
    }

    @Test func aBrowsersImageCopyAttachesTheJPEGAndLeavesTheComposerAsItWas() async {
        let vm = ChatViewModel()
        vm.prompt = "hi " + Self.url
        await vm.takeImageItemPaste(before: "hi ", focused: true, from: { Self.browserCopy }, limit: 10)?.value
        #expect(vm.prompt == "hi ")
        #expect(vm.pendingImages == [try? ImageIntake.fromBytes(Self.jpeg, declared: .jpeg).get()].compactMap { $0 })
        #expect(vm.imageNote == nil)

        vm.prompt = "hi there"
        #expect(vm.takeImageItemPaste(before: "hi ", focused: true, from: { Self.browserCopy }, limit: 10) == nil)
        #expect(vm.prompt == "hi there")
    }

    /// trip.com (the maintainer's device check, 2026-11-09): an app's UIImage beside its page URL pasted as the URL. UIKit
    /// stores that UIImage as `com.apple.uikit.image` holding PNG bytes (simulator probe 2026-11-11); it attaches.
    @Test func anAppsUIImageBesideItsURLAttachesTheImageAndNoText() async throws {
        #expect(PastedImage.choice(offered: ["com.apple.uikit.image", "public.url"]) == .sniff)
        #expect(PastedImage.choice(offered: ["com.apple.uikit.image", "public.png"]) == .read(.png, .png))
        let url = try PropertyListSerialization.data(fromPropertyList: [Self.url, ""], format: .binary, options: 0)
        for board in [Self.board([["com.apple.uikit.image": Self.png, "public.url": url]]),
                      Self.board([["com.apple.uikit.image": Self.png], ["public.url": url]])] {
            let vm = ChatViewModel()
            vm.prompt = Self.url
            await vm.takeImageItemPaste(before: "", focused: true, from: { board }, limit: 10)?.value
            #expect(vm.prompt == "")
            #expect(vm.pendingImages == [try ImageIntake.fromBytes(Self.png, declared: .png).get()])
        }
        // Its bytes are sniffed: a HEIC inside goes to the system decode, anything else is refused.
        let heic = ImageIntakeTests.encode(ImageIntakeTests.quadrants(), as: .heic)
        #expect((try? PastedImage.imported(heic, offered: "com.apple.uikit.image").result.get()) != nil)
        #expect(PastedImage.imported(Data("not an image".utf8), offered: "com.apple.uikit.image").result == .failure(.unsupportedFormat))
    }

    /// Brave (the maintainer's device check 2026-11-11): its Copy Image writes one item {public.jpeg, public.url} whose URL is an
    /// NSURL object in an item provider. That URL's bytes read back as a plist no string decoder took, so the URL stayed in.
    @Test func aBrowserURLWrittenAsAnObjectStillComesBackOut() async throws {
        let url = URL(string: Self.url)!
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { $0(Self.jpeg, nil); return nil }
        provider.registerObject(url as NSURL, visibility: .all)
        UIPasteboard.general.setItemProviders([provider], localOnly: true, expirationDate: nil)
        #expect(PastedImage.Items.general.texts(0) == [Self.url])
        let vm = ChatViewModel()
        vm.prompt = "hi " + Self.url
        await vm.takeImageItemPaste(before: "hi ", focused: true, from: { .general }, limit: 10)?.value
        #expect(vm.prompt == "hi ")
        #expect(vm.pendingImages == [try ImageIntake.fromBytes(Self.jpeg, declared: .jpeg).get()])
        UIPasteboard.general.items = []
    }

    /// S41 (the maintainer 2026-11-09, Android a9adbcd4): [{image only}, {text = data: URL}] attaches both, in item order.
    @Test func aDataURLItemBesideAnImageItemAttachesBothInOrder() async throws {
        let vm = ChatViewModel()
        vm.prompt = "hi " + Self.jpegURL
        let board = Self.board([["public.png": Self.png], ["public.utf8-plain-text": Data(Self.jpegURL.utf8)]])
        await vm.takeImageItemPaste(before: "hi ", focused: true, from: { board }, limit: 10)?.value
        #expect(vm.prompt == "hi ")
        #expect(vm.pendingImages == [try ImageIntake.fromBytes(Self.png, declared: .png).get(),
                                     try ImageIntake.fromBytes(Self.jpeg, declared: .jpeg).get()])
        #expect(vm.imageNote == nil)
    }

    @Test func anImageItemPasteKeepsTheLimitAndTheNotes() async {
        let full = ChatViewModel()
        full.pendingImages = (1...4).map { ComposerImageTests.kept($0) }
        full.prompt = Self.url
        await full.takeImageItemPaste(before: "", focused: true, from: { Self.browserCopy }, limit: 4)?.value
        #expect(full.pendingImages.count == 4 && full.prompt.isEmpty)
        #expect(full.imageNote == ChatViewModel.tooManyImagesMessage(limit: 4))

        let heic = ChatViewModel()
        heic.prompt = Self.url
        var reads: [String] = []
        let board = PastedImage.Items(types: [["public.svg-image", "public.utf8-plain-text"]]) { _, type in
            reads.append(type)
            return type == "public.svg-image" ? Data([0, 1, 2]) : Data(Self.url.utf8)
        }
        await heic.takeImageItemPaste(before: "", focused: true, from: { board }, limit: 10)?.value
        #expect(heic.prompt.isEmpty && heic.pendingImages.isEmpty)
        #expect(heic.imageNote == ChatViewModel.unreadableImageMessage)
        #expect(!reads.contains("public.svg-image"), "an SVG's bytes were read")

        // An unreadable image item beside a URL-only item: the note, and the URL goes in neither (6b).
        let beside = ChatViewModel()
        beside.prompt = Self.url
        let twoItems = Self.board([["public.heic": Data([0, 1, 2])], ["public.utf8-plain-text": Data(Self.url.utf8)]])
        await beside.takeImageItemPaste(before: "", focused: true, from: { twoItems }, limit: 10)?.value
        #expect(beside.prompt.isEmpty && beside.pendingImages.isEmpty)
        #expect(beside.imageNote == ChatViewModel.unreadableImageMessage)
    }
}
