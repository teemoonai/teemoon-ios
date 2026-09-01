//
//  ToolCallFormat.swift
//  teemoon
//
//  Pluggable text tool-call formats. A model that isn't given native `tool_calls`
//  (or chooses to emit them inline) writes them in ITS OWN syntax — the chat template
//  decides — so teemoon can't assume one format. Each case declares the marker(s) that
//  identify it in the content stream and how to parse its calls; the parser detects by
//  marker and dispatches. Adding a model family = add a case (the compiler then flags
//  every switch), with no change to SSEStreamParser.
//
//  WHEN THIS FIRES (gotcha): only when the server returns the tool call as RAW content.
//  Servers that native-parse the model's template (e.g. Ollama's OpenAI endpoint) return
//  structured `tool_calls` and empty content — teemoon's normal `tool_calls` decoding
//  handles those, and this text parser is never reached. It exists for servers that DON'T
//  parse: raw llama.cpp, or a model on a vLLM/near.ai endpoint with no matching tool parser.
//  Verified live: gemma4:e2b-it-qat emits `\`\`\`tool_code\nname(k="v")\n\`\`\`` as raw
//  content in exactly that case (see ToolCallFormatTests.parsesRealGemmaOutput).
//
//  Modelled as an enum, not a protocol: this is a CLOSED, teemoon-owned set (no
//  third-party conformances), so an exhaustive enum is the idiomatic Swift shape — and
//  it matches ModelDefaultRule. Wire formats per family (vLLM/SGLang parser sources):
//  Qwen/GLM `<tool_call>…`, Gemma ```` ```tool_code ```` python calls, DeepSeek
//  `<｜tool▁calls▁begin｜>`, gpt-oss Harmony `…to=functions.NAME<|message|>{json}`. The
//  last two are unlisted until we can test against their real output.
//

import Foundation

enum ToolCallFormat: CaseIterable {
    case angleBracket   // <tool_call> — Qwen / GLM (+ JSON / <function=> / <arg_key> / kwarg-collapse)
    case gemmaToolCode  // ```tool_code — Gemma python calls

    /// Substrings whose presence signals this format — used both to suppress the raw
    /// syntax from the visible reply and to route parsing.
    var markers: [String] {
        switch self {
        case .angleBracket:  return ["<tool_call>"]
        case .gemmaToolCode: return ["```tool_code"]
        }
    }

    /// The marker that CLOSES a region one of this format's `markers` opened.
    ///
    /// Streaming elision (SSEStreamParser) suppresses from an opening marker
    /// through this close and then RESUMES forwarding — the fix for the sticky
    /// suppression that withheld the whole second half of a prose→call→prose
    /// turn until [DONE]. An exhaustive switch on purpose: adding a format case
    /// without declaring how its region ends must not compile, because a family
    /// the elision can't close would silently regress to end-of-turn batching.
    var closingMarker: String {
        switch self {
        case .angleBracket:  return "</tool_call>"
        // Gemma's fence closes with a bare ``` — the elision only searches for
        // it AFTER the opening ```tool_code, so the opener can't self-close.
        case .gemmaToolCode: return "```"
        }
    }

    /// Parse tool calls out of the full accumulated content in this format.
    func parse(_ content: String, tools: [RecoveryToolSpec]) -> [Int: ToolCallState] {
        switch self {
        case .angleBracket:  return SSEStreamParser.parseAngleBracketToolCalls(from: content, tools: tools)
        case .gemmaToolCode: return GemmaToolCode.parse(content)
        }
    }

    // MARK: registry (free via CaseIterable)

    /// Every marker across formats — for the (cheap) suppression scan in the parser.
    static let allMarkers: [String] = allCases.flatMap(\.markers)

    /// Every (open, close) pair across formats — the streaming elision scans these
    /// so it knows both where a markup region starts and where prose resumes.
    static let markerPairs: [(open: String, close: String)] =
        allCases.flatMap { fmt in fmt.markers.map { (open: $0, close: fmt.closingMarker) } }

