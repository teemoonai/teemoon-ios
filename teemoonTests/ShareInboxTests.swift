//
//  ShareInboxTests.swift
//  teemoonTests
//
//  docs/SHARE_IN.md: the share extension copies into `Inbox/<uuid>/`, teemoon takes the newest entry into a new
//  chat's composer and never sends. Over a cap or unreadable, nothing is kept. An entry older than
//  `ShareInbox.expiry` is purged when the app or the extension next starts; the inbox is out of backups and
//  `.completeUnlessOpen` (the simulator reads the protection class back as nil, so it is asserted only where it does).
//

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import teemoon

@Suite("Share — inbox")
struct ShareInboxTests {

    static func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "share-inbox-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Everything under `Inbox/`, staging folders included.
    static func onDisk(_ root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Inbox").path)) ?? []
    }

    /// A shareable PNG file `width` wide, so order survives the intake's re-encoding.
    static func pngFile(width: Int, in dir: URL) throws -> URL {
        let url = dir.appending(path: "shared-\(width)-\(UUID().uuidString).png")
        try ImageIntakeTests.encode(ImageIntakeTests.quadrants(width: width, height: 20), as: .png).write(to: url)
        return url
    }

    /// Every `image-` file anywhere under `root`.
    static func imageFiles(under root: URL) -> [URL] {
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("image-") }
    }

    static func sparseFile(bytes: Int, in dir: URL) throws -> URL {
        let url = dir.appending(path: "big-\(UUID().uuidString).jpg")
        FileManager.default.createFile(atPath: url.path, contents: Data([0xFF, 0xD8, 0xFF]))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return url
    }

    @Test func theImageCapIsTheIntakes() {
        #expect(ShareInbox.maxImageBytes == ImageIntake.maxEncodedBytes)
        #expect(ShareInbox.maxImages == 10)
        #expect(ShareInbox.maxTextCharacters == 100_000)
    }

    @Test func elevenImagesKeepNothing() throws {
        let root = Self.tempRoot(), source = Self.tempRoot()
        let images = try (1...11).map { ShareInbox.Item.image(try Self.pngFile(width: 20 + $0, in: source)) }
        let inbox = ShareInbox(root: root)
        #expect(inbox.write(images) == .failure(.overCap))
        #expect(Self.onDisk(root).isEmpty)
        #expect(inbox.take() == nil)
        // Ten is the cap, not over it.
        #expect((try? inbox.write(Array(images.prefix(10))).get()) != nil)
    }

    @Test func anImageOneByteOverTwentyMiBKeepsNothing() throws {
        let root = Self.tempRoot(), source = Self.tempRoot()
        let small = try Self.pngFile(width: 30, in: source)
        let big = try Self.sparseFile(bytes: ShareInbox.maxImageBytes + 1, in: source)
        let inbox = ShareInbox(root: root)
        #expect(inbox.write([.image(small), .image(big), .text("look")]) == .failure(.overCap))
        #expect(Self.onDisk(root).isEmpty)
        let atCap = try Self.sparseFile(bytes: ShareInbox.maxImageBytes, in: source)
        #expect((try? inbox.write([.image(atCap)]).get()) != nil)
    }

    @Test func textOverOneHundredThousandCharactersKeepsNothing() {
        let root = Self.tempRoot()
        let inbox = ShareInbox(root: root)
        // Its own refusal: the extension says "more text", not "10 photos, 20 MB each".
        #expect(inbox.write([.text(String(repeating: "a", count: 100_001))]) == .failure(.textOverCap))
        #expect(Self.onDisk(root).isEmpty)
        #expect((try? inbox.write([.text(String(repeating: "a", count: 100_000))]).get()) != nil)
    }

    @Test func anUnreadableImageKeepsNothing() throws {
        let root = Self.tempRoot(), source = Self.tempRoot()
        let good = try Self.pngFile(width: 30, in: source)
        let missing = source.appending(path: "gone.jpg")
        let inbox = ShareInbox(root: root)
        #expect(inbox.write([.image(good), .image(missing)]) == .failure(.unreadable))
        #expect(Self.onDisk(root).isEmpty)
        #expect(inbox.write([]) == .failure(.unreadable), "nothing shared is nothing to open")
    }

    @Test func aWrittenEntryIsTakenInShareOrderAndItsFolderGoes() throws {
        let root = Self.tempRoot(), source = Self.tempRoot()
        let a = try Self.pngFile(width: 41, in: source), b = try Self.pngFile(width: 42, in: source)
        let inbox = ShareInbox(root: root)
        let id = try inbox.write([.image(a), .text("fact check"), .image(b),
                                  .link(URL(string: "https://example.com/a?b=c")!)]).get()
        #expect(inbox.contains(id))
        let entry = try #require(inbox.take())
        #expect(entry.id == id)
        #expect(entry.text == "fact check\nhttps://example.com/a?b=c")
        #expect(!inbox.contains(id))
        #expect(Self.onDisk(root).isEmpty)
        #expect(inbox.take() == nil)
        #expect(entry.imageFiles.count == 2, "take moves the photos out; it does not read them")
        #expect(entry.readImages() == [try Data(contentsOf: a), try Data(contentsOf: b)])
        #expect(Self.imageFiles(under: root).isEmpty, "the taken folder goes after the read")
    }

    @Test func theNewestEntryWinsAndOlderOnesGo() throws {
        let root = Self.tempRoot()
        let inbox = ShareInbox(root: root)
        let older = try inbox.write([.text("older")]).get()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                              ofItemAtPath: root.appending(path: "Inbox/\(older.uuidString)").path)
        let newer = try inbox.write([.text("newer")]).get()
        let entry = try #require(inbox.take())
        #expect(entry.id == newer)
        #expect(entry.text == "newer")
        #expect(!inbox.contains(older))
        #expect(inbox.take() == nil)
    }

    static func age(_ path: String, in root: URL, days: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -days * 86_400)],
                                              ofItemAtPath: root.appending(path: path).path)
    }

    @Test func theExpiryIsSevenDays() {
        #expect(ShareInbox.expiry == 7 * 86_400)
    }

    @Test func anEntryPastTheExpiryIsPurgedAndNeverTaken() throws {
        let root = Self.tempRoot()
        let inbox = ShareInbox(root: root)
        let id = try inbox.write([.text("from last week")]).get()
        try Self.age("Inbox/\(id.uuidString)", in: root, days: 7.1)
        inbox.purgeExpired()
        #expect(!inbox.contains(id))
        #expect(Self.onDisk(root).isEmpty)
        #expect(inbox.take() == nil)
    }

    @Test func takeNeverHandsOverAnExpiredEntry() throws {
        let root = Self.tempRoot()
        let inbox = ShareInbox(root: root)
        let id = try inbox.write([.text("from last week")]).get()
        try Self.age("Inbox/\(id.uuidString)", in: root, days: 8)
        #expect(inbox.take() == nil, "an app that starts by taking still applies the expiry")
        #expect(Self.onDisk(root).isEmpty)
    }

    @Test func anEntryInsideTheExpiryStillArrives() throws {
        let root = Self.tempRoot()
        let inbox = ShareInbox(root: root)
        let id = try inbox.write([.text("shared before the phone locked")]).get()
        try Self.age("Inbox/\(id.uuidString)", in: root, days: 6.9)
        inbox.purgeExpired()
        #expect(inbox.take()?.text == "shared before the phone locked")
    }

    /// The extension writes, the phone locks, teemoon opens later: the start-up purge must not eat the share.
    /// (The lock itself is device-only; `.completeUnlessOpen` lets the extension finish a file it opened.)
    @Test func aShareMadeJustBeforeLockArrivesWhenTeemoonOpens() throws {
        let root = Self.tempRoot(), source = Self.tempRoot()
        let inbox = ShareInbox(root: root)
        let png = try Self.pngFile(width: 43, in: source)
        let id = try inbox.write([.image(png), .text("just before lock")]).get()
        ShareInbox(root: root).purgeExpired()
        let entry = try #require(ShareInbox(root: root).take())
        #expect(entry.id == id)
        #expect(entry.text == "just before lock")
        #expect(entry.readImages() == [try Data(contentsOf: png)])
    }

    @Test func stagingAndTakenLeftoversPastTheExpiryArePurged() throws {
        let root = Self.tempRoot(), source = Self.tempRoot()
        let fm = FileManager.default
        let staging = root.appending(path: "Inbox/.\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Self.age("Inbox/\(staging.lastPathComponent)", in: root, days: 8)
        let inbox = ShareInbox(root: root)
        _ = try inbox.write([.image(try Self.pngFile(width: 44, in: source))]).get()
        let entry = try #require(inbox.take())
        let takenFolder = try #require(entry.imageFiles.first?.deletingLastPathComponent())
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 86_400)], ofItemAtPath: takenFolder.path)
        inbox.purgeExpired()
        #expect(Self.onDisk(root).isEmpty, "a killed extension's staging folder goes")
        #expect(Self.imageFiles(under: root).isEmpty, "an unread taken folder goes")
    }

    static func tree(_ url: URL) -> [URL] {
        [url] + (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
    }

    static func expectHardened(_ urls: [URL]) throws {
        for url in urls {
            let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true, "\(url.lastPathComponent) is in backups")
            if let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType {
                #expect(protection == .completeUnlessOpen, "\(url.lastPathComponent) is \(protection.rawValue)")
            }
        }
    }

    @Test func theInboxIsOutOfBackupsAndCompleteUnlessOpen() throws {
        let root = Self.tempRoot(), source = Self.tempRoot()
        let inbox = ShareInbox(root: root)
        _ = try inbox.write([.image(try Self.pngFile(width: 45, in: source)), .text("t")], unreadable: 1).get()
        let written = Self.tree(root.appending(path: "Inbox"))
        #expect(written.count == 5, "Inbox, the entry, its image, text and unreadable files")
        try Self.expectHardened(written)
        _ = try #require(inbox.take())
        let taken = Self.tree(root.appending(path: "Taken"))
        #expect(taken.count == 5, "Taken, the entry, its image, text and unreadable files")
        try Self.expectHardened(taken)
    }

    @Test func takeOnAnEmptyInboxIsNil() {
        #expect(ShareInbox(root: Self.tempRoot()).take() == nil)
        #expect(ShareInbox(root: Self.tempRoot().appending(path: "never-made")).take() == nil)
    }

    @Test func theLinkAndGroupAreTheBundlesOwn() throws {
        let id = UUID()
        let link = try #require(ShareInbox.link(for: id, bundleID: "ai.teemoon.app.dev"))
        #expect(link.absoluteString == "ai.teemoon.app.dev://share/\(id.uuidString)")
        #expect(ShareInbox.entryID(from: link, bundleID: "ai.teemoon.app.dev") == id)
        #expect(ShareInbox.entryID(from: link, bundleID: "ai.teemoon.app") == nil, "a dev share never opens the store app")
        #expect(ShareInbox.entryID(from: URL(string: "ai.teemoon.app.dev://other/\(id.uuidString)")!,
                                   bundleID: "ai.teemoon.app.dev") == nil)
        #expect(ShareInbox.appGroupID(bundleID: "ai.teemoon.app.dev") == "group.ai.teemoon.app.dev")
    }

    @Test func theExtensionFindsItsAppsBundleID() {
        #expect(ShareInbox.appBundleID(extensionBundleID: "ai.teemoon.app.dev.share") == "ai.teemoon.app.dev")
        #expect(ShareInbox.appBundleID(extensionBundleID: "ai.teemoon.app.share") == "ai.teemoon.app")
        #expect(ShareInbox.appBundleID(extensionBundleID: "ai.teemoon.app") == nil)
    }

    @Test func imagesTheExtensionCouldNotReadTravelWithTheEntry() throws {
        let root = Self.tempRoot(), source = Self.tempRoot()
        let inbox = ShareInbox(root: root)
        _ = try inbox.write([.image(try Self.pngFile(width: 30, in: source))], unreadable: 2).get()
        #expect(inbox.take()?.unreadable == 2)
        _ = try inbox.write([.text("plain")]).get()
        #expect(inbox.take()?.unreadable == 0)
    }

    @Test func anImageFileTeemoonCannotReadStillReachesTheIntake() throws {
        let root = Self.tempRoot(), source = Self.tempRoot()
        let inbox = ShareInbox(root: root)
        let id = try inbox.write([.image(try Self.pngFile(width: 30, in: source))]).get()
        let folder = root.appending(path: "Inbox/\(id.uuidString)")
        let image = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.path).first { $0.hasPrefix("image-") })
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.appending(path: image).path)
        let entry = try #require(inbox.take())
        let images = entry.readImages()
        #expect(images.count == 1, "an unreadable file is an image the intake refuses, not a share of nothing")
        #expect(images.first?.isEmpty == true)
    }
}

