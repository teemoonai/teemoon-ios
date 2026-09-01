//
//  BraveWebSearchTool.swift
//  teemoon

import Foundation
import ModelBackend

/// A single web source returned by Brave grounding.
struct GroundingSource: Codable, Identifiable, Sendable {
    var id: String { url }
    let url: String
    let domain: String
    let title: String
    let snippet: String

    init(url: String, domain: String, title: String, snippet: String = "") {
        self.url = url
        self.domain = domain
        self.title = title
        self.snippet = snippet
    }

    // Backward-compatible decoding: snippet defaults to "" if absent in stored JSON.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url     = try c.decode(String.self, forKey: .url)
        domain  = try c.decode(String.self, forKey: .domain)
        title   = try c.decode(String.self, forKey: .title)
        snippet = (try? c.decode(String.self, forKey: .snippet)) ?? ""
    }

    var displaySnippet: String {
        Self.isStructuredData(snippet) ? "" : snippet
    }

    static func isStructuredData(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.first == "{" || t.first == "[" { return true }
        if t.contains("\"@type\":") || t.contains("\"@graph\":") { return true }
        if t.hasPrefix("\"@") { return true }
        return false
    }

    /// Prose for a passage that arrived as JSON-LD.
    ///
    /// `displaySnippet` hides structured data from the citation UI, which is
    /// right for a preview — but the model was being handed the blob verbatim,
    /// and that is worst for the queries that need it most. The captured
    /// "weather 10001" response carries the entire forecast as
    /// `{"title":…,"table":[{"DEWPOINT":"40°"},{"HUMIDITY":"93%"},…]}`, so the
    /// model had to parse JSON to read a temperature.
    ///
    /// Unpacks to `key: value` prose. Non-structured text is returned trimmed
    /// and unchanged; anything that unpacks to nothing returns "" so the caller
    /// can drop the passage rather than emit an empty `<content>`.
    static func readableSnippet(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        guard isStructuredData(t) else { return t }

        if let data = t.data(using: .utf8),
           let node = try? JSONSerialization.jsonObject(with: data) {
            return flatten(node)
        }
        // A truncated blob is still worth mining: Brave cuts passages mid-object,
        // so the prose-bearing keys are usually present even when the JSON is not
        // parseable as a whole.
        return salvageFragments(from: t)
    }

    /// Depth-first `key: value` rendering. Keys are visited in sorted order —
    /// Swift dictionaries have no stable order, and without this the same
    /// passage would render differently between runs.
    private static func flatten(_ node: Any) -> String {
        var parts: [String] = []
        switch node {
        case let dict as [String: Any]:
            for key in dict.keys.sorted() {
                // Presentational scaffolding, not content.
                if ["@context", "@type", "@graph", "headers", "caption"].contains(key) { continue }
                // Unwrap before recursing: `dict[key]` is `Any?`, and widening that
                // to `Any` renders leaves as "Optional(40°)".
                guard let value = dict[key] else { continue }
                let child = flatten(value)
                if !child.isEmpty { parts.append("\(key): \(child)") }
            }
        case let arr as [Any]:
            for item in arr {
                let child = flatten(item)
                if !child.isEmpty { parts.append(child) }
            }
        case is NSNull:
            return ""
        default:
            return String(describing: node).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return parts.joined(separator: "; ")
    }

    /// Pulls the prose-bearing values out of JSON that will not parse.
    private static func salvageFragments(from text: String) -> String {
        let pattern = #""(?:headline|articleBody|description|name|title)"\s*:\s*"((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let ns = text as NSString
        let passages = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .filter { $0.numberOfRanges > 1 }
            .map {
                ns.substring(with: $0.range(at: 1))
                    .replacingOccurrences(of: "\\/", with: "/")
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        return passages.joined(separator: "; ")
    }
}

/// The full response shape of `GET /res/v1/llm/context`.
///
/// Captured from live responses (`teemoonTests/Fixtures/brave_llm_context*.json`).
/// `grounding.generic` carries the passages; the top-level `sources` map is keyed
/// by URL and carries the per-page metadata — title, hostname, age and a
/// page-level snippet — that `generic` does not.
struct BraveGroundingResponse: Decodable, Sendable {
    struct Grounding: Decodable, Sendable {
        struct Generic: Decodable, Sendable {
            let url: String
            let title: String?
            /// Discrete passages pulled from the page. Some are raw JSON-LD blobs.
            let snippets: [String]?
        }
        /// Local/business results. Empty in every observed response — including
        /// explicit local-business queries — so the element shape is unknown.
        /// Decoded permissively so a future payload cannot fail the whole parse.
        struct MapEntry: Decodable, Sendable {
            let url: String?
            let title: String?
        }
        let generic: [Generic]
        let map: [MapEntry]?
    }

    struct Source: Decodable, Sendable {
        let title: String?
        let hostname: String?
        /// Three renderings of the page's publish date —
        /// `["Saturday, July 25, 2026", "2026-07-25", "0 days ago"]`.
        /// Empty when Brave has no date for the page.
        let age: [String]?
        /// Page-level summary. Cleaner prose than `snippets`, which can be JSON-LD.
        let snippet: String?

        /// Human-readable publish date, or nil when Brave reported no date.
        var displayDate: String? {
            guard let first = age?.first, !first.isEmpty else { return nil }
            return first
        }
    }

    let grounding: Grounding
    /// Keyed by the page URL.
    let sources: [String: Source]?
}

/// How much web context to pull into the prompt.
///
/// Grounding dwarfs everything else teemoon adds to a request: measured on
/// "weather 10001", 4096 tokens × 10 URLs costs ~2,600 prompt tokens, while the
/// persona is ~173 and the `web_search` tool definition ~79.
///
/// There used to be a second, `compact` policy (3 pages / 1024 tokens) handed
/// to self-hosted endpoints, on the theory that a small model on a phone-sized
/// context pays for every extra prompt token again in local prefill. Measured,
/// that was wrong in all three of its claims — prefill went 0.02s → 0.02s for
/// 538 → 4038 input tokens on an M-series GPU (decode is the serial part, not
/// prefill); Brave bills per QUERY, not per source, so it saved nothing; and
/// the smaller payload lost 6 of 6 accuracy cells. It is deleted rather than
/// left switched off, because an unused policy still has to be read, understood
/// and kept correct by everyone who touches this file.
///
/// If a smaller payload is ever needed again — a CPU-only server, where prefill
/// genuinely is expensive, or a model whose context window can't take 2,600
/// tokens on top of persona and history — reintroduce it keyed on the CONTEXT
/// WINDOW, which teemoon knows from the catalogue. Not on `isSelfHosted`, which
/// was a proxy for the wrong thing. `git show fec4207` has the old shape.
enum GroundingBudget {
    /// Pages Brave should return, capped at the model's requested `count`.
    static func urlCap(forCount count: Int) -> Int { min(count, 10) }

    /// The on-device cap. This is the "CPU-only server, where prefill genuinely
    /// is expensive" case the note above anticipated — except it is a phone, and
    /// the discriminator is not the context window (Qwen3 has 32k and the full
    /// payload fits fine) but **who pays for prefill**.
    ///
    /// Measured on an iPhone 16 Pro, round-two prefill of a real-shaped payload:
    ///
    ///      1 source   3,375 chars →  0.63 s
    ///      3 sources 10,127 chars →  1.79 s
    ///      5 sources 16,879 chars →  3.63 s
    ///     10 sources 33,762 chars → 12.98 s
    ///
    /// Superlinear — doubling from 5 to 10 sources costs 3.6× the time, which is
    /// attention behaving exactly as advertised. The earlier "prefill is free"
    /// measurement (538→4,038 tokens, 0.02 s→0.02 s) was taken on an M-series
    /// GPU and does not transfer to this hardware.
    ///
    /// 5 rather than 3: it keeps most of the context the accuracy A/B favoured
    /// while cutting ~9 s, and the knee in the curve is between 5 and 10.
    static let onDeviceURLCap = 5

    static func urlCap(forCount count: Int, onDevice: Bool) -> Int {
        onDevice ? min(count, onDeviceURLCap) : urlCap(forCount: count)
    }

    /// Token ceiling for the whole context payload, scaled to query breadth —
    /// small lookups don't need 8 k tokens.
    static func maxTokens(forCount count: Int) -> Int {
        count <= 5 ? 2048 : count <= 10 ? 4096 : 8192
    }

    /// On-device ceiling. **2048, for HALF THE PREFILL at the same source count.**
    ///
    /// Measured across ten live queries, 2048 against 4096:
    ///
    ///     ask=2048: mean 3.9 sources, mean 1,809 tokens, single-source 2/10
    ///     ask=4096: mean 3.9 sources, mean 3,547 tokens, single-source 2/10
    ///
    /// Same sources, ~half the tokens. On device that is the whole argument:
    /// this payload is prefilled on the phone's own GPU, prefill is superlinear
    /// (6,009 chars → 5.1 s, 12,022 chars → 13.7 s), and it shares an 8,192-token
    /// KV cache with the persona, the history and the answer.
    ///
    /// AN EARLIER VERSION OF THIS COMMENT CLAIMED "asking for less returns MORE
    /// sources", from a single query where 4096 returned one 17,716-character
    /// page and 2048 returned five. That was n=1 and it does not generalise:
    /// across ten queries both budgets average 3.9 sources and both collapse to
    /// a single source twice — on DIFFERENT queries. Which budget gets unlucky
    /// is a property of the query, not of the number.
    ///
    /// WORTH KNOWING: ~20% of queries return one source at any budget, because
    /// Brave fills the allowance highest-ranked-page-first and some top results
    /// are enormous. That is not fixed here and is not fixable by tuning this
    /// constant.
    static let onDeviceMaxTokens = 2048

    static func maxTokens(forCount count: Int, onDevice: Bool) -> Int {
        onDevice ? onDeviceMaxTokens : maxTokens(forCount: count)
    }
}

/// An AnyLanguageModel `Tool` that fetches live Brave web search context.
/// Attach to a `LanguageModelSession` to give the model on-demand web access.
struct BraveWebSearchTool: Tool {
    static let keychainKey = "brave-grounding"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f
    }()

    let apiKey: String
    /// Injection point for tests. Production is URLSession.
    var http: any HTTPClient = URLSessionHTTP()
    /// Called with the query when the model asks to search and no key is set.
    /// The generation layer uses it to raise the offer card. Not `Codable`,
    /// never persisted — it exists for the length of one turn.
    var onUnconfiguredSearch: ((String) -> Void)?
    let description: String

    let name = "web_search"

    /// True when the answering model runs on this device, so teemoon pays for
    /// prefill of whatever this tool returns. Caps the payload — see
    /// `GroundingBudget.onDeviceURLCap`.
    let onDevice: Bool

    init(apiKey: String, onDevice: Bool = false) {
        self.onDevice = onDevice
        self.apiKey = apiKey
        let today = Self.dateFormatter.string(from: Date())
        self.description = """
            Search the web for current, real-time information. Use this when the user asks about \
            recent events, current news, live prices, or anything that may have changed since your \
            training cutoff. Today is \(today) — always use the specific date (not just the month \
            or year) in queries for time-sensitive information. Results are returned as XML \
            <source> elements with <url>, <title>, <content> and, when known, <published> fields. \
            Do not reproduce the XML tags in your response. When citing information, use a \
            markdown link: [Page Title](url).
            """
    }

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "The search query. Be specific and include key terms. For time-sensitive topics, include the date or year.")
        var query: String

        @Guide(description: """
            Recency filter for news-style content. Use only when the user explicitly asks \
            about recent events or breaking news. \
            "pd" = past day (breaking news, live scores — NOT for weather or service pages); \
            "pw" = past week (recent announcements, this week's developments); \
            "pm" = past month (recent trends, last few weeks); \
            "py" = past year (annual summaries, recent history). \
            Omit for weather, prices, general knowledge, or any query where freshness \
            would filter out authoritative service pages (weather.gov, accuweather.com, etc.).
            """)
        var freshness: String?

        @Guide(description: """
            Relevance threshold for returned content. \
            "strict" = factual, medical, legal, or technical queries where precision matters; \
            "balanced" = general use (default); \
            "lenient" = exploratory, creative, or niche topics where broader coverage helps.
            """)
        var contextThresholdMode: String?

        @Guide(description: """
            Number of web pages to consider (1–50). \
            Use 5–10 for simple factual lookups, 20–30 for research questions, \
            40–50 for rare, niche, or highly specific information. Default is 20.
            """)
        var count: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        let q = String(arguments.query.prefix(400))
        guard !q.isEmpty else {
            return "[BraveWebSearchTool] Empty query — skipping search."
        }
        // NO KEY: the tool is attached anyway, so the model can TELL US it
        // wanted the web. That decision is the only honest trigger for the
        // offer card — the alternative is sniffing the prompt for words like
        // "today", which guesses at intent the model has already stated.
        //
        // Reports the refusal back to the model rather than throwing: a thrown
        // error aborts the turn, and the whole point is that the answer still
        // gets written. Told plainly that search is unavailable, models answer
        // from memory and usually say so.
        guard !apiKey.isEmpty else {
            onUnconfiguredSearch?(q)
            // DO NOT ask the model to announce that it couldn't search.
            //
            // The earlier wording ended with "say plainly that you could not
            // check current sources", and gemma e2b duly wrote "I do not have
            // access to real-time weather data." That sentence is then in the
            // thread forever — and tool results are NOT (there is no `tool`
            // role in `ChatModels`), so on the next turn the refusal is the only
            // thing the model sees about searching. It copies it, never calls
            // `web_search` again, and the offer card can never reappear.
            //
            // THREE THINGS THIS DELIBERATELY DOES NOT DO, each a fix for a
            // worse earlier version:
            //
            // It does not claim the search RAN and found nothing. It did not
            // run. A model told "no results" can conclude the web has nothing
            // on the subject, which is a bigger lie than the one it replaces.
            //
            // It does not ask the model to hide that it cannot check live
            // sources. That version was measured on device and gemma e2b
            // ignored it — rightly, since for "weather right now" there is
            // nothing else truthful to say. Asking a model to conceal a real
            // limitation is both ineffective and against what teemoon is for.
            //
            // NEVER REPORT A FAILURE HERE. This took five device runs and one
            // decisive probe to see, and two wrong theories died on the way.
            //
            // The probe returned fake DATA — "Tokyo is currently 17C ...
            // reference code ZEBRA-7" — and gemma e2b reproduced every part of
            // it, reference code included. So the tool result is delivered
            // verbatim and the model follows it closely. Delivery was never the
            // problem, and neither was negation (an earlier theory rested on
            // the model "obeying" an instruction to say it could not check —
            // which is simply what it says anyway).
            //
            // The variable is whether the result reads as a FAILED TOOL CALL.
            // Every string that opened with "[web_search did not run]" or
            // "unavailable" produced the same apologise-and-redirect reply,
            // because that is what a model does when a tool fails, and the
            // reflex outranks any instruction that follows it.
            //
            // So this frames the state as a SETTING. Nothing went wrong, there
            // is nothing to apologise for, and the instructions are read as
            // instructions rather than as consolation after an error.
            //
            // WRITTEN FOR THE MODELS THAT COMPLY, not for gemma. This tool
            // attaches to every provider except brave answers and non-tool
            // models, so a cloud model with no key reads this and does what it
            // says — which is why the wording still matters even though the
            // on-device case ignores it entirely.
            //
            // Which is why it does NOT ask the model to mention teemoon or web
            // answers. An earlier version did, to fight gemma's redirect; that
            // fight is lost, and on a compliant model the only effect left is
            // printing the offer in prose directly above the card making the
            // same offer. The card owns the offer, the model owns the answer.
            //
            // THE REDIRECT BAN IS BACK, and removing it was a reasoning error
            // worth naming: it was dropped because GEMMA ignores negations —
            // then applied to a string whose whole point is that it is written
            // for models that COMPLY. Measured on deepseek-v4-flash via
            // near.ai, which obeyed "say roughly when that knowledge is from"
            // ("my knowledge cutoff is April 2024") while listing weather.com,
            // accuweather.com and the JMA, plus suggesting the user run their
            // own search. A model that follows one instruction will follow the
            // one beside it. Evidence from a model that ignores everything
            // cannot be used to strip instructions aimed at models that do not.
            return """
                SEARCH POLICY: live web search is turned off for this \
                conversation, so this query was not sent anywhere. This is a \
                setting, not a failure.
                Answer the question now from your own knowledge, and say \
                roughly when that knowledge is from. Do not recommend other \
                websites, apps, or services, and do not suggest that the user \
                run a search themselves.
                """
        }
        return try await fetchContext(for: q, freshness: arguments.freshness,
                                      contextThresholdMode: arguments.contextThresholdMode,
                                      count: arguments.count)
    }

    // MARK: - Key validation

    /// What one real request to Brave says about a key.
    ///
    /// EVERY CASE NEEDS DIFFERENT ADVICE, which is the point of not collapsing
    /// this to a Bool. "didn't work" sends a user to re-check a key that is
    /// fine but out of credit, or to re-type one when their wifi is off.
    enum KeyCheck: Equatable {
        /// Brave answered. The key is good.
        case valid
        /// Brave rejected it — 401/403. A typo, or a key from the wrong product.
        case rejected
        /// The key is REAL but has no credit left, or is being throttled — 429.
        /// Saving it is correct; searches will work again next month.
        case outOfCredit
        /// Could not reach brave at all. Says nothing about the key.
        case unreachable
        /// Brave answered with a server error. Also says nothing about the key.
        case braveUnavailable(status: Int)
    }

    /// Spends one real search to find out, because there is no cheaper way to
    /// know and a wrong key is otherwise SILENT: it saves, the chip lights, and
    /// every later search 401s where only the model can see it.
    static func checkKey(_ apiKey: String, http: any HTTPClient = URLSessionHTTP()) async -> KeyCheck {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected }

        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "teemoon key check"),
            URLQueryItem(name: "maximum_number_of_urls", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(trimmed, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (_, response) = try await http.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            switch http.statusCode {
            case 200...299: return .valid
            case 401, 403:  return .rejected
            case 429:       return .outOfCredit
            default:        return .braveUnavailable(status: http.statusCode)
            }
        } catch {
            // No signal about the key itself — offline, DNS, timeout. Telling
            // the user their key is wrong here would be a guess, and the wrong
            // one most of the time.
            return .unreachable
        }
    }

    // MARK: - Source parsing

    /// Parses `GroundingSource` values out of the XML context string produced by `fetchContext`.
    /// Format: `<source index="N"><url>…</url><title>…</title>[<published>…</published>]<content>…</content></source>`
    static func parseSources(from toolResult: String) -> [GroundingSource] {
        let pattern = #/<source[^>]*>\s*<url>(.*?)<\/url>\s*<title>(.*?)<\/title>(?:\s*<published>.*?<\/published>)?\s*<content>(.*?)<\/content>\s*<\/source>/#.dotMatchesNewlines()
        return toolResult.matches(of: pattern).map { match in
            let url = String(match.output.1)
            return GroundingSource(
                url: url,
                domain: URL(string: url)?.host ?? url,
                title: String(match.output.2),
                snippet: String(match.output.3)
            )
        }
    }

    /// Extracts unique `GroundingSource` values from markdown links (`[title](url)`) in a string.
    /// Used to surface only the sources the model actually cited in its response.
    static func parseMarkdownLinks(from text: String) -> [GroundingSource] {
        let pattern = /\[([^\]]+)\]\((https?:\/\/[^)]+)\)/
        var seen = Set<String>()
        return text.matches(of: pattern).compactMap { match in
            let url = String(match.output.2)
            guard seen.insert(url).inserted else { return nil }
            return GroundingSource(
                url: url,
                domain: URL(string: url)?.host ?? url,
                title: String(match.output.1)
            )
        }
    }

    // MARK: - Private fetch

    private static let endpoint = "https://api.search.brave.com/res/v1/llm/context"

    private func fetchContext(for query: String, freshness: String? = nil, contextThresholdMode: String? = nil, count: Int? = nil) async throws -> String {
        guard var components = URLComponents(string: Self.endpoint) else {
            throw LLMError(source: .braveGrounding,
                           userMessage: "Brave web search failed — invalid endpoint URL.",
                           httpStatus: nil, url: nil,
                           requestHeaders: nil, requestBodyJSON: nil,
                           messageHistory: nil, responseBody: nil, underlyingError: nil)
        }
        // Default 10 pages: halves follow-up payload vs. the old 20-page default (4096 vs 8192
        // max tokens), reducing upload time and model input tokens for the final response turn.
        let resolvedCount = count ?? 10
        let maxTokens = GroundingBudget.maxTokens(forCount: resolvedCount, onDevice: onDevice)
        // Cap returned sources to avoid flooding the context window.
        // Brave may fetch `count` pages but we only need the best N in the output.
        let maxURLs = GroundingBudget.urlCap(forCount: resolvedCount, onDevice: onDevice)
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maximum_number_of_tokens", value: String(maxTokens)),
            URLQueryItem(name: "maximum_number_of_urls", value: String(maxURLs)),
        ]
        if let freshness { items.append(URLQueryItem(name: "freshness", value: freshness)) }
        if let contextThresholdMode { items.append(URLQueryItem(name: "context_threshold_mode", value: contextThresholdMode)) }
        if resolvedCount != 10 { items.append(URLQueryItem(name: "count", value: String(resolvedCount))) }
        components.queryItems = items

        guard let url = components.url else {
            throw LLMError(source: .braveGrounding,
                           userMessage: "Brave web search failed — invalid URL.",
                           httpStatus: nil, url: nil,
                           requestHeaders: nil, requestBodyJSON: nil,
                           messageHistory: nil, responseBody: nil, underlyingError: nil)
        }

        // An EXPLICIT timeout, because the defaults do not bound this.
        //
        // `URLRequest`'s default 60 s is an *idle* timeout — it fires only when
        // no bytes move — and `timeoutIntervalForResource` defaults to SEVEN
        // DAYS. A connection that opens and then stalls therefore hangs
        // indefinitely, and this call sits inside a tool round: the model is
        // waiting on the search, the user is waiting on the model, and nothing
        // ever times out.
        //
        // Observed on device: a live suite stopped dead here for 16 minutes with
        // no error, twice. Every other network call in teemoon sets 10-20 s;
        // this one was relying on defaults that do not mean what they look like.
        //
        // A failed search is recoverable — the tool returns an error string the
        // model can answer around. A hung one is not.
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await http.data(for: request)
        } catch {
            throw LLMError(source: .braveGrounding,
                           userMessage: "Brave web search failed — check your network connection.",
                           httpStatus: nil, url: url,
                           requestHeaders: ["X-Subscription-Token": apiKey],
                           requestBodyJSON: nil, messageHistory: nil,
                           responseBody: nil, underlyingError: error)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LLMError(source: .braveGrounding,
                           userMessage: LLMError.groundingMessage(httpStatus: http.statusCode),
                           httpStatus: http.statusCode, url: url,
                           requestHeaders: ["X-Subscription-Token": apiKey],
                           requestBodyJSON: nil, messageHistory: nil,
                           responseBody: String(data: data, encoding: .utf8),
                           underlyingError: nil)
        }

        guard let decoded = try? JSONDecoder().decode(BraveGroundingResponse.self, from: data) else {
            throw LLMError(source: .braveGrounding,
                           userMessage: "Brave web search returned an unexpected response format.",
                           httpStatus: nil, url: url,
                           requestHeaders: ["X-Subscription-Token": apiKey],
                           requestBodyJSON: nil, messageHistory: nil,
                           responseBody: String(data: data, encoding: .utf8),
                           underlyingError: nil)
        }

        let context = Self.contextXML(from: decoded)
        guard !context.isEmpty else {
            throw LLMError(source: .braveGrounding,
                           userMessage: "Brave web search returned no results for this query.",
                           httpStatus: nil, url: url,
                           requestHeaders: ["X-Subscription-Token": apiKey],
                           requestBodyJSON: nil, messageHistory: nil,
                           responseBody: nil, underlyingError: nil)
        }
        return context
    }

    // MARK: - Context rendering

    /// Renders the grounding payload as the `<source>` XML handed to the model.
    ///
    /// `grounding.generic` supplies the passages; the top-level `sources` map
    /// supplies the metadata it omits — a cleaner page-level title, and the
    /// publish date, which the model needs to judge whether a passage is
    /// actually current. Its `snippet` is also the fallback when a page came
    /// back with no passages at all.
    /// `includePublished` exists so the date signal can be A/B'd against the
    /// same grounding payload — Brave's results span different dates, and
    /// whether that actually helps a small model pick the current one is a
    /// measurement, not an assumption.
    static func contextXML(from response: BraveGroundingResponse,
                           includePublished: Bool = true) -> String {
        response.grounding.generic
            .compactMap { page -> String? in
                guard !page.url.isEmpty else { return nil }
                let meta = response.sources?[page.url]
                // Join multiple snippets with an ellipsis marker so the model can see
                // they are discrete passages rather than one continuous block of text.
                // Each is unpacked first: some arrive as JSON-LD, and the model should
                // read facts rather than syntax. See `readableSnippet`.
                let snippets = (page.snippets ?? [])
                    .map(GroundingSource.readableSnippet)
                    .filter { !$0.isEmpty }
                let content = snippets.isEmpty
                    ? GroundingSource.readableSnippet(meta?.snippet ?? "")
                    : snippets.joined(separator: " […] ")
                guard !content.isEmpty else { return nil }

                let title = [page.title, meta?.title]
                    .compactMap { $0 }
                    .first(where: { !$0.isEmpty }) ?? ""
                let published = includePublished
                    ? (meta?.displayDate.map { "\n<published>\($0)</published>" } ?? "")
                    : ""

                return """
                <url>\(page.url)</url>
                <title>\(title)</title>\(published)
                <content>\(content)</content>
                """
            }
            .enumerated()
            .map { i, body in "<source index=\"\(i + 1)\">\n\(body)\n</source>" }
            .joined(separator: "\n")
    }
}

// MARK: - Cited-source reconciliation

extension GroundingSource {
    /// Sources to persist with an assistant message: prefers links the model
    /// explicitly cited in `output`, enriched with snippets from the full
    /// grounding results; falls back to all grounding sources when the model
    /// cited nothing.
    static func citedOrAll(in output: String, grounding: [GroundingSource]) -> [GroundingSource] {
        let cited = BraveWebSearchTool.parseMarkdownLinks(from: output)
        guard !cited.isEmpty else { return grounding }
        let snippetsByURL = Dictionary(grounding.map { ($0.url, $0.snippet) },
                                       uniquingKeysWith: { first, _ in first })
        return cited.map { source in
            let snippet = snippetsByURL[source.url] ?? ""
            return snippet.isEmpty ? source : GroundingSource(
                url: source.url, domain: source.domain, title: source.title, snippet: snippet
            )
        }
    }

    /// JSON encoding for Message.sourcesJSON; nil when there is nothing to save.
    static func encodedJSON(_ sources: [GroundingSource]) -> String? {
        guard !sources.isEmpty,
              let data = try? JSONEncoder().encode(sources) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