    /// Longest marker, so the streaming boundary scan keeps a large-enough tail.
    static let maxMarkerLength: Int = allMarkers.map(\.count).max() ?? 1

    /// Parse using the first format whose marker appears and yields at least one call.
    static func parseAny(_ content: String, tools: [RecoveryToolSpec]) -> [Int: ToolCallState] {
        for fmt in allCases where fmt.markers.contains(where: { content.contains($0) }) {
            let calls = fmt.parse(content, tools: tools)
            if !calls.isEmpty { return calls }
        }
        return [:]
    }
}

// MARK: - Streaming markup elision (the shared state machine)

/// Elides text tool-call markup REGIONS out of a streaming reply, so raw
/// syntax never reaches the user while the prose around a call keeps
/// streaming: forward until an opening marker, suppress through that format's
/// closing marker (`ToolCallFormat.markerPairs`), then resume forwarding.
///
/// ONE machine, TWO feeders — deliberately. `SSEStreamParser` (network) and
/// `LiteRTTransport` (on-device) each had the same defect independently:
/// suppression that LATCHED on the first marker and withheld the whole rest of
/// the turn, so a prose→call→prose reply arrived with its second half in one
/// batch. Fixing them separately is how they drift apart the next time a
/// format is added — so both now drive this class, and a new `ToolCallFormat`
/// case reaches both paths by construction (its `closingMarker` switch won't
/// even compile without declaring how the new region ends).
///
/// The two streams turn out to have the same shape. SSE is delta-fed by
/// definition; LiteRT LOOKS cumulative at its call site (it streams a growing
/// `answer`), but the engine actually yields per-chunk pieces and the
/// transport does the accumulating itself — so the delta machine serves both,
/// and `visibleContent` is the cumulative already-elided string either caller
/// can hand straight to `onPartialContent`.
///
/// The contract, carried over verbatim from the SSE fix:
///  - A marker split across chunks is neither missed nor forwarded-then-
///    retracted: while forwarding, a suffix that is a proper prefix of an
///    opening marker is HELD BACK until the next chunk disambiguates it; while
///    suppressing, a bounded tail of elided text is kept so a split closing
///    marker is still recognized. The scan is O(chunk), never O(accumulated).
///  - `visibleContent` only ever GROWS by appending. A snapshot a caller has
///    already shown is never rewritten — that monotonicity is what makes it
///    safe to display live (no flicker, no retraction).
///  - An UNTERMINATED region stays suppressed to end of turn: leaking half a
///    call is worse than batching its tail, and the end-of-turn sanitize pass
///    (`SSEStreamParser.sanitizeToolMarkup`) remains the containment net.
///
/// Elision affects only what is SHOWN. Callers keep their own raw
/// accumulation for machine consumption — SSE recovers text tool calls from
/// it at [DONE]; LiteRT parses thinking out of it for the final `TurnOutput`.
final class ToolMarkupElider {

    /// The cumulative user-visible text: everything appended so far with
    /// markup regions elided. Callers may stream this directly; it must never
    /// contain markup, not even transiently.
    private(set) var visibleContent = ""

    /// Whether any markup region was entered. Distinct from the CURRENT state,
    /// which is back to `.forwarding` once a call closes — the SSE [DONE]
    /// handler keys text tool-call recovery off this.
    private(set) var markerSeen = false

    /// When false, `append` passes everything through unscanned. The SSE path
    /// disables elision when no tools are configured (markup can't be a tool
    /// call then); the on-device path always enables it, because a small local
    /// model may emit tool syntax whether or not tools were offered.
    private let enabled: Bool

    private enum State {
        case forwarding
        /// Inside a markup region; `close` is the marker that ends it.
        case suppressing(close: String)
    }
    private var state: State = .forwarding

