//
//  ChatListSession.swift
//  teemoon
//
//  Session-lifetime state for the chats list's search, kept OUTSIDE the view:
//  on iPhone the list is a sheet whose @State dies on every dismissal, which
//  made "tap a result, glance at the thread, come back" retype the query from
//  scratch. Plain types so the semantics are testable; nothing here persists.
//

import Foundation
import Observation

/// The query the chats list was last searching. Process-lifetime only — a
/// fresh launch starts blank on purpose; restoring day-old search UI would
/// read as a bug, not a memory.
@MainActor
@Observable
final class ChatListSearchMemory {
    static let shared = ChatListSearchMemory()
    var query: String = ""
}

/// A one-shot "open this thread AT this message" hand-off from a search
/// result tap to the transcript. The list and the transcript never talk
/// directly — the list deposits the target here, the transcript consumes it
/// when it presents that thread.
@MainActor
@Observable
final class TranscriptDeepLink {
    static let shared = TranscriptDeepLink()

    struct Target: Equatable {
        let threadID: UUID
        let messageID: UUID
        /// Where the match sits inside the message, 0...1. Replies here run
        /// thousands of characters — landing a multi-screen message TOP-aligned
        /// puts the matched passage two screens below the fold, which reads as
        /// "search took me to the wrong place". 0 = unknown, land at the top.
        let fraction: Double
    }

    /// Bumped on every deposit so an observer can react even when the SAME
    /// thread is already on screen (the sheet dismisses without a thread
    /// change, but the transcript still has to jump).
    private(set) var stamp = 0
    private(set) var pending: Target?

    func deposit(threadID: UUID, messageID: UUID, fraction: Double = 0) {
        pending = Target(threadID: threadID, messageID: messageID,
                         fraction: fraction.isFinite ? min(max(fraction, 0), 1) : 0)
        stamp += 1
    }

    /// Returns the target for `threadID` and clears it. A pending target for
    /// a DIFFERENT thread is stale (the user navigated somewhere else before
    /// the transcript consumed it) and is discarded rather than left to fire
    /// on some later visit.
    func consume(for threadID: UUID) -> Target? {
        defer { pending = nil }
        guard let pending, pending.threadID == threadID else { return nil }
        return pending
    }

    /// Locates the snippet's first highlighted term inside the full message,
    /// as a 0...1 fraction of the content. Pure so the arithmetic is pinned:
    /// the snippet is an 18-token verbatim window with `…` ellipses and
    /// U+0001/U+0002 wrapped around matched terms (`ChatSearchIndex`).
    /// Returns 0 (land at the top) whenever the location cannot be trusted.
    nonisolated static func matchFraction(snippet: String, content: String) -> Double {
        guard !content.isEmpty else { return 0 }
        let junk = CharacterSet(charactersIn: "…").union(.whitespacesAndNewlines)

        let deClosed = snippet.replacingOccurrences(
            of: ChatSearchIndex.highlightClose, with: "")
        let prefixLength: Int
        if let open = deClosed.range(of: ChatSearchIndex.highlightOpen) {
            prefixLength = deClosed.distance(from: deClosed.startIndex,
                                             to: open.lowerBound)
        } else {
            prefixLength = 0
        }

        let core = deClosed.replacingOccurrences(
            of: ChatSearchIndex.highlightOpen, with: "")
        let trimmedCore = core.trimmingCharacters(in: junk)
        guard !trimmedCore.isEmpty,
              let found = content.range(of: trimmedCore) else { return 0 }

        // The prefix was measured on the untrimmed core; discount whatever
        // the trim removed from the head so the two indices line up.
        let headJunk = core.prefix { char in
            char.unicodeScalars.allSatisfy(junk.contains)
        }.count
        let offsetInCore = max(0, prefixLength - headJunk)
        let coreStart = content.distance(from: content.startIndex,
                                         to: found.lowerBound)
        let fraction = Double(coreStart + offsetInCore) / Double(content.count)
        return min(max(fraction, 0), 1)
    }
}
