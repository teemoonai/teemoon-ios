import Foundation
import Testing
@testable import teemoon

@Suite("ChatGeneration.resolvePromptTemplates")
struct ResolvePromptTemplatesTests {

    @Test @MainActor func replacesDatetimePlaceholder() {
        let prompt = "Today is {{datetime}}. Be helpful."
        let resolved = ChatGeneration.resolvePromptTemplates(prompt)
        #expect(!resolved.contains("{{datetime}}"))
        #expect(resolved.contains("Be helpful."))
    }

    @Test @MainActor func noPlaceholder_unchanged() {
        let prompt = "You are a helpful assistant."
        let resolved = ChatGeneration.resolvePromptTemplates(prompt)
        #expect(resolved == prompt)
    }

    @Test @MainActor func multiplePlaceholders() {
        let prompt = "{{datetime}} and {{datetime}}"
        let resolved = ChatGeneration.resolvePromptTemplates(prompt)
        #expect(!resolved.contains("{{datetime}}"))
    }

    @Test @MainActor func emptyPrompt() {
        let resolved = ChatGeneration.resolvePromptTemplates("")
        #expect(resolved == "")
    }
}

// MARK: - SSE helpers

private func sseEvent(_ json: [String: Any]) -> Data {
    let data = try! JSONSerialization.data(withJSONObject: json)
    let str = String(data: data, encoding: .utf8)!
    return Data("data: \(str)\n\n".utf8)
}

private func sseContentDelta(_ content: String, finishReason: String? = nil) -> Data {
    var choice: [String: Any] = [
        "index": 0,
        "delta": ["content": content] as [String: Any]
    ]
    if let reason = finishReason {
        choice["finish_reason"] = reason
    } else {
        choice["finish_reason"] = NSNull()
    }
    return sseEvent([
        "id": "chatcmpl-test",
        "object": "chat.completion.chunk",
        "choices": [choice]
    ])
}

private func sseDone() -> Data {
    Data("data: [DONE]\n\n".utf8)
}

// MARK: - Text tool call parsing tests

@Suite("SSEStreamParser.parseTextToolCalls")
struct ParseTextToolCallsTests {

    @Test func parsesJSONVariant() {
        let content = """
        Some text before
        <tool_call>{"name": "web_search", "arguments": {"query": "test query"}}</tool_call>
        Some text after
        """
        let result = SSEStreamParser.parseTextToolCalls(from: content)
        #expect(result.count == 1)
        #expect(result[0]?.name == "web_search")
        #expect(result[0]?.arguments.contains("test query") == true)
    }

    @Test func parsesMultipleToolCalls() {
        let content = """
        <tool_call>{"name": "web_search", "arguments": {"query": "first"}}</tool_call>
        <tool_call>{"name": "web_search", "arguments": {"query": "second"}}</tool_call>
        """
        let result = SSEStreamParser.parseTextToolCalls(from: content)
        #expect(result.count == 2)
    }

    @Test func parsesXMLAttributeVariant() {
        let content = """
        <tool_call><function=web_search><parameter=query>test query</parameter></function></tool_call>
        """
        let result = SSEStreamParser.parseTextToolCalls(from: content)
        #expect(result.count == 1)
        #expect(result[0]?.name == "web_search")
        #expect(result[0]?.arguments.contains("test query") == true)
    }

    @Test func returnsEmptyForNoToolCalls() {
        let result = SSEStreamParser.parseTextToolCalls(from: "Just regular text")
        #expect(result.isEmpty)
    }

    @Test func parsesArgKeyArgValueVariant() {
        let content = """
        <tool_call>web_search<arg_key>count</arg_key><arg_value>10</arg_value><arg_key>query</arg_key><arg_value>windfinder Da Nang</arg_value></tool_call>
        """
        let result = SSEStreamParser.parseTextToolCalls(from: content)
        #expect(result.count == 1)
        #expect(result[0]?.name == "web_search")
    }
}

@Suite("SSEStreamParser.stripTextToolCalls")
struct StripTextToolCallsTests {

    @Test func stripsToolCallTags() {
        let content = "Hello <tool_call>{\"name\": \"web_search\"}</tool_call> world"
        let result = SSEStreamParser.stripTextToolCalls(from: content)
        #expect(result == "Hello  world")
    }

    @Test func stripsMultipleToolCalls() {
        let content = "<tool_call>first</tool_call> middle <tool_call>second</tool_call>"
        let result = SSEStreamParser.stripTextToolCalls(from: content)
        #expect(result == "middle")
    }

    @Test func preservesContentWithoutToolCalls() {
        let content = "No tool calls here"
        let result = SSEStreamParser.stripTextToolCalls(from: content)
        #expect(result == content)
    }
}

// MARK: - SSE forwarding / suppression tests

