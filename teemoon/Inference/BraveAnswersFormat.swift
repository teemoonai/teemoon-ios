//
//  BraveAnswersFormat.swift
//  teemoon
//
//  Brave Answers (`POST /res/v1/chat/completions`) is OpenAI-compatible on the
//  envelope but NOT in the delta payload: it interleaves two XML-ish blocks into
//  the assistant's `content` stream, so a client that just renders `content`
//  shows raw JSON in the middle of the prose.
//
//    …most populous city of France.<citation>{"start_index": 58, "end_index": 58,
//      "number": 1, "url": "https://…", "favicon": "https://imgs.search.brave.com/…",
//      "snippet": "Paris is the capital…"}</citation><citation>{…}</citation>
//    …renowned for the Eiffel Tower.<usage>{"X-Request-Tokens-In": 9970,
//      "X-Request-Total-Cost": 0.0548…}</usage>
//
//  Observed live 2026-07-25 (brave-pro): `<citation>` blocks appear when the
//  request sets `enable_citations` (teemoon's preset does — they ARE the
//  provider's value); the trailing `<usage>` cost block is emitted **always**,
//  citations on or off. A 16.8 KB answer to "capital of france" was mostly
//  citation JSON, base64 favicon URLs included.
//
//  So teemoon splits the stream: prose to the message, citations to the same
//  `GroundingSource` rail the web-search tool feeds, usage discarded (it is
//  already reported per-request in the debug panel).
//
//  Docs: https://api-dashboard.search.brave.com/app/documentation
//

import Foundation

enum BraveAnswersFormat {

    /// Blocks Brave inlines into `content`. Order matters only for readability.
    private static let blocks = [("<citation>", "</citation>"), ("<usage>", "</usage>")]

    /// Splits a (possibly partial) answer into the text to display and the
    /// citations found so far.
    ///
    /// Safe to call on every streaming delta: a block that hasn't closed yet is
    /// withheld rather than shown half-parsed, and so is a bare `<` that could
    /// still become an opening tag — otherwise the user watches `{"start_ind`
    /// type across the screen before it disappears.
    static func split(_ text: String) -> (visible: String, sources: [GroundingSource]) {
        guard text.contains("<") else { return (text, []) }

        var visible = ""
        var citations: [String] = []
        var rest = Substring(text)

        while let open = nextOpen(in: rest) {
            visible += rest[rest.startIndex..<open.range.lowerBound]
            let afterOpen = rest[open.range.upperBound...]
            guard let close = afterOpen.range(of: open.closing) else {
                // Unterminated — the rest is a block still streaming in. Drop it.
                return (visible, parseCitations(citations))
            }
            if open.opening == "<citation>" {
                citations.append(String(afterOpen[afterOpen.startIndex..<close.lowerBound]))
            }
            rest = afterOpen[close.upperBound...]
        }

        // A trailing "<", "<cit", "<citation" … could be the start of a block.
        if let partial = trailingPartialTag(in: rest) {
            visible += rest[rest.startIndex..<partial]
        } else {
            visible += rest
        }
        return (visible, parseCitations(citations))
    }

    /// Sources for the `GroundingSourcesView` rail, in first-cited order and
    /// deduplicated by URL. Brave's citation JSON carries no title, so the title
    /// is left empty — the row falls back to the domain rather than inventing one.
    static func parseCitations(_ payloads: [String]) -> [GroundingSource] {
        var seen = Set<String>()
        return payloads.compactMap { json -> GroundingSource? in
            guard let data = json.data(using: .utf8),
                  let c = try? JSONDecoder().decode(Citation.self, from: data),
                  let url = c.url, !url.isEmpty,
                  seen.insert(url).inserted else { return nil }
            return GroundingSource(
                url: url,
                domain: URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url,
                title: "",
                snippet: c.snippet ?? "")
        }
    }

    /// One `<citation>` payload. `favicon` is a Brave image-proxy URL and
    /// `start_index`/`end_index` are offsets into the answer text — teemoon
    /// renders a source list, not inline superscripts, so neither is used yet.
    struct Citation: Decodable {
        let url: String?
        let snippet: String?
        let number: Int?
        let favicon: String?
        let start_index: Int?
        let end_index: Int?
    }

    // MARK: - Scanning

    private static func nextOpen(
        in text: Substring
    ) -> (opening: String, closing: String, range: Range<Substring.Index>)? {
        blocks.compactMap { block -> (String, String, Range<Substring.Index>)? in
            text.range(of: block.0).map { (block.0, block.1, $0) }
        }
        .min { $0.2.lowerBound < $1.2.lowerBound }
    }

    /// Index of a trailing `<…` that is still a viable prefix of an opening tag
    /// ("<", "<cit", "<usage" …), or nil when the tail can't become one.
    private static func trailingPartialTag(in text: Substring) -> Substring.Index? {
        guard let last = text.lastIndex(of: "<") else { return nil }
        let tail = text[last...]
        return blocks.contains { $0.0.hasPrefix(tail) } ? last : nil
    }
}