@Suite("Share — the jump")
struct ShareJumpTests {

    @Test func theSwitchReadsTheBuildSetting() {
        #expect(ShareJump.shouldJump(flag: nil), "YES by default")
        #expect(ShareJump.shouldJump(flag: "YES"))
        #expect(ShareJump.shouldJump(flag: true))
        #expect(!ShareJump.shouldJump(flag: "NO"))
        #expect(!ShareJump.shouldJump(flag: "no"))
        #expect(!ShareJump.shouldJump(flag: false))
        #expect(!ShareJump.shouldJump(flag: "0"))
    }

    @Test func switchOffAlwaysFallsBack() {
        for returned in [true, false] {
            for active in [true, false] {
                #expect(ShareJump.outcome(jumps: false, openReturned: returned, appBecameActive: active) == .fallback)
            }
        }
    }

    @Test func anOpenThatFailsFallsBack() {
        #expect(ShareJump.outcome(jumps: true, openReturned: false, appBecameActive: false) == .fallback)
        #expect(ShareJump.outcome(jumps: true, openReturned: true, appBecameActive: false) == .fallback,
                "open said yes but teemoon never came up within the wait")
        #expect(ShareJump.outcome(jumps: true, openReturned: true, appBecameActive: true) == .opened)
        #expect(ShareJump.openWait == 1.5)
    }

    @Test func theActivationRuleIsTheSpecsDictionary() throws {
        let plist = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "teemoonShare/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
        let ext = try #require(info["NSExtension"] as? [String: Any])
        #expect(ext["NSExtensionPointIdentifier"] as? String == "com.apple.share-services")
        let attributes = try #require(ext["NSExtensionAttributes"] as? [String: Any])
        let rule = try #require(attributes["NSExtensionActivationRule"] as? [String: Any], "a dictionary, never TRUEPREDICATE")
        #expect(rule.count == 3)
        #expect(rule["NSExtensionActivationSupportsImageWithMaxCount"] as? Int == ShareInbox.maxImages)
        #expect(rule["NSExtensionActivationSupportsText"] as? Bool == true)
        #expect(rule["NSExtensionActivationSupportsWebURLWithMaxCount"] as? Int == 1)
        #expect(info["SHARE_OPENS_APP"] as? String == "$(SHARE_OPENS_APP)")
        #expect(info["CFBundleDisplayName"] as? String == "$(APP_DISPLAY_NAME:default=teemoon)", "the app's own name, dev included")
    }

    @Test func theExtensionIsDarkAndWearsTheAppsAccent() throws {
        let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let info = try #require(NSDictionary(contentsOf: repo.appending(path: "teemoonShare/Info.plist")) as? [String: Any])
        #expect(info["UIUserInterfaceStyle"] as? String == "Dark", "the app is dark-only; so is its share sheet")
        let colorset = "Assets.xcassets/AccentColor.colorset/Contents.json"
        let app = try Data(contentsOf: repo.appending(path: "teemoon/" + colorset))
        let share = try Data(contentsOf: repo.appending(path: "teemoonShare/" + colorset))
        #expect(try JSONSerialization.jsonObject(with: share) as? NSDictionary
                == JSONSerialization.jsonObject(with: app) as? NSDictionary, "the same orange as the app")
        let project = try String(contentsOf: repo.appending(path: "teemoon.xcodeproj/project.pbxproj"), encoding: .utf8)
        let shareConfigs = project.components(separatedBy: "/* Begin XCBuildConfiguration section */")[1]
            .components(separatedBy: "isa = XCBuildConfiguration;")
            .filter { $0.contains("INFOPLIST_FILE = teemoonShare/Info.plist;") }
        #expect(shareConfigs.count == 2)
        for config in shareConfigs {
            #expect(config.contains("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;"))
        }
    }

    @Test func eachSharedItemIsReadAsItsKind() {
        #expect(ShareJump.kind(of: ["public.heic"]) == .image("public.heic"))
        #expect(ShareJump.kind(of: ["public.file-url", "public.jpeg"]) == .image("public.jpeg"), "Files hands a URL and the image")
        #expect(ShareJump.kind(of: ["public.png"]) == .image("public.png"))
        #expect(ShareJump.kind(of: ["org.webmproject.webp"]) == .image("org.webmproject.webp"))
        #expect(ShareJump.kind(of: ["public.url"]) == .link)
        #expect(ShareJump.kind(of: ["public.url", "public.plain-text"]) == .link)
        #expect(ShareJump.kind(of: ["public.plain-text"]) == .text)
        #expect(ShareJump.kind(of: ["public.utf8-plain-text"]) == .text)
        #expect(ShareJump.kind(of: ["public.file-url"]) == nil, "a file that is not an image is not offered")
        #expect(ShareJump.kind(of: ["com.adobe.pdf"]) == nil)
        #expect(ShareJump.kind(of: ["public.mpeg-4"]) == nil)
        #expect(ShareJump.kind(of: []) == nil)
    }

    @Test func overACapNothingIsCopied() {
        let images = (0..<11).map { _ in ShareJump.Kind.image("public.jpeg") }
        #expect(ShareJump.precheck(images) == ShareJump.Line.overCap)
        #expect(ShareJump.precheck(Array(images.prefix(10)) + [.text]) == nil)
        #expect(ShareJump.precheck([]) == ShareJump.Line.nothingRead)
    }

    @Test func theLinesAreTheSpecs() {
        #expect(ShareJump.Line.opening == "opening teemoon…")
        #expect(ShareJump.Line.fallback == "it's in teemoon's composer next time you open it.")
        #expect(ShareJump.Line.overCap == "that's more than teemoon can take at once: up to 10 photos, 20 MB each.")
        #expect(ShareJump.Line.textOverCap == "that's more text than teemoon can take at once: up to 100,000 characters.")
        #expect(ShareJump.Line.nothingRead == "teemoon couldn't read what was shared.")
        #expect(ShareJump.Line.done == "done")
        #expect(ShareJump.Line.unreadable(0) == nil)
        #expect(ShareJump.Line.unreadable(1) == "1 image couldn't be read")
        #expect(ShareJump.Line.unreadable(3) == "3 images couldn't be read")
        #expect(ShareJump.progressDelay == 0.3)
    }

    @Test func afterTheCopyEachRefusalHasItsLineAndKeepsNothing() {
        #expect(ShareJump.step(after: .failure(.overCap), unreadable: 0, jumps: true) == .refuse(ShareJump.Line.overCap))
        #expect(ShareJump.step(after: .failure(.textOverCap), unreadable: 0, jumps: true)
                == .refuse(ShareJump.Line.textOverCap))
        #expect(ShareJump.step(after: .failure(.unreadable), unreadable: 2, jumps: true)
                == .refuse(ShareJump.Line.nothingRead))
    }

    @Test func aWrittenEntryJumpsUnlessTheSwitchIsOff() {
        let id = UUID()
        #expect(ShareJump.step(after: .success(id), unreadable: 0, jumps: true) == .open(id, note: nil))
        #expect(ShareJump.step(after: .success(id), unreadable: 1, jumps: true)
                == .open(id, note: "1 image couldn't be read"))
        #expect(ShareJump.step(after: .success(id), unreadable: 0, jumps: false) == .fallback(id, note: nil))
        #expect(ShareJump.step(after: .success(id), unreadable: 2, jumps: false)
                == .fallback(id, note: "2 images couldn't be read"))
    }

    @Test func aFailedOpenKeepsTheEntryForTheNextOpen() throws {
        let inbox = ShareInbox(root: ShareInboxTests.tempRoot())
        let id = try inbox.write([.text("keep me")]).get()
        #expect(ShareJump.outcome(jumps: true, openReturned: false, appBecameActive: false) == .fallback)
        #expect(inbox.contains(id))
        #expect(inbox.take()?.text == "keep me")
    }
}