@Suite("SSEStreamParser.processSSEChunks — text tool call suppression")
struct SSETextToolCallSuppressionTests {

    @Test func normalContentForwardedWhenNoTools() {
        var data = Data()
        data.append(sseContentDelta("Hello world"))
        data.append(sseDone())

        let (forwarded, toolCalls, detected) = SSEStreamParser.processSSEChunks(data, hasTools: false)
        #expect(!detected)
        #expect(toolCalls.isEmpty)
        let forwardedStr = String(data: forwarded, encoding: .utf8) ?? ""
        #expect(forwardedStr.contains("Hello world"))
    }

    @Test func structuredToolCallDetected() {
        var data = Data()
        let toolCallChunk = sseEvent([
            "id": "chatcmpl-test",
            "object": "chat.completion.chunk",
            "choices": [[
                "index": 0,
                "delta": [
                    "tool_calls": [[
                        "index": 0,
                        "id": "call_123",
                        "function": ["name": "web_search", "arguments": "{\"query\": \"test\"}"]
                    ] as [String: Any]]
                ] as [String: Any],
                "finish_reason": NSNull()
            ] as [String: Any]]
        ])
        data.append(toolCallChunk)
        let finishChunk = sseEvent([
            "id": "chatcmpl-test",
            "object": "chat.completion.chunk",
            "choices": [[
                "index": 0,
                "delta": [String: Any](),
                "finish_reason": "tool_calls"
            ] as [String: Any]]
        ])
        data.append(finishChunk)
        data.append(sseDone())

        let (forwarded, toolCalls, detected) = SSEStreamParser.processSSEChunks(data, hasTools: true)
        #expect(detected)
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0]?.name == "web_search")
        #expect(forwarded.isEmpty)
    }

    /// BUG TEST: When the model emits `<tool_call>` XML in the content field,
    /// the chunk containing the opening tag must NOT be forwarded to the client.
    /// This test fails before the fix because the first chunk leaks through.
    @Test func textToolCallXMLNotForwardedToClient() {
        var data = Data()
        // The model starts with normal text, then emits a tool call as XML
        data.append(sseContentDelta("<tool_call>"))
        data.append(sseContentDelta("{\"name\": \"web_search\", \"arguments\": {\"query\": \"test\"}}"))
        data.append(sseContentDelta("</tool_call>"))
        data.append(sseDone())

        let (forwarded, toolCalls, detected) = SSEStreamParser.processSSEChunks(data, hasTools: true)

        let forwardedStr = String(data: forwarded, encoding: .utf8) ?? ""
        // The XML must not leak to the client
        #expect(!forwardedStr.contains("<tool_call>"), "tool_call XML leaked to client")
        #expect(!forwardedStr.contains("web_search"), "tool call content leaked to client")
        // Tool call should be detected and parsed
        #expect(detected, "text-based tool call should be detected")
        #expect(toolCalls.count == 1, "should parse one tool call")
        #expect(toolCalls[0]?.name == "web_search")
    }

    /// When the tool call XML arrives in a single chunk, it must also be suppressed.
    @Test func singleChunkTextToolCallSuppressed() {
        var data = Data()
        data.append(sseContentDelta("<tool_call>{\"name\": \"web_search\", \"arguments\": {\"query\": \"test\"}}</tool_call>"))
        data.append(sseDone())

        let (forwarded, toolCalls, detected) = SSEStreamParser.processSSEChunks(data, hasTools: true)

        let forwardedStr = String(data: forwarded, encoding: .utf8) ?? ""
        #expect(!forwardedStr.contains("<tool_call>"), "tool_call XML leaked in single-chunk case")
        #expect(detected)
        #expect(toolCalls.count == 1)
    }

    /// The arg_key/arg_value variant from the actual bug report must also be suppressed.
    @Test func argKeyArgValueVariantSuppressed() {
        var data = Data()
        data.append(sseContentDelta("<tool_call>web_search"))
        data.append(sseContentDelta("<arg_key>count</arg_key><arg_value>10</arg_value>"))
        data.append(sseContentDelta("<arg_key>query</arg_key><arg_value>windfinder Da Nang</arg_value>"))
        data.append(sseContentDelta("</tool_call>"))
        data.append(sseDone())

        let (forwarded, _, _) = SSEStreamParser.processSSEChunks(data, hasTools: true)

        let forwardedStr = String(data: forwarded, encoding: .utf8) ?? ""
        #expect(!forwardedStr.contains("<tool_call>"), "arg_key/arg_value tool call XML leaked")
        #expect(!forwardedStr.contains("web_search"), "tool call content leaked")
    }

    /// When hasTools is false, tool call XML should NOT be suppressed — pass through as text.
    @Test func toolCallXMLPassesThroughWhenNoTools() {
        var data = Data()
        data.append(sseContentDelta("<tool_call>{\"name\": \"web_search\"}</tool_call>"))
        data.append(sseDone())

        let (forwarded, _, detected) = SSEStreamParser.processSSEChunks(data, hasTools: false)

        let forwardedStr = String(data: forwarded, encoding: .utf8) ?? ""
        #expect(forwardedStr.contains("<tool_call>"), "should pass through when no tools configured")
        #expect(!detected)
    }

    /// Real production path for Gemma. Both endpoints teemoon serves Gemma on — Ollama
    /// and near.ai (google/gemma-4-31B-it) — native-parse the model's ```tool_code into
    /// STRUCTURED tool_calls, so the text parser is never reached; this decoder is. near.ai
    /// streams the call as: name in delta 1, then the arguments JSON SPLIT across later
    /// deltas keyed by `index` (`{"city": ` + `"San Francisco"}`). Captured verbatim from
    /// cloud-api.near.ai 2026-07-25. The decoder must concatenate the fragments per index.
    @Test func assemblesNearAIGemmaSplitArgumentDeltas() {
        func toolDelta(_ fn: [String: Any]) -> Data {
            sseEvent([
                "id": "chatcmpl-test", "object": "chat.completion.chunk",
                "choices": [[
                    "index": 0,
                    "delta": ["tool_calls": [["index": 0, "function": fn] as [String: Any]]] as [String: Any],
                    "finish_reason": NSNull(),
                ] as [String: Any]],
            ])
        }
        var data = Data()
        data.append(toolDelta(["name": "get_weather", "id": "chatcmpl-tool-a9280f43", "type": "function"]))
        data.append(toolDelta(["arguments": "{\"city\": "]))
        data.append(toolDelta(["arguments": "\"San Francisco\"}"]))
        data.append(sseEvent([
            "id": "chatcmpl-test", "object": "chat.completion.chunk",
            "choices": [["index": 0, "delta": [String: Any](), "finish_reason": "tool_calls"] as [String: Any]],
        ]))
        data.append(sseDone())

        let (_, toolCalls, detected) = SSEStreamParser.processSSEChunks(data, hasTools: true)
        #expect(detected)
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0]?.name == "get_weather")
        // The split fragments must reassemble into valid JSON.
        let args = (try? JSONSerialization.jsonObject(with: Data((toolCalls[0]?.arguments ?? "").utf8))) as? [String: Any]
        #expect(args?["city"] as? String == "San Francisco")
    }

    /// Normal text before a tool call should still be forwarded.
    @Test func textBeforeToolCallIsForwarded() {
        var data = Data()
        data.append(sseContentDelta("Here is some info: "))
        data.append(sseContentDelta("<tool_call>{\"name\": \"web_search\", \"arguments\": {\"query\": \"test\"}}</tool_call>"))
        data.append(sseDone())

        let (forwarded, toolCalls, detected) = SSEStreamParser.processSSEChunks(data, hasTools: true)

        let forwardedStr = String(data: forwarded, encoding: .utf8) ?? ""
        #expect(forwardedStr.contains("Here is some info"))
        #expect(!forwardedStr.contains("<tool_call>"))
        #expect(detected)
        #expect(toolCalls.count == 1)
    }
}