    /// While forwarding: a suffix of otherwise-visible text held back because
    /// it is a proper prefix of an opening marker (at most maxMarkerLength − 1
    /// chars). Released by the next chunk or by `finish()`.
    private var heldBack = ""

    /// While suppressing: the last close.count − 1 suppressed chars, so a
    /// closing marker split across chunks is still seen. Never forwarded.
    private var suppressedTail = ""

    /// True while inside a markup region (callers withhold non-content frames
    /// mid-region).
    var isSuppressing: Bool {
        if case .suppressing = state { return true }
        return false
    }

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    /// Consumes one delta and returns its visible portion (also appended to
    /// `visibleContent`). An empty return means nothing new may be shown yet —
    /// either the chunk was markup through and through, or its tail is an
    /// ambiguous maybe-marker being held back.
    @discardableResult
    func append(_ chunk: String) -> String {
        guard enabled else {
            visibleContent += chunk
            return chunk
        }
        let visible = elide(chunk)
        visibleContent += visible
        return visible
    }

    /// End of turn while forwarding: the held-back tail was NOT the start of a
    /// marker after all — it belongs to the visible reply; returns it (also
    /// appended to `visibleContent`). While suppressing, deliberately a no-op:
    /// the tail of an UNTERMINATED region stays elided, because partial markup
    /// must never leak.
    @discardableResult
    func finish() -> String {
        guard case .forwarding = state, !heldBack.isEmpty else { return "" }
        let released = heldBack
        heldBack = ""
        visibleContent += released
        return released
    }

    /// The elision state machine. Consumes one chunk plus the bounded tail the
    /// previous chunk left behind; never rescans the accumulated reply.
    private func elide(_ chunk: String) -> String {
        // Prepend the carried tail for THIS state: held-back maybe-marker prose
        // when forwarding, the suppressed close-scan window when suppressing.
        // (Exactly one is ever non-empty.)
        var work: Substring
        switch state {
        case .forwarding:  work = (heldBack + chunk)[...];       heldBack = ""
        case .suppressing: work = (suppressedTail + chunk)[...]; suppressedTail = ""
        }

        var out = ""
        while !work.isEmpty {
            switch state {
            case .forwarding:
                // Earliest opening marker of ANY registered format wins — a reply
                // could legitimately contain a later marker of another family.
                var earliest: (open: Range<Substring.Index>, close: String)?
                for (open, close) in ToolCallFormat.markerPairs {
                    if let r = work.range(of: open),
                       earliest == nil || r.lowerBound < earliest!.open.lowerBound {
                        earliest = (r, close)
                    }
                }
                if let (openRange, close) = earliest {
                    out += work[..<openRange.lowerBound]
                    work = work[openRange.upperBound...]
                    state = .suppressing(close: close)
                    markerSeen = true
                } else {
                    // No marker — but the chunk may END with the start of one. Hold
                    // that tail back rather than forward-then-retract it.
                    let hold = Self.markerPrefixHoldback(of: work)
                    out += work.dropLast(hold.count)
                    heldBack = hold
                    return out
                }
            case .suppressing(let close):
                if let closeRange = work.range(of: close) {
                    // Region closed: drop the markup, resume forwarding after it.
                    // (suppressedTail chars were already elided, and `close` is
                    // longer than the tail, so the resume point is inside the
                    // new chunk — nothing gets elided twice or shown twice.)
                    work = work[closeRange.upperBound...]
                    state = .forwarding
                } else {
                    // Still inside the region. Keep just enough suppressed tail to
                    // recognize a close split across the next boundary.
                    suppressedTail = String(work.suffix(close.count - 1))
                    return out
                }
            }
        }
        return out
    }

