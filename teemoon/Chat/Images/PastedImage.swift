//
//  PastedImage.swift
//  teemoon
//
//  A pasted image (docs/IMAGES.md §4c): JPEG, PNG and GIF through Wuffs like a picked photo; HEIC, WebP, AVIF,
//  TIFF and BMP through SystemImageDecode. Any other image type is refused unread.
//

#if os(iOS)
import CoreTransferable
import Foundation
import UIKit
import UniformTypeIdentifiers

struct PastedImage: Transferable {
    let result: Result<ImageIntake.Image, ImageIntake.Failure>

    typealias Decode = (Data, ImageIntake.Format) -> Result<ImageIntake.Image, ImageIntake.Failure>

    /// What one pasteboard item is, from the type identifiers it offers.
    enum Choice: Equatable {
        case read(UTType, ImageIntake.Format)
        /// A type Wuffs does not decode, read by SystemImageDecode.
        case system(UTType)
        /// An app's UIImage (`com.apple.uikit.image`): its bytes are an encoded image, sniffed to either decoder.
        case sniff
        /// An image in no type either path reads (SVG, PDF, …): refused without loading its bytes.
        case refuse
        case notAnImage

        /// The type identifier whose bytes to load, nil when none are.
        var readIdentifier: String? {
            switch self {
            case .read(let type, _), .system(let type): type.identifier
            case .sniff: PastedImage.uikitImage
            case .refuse, .notAnImage: nil
            }
        }
    }

    /// The picker's types, then GIF: every format Wuffs decodes. Do not add one it does not.
    static let accepted = PickedImageTypes.accepted + [(UTType.gif, ImageIntake.Format.gif)]

    static func choice(offered identifiers: [String]) -> Choice {
        if let (type, format) = accepted.first(where: { identifiers.contains($0.0.identifier) }) {
            return .read(type, format)
        }
        if let system = identifiers.first(where: SystemImageDecode.reads), let type = UTType(system) {
            return .system(type)
        }
        if identifiers.contains(uikitImage) { return .sniff }
        let isImage = identifiers.contains { UTType($0)?.conforms(to: .image) == true }
        return isImage ? .refuse : .notAnImage
    }

    /// UIKit's type for a UIImage an app put on the pasteboard (trip.com does, beside a URL): it holds PNG bytes.
    static let uikitImage = "com.apple.uikit.image"

    typealias SystemDecode = (Data) -> Result<ImageIntake.Image, ImageIntake.Failure>

    /// Bytes go to the decoder their type names; a refused type's bytes reach none. Bytes offered as a generic
    /// image or a UIImage are sniffed for one of the two.
    static func imported(_ bytes: Data, as type: UTType, decode: Decode = ImageIntake.fromBytes,
                         system: SystemDecode = SystemImageDecode.decode) -> PastedImage {
        if type == .image { return sniffed(bytes, decode: decode, system: system) }
        return imported(bytes, offered: type.identifier, decode: decode, system: system)
    }

    static func imported(_ bytes: Data, offered identifier: String, decode: Decode = ImageIntake.fromBytes,
                         system: SystemDecode = SystemImageDecode.decode) -> PastedImage {
        switch choice(offered: [identifier]) {
        case .read(_, let format): PastedImage(result: decode(bytes, format))
        case .system: PastedImage(result: system(bytes))
        case .sniff: sniffed(bytes, decode: decode, system: system)
        case .refuse, .notAnImage: PastedImage(result: .failure(.unsupportedFormat))
        }
    }

    private static func sniffed(_ bytes: Data, decode: Decode, system: SystemDecode) -> PastedImage {
        if let format = ImageIntake.Format(sniffing: bytes) { return PastedImage(result: decode(bytes, format)) }
        if SystemImageDecode.Kind(sniffing: bytes) != nil { return PastedImage(result: system(bytes)) }
        return PastedImage(result: .failure(.unsupportedFormat))
    }

