//
//  RequestDebugView.swift
//  teemoon

import SwiftUI

/// Solid fill, not material. `.ultraThinMaterial` (even over a plate)
/// still composites a frame late inside `UIHostingConfiguration`, so
/// type painted first and the fill second. An opaque surface is one paint.
///
/// SECONDARY, not `background`. `PlatformColors.background` is
/// `systemBackground`, which is the colour the transcript itself is drawn
/// on — in dark mode both are pure black, so the card lost its edges and
/// read as a black slab rather than a panel (the 0.5pt stroke is not
/// enough on its own). `secondaryBackground` is the raised-surface colour
/// the rest of the app already uses (`MessageView`, `WebSearchOffer`,
/// `ChatView`) and it stays one opaque paint, so the paint-order fix above
/// is untouched.
extension View {
    func debugCardSurface(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(PlatformColors.secondaryBackground))
            .clipShape(shape)
    }
}

// MARK: - RequestDebugView

/// Shown in the conversation when developer mode is enabled, after every successful generation.
/// Identical layout to ErrorMessageView but with neutral styling — not error-framed.
struct RequestDebugView: View {
    let info: LastRequestDebugInfo

    /// Injectable so the on-device `load` figure can be LOOKED at.
    ///
    /// It read `LocalEngineResidency.shared` directly, and a canvas builds no
    /// engine — so the one row that had never been reviewed was the row this card
    /// gained most recently, and seeing it meant a cold generation on a device.
    /// Defaulted, so no production call site changes.
    var residency: LocalEngineResidency = .shared

    /// What building the on-device engine cost, when there is one.
    ///
    /// ON-DEVICE ONLY (`info.url == nil` is exactly that case). Measured 2.3–4.0 s
    /// cold against 0.86 s warm on an iPhone 16 Pro, which is usually the whole
    /// explanation for a slow first answer — and it existed only in a log line.
    ///
    /// Lives on the HEADER row, beside `on-device`, not in the timing chain below.
    /// Two reasons, and they agree:
    ///
    /// - It is a SESSION fact, not a turn fact. One build serves every turn until
    ///   it's evicted, so listing it among this turn's numbers implies this turn
    ///   paid it, which is false from the second message onward. The header is
    ///   already where session-scoped facts live (`on-device`, `E2EE`).
    /// - The timing chain is six values joined by separators and was already near
    ///   the card's width; a seventh wrapped it to two lines. The header had room.
    ///
    /// A home model's load can't appear here: Ollama loads inside the request and
    /// never reports what it cost, so there is no figure to show.
    private var engineLoadPart: String? {
        guard info.url == nil, let load = residency.lastLoad
        else { return nil }
        let seconds = Double(load.took.components.seconds)
            + Double(load.took.components.attoseconds) / 1e18
        return "load \(seconds.debugFormatted)"
    }