    /// The longest suffix of `s` that is a PROPER prefix of any opening marker —
    /// the text that cannot be shown yet because the next chunk may complete a
    /// marker. Full markers never reach here: `elide` already consumed them.
    private static func markerPrefixHoldback(of s: Substring) -> String {
        let maxLen = min(s.count, ToolCallFormat.maxMarkerLength - 1)
        guard maxLen > 0 else { return "" }
        for len in stride(from: maxLen, through: 1, by: -1) {
            let suffix = s.suffix(len)
            if ToolCallFormat.allMarkers.contains(where: { $0.count > len && $0.starts(with: suffix) }) {
                return String(suffix)
            }
        }
        return ""
    }
}

// MARK: - Gemma ```tool_code parsing

/// Gemma emits function calls inside a ```` ```tool_code ```` fenced block using Python
/// call syntax — `web_search(query="weather in SF", count=5)` — optionally wrapped in
/// `print(...)`. https://ai.google.dev/gemma/docs/capabilities/function-calling
enum GemmaToolCode {
    static func parse(_ content: String) -> [Int: ToolCallState] {
        var result: [Int: ToolCallState] = [:]
        var idx = 0
        var search = content.startIndex..<content.endIndex
        while let open = content.range(of: "```tool_code", range: search) {
            let after = open.upperBound
            let close = content.range(of: "```", range: after..<content.endIndex)
            let body = content[after..<(close?.lowerBound ?? content.endIndex)]
            search = (close?.upperBound ?? content.endIndex)..<content.endIndex
            for call in pythonCalls(in: String(body)) {
                result[idx] = ToolCallState(id: "text_tool_\(idx)", name: call.name, arguments: call.argsJSON)
                idx += 1
            }
        }
        return result
    }

    /// Extract `name(args…)` calls (stripping a `print(…)` wrapper) and JSON-encode the
    /// kwargs. One call per line / semicolon.
    static func pythonCalls(in body: String) -> [(name: String, argsJSON: String)] {
        var out: [(String, String)] = []
        for raw in body.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("print(") && line.hasSuffix(")") {
                line = String(line.dropFirst("print(".count).dropLast())
            }
            guard let openParen = line.firstIndex(of: "("), line.hasSuffix(")") else { continue }
            let name = String(line[..<openParen]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else { continue }
            let argStr = String(line[line.index(after: openParen)..<line.index(before: line.endIndex)])
            let json = (try? JSONSerialization.data(withJSONObject: parseKwargs(argStr)))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            // Names can be dotted (functions.web_search) — take the last segment.
            out.append((name.split(separator: ".").last.map(String.init) ?? name, json))
        }
        return out
    }

    /// `k="v", k2=3, k3=true` → [String: Any], splitting on top-level commas only.
    static func parseKwargs(_ s: String) -> [String: Any] {
        var args: [String: Any] = [:]
        for part in splitTopLevel(s, on: ",") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces)
            let val = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { args[key] = pythonLiteral(val) }
        }
        return args
    }

    /// Split on `sep` when not inside quotes or brackets.
    static func splitTopLevel(_ s: String, on sep: Character) -> [String] {
        var parts: [String] = []; var cur = ""; var depth = 0; var inStr: Character? = nil
        for ch in s {
            if let q = inStr { cur.append(ch); if ch == q { inStr = nil }; continue }
            switch ch {
            case "\"", "'": inStr = ch; cur.append(ch)
            case "(", "[", "{": depth += 1; cur.append(ch)
            case ")", "]", "}": depth -= 1; cur.append(ch)
            case sep where depth == 0: parts.append(cur); cur = ""
            default: cur.append(ch)
            }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(cur) }
        return parts
    }

    /// A Python literal → JSON value: quoted → String, true/false → Bool, int/float →
    /// number, else the raw token as a string.
    static func pythonLiteral(_ v: String) -> Any {
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            return String(v.dropFirst().dropLast())
        }
        switch v {
        case "true", "True":   return true
        case "false", "False": return false
        default: break
        }
        if let i = Int(v) { return i }
        if let d = Double(v) { return d }
        return v
    }
}