#if os(iOS)

/// the maintainer 2026-11-14, device trace (iOS 27.2.1, a second share from Photos with teemoon left keyboard-up): iOS restored
/// the old keyboard with no animation (the panel jumped up with nothing drawn under it), then hid it as the share
/// sheet's app gave the keyboard back (the panel dropped), then UIKit refocused the field (the panel rose again).
@Suite("Share — the keyboard on open")
struct ShareFocusTests {
    @Test func aShareBeforeActiveDropsTheOldKeyboardAndAsksOnceActive() {
        #expect(ShareFocus.plan(sceneActive: false) == .dropThenOnActive)
    }

    @Test func aShareWhileActiveAsksNow() {
        #expect(ShareFocus.plan(sceneActive: true) == .now)
    }
}

@MainActor
@Suite("Share — into the composer")
struct ShareComposerTests {

    @Test func aTakenEntryFillsTheComposerInOrderAndSendsNothing() async throws {
        let root = ShareInboxTests.tempRoot(), source = ShareInboxTests.tempRoot()
        let inbox = ShareInbox(root: root)
        _ = try inbox.write([.image(try ShareInboxTests.pngFile(width: 51, in: source)), .text("fact check"),
                             .image(try ShareInboxTests.pngFile(width: 52, in: source)),
                             .link(URL(string: "https://example.com/x")!)]).get()
        let vm = ChatViewModel()
        vm.prompt = "an old draft"
        vm.pendingImages = [ComposerImageTests.kept(1)]
        let task = try #require(vm.takeShare(from: inbox))
        #expect(vm.prompt == "fact check\nhttps://example.com/x", "the text is there before the photos decode")
        await task.value
        #expect(vm.pendingImages.map(\.width) == [51, 52])
        #expect(vm.imageNote == nil)
        #expect(vm.generatingThreadID == nil, "a share never sends")
        #expect(ShareInboxTests.onDisk(root).isEmpty)
    }