    #if os(iOS)
    /// How many results `load(from:)` will hand back, counted before any decode.
    static func imageItemCount(on board: UIPasteboard) -> Int {
        (0..<board.numberOfItems).filter {
            choice(offered: board.types(forItemSet: IndexSet(integer: $0))?.first ?? []) != .notAnImage
        }.count
    }

    /// The composer's paste (§4d): one result per image item, in order, from the pasteboard's own bytes. Item
    /// providers hold no data form of an app's UIImage, so it is read here. Decoding runs off the main thread.
    static func load(from board: UIPasteboard, decode: @escaping Decode = ImageIntake.fromBytes,
                     completion: @escaping ([Result<ImageIntake.Image, ImageIntake.Failure>]) -> Void) {
        var reads: [(id: String?, bytes: Data?)] = []
        for n in 0..<board.numberOfItems {
            let set = IndexSet(integer: n)
            let choice = choice(offered: board.types(forItemSet: set)?.first ?? [])
            if choice == .notAnImage { continue }
            let id = choice.readIdentifier
            reads.append((id, id.flatMap { board.data(forPasteboardType: $0, inItemSet: set)?.first }))
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let results = reads.map { read -> Result<ImageIntake.Image, ImageIntake.Failure> in
                guard let id = read.id else { return .failure(.unsupportedFormat) }
                guard let bytes = read.bytes else { return .failure(.corrupt) }
                return imported(bytes, offered: id, decode: decode).result
            }
            DispatchQueue.main.async { completion(results) }
        }
    }
    #endif

    /// UIKit's paste: one result per image item, in order; items that are not images are skipped.
    static func load(_ providers: [NSItemProvider], decode: @escaping Decode = ImageIntake.fromBytes,
                     completion: @escaping ([Result<ImageIntake.Image, ImageIntake.Failure>]) -> Void) {
        let group = DispatchGroup()
        // Decodes and writes run one at a time here: LockedBox's subscript write is not atomic.
        let serial = DispatchQueue(label: "teemoon.paste.decode", qos: .userInitiated)
        let collected = LockedBox<[Int: Result<ImageIntake.Image, ImageIntake.Failure>]>([:])
        for (n, provider) in providers.enumerated() {
            switch choice(offered: provider.registeredTypeIdentifiers) {
            case .notAnImage:
                continue
            case .refuse:
                group.enter()
                serial.async {
                    collected.value[n] = .failure(.unsupportedFormat)
                    group.leave()
                }
            case .read, .system, .sniff:
                let id = choice(offered: provider.registeredTypeIdentifiers).readIdentifier!
                group.enter()
                _ = provider.loadDataRepresentation(forTypeIdentifier: id) { data, _ in
                    serial.async {
                        collected.value[n] = data.map { imported($0, offered: id, decode: decode).result } ?? .failure(.corrupt)
                        group.leave()
                    }
                }
            }
        }
        group.notify(queue: .main) {
            completion(collected.value.sorted { $0.key < $1.key }.map(\.value))
        }
    }

    /// A composer edit that inserted one `data:` URL and nothing else (§4c), with its scheme lowercased; nil otherwise.
    static func soleDataURL(before old: String, after new: String) -> String? {
        guard new.utf8.count - old.utf8.count >= 6, new.range(of: "data:", options: .caseInsensitive) != nil else { return nil }
        let a = Array(old.utf8), b = Array(new.utf8)
        var p = 0, s = 0
        while p < a.count, a[p] == b[p] { p += 1 }
        while s < a.count, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        if p + s >= a.count {
            // An insertion: it may sit at any offset where the old text still matches on both sides.
            let added = b.count - a.count
            for k in stride(from: p, through: a.count - s, by: -1) {
                if let url = dataURL(b[k..<k + added]) { return url }
            }
            return nil
        }
        // Over a selection: the paste may share up to a base64 quantum with the text around it.
        var fallback: String?
        for start in stride(from: p, through: max(0, p - 4), by: -1) {
            for end in (b.count - s)...min(b.count, b.count - s + 3) where end > start {
                guard let url = dataURL(b[start..<end]) else { continue }
                if isWholeBase64(url) { return url }
                fallback = fallback ?? url
            }
        }
        return fallback
    }

