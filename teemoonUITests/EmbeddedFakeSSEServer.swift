//
//  EmbeddedFakeSSEServer.swift
//  teemoonUITests
//
//  The host-side fake SSE server, reborn inside the test runner — because the
//  runner runs ON THE DEVICE. The Python server on the Mac is fine for
//  simulators (localhost is shared), but a physical phone has to cross the
//  LAN to reach it, which stacks three failure modes this suite spent a
//  night discovering: ATS blocks plain HTTP to LAN IPs, the Local Network
//  permission dialog races the first request, and home-router client
//  isolation silently drops phone→Mac traffic anyway. Loopback on the phone
//  itself has none of those: the app talks to 127.0.0.1, which is ATS-exempt
//  and permission-free.
//
//  Deliberately primitive: one paragraph generator matching the Python
//  server's shape (`Paragraph N: word-word …`), word-by-word SSE chunks, a
//  finish_reason chunk, `data: [DONE]`, and then CONNECTION CLOSE — the
//  framing lesson of 2026-08-06 (an unframed keep-alive response never ends,
//  and the turn outlives its own reply).
//

import Foundation
import Network

final class EmbeddedFakeSSEServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-sse", qos: .userInitiated)
    let lines: Int
    let delay: TimeInterval
    /// Paragraphs streamed as `reasoning_content` BEFORE any content — the
    /// shape of DeepSeek-style thinking models. The reasoning window has its
    /// own freeze variant (scroll up during "thinking...", 2026-08-07): the
    /// live reasoning block grows and re-lays-out per token while the user
    /// roams, and none of the settled-row protections apply to it.
    let reasoningLines: Int

    /// Bound port — hand `http://127.0.0.1:<port>/v1` to the app.
    private(set) var port: UInt16 = 0

    /// Override the completion status. ≥400 returns a JSON error and no stream.
    /// Mutable so a test can send once (500), then flip back to 200 for retry.
    var statusCode: Int = 200

    /// If non-empty, each POST streams the next string (last one repeats).
    /// Distinct bodies let a two-turn test prove the second reply is new.
    var replies: [String] = []

    /// `/v1/models` ids. Home-server probe copies this into the equipped set.
    var modelIDs: [String] = ["fake-model"]

    /// First user-only POST emits a native `web_search` tool_calls round.
    /// The engine's follow-up (a `tool` role or text-recovered results
    /// message) streams `toolFollowUpReply`.
    var emitToolRound = false
    var toolFollowUpReply = "tool-round-ok-zeta"

    /// Pause before the first token so a UI test can catch the empty-text
    /// thinking chip (it is only on screen until paced text arrives).
    var startDelay: TimeInterval = 0

    /// Go quiet mid-stream every `stallEvery` blocks, for `stallDuration`.
    ///
    /// The 2026-08-25 jitter cannot be reproduced by a continuous stream:
    /// `StreamingMessageView.stallDelay` is 1s, so the trailing activity chip
    /// only mounts once the wire has been silent for longer than that, and it
    /// is the chip's spring that moves the transcript. A bursty provider does
    /// this several times a generation (near.ai's silent reasoning gaps,
    /// fireworks' kilochar flushes); this is that shape on demand.
    ///
    /// `stallDuration` MUST exceed 1s or the chip never appears and the
    /// fixture silently proves nothing.
    var stallEvery: Int = 0
    var stallDuration: TimeInterval = 0

    /// Stream the reply as ONE ENORMOUS UNSETTLED BLOCK — a long bullet list.
    ///
    /// `MarkdownStreamSplitter.isHardBlockStart` returns FALSE for "- x" and
    /// "1. x", so a list never settles: it stays the tail, and the tail
    /// re-parses and re-lays-out on every pacer tick. The default fixture's
    /// `Paragraph N:` / `## heading` / table blocks all settle immediately,
    /// which keeps the tail one small block at the very bottom — and that is
    /// why five parked-reader runs (2026-08-25) found the transcript
    /// perfectly still while the recording they were chasing shows it moving.
    /// The recording's reply is a bulleted list under headings, i.e. a reader
    /// parked INSIDE the tail.
    var bulletTail = false

    init(lines: Int = 40, delay: TimeInterval = 0.02, reasoningLines: Int = 0) throws {
        self.lines = lines
        self.delay = delay
        self.reasoningLines = reasoningLines
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
        // Handler assignment happens AFTER full initialisation — capturing
        // self inside init is use-before-initialised.
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        listener.start(queue: queue)
        // Wait for the ephemeral port assignment.
        for _ in 0..<100 {
            if let p = listener.port?.rawValue, p != 0 { port = p; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func stop() { listener.cancel() }

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    // MARK: - request handling

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { conn.cancel(); return }
            var buffer = buffer
            buffer.append(data)
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return self.receiveRequest(conn, buffer: buffer)
            }
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let requestLine = head.components(separatedBy: "\r\n").first ?? ""
            let bodyStart = headerEnd.upperBound
            let contentLength = head.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            let have = buffer.count - bodyStart
            if have < contentLength {
                return self.receiveRequest(conn, buffer: buffer)
            }
            let body = String(decoding: buffer[bodyStart..<(bodyStart + contentLength)], as: UTF8.self)
            if requestLine.hasPrefix("POST") {
                if self.statusCode >= 400 {
                    self.sendError(conn, status: self.statusCode)
                } else {
                    self.streamCompletion(conn, requestBody: body)
                }
            } else {
                self.sendModels(conn)
            }
        }
    }

    private func sendError(_ conn: NWConnection, status: Int) {
        let reason = status == 401 ? "Unauthorized" : "Internal Server Error"
        let body = #"{"error":{"message":"synthetic \#(status)","type":"server_error"}}"#
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendModels(_ conn: NWConnection) {
        let data = modelIDs.map { #"{"id": "\#($0)", "object": "model", "owned_by": "test"}"# }
            .joined(separator: ", ")
        let body = #"{"object": "list", "data": [\#(data)]}"#
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Scripted replies are keyed by how many user turns the request carries,
    /// so a warmth / probe POST cannot eat turn 1 of a two-turn test.
    private func scriptedReply(for requestBody: String) -> String? {
        guard !replies.isEmpty else { return nil }
        let users = requestBody.components(separatedBy: "\"role\"").dropFirst().filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(":\"user\"")
                || $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(": \"user\"")
        }.count
        guard users > 0 else { return "probe-ack" }
        return replies[min(users - 1, replies.count - 1)]
    }

    private func streamCompletion(_ conn: NWConnection, requestBody: String = "") {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in })

        // Same non-repeating vocabulary trick as the Python server: every
        // line visually unique, so scroll motion is measurable off video.
        let words = ["attestation", "quote", "enclave", "measurement", "provenance",
                     "transcript", "verifier", "ledger", "manifest", "revision",
                     "registry", "custody", "quantisation", "latency", "envelope"]

        func chunk(_ text: String) -> Data {
            let payload: [String: Any] = ["id": "chatcmpl-fake", "object": "chat.completion.chunk",
                "model": "fake-model",
                "choices": [["index": 0, "delta": ["content": text], "finish_reason": NSNull()]]]
            let json = try! JSONSerialization.data(withJSONObject: payload)
            return Data("data: ".utf8) + json + Data("\n\n".utf8)
        }

        func reasoningChunk(_ text: String) -> Data {
            let payload: [String: Any] = ["id": "chatcmpl-fake", "object": "chat.completion.chunk",
                "model": "fake-model",
                "choices": [["index": 0, "delta": ["reasoning_content": text], "finish_reason": NSNull()]]]
            let json = try! JSONSerialization.data(withJSONObject: payload)
            return Data("data: ".utf8) + json + Data("\n\n".utf8)
        }

        // A dedicated thread, so `Thread.sleep` paces the words without tying
        // up the listener queue.
        let scripted = scriptedReply(for: requestBody)
        let emitTool = emitToolRound
        let followUp = toolFollowUpReply
        let isFollowUp = Self.isToolFollowUp(requestBody)
        Thread.detachNewThread { [lines, delay, reasoningLines, scripted, emitTool, followUp, isFollowUp, startDelay, stallEvery, stallDuration, bulletTail] in
            if startDelay > 0 { Thread.sleep(forTimeInterval: startDelay) }
            if emitTool {
                if isFollowUp {
                    Self.streamWords(conn, followUp, delay: delay)
                } else {
                    Self.streamNativeWebSearch(conn)
                }
                return
            }
            if let scripted {
                for word in scripted.split(separator: " ", omittingEmptySubsequences: false) {
                    conn.send(content: chunk(String(word) + " "), completion: .contentProcessed { _ in })
                    Thread.sleep(forTimeInterval: delay)
                }
                let finish = #"{"id": "chatcmpl-fake", "object": "chat.completion.chunk", "model": "fake-model", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}"#
                conn.send(content: Data("data: \(finish)\n\ndata: [DONE]\n\n".utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            for i in 0..<reasoningLines {
                let body = (0..<22).map { j in "\(words[(i * 5 + j * 2) % words.count])~\(i)\(j)" }
                    .joined(separator: " ")
                for word in "Thinking step \(i): \(body).".split(separator: " ") {
                    conn.send(content: reasoningChunk(String(word) + " "), completion: .contentProcessed { _ in })
                    Thread.sleep(forTimeInterval: delay)
                }
                conn.send(content: reasoningChunk("\n\n"), completion: .contentProcessed { _ in })
            }
            for i in 0..<lines {
                // RICH by default: the device freeze's own replies carried
                // headings, tables and links — StructuredText.TableLayout and
                // TextLinkInteraction are hot in every freeze trace — and a
                // plain-paragraph stream failed to reproduce what a thumb
                // reproduced in seconds. Every third block is a table under a
                // heading with linked prose.
                let block: String
                if bulletTail {
                    // No heading, no table, no bare paragraph — nothing that
                    // would settle the block and end the tail.
                    let body = (0..<26).map { j in "\(words[(i * 7 + j * 3) % words.count])-\(i)\(j)" }
                        .joined(separator: " ")
                    block = "- **Item \(i)** — \(body)."
                } else if i % 3 == 2 {
                    block = """
                    ## Comparing block \(i)

                    | provider | boundary | hardware | verdict \(i) |
                    |---|---|---|---|
                    | [one-\(i)](https://example.com/\(i)/1) | model enclave | TDX | keep |
                    | [two-\(i)](https://example.com/\(i)/2) | gateway | SEV-SNP | reject |
                    | [three-\(i)](https://example.com/\(i)/3) | router | TDX | lower tier |

                    See [the writeup](https://example.com/writeup/\(i)) for block \(i).
                    """
                } else {
                    let body = (0..<22).map { j in "\(words[(i * 7 + j * 3) % words.count])-\(i)\(j)" }
                        .joined(separator: " ")
                    block = "Paragraph \(i): \(body)."
                }
                for word in block.split(separator: " ", omittingEmptySubsequences: false) {
                    conn.send(content: chunk(String(word) + " "), completion: .contentProcessed { _ in })
                    Thread.sleep(forTimeInterval: delay)
                }
                conn.send(content: chunk("\n\n"), completion: .contentProcessed { _ in })
                if stallEvery > 0, stallDuration > 0, i % stallEvery == stallEvery - 1 {
                    Thread.sleep(forTimeInterval: stallDuration)
                }
            }
            Self.finishStop(conn)
        }
    }

    private static func isToolFollowUp(_ body: String) -> Bool {
        body.contains("\"role\":\"tool\"")
            || body.contains("\"role\": \"tool\"")
            || body.contains("tool_call_id")
            || body.localizedCaseInsensitiveContains("please answer based on these results")
    }

    private static func sse(_ object: [String: Any]) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: object)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    private static func chunk(delta: [String: Any], finish: Any = NSNull()) -> [String: Any] {
        [
            "id": "chatcmpl-fake",
            "object": "chat.completion.chunk",
            "model": "fake-model",
            "choices": [[
                "index": 0,
                "delta": delta,
                "finish_reason": finish,
            ]],
        ]
    }

    /// OpenAI-shaped native tool_calls stream the parser already understands.
    private static func streamNativeWebSearch(_ conn: NWConnection) {
        let open: [String: Any] = [
            "role": "assistant",
            "content": NSNull(),
            "tool_calls": [[
                "index": 0,
                "id": "call_uitest",
                "type": "function",
                "function": ["name": "web_search", "arguments": ""] as [String: Any],
            ] as [String: Any]],
        ]
        conn.send(content: sse(chunk(delta: open)), completion: .contentProcessed { _ in })
        let args: [String: Any] = [
            "tool_calls": [[
                "index": 0,
                "function": ["arguments": #"{"query":"ui-e2e-sky-color"}"#] as [String: Any],
            ] as [String: Any]],
        ]
        conn.send(content: sse(chunk(delta: args)), completion: .contentProcessed { _ in })
        conn.send(content: sse(chunk(delta: [:], finish: "tool_calls")),
                  completion: .contentProcessed { _ in })
        conn.send(content: Data("data: [DONE]\n\n".utf8),
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func streamWords(_ conn: NWConnection, _ text: String, delay: TimeInterval) {
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let payload: [String: Any] = chunk(delta: ["content": String(word) + " "])
            conn.send(content: sse(payload), completion: .contentProcessed { _ in })
            Thread.sleep(forTimeInterval: delay)
        }
        finishStop(conn)
    }

    private static func finishStop(_ conn: NWConnection) {
        conn.send(content: sse(chunk(delta: [:], finish: "stop"))
                    + Data("data: [DONE]\n\n".utf8),
                  completion: .contentProcessed { _ in conn.cancel() })
    }
}