    @Test func aTypePasteRefusesIsRefusedHere() async throws {
        let root = ShareInboxTests.tempRoot(), source = ShareInboxTests.tempRoot()
        let svg = source.appending(path: "x.svg")
        try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(to: svg)
        let inbox = ShareInbox(root: root)
        _ = try inbox.write([.image(svg)]).get()
        let vm = ChatViewModel()
        await vm.takeShare(from: inbox)?.value
        #expect(vm.pendingImages.isEmpty)
        #expect(vm.imageNote == ChatViewModel.unreadableImageMessage)
        #expect(vm.generatingThreadID == nil)
    }

    @Test func sharedPhotosAreLoadingTilesFromTheFirstFrameAndSendWaits() async throws {
        let root = ShareInboxTests.tempRoot(), source = ShareInboxTests.tempRoot()
        let inbox = ShareInbox(root: root)
        _ = try inbox.write([.image(try ShareInboxTests.pngFile(width: 61, in: source)),
                             .image(try ShareInboxTests.pngFile(width: 62, in: source)), .text("fact check")]).get()
        let vm = ChatViewModel()
        let task = try #require(vm.takeShare(from: inbox))
        // Synchronously, before any decode: the strip already holds a tile per photo and does not animate them in.
        #expect(vm.imagesLoading == 2)
        #expect(!vm.canSend, "the text must not go alone while the photos decode")
        #expect(!vm.animatesImageArrival, "a share is in the strip on the first frame, no climb")
        await task.value
        #expect(vm.imagesLoading == 0)
        #expect(vm.pendingImages.map(\.width) == [61, 62])
        #expect(vm.canSend)
        #expect(vm.animatesImageArrival, "the user's own adds animate again")
        #expect(vm.generatingThreadID == nil)
    }