    /// Full debug dump copied to the clipboard. Credentials are redacted here
    /// and NOT on screen — see `DebugHeaderRedaction.copyValue`.
    var debugText: String {
        var parts: [String] = []
        // The FULL id here, unlike the header — a pasted card is read away from the
        // app, where `accounts/fireworks/models/deepseek-v4-flash` is the only form
        // that can be pasted back into a request.
        parts.append("=== \(info.providerName)\(info.modelID.isEmpty ? "" : " \(info.modelID)") Debug ===")
        let timingParts: [String] = [
            info.totalDuration.map    { $0.debugFormatted },
            info.timeToFirstToken.map { "ttft \($0.debugFormatted)" },
            // Between ttft and gen, which is the order it happens in — and the
            // number that explains a "slow" answer from a warm model. Absent when
            // the model didn't think, so a non-reasoning row doesn't grow a "0s".
            info.thinkingTime.map     { "think \($0.debugFormatted)" },
            info.generationTime.map   { "gen \($0.debugFormatted)" },
            info.outputTokens.map     { "\($0)tok" },
            info.tokensPerSecond.map  { String(format: "%.0ftok/s", $0) },
            engineLoadPart
        ].compactMap { $0 }
        if !timingParts.isEmpty { parts.append(timingParts.joined(separator: " · ")) }
        if let url = info.url {
            parts.append("\n--- URL ---\n\(DebugHeaderRedaction.copyURLString(url.absoluteString))")
        }
        if let headers = info.requestHeaders, !headers.isEmpty {
            parts.append("\n--- Headers ---\n\(DebugHeaderRedaction.copyHeaderBlock(headers))")
        }
        if let body = info.requestBodyJSON {
            parts.append("\n--- Request Body ---\n\(info.isE2EEActive ? compactRequestBody(body) : body)")
        }
        for (i, tc) in info.toolCalls.enumerated() {
            var sig = toolCallSignature(name: tc.name, arguments: tc.arguments, result: tc.result)
            if let sub = toolCallSubtitle(name: tc.name, arguments: tc.arguments) { sig += " \(sub)" }
            let label = info.toolCalls.count > 1 ? "\(sig) \(i + 1)" : sig
            if let json = sourcesJSONString(tc.result) {
                parts.append("\n--- Tool: \(label) · Response JSON ---\n\(json)")
            }
            parts.append("\n--- Tool: \(label) · Response for LLM ---\n\(tc.result)")
        }
        if let response = info.responseBody, !response.isEmpty { parts.append("\n--- Response ---\n\(response)") }
        return parts.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 6) {
                Image(systemName: "hammer.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(info.providerName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                // The model as SENT, in the id's own spelling — `deepseek-v4-flash`,
                // not the catalogue's `DeepSeek V4 Flash`. A debug card should print
                // what went on the wire, and that difference is one of the things you
                // open this card to check.
                //
                // Container prefix dropped (`accounts/fireworks/models/…`), because it
                // names the hosting account and the url row above already says which
                // host answered; kept whole it would eat the header.
                //
                // This row exists because the header named the provider RECORD's
                // label, which is auto-generated as "<provider> <model>" when a key is
                // saved and never refreshed — so it kept naming the model the key was
                // added with, on the one surface whose job is to say what was sent.
                // NOT on-device, where the header would print the model twice.
                // `Provider.local` names the record after the model it wraps
                // (`Provider.local` → `name: model.displayName`), so the first token
                // is already "gemma 4 e2b" — and the second copy was the useless
                // half: the repo id's tail is `-it-litert-lm`, a tuning marker plus
                // a file format plus a runtime, middle-truncated into
                // "gemma-4…tert-lm". `compactName` can't rescue that either; it
                // peels build words from cloud ids and has never heard of litert.
                //
                // Nothing is lost — an on-device provider IS one model (they all
                // share the literal endpoint "on-device"), the `on-device` token
                // right after says where it ran, and the full repo id is in the
                // request body below and in the copied text.
                if !info.modelID.isEmpty, info.url != nil {
                    Text(ModelCatalog.displayName(forID: info.modelID))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // "HTTP 200" is a lie for on-device inference: nothing was
                // sent anywhere. `url == nil` is exactly the local case.
                Text(info.url == nil ? "on-device" : "HTTP 200")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if let engineLoadPart {
                    Text(engineLoadPart)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if info.isE2EEActive {
                    Text("E2EE")
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("chat.debugCard.e2ee")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let url = info.url {
                InlineDebugRow(label: "url", value: url.absoluteString, scrollable: true)
            }
            if info.totalDuration != nil || info.timeToFirstToken != nil {
                let parts: [String] = [
                    info.totalDuration.map    { $0.debugFormatted },
                    info.timeToFirstToken.map { "ttft \($0.debugFormatted)" },
                    // Between ttft and gen, the order it happens in. Absent when the
                    // model didn't think, so a plain row doesn't sprout a "think 0s".
                    info.thinkingTime.map     { "think \($0.debugFormatted)" },
                    info.generationTime.map   { "gen \($0.debugFormatted)" },
                    info.outputTokens.map     { "\($0)tok" },
                    info.tokensPerSecond.map  { String(format: "%.0ftok/s", $0) }
                ].compactMap { $0 }
                Divider().padding(.leading, 12)
                // ONE LINE, always. The chain is a shape as much as a set of numbers:
                // six values in a row read as one measurement of one request, and the
                // same six wrapped read as two of something. It fit at five and
                // `think` was the sixth, so rather than drop a figure to keep the
                // shape, the line scales itself down the few percent it needs.
                //
                // A floor, not free rein: 0.75 of caption2 is still legible, and if a
                // future part cannot fit inside that, the truncation is the signal
                // that the chain has outgrown the row.
                Text(parts.joined(separator: " · "))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            // Loud, and above the request: the answer above this card may be a
            // reply to a question the server threw away, and nothing else on
            // screen would say so.
            if let budget = info.promptBudget, budget.looksTruncated {
                Divider().padding(.leading, 12)
                VStack(alignment: .leading, spacing: 2) {
                    Label("context truncated", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                    Text("server evaluated \(budget.evaluated) of ~\(budget.sentEstimate) input tokens — it dropped the front of the prompt (system prompt and question first). raise its context window; ollama: OLLAMA_CONTEXT_LENGTH")
                        .font(.system(.caption2, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            if let headers = info.requestHeaders, !headers.isEmpty {
                let formatted = headers
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key): \(DebugHeaderRedaction.value($0.value, for: $0.key))" }
                    .joined(separator: "\n")
                CollapsibleDebugRow(label: "headers (\(headers.count))", content: formatted)
            }
            if let body = info.requestBodyJSON {
                if info.isE2EEActive {
                    EncryptedBodyDebugRow(content: body, sealed: info.sealedBodyJSON)
                } else {
                    CollapsibleDebugRow(label: "request body", content: body)
                }
            }
            if !info.toolCalls.isEmpty {
                ForEach(Array(info.toolCalls.enumerated()), id: \.offset) { i, tc in
                    let sig = toolCallSignature(name: tc.name, arguments: tc.arguments, result: tc.result)
                    let callLabel = "tool: \(sig)"
                    ToolCallDebugRow(
                        label: callLabel,
                        subtitle: toolCallSubtitle(name: tc.name, arguments: tc.arguments),
                        rawJSON: sourcesJSONString(tc.result),
                        // Bounded — the full payload stays on the copy path.
                        // Mounting a whole unbounded tool result here is what
                        // blanked the screen (see ToolCallRecord.displayCap).
                        processedForLLM: tc.displayResult
                    )
                }
            }
            if let responseContent = info.responseBody, !responseContent.isEmpty {
                CollapsibleDebugRow(label: "response", content: responseContent)
            }
        }
        .fontDesign(.monospaced)
        .debugCardSurface()
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        // Combined label is just "build " to XCUI (the material card reads
        // as an Image). Stamp E2EE here so a UI test can see the seal
        // without walking children the container hides.
        .accessibilityValue(info.isE2EEActive ? "E2EE" : "not-e2ee")
        .contextMenu {
            Button {
                #if os(iOS) || os(visionOS)
                UIPasteboard.general.string = debugText
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(debugText, forType: .string)
                #endif
            } label: {
                Label("Copy Debug Info", systemImage: "square.on.square")
            }
        }
    }
}

/// Formats a tool call header. For web_search the query is omitted (shown as subtitle instead).
/// - Single string field: `name("value")`
/// - web_search: `web_search · fresh:pd · mode:strict · n:10 · fetched:7`
/// - Fallback: `name({...})`
func toolCallSignature(name: String, arguments: String, result: String = "") -> String {
    guard let data = arguments.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return "\(name)(\(arguments))" }

    // web_search is matched BEFORE the single-field shorthand. Every argument
    // but `query` is optional, so the shorthand used to catch exactly those
    // calls where the model happened to pass nothing else — rendering two
    // identical searches in two different formats within one card, one with the
    // query inline and one (`web_search · n:5 -> 4`) with no query at all.
    if name == "web_search" {
        var parts: [String] = [name]
        if let freshness = json["freshness"] as? String { parts.append("fresh:\(freshness)") }
        if let mode = json["contextThresholdMode"] as? String, mode != "balanced" { parts.append("mode:\(mode)") }
        if let count = json["count"] as? Int, count != 20 { parts.append("n:\(count)") }
        let fetched = BraveWebSearchTool.parseSources(from: result).count
        let base = parts.joined(separator: " · ")
        return fetched > 0 ? "\(base) -> \(fetched)" : base
    }

    if json.count == 1, let value = json.values.first as? String {
        return "\(name)(\"\(value)\")"
    }

    return "\(name)(\(arguments))"
}

/// Returns the always-visible subtitle for a tool call row, if any.
/// For web_search: the full query string, untruncated.
///
/// Falls back to the raw arguments when there is no `query` to show. The header
/// omits the query for every web_search row, so without a fallback a call the
/// model emitted without one — the shape that also fails `@Generable` decoding —
/// renders as a row with no identifying text anywhere.
func toolCallSubtitle(name: String, arguments: String) -> String? {
    guard name == "web_search" else { return nil }
    guard let data = arguments.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let query = json["query"] as? String
    else { return arguments.isEmpty ? nil : arguments }
    return "\"\(query)\""
}

/// Reconstructs the Brave API response shape from parsed tool result text.
/// Returns nil if no SOURCE blocks are found.
/// Wraps in `{"grounding":{"generic":[...]}}` to mirror the actual API structure.
private func sourcesJSONString(_ result: String) -> String? {
    let sources = BraveWebSearchTool.parseSources(from: result)
    guard !sources.isEmpty else { return nil }
    let generic: [[String: String]] = sources.map {
        ["url": $0.url, "title": $0.title, "snippet": $0.snippet]
    }
    let wrapper: [String: Any] = ["grounding": ["generic": generic]]
    guard let data = try? JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted, .sortedKeys]),
          let str = String(data: data, encoding: .utf8) else { return nil }
    return str
}

/// Returns a pretty-printed version of `string` if it is valid JSON, otherwise returns it unchanged.
func prettyJSONString(_ string: String) -> String {
    guard let data = string.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
          let result = String(data: pretty, encoding: .utf8)
    else { return string }
    return result
}

/// Produces a compact version of a JSON request body by truncating hex ciphertext values.
/// Long hex strings (≥ 64 chars) are replaced with `"ab01…ef99" (341 bytes, encrypted)`.
func compactRequestBody(_ json: String) -> String {
    json.replacing(/"[0-9a-f]{64,}"/) { match in
        let hex = match.output.dropFirst().dropLast() // strip quotes
        let byteCount = hex.count / 2
        return "\"\(hex.prefix(8))…\(hex.suffix(8))\" (\(byteCount) bytes, encrypted)"
    }
}

// MARK: - Preview

/// A CLOUD request, which is why there is no `load` on the header — that figure is
/// on-device only.
///
/// Named for a provider teemoon actually ships. This said "OpenAI" against an
/// `api.openai.com` url, which is not in `Provider.presets` and never was on this
/// branch, so the one preview of this card described a configuration the app cannot
/// produce.
#Preview("Request Debug View") {
    ScrollView {
        RequestDebugView(info: LastRequestDebugInfo(
            providerName: "grok",
            modelID: "grok-4.3",
            url: URL(string: "https://api.x.ai/v1/chat/completions"),
            requestHeaders: [
                "Authorization": "Bearer xai-abc123def456",
                "Content-Type": "application/json"
            ],
            requestBodyJSON: """
            {
              "messages" : [
                { "role" : "system", "content" : "You are a helpful assistant." },
                { "role" : "user", "content" : "What is the weather and top news today?" }
              ],
              "model" : "grok-4.3",
              "stream" : true,
              "tools" : [
                { "function" : { "description" : "Search the web", "name" : "web_search" }, "type" : "function" }
              ]
            }
            """,
            responseBody: "The weather today in San Francisco is 62°F with partly cloudy skies.",
            toolCalls: [
                // Two shapes of the same tool: `query` alone, and `query` plus
                // optionals. They must render the same way — see
                // ToolCallDebugRowFormatTests.
                ToolCallRecord(name: "web_search", arguments: "{\"query\":\"weather today San Francisco\"}",
                               result: "<source index=\"1\"><url>https://sfgate.com/weather</url><title>SF Weather</title><content>62°F, partly cloudy skies in San Francisco.</content></source><source index=\"2\"><url>https://weather.com/sf</url><title>Weather.com SF</title><content>Expect partly cloudy skies with a high of 65°F.</content></source>"),
                ToolCallRecord(name: "web_search", arguments: "{\"query\":\"top news headlines July 28 2026\",\"freshness\":\"pd\",\"count\":5}",
                               result: "<source index=\"1\"><url>https://reuters.com/top</url><title>Reuters Top News</title><content>Markets closed mixed ahead of the central bank meeting.</content></source><source index=\"2\"><url>https://apnews.com/top</url><title>AP Top Headlines</title><content>Storm system moves east overnight.</content></source>"),
                // The row that blanked the screen (2026-08-26): an oversized
                // tool result mounted whole swung the transcript tail by
                // thousands of points, and the expanded row must render the
                // TRAILER, not the text. Keep this fixture huge.
                ToolCallRecord(name: "web_search", arguments: "{\"query\":\"deep research sweep\",\"count\":50}",
                               result: (1...80).map { n in
                                   "<source index=\"\(n)\"><url>https://example.com/page-\(n)</url><title>Result \(n)</title><content>Result \(n): a long extracted passage that runs on for a while so the combined payload is tens of thousands of characters.</content></source>"
                               }.joined(separator: "\n"))
            ],
            threadID: UUID(),
            totalDuration: 4.137,
            timeToFirstToken: 0.821,
            outputTokens: 312,
            isE2EEActive: false,
            teeVerification: .verified(.init(signingAddress: "0x4a8b3f2e9d1c7a"))
        ))
        .padding()
    }
}

/// The 4096-default failure: the numbers are the ones measured against Ollama
/// 0.32.4 running gemma4:latest, where a grounded bodega turn came back having
/// evaluated 392 of ~4,500 input tokens and the model answered a question it
/// could no longer see.
#Preview("Context truncated") {
    ScrollView {
        RequestDebugView(info: LastRequestDebugInfo(
            providerName: "ringzero",
            modelID: "gemma4:latest",
            url: URL(string: "https://ringzero.tailnet-name.ts.net:11434/v1/chat/completions"),
            requestHeaders: ["Content-Type": "application/json"],
            requestBodyJSON: "{ \"model\" : \"gemma4:latest\" }",
            responseBody: "AI is rapidly transforming healthcare across multiple domains…",
            toolCalls: [
                ToolCallRecord(name: "web_search", arguments: "{\"query\":\"what is an nyc city bodega\"}",
                               result: "<source index=\"1\"><url>https://en.wikipedia.org/wiki/Bodega</url><title>Bodega</title><content>A small owner-operated convenience store.</content></source>")
            ],
            threadID: UUID(),
            totalDuration: 65.1,
            timeToFirstToken: 50.5,
            outputTokens: 1110,
            promptBudget: PromptBudget(sentEstimate: 4_500, evaluated: 392),
            isE2EEActive: false,
            teeVerification: nil
        ))
        .padding()
    }
}

/// ON-DEVICE, cold — the state the `load` figure exists for, and the one that had
/// never been looked at.
///
/// `url == nil` is what makes a request on-device (there is no endpoint), and the
/// header then reads `on-device · load 3.1s`. Every number is measured on an
/// iPhone 16 Pro by `measuresWhatAColdStartCosts`: a 3.1 s engine build inside a
/// 4.4 s turn whose first token took 3.4 s, against 0.86 s warm. That is the whole
/// explanation for a slow first answer, and it lived only in a log line until this
/// row.
///
/// Injecting the residency is the only way to render it: the real one is a mirror
/// of an engine cache, and a canvas builds no engine. `nil` there — the warm case,
/// or before anything has been built this session — simply drops the part.
/// A THINKING model on a warm machine — the card that prompted the question
/// of why a warm model took six seconds.
///
/// Every figure is measured against that server (2026-07-30, `gemma4:e4b` resident):
/// first delta on the wire at 0.6s, first VISIBLE character at 5.1s after 824
/// characters of reasoning, 124 tokens total for a two-word reply. The old chain read
/// `ttft 6.3s · gen 0.1s · 1874tok/s`, which described a machine that does not exist;
/// `think` names the wait, and the rate is over the window the tokens were actually
/// produced in.
#Preview("Request Debug View — thinking model") {
    ScrollView {
        RequestDebugView(info: LastRequestDebugInfo(
            providerName: "ringzero",
            modelID: "gemma4:e4b",
            url: URL(string: "https://ringzero.tailnet-name.ts.net:11434/v1/chat/completions"),
            requestHeaders: ["Content-Type": "application/json"],
            requestBodyJSON: "{ \"model\" : \"gemma4:e4b\", \"stream\" : true }",
            responseBody: "Ho.",
            toolCalls: [],
            threadID: UUID(),
            totalDuration: 6.4,
            timeToFirstToken: 6.3,
            thinkingTime: 4.5,
            outputTokens: 124,
            isE2EEActive: false,
            teeVerification: nil
        ))
        .padding()
    }
}

#Preview("Request Debug View — on-device, cold") {
    ScrollView {
        RequestDebugView(
            info: LastRequestDebugInfo(
                // What production ACTUALLY passes: `canonicalName(for:)` falls back
                // to the record's name, and `Provider.local` names the record after
                // the model — so this is "gemma 4 e2b", never a place like "on this
                // phone". This preview said the latter, which is why it did not show
                // the model printing twice; a preview that invents a string the app
                // can't produce is the same trap 265518b fixed for "OpenAI".
                providerName: "gemma 4 e2b",
                modelID: "google/gemma-4-e2b-it-litert-lm",
                url: nil,
                requestHeaders: nil,
                requestBodyJSON: """
                {
                  "messages" : [
                    { "role" : "user", "content" : "Summarize this in one line." }
                  ],
                  "model" : "google/gemma-4-e2b-it-litert-lm",
                  "stream" : true
                }
                """,
                responseBody: "A short summary, generated entirely on the phone.",
                toolCalls: [],
                threadID: UUID(),
                totalDuration: 4.412,
                timeToFirstToken: 3.402,
                outputTokens: 24,
                isE2EEActive: false,
                teeVerification: nil
            ),
            residency: .previewing(
                [],
                lastLoad: (file: URL(fileURLWithPath: "/models/gemma-4-e2b-it-litert-lm.task"),
                           took: .milliseconds(3_140))
            )
        )
        .padding()
    }
}

#Preview("E2EE Request Debug View") {
    ScrollView {
        RequestDebugView(info: LastRequestDebugInfo(
            providerName: "near.ai",
            modelID: "z-ai/glm-5.2",
            url: URL(string: "https://cloud-api.near.ai/v1/chat/completions"),
            requestHeaders: [
                "Authorization": "Bearer ••••••••",
                "Content-Type": "application/json",
                "X-Signing-Algo": "ed25519",
                "X-Encryption-Version": "2",
                "X-Encrypt-All-Fields": "true",
                "X-Client-Pub-Key": "25a56ed8edcd075800b3e46bc51db79ccf639feee3a21f7ae6a05eb6d3a8fcb1",
                "X-Model-Pub-Key": "40ef1aadbb12f26cf4c2d499b9e7a7b043da4388200715abed573fa135a561bb",
                "Accept": "text/event-stream"
            ],
            requestBodyJSON: """
            {
              "messages" : [
                {
                  "content" : "437bcbd1e9b1889d28c468fe75bd5fff838953bd4f02cedaa5befa29fcf4c018e61af95ba7465764a56c27af92591ae050c4ea428d350ecb3c87df019ddbc29bad23486942f6b96d20bf67af4daa20d205d79a511f04cc6d86c3055bf5b9e18be45c61c9188442522e5d6c459bbafbaca6b8670297e652a8d3bb756fc142901053e862f671fa66925172da140bc9714111820de3e070b224050c017ff6b4f070b2eb3e5a27fc99b88aae9bae282cb48c23add3609f8691991b0d2990e09a91e5aa29702842cc2a55708c120a9e9cef0bd0a37110017c28da4fc18b44f0abbf6d6f895422e8e4a3e457d4304e4f7ec65cb03eed63ec98749014f1f2b387533442fb861673e7e4236aeacac16a99952d1f4c9e70efcccef286ed615123b762ba953215492a8ed49a9cb45024bd68841a55c417456b1cfda57dcd3b720ecc37e1bbfef5250f109e333d254e4ee78201aaccdc0afe00f78a8ac276c9f9bba176ec6b574e45bb57a743e35f66eca5394a251cad3877d608ac21ebba611f2679bf86abe5c33997fc9e971b1cd69b1666a7f03be12c08f221c6056ef720c13f1fc9047482b82cfc372b0ed63b243d135e8bd3eebbfab49c44615ec6e8564e33e92529f7ae7ae00e568d08bab4b1be2591ed763e74013a7075b0c9d1bd065f06682c47ee2b6f01791d57de65aa0cf4015be2636bfe494a669d5690a77259c2ca74c1bf761e0ca3fd914fb45bf03689a7523e406486ca7b4261512392fced87748218d52d478a9da5851c0c94ca12ade64bd19d9686f8e3c3c662e551f7ed26ea8e2b3c2656325cc61f6c7b74c4f3df49db43816e22a20a357626db4e47d1a5e5c80c136e3a9e427057b4831d1c858c4efbad0ff577c755997c8a6cac9bb73d827b5939be44b7c6e57ab27f673432f1489129c9f726999e27aca57f3a529d2489da97201ca85c36ac318809cc581bb284c086d6425258bda9f680c8abbe0957ad03b0538858833f67644804d57bf15023803aca1061a635d2d2c242af2d9be87644409ae3c11281d514b2cd590676c9ebcb8ed38463524953874f9495c652103fc49cf46503b13f689f4d09ef4259274ef44641f66020aa1f",
                  "role" : "system"
                },
                {
                  "content" : "cec2c588a87e71889ee2dc89da572b8590ac69ef2094fb89349765a1670ce23d1d378234fdf39ea4791b941050b6ffe62ebe3cad74fd2352c89ae81a088729f0393bcc2fe9f1347053aaa85b982eb0d3d391eb421f90d5c61026218f06f21eccaa7e0a12893ecff9d4272823aa3699d5972ed7542b0f44ad06eb2e87dfd13a763a4708dd0045bd4aeda5e220473f7fa01f1120eef2b79ec102f8edc40bb74fc6df96f9a33bf0ba17",
                  "role" : "user"
                },
                {
                  "content" : "",
                  "role" : "assistant",
                  "tool_calls" : [
                    {
                      "type" : "function",
                      "id" : "call_568a520752f6490e887e8536",
                      "function" : {
                        "name" : "891ab5883d36cb984f0fb8110808cfb8c6d2d45678db1e5ef049208b5e58050bdc4c79154138d711f9d0e6f332f8f7c88472757c4cd81c406d9d83e2fe061b38de5f8ee09fd24e14ae87477d62be3f41c464",
                        "arguments" : "d3b9a03a316d9e2846841869cd5dee6b74fab7f1a27ce313919651cddb35b75124af8e0e9d2db3391a8f88e2bddd3a528ca618efb67b7fc978594f15b1b217b603651d4dec08c0689389ce445d8a51736f7243b9b49dd995bbe77c8fe6d053f0aacebcc179b78dbe388d5dbad65a170cee2cd3e2238379311eb99f2778f1b55bfa52ab3b067766799ed11c34a2aa3ecd44f167115179b1c1a46e7aacc090dfc465488e20318edb232458f30fb154f9b69310313ba168b6d95b413e958add1c5cb66fb07efd83b5a4f086d660b86ef2"
                      }
                    }
                  ]
                }
              ],
              "model" : "zai-org/GLM-5.1-FP8",
              "stream" : true
            }
            """,
            responseBody: "The model returned an encrypted response.",
            toolCalls: [],
            threadID: UUID(),
            totalDuration: 2.341,
            timeToFirstToken: 0.612,
            outputTokens: 187,
            isE2EEActive: true,
            teeVerification: .verified(.init(signingAddress: "0x4a8b3f2e9d1c7a"))
        ))
        .padding()
    }
}
