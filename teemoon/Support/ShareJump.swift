//
//  ShareJump.swift
//  teemoon
//
//  The share extension's jump to teemoon and its fallback (docs/SHARE_IN.md, "The jump"). Foundation only: the
//  extension compiles this file and has no app type.
//

import Foundation
import UniformTypeIdentifiers

enum ShareJump {
    /// How long the extension waits for teemoon to take the entry before it shows the fallback.
    static let openWait: TimeInterval = 1.5

    enum Outcome: Equatable, Sendable {
        case opened
        /// The entry stays in the inbox for teemoon's next open.
        case fallback
    }

    /// `SHARE_OPENS_APP` from the extension's Info.plist; YES when absent. Only an explicit no turns the jump off.
    static func shouldJump(flag: Any?) -> Bool {
        switch flag {
        case let value as Bool: value
        case let value as String: !["no", "false", "0"].contains(value.lowercased())
        default: true
        }
    }

    /// Opened only when the switch is on, the open said yes AND teemoon came up within `openWait`.
    static func outcome(jumps: Bool, openReturned: Bool, appBecameActive: Bool) -> Outcome {
        jumps && openReturned && appBecameActive ? .opened : .fallback
    }

    /// What the extension reads a shared item as. Image first: Files offers a file URL beside the image itself.
    enum Kind: Equatable, Sendable {
        /// The type identifier to ask `loadFileRepresentation` for.
        case image(String)
        case text
        case link
    }

    /// How long a copy runs before the extension says "opening teemoon…".
    static let progressDelay: TimeInterval = 0.3

    static func kind(of typeIdentifiers: [String]) -> Kind? {
        let types = typeIdentifiers.compactMap { UTType($0) }
        if let image = types.first(where: { $0.conforms(to: .image) }) { return .image(image.identifier) }
        if types.contains(where: { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }) { return .link }
        if types.contains(where: { $0.conforms(to: .plainText) }) { return .text }
        return nil
    }

    /// Checked before a byte is copied: over the image count, or nothing teemoon reads.
    static func precheck(_ kinds: [Kind]) -> String? {
        if kinds.isEmpty { return Line.nothingRead }
        let images = kinds.filter { if case .image = $0 { true } else { false } }.count
        return images > ShareInbox.maxImages ? Line.overCap : nil
    }

    /// The extension's visible lines, all DRAFT (docs/SHARE_IN.md).
    enum Line {
        static let opening = "opening teemoon…"
        static let fallback = "it's in teemoon's composer next time you open it."
        static let overCap = "that's more than teemoon can take at once: up to \(ShareInbox.maxImages) photos, "
            + "\(ShareInbox.maxImageBytes / (1024 * 1024)) MB each."
        static let textOverCap = "that's more text than teemoon can take at once: up to "
            + "\(ShareInbox.maxTextCharacters.formatted(.number.locale(Locale(identifier: "en_US")))) characters."
        static let nothingRead = "teemoon couldn't read what was shared."
        static let done = "done"
        static func unreadable(_ count: Int) -> String? {
            switch count {
            case ..<1: nil
            case 1: "1 image couldn't be read"
            default: "\(count) images couldn't be read"
            }
        }
    }

    enum Step: Equatable, Sendable {
        /// The line and done; nothing was kept.
        case refuse(String)
        case open(UUID, note: String?)
        /// The switch is off: the entry stays for teemoon's next open.
        case fallback(UUID, note: String?)
    }

    static func step(after result: Result<UUID, ShareInbox.Refusal>, unreadable: Int, jumps: Bool) -> Step {
        switch result {
        case .failure(.overCap): .refuse(Line.overCap)
        case .failure(.textOverCap): .refuse(Line.textOverCap)
        case .failure(.unreadable): .refuse(Line.nothingRead)
        case .success(let id): jumps ? .open(id, note: Line.unreadable(unreadable))
                                     : .fallback(id, note: Line.unreadable(unreadable))
        }
    }
}

/// How teemoon takes the keyboard for a shared entry. A share that lands before the scene is active must not keep the
/// keyboard teemoon was left with: iOS restores it undrawn, then hands it back from the share sheet's app.
enum ShareFocus: Equatable, Sendable {
    case now
    case dropThenOnActive

    static func plan(sceneActive: Bool) -> ShareFocus { sceneActive ? .now : .dropThenOnActive }
}