    @Test func aShareWhoseImagesNoneReadOpensWithTheCantReadNote() async throws {
        let root = ShareInboxTests.tempRoot(), source = ShareInboxTests.tempRoot()
        let empty = source.appending(path: "empty.jpg")
        try Data().write(to: empty)
        let inbox = ShareInbox(root: root)
        _ = try inbox.write([.image(empty)]).get()
        let vm = ChatViewModel()
        let task = try #require(vm.takeShare(from: inbox), "the new chat still opens")
        await task.value
        #expect(vm.pendingImages.isEmpty)
        #expect(vm.imageNote == ChatViewModel.unreadableImageMessage)
        #expect(vm.generatingThreadID == nil)
    }

    @Test func imagesTheExtensionDroppedShowTheCantReadNote() async throws {
        let root = ShareInboxTests.tempRoot(), source = ShareInboxTests.tempRoot()
        let inbox = ShareInbox(root: root)
        _ = try inbox.write([.image(try ShareInboxTests.pngFile(width: 71, in: source))], unreadable: 1).get()
        let vm = ChatViewModel()
        await vm.takeShare(from: inbox)?.value
        #expect(vm.pendingImages.map(\.width) == [71])
        #expect(vm.imageNote == "1 image couldn't be read", "the card's line, not the picker's singular")
    }