    /// The pasteboard as the composer reads it: type names per item (never prompts) and one item's bytes for one type.
    struct Items {
        let types: [[String]]
        let data: (Int, String) -> Data?
        /// The pasteboard's own object for a type, for bytes no string decoder takes.
        var value: (Int, String) -> Any? = { _, _ in nil }

        static var general: Items {
            let board = UIPasteboard.general
            return Items(types: board.types(forItemSet: nil) ?? [],
                         data: { item, type in board.data(forPasteboardType: type, inItemSet: IndexSet(integer: item))?.first },
                         value: { item, type in board.values(forPasteboardType: type, inItemSet: IndexSet(integer: item))?.first })
        }

        func isImage(_ item: Int) -> Bool { choice(offered: types[item]) != .notAnImage }

        /// The strings the text field may have inserted for this item: its text and URL representations. A URL an app
        /// wrote as an object (Brave's Copy Image) reads back as bytes `text` does not take; its value is the URL.
        func texts(_ item: Int) -> [String] {
            types[item].filter(PastedImage.isText).compactMap { type in
                if let string = data(item, type).flatMap(PastedImage.text) { return string }
                switch value(item, type) {
                case let url as URL: return url.absoluteString
                case let string as String: return string
                default: return nil
                }
            }
        }
    }

    /// One attachment a paste reads, decoded off the main thread.
    enum Read: Sendable {
        case bytes(Data?, String)
        case dataURL(String)
        case refused

        var result: Result<ImageIntake.Image, ImageIntake.Failure> {
            switch self {
            case .bytes(nil, _): .failure(.corrupt)
            case .bytes(let bytes?, let identifier): PastedImage.imported(bytes, offered: identifier).result
            case .dataURL(let url): ImageIntake.fromDataURL(url)
            case .refused: .failure(.unsupportedFormat)
            }
        }
    }