// MARK: - Reasoning-content accumulation (DeepSeek V4 Flash regression)

/// Reasoning models can stream their entire visible answer as
/// `reasoning_content` and leave `content` empty. The parser must accumulate
/// reasoning so the engine's fallback can persist the reply instead of saving
/// an empty assistant message (blank thread preview).
@Suite("SSEStreamParser — reasoning_content accumulation")
struct ReasoningAccumulationTests {

    private func reasoningDelta(_ text: String) -> Data {
        sseEvent([
            "id": "chatcmpl-test",
            "object": "chat.completion.chunk",
            "choices": [[
                "index": 0,
                "delta": ["reasoning_content": text] as [String: Any],
                "finish_reason": NSNull(),
            ] as [String: Any]],
        ])
    }

    @Test func accumulatesReasoningSeparatelyFromContent() {
        let parser = SSEStreamParser(hasTools: false)
        _ = parser.consume(reasoningDelta("thinking… "))
        _ = parser.consume(reasoningDelta("the answer is 4."))
        _ = parser.consume(sseContentDelta("", finishReason: "stop"))
        _ = parser.consume(sseDone())
        #expect(parser.accumulatedContent.isEmpty)
        #expect(parser.accumulatedReasoning == "thinking… the answer is 4.")
    }

    @Test func contentStillAccumulatesWhenBothPresent() {
        let parser = SSEStreamParser(hasTools: false)
        _ = parser.consume(reasoningDelta("let me think"))
        _ = parser.consume(sseContentDelta("2+2 = 4"))
        _ = parser.consume(sseDone())
        #expect(parser.accumulatedContent == "2+2 = 4")
        #expect(parser.accumulatedReasoning == "let me think")
    }
}