    @Test func manyImagesTheExtensionDroppedAreCountedInTheNote() async throws {
        let root = ShareInboxTests.tempRoot(), source = ShareInboxTests.tempRoot()
        let inbox = ShareInbox(root: root)
        _ = try inbox.write([.image(try ShareInboxTests.pngFile(width: 72, in: source))], unreadable: 3).get()
        let vm = ChatViewModel()
        await vm.takeShare(from: inbox)?.value
        #expect(vm.pendingImages.map(\.width) == [72])
        #expect(vm.imageNote == ShareJump.Line.unreadable(3))
        #expect(vm.imageNote == "3 images couldn't be read")
    }

    @Test func aSharesPhotosAreReadAfterTakeShareReturnsNotOnTheCallingThread() async throws {
        let root = ShareInboxTests.tempRoot(), source = ShareInboxTests.tempRoot()
        let inbox = ShareInbox(root: root)
        let id = try inbox.write([.image(try ShareInboxTests.pngFile(width: 81, in: source)),
                                  .image(try ShareInboxTests.pngFile(width: 82, in: source)), .text("now")]).get()
        let vm = ChatViewModel()
        let task = try #require(vm.takeShare(from: inbox))
        #expect(vm.prompt == "now")
        #expect(!inbox.contains(id), "taken at once: the extension sees the jump landed")
        #expect(ShareInboxTests.imageFiles(under: root).count == 2, "the photos are still unread when takeShare returns")
        await task.value
        #expect(vm.pendingImages.map(\.width) == [81, 82])
        #expect(ShareInboxTests.imageFiles(under: root).isEmpty, "the taken folder goes after the read")
    }