    /// A text representation's string; a `public.url` arrives as a binary plist of [URL, base].
    static func text(_ bytes: Data) -> String? {
        if bytes.starts(with: Data("bplist00".utf8)),
           let pair = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String], let first = pair.first {
            let base = pair.dropFirst().first.flatMap { $0.isEmpty ? nil : URL(string: $0) }
            return URL(string: first, relativeTo: base)?.absoluteString ?? first
        }
        return String(data: bytes, encoding: .utf8)
    }

    static func isText(_ identifier: String) -> Bool {
        guard let type = UTType(identifier), !type.conforms(to: .image) else { return false }
        return type.conforms(to: .text) || type.conforms(to: .url)
    }

    /// Whether an edit may have put in one URL (`http:`, `https:`, `data:`, no blank inside): the only edit that reads
    /// the pasteboard. Do not widen it: autocorrect, dictation and suggestions put in words, and a read may prompt.
    static func mayHavePutInAURL(before old: String, after new: String) -> Bool {
        let a = Array(old.utf8), b = Array(new.utf8)
        var p = 0, s = 0
        while p < min(a.count, b.count), a[p] == b[p] { p += 1 }
        while s < min(a.count, b.count), a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let added = b.count - a.count
        if added > 0, p + s >= a.count {
            // An insertion: it may sit at any offset where the old text still matches on both sides.
            for k in stride(from: min(p, a.count), through: max(0, a.count - s), by: -1) where isURL(b[k..<k + added]) {
                return true
            }
            return false
        }
        // Over a selection: the paste may share a few characters with the text around it.
        let keptSuffix = min(s, min(a.count, b.count) - p)
        for start in stride(from: p, through: max(0, p - 8), by: -1) {
            for end in (b.count - keptSuffix)...min(b.count, b.count - keptSuffix + 8) where end > start {
                if isURL(b[start..<end]) { return true }
            }
        }
        return false
    }

    private static func isURL(_ span: ArraySlice<UInt8>) -> Bool {
        guard let first = span.firstIndex(where: { !blank.contains($0) }),
              let last = span.lastIndex(where: { !blank.contains($0) }) else { return false }
        let url = span[first...last]
        guard !url.contains(where: blank.contains) else { return false }
        let head = String(decoding: url.prefix(8), as: UTF8.self).lowercased()
        return head.hasPrefix("http://") || head.hasPrefix("https://") || head.hasPrefix("data:")
    }

    /// From type names only: an image item and some item with text (§4c). Do not read bytes before this says yes.
    static func mayHoldImageItemText(_ itemTypes: [[String]]) -> Bool {
        itemTypes.contains { choice(offered: $0) != .notAnImage } && itemTypes.contains { $0.contains(where: isText) }
    }

    /// One pasteboard item as the composer's rule sees it: whether it offers an image, and its strings.
    struct ItemText: Equatable {
        let isImage: Bool
        let texts: [String]
    }

    /// The composer text after a paste of `items` put in their strings at one place (§4c): the old text, since a paste
    /// with an image item puts in nothing (case 6b). nil when the edit was not that paste or no item is an image.
    static func keptText(before old: String, after new: String, items: [ItemText]) -> String? {
        let withText = items.filter { !$0.texts.isEmpty }
        guard items.contains(where: \.isImage), !withText.isEmpty else { return nil }
        let separators = withText.count == 1 ? [""] : ["\n", " "]
        for choice in combinations(withText.map(\.texts), cap: 64) {
            for separator in separators {
                if insertionSpot(old, new, inserted: choice.joined(separator: separator)) != nil { return old }
            }
        }
        return nil
    }

    /// Where `inserted` went into `old` to make `new` (over a selection too): kept UTF-8 prefix and suffix lengths.
    private static func insertionSpot(_ old: String, _ new: String, inserted: String) -> (Int, Int)? {
        let a = Array(old.utf8), b = Array(new.utf8), t = Array(inserted.utf8)
        guard !t.isEmpty, b.count >= t.count else { return nil }
        for k in 0...(b.count - t.count) where k <= a.count && b[k..<k + t.count].elementsEqual(t) {
            let rest = b.count - k - t.count
            if a.count - rest >= k, a[..<k].elementsEqual(b[..<k]), a.suffix(rest).elementsEqual(b.suffix(rest)) {
                return (k, rest)
            }
        }
        return nil
    }

    private static func combinations(_ options: [[String]], cap: Int) -> [[String]] {
        options.reduce([[]]) { partial, texts in
            Array(partial.lazy.flatMap { head in Set(texts).sorted().map { head + [$0] } }.prefix(cap))
        }
    }

    private static let blank: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]

    /// The span, trimmed, as one `data:` URL with a comma and no blank inside; nil for anything else.
    private static func dataURL(_ span: ArraySlice<UInt8>) -> String? {
        guard let first = span.firstIndex(where: { !blank.contains($0) }),
              let last = span.lastIndex(where: { !blank.contains($0) }), last - first >= 5,
              String(decoding: span[first..<first + 5], as: UTF8.self).lowercased() == "data:" else { return nil }
        let url = span[first...last]
        guard url.contains(UInt8(ascii: ",")), !url.contains(where: blank.contains) else { return nil }
        return "data:" + String(decoding: url.dropFirst(5), as: UTF8.self)
    }

    private static func isWholeBase64(_ url: String) -> Bool {
        guard let comma = url.firstIndex(of: ","), url[..<comma].lowercased().hasSuffix(";base64") else { return true }
        return url[url.index(after: comma)...].utf8.count % 4 == 0
    }

    /// Order is preference: JPEG, PNG, GIF, then any other image, sniffed. Do not add a type above `.image`.
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .jpeg) { imported($0, as: .jpeg) }
        DataRepresentation(importedContentType: .png) { imported($0, as: .png) }
        DataRepresentation(importedContentType: .gif) { imported($0, as: .gif) }
        DataRepresentation(importedContentType: UTType(importedAs: uikitImage)) { imported($0, offered: uikitImage) }
        DataRepresentation(importedContentType: .image) { imported($0, as: .image) }
    }
}
#endif