    @Test func moreSharedPhotosThanTheModelTakesAreOnlyItsFreeSlotsOfTiles() async throws {
        let root = ShareInboxTests.tempRoot(), source = ShareInboxTests.tempRoot()
        let inbox = ShareInbox(root: root)
        let photos = try (0..<10).map { Item.image(try ShareInboxTests.pngFile(width: 90 + $0, in: source)) }
        _ = try inbox.write(photos).get()
        let vm = ChatViewModel()
        vm.imageLimit = 4
        let task = try #require(vm.takeShare(from: inbox))
        #expect(vm.imagesLoading == 4, "never a tile the model has no slot for")
        await task.value
        #expect(vm.imagesLoading == 0)
        #expect(vm.pendingImages.map(\.width) == [90, 91, 92, 93])
        #expect(vm.imageNote == ChatViewModel.tooManyImagesMessage(limit: 4))
    }

    typealias Item = ShareInbox.Item

    @Test func noInboxOrAnEmptyOneLeavesTheComposerAlone() {
        let vm = ChatViewModel()
        vm.prompt = "mine"
        #expect(vm.takeShare(from: nil) == nil)
        #expect(vm.takeShare(from: ShareInbox(root: ShareInboxTests.tempRoot())) == nil)
        #expect(vm.prompt == "mine")
    }
}
#endif
