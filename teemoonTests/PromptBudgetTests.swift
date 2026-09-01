import Foundation
import Testing
@testable import teemoon

/// A server whose context window is smaller than the prompt may discard the
/// front of it and answer anyway — no error, HTTP 200. `usage.prompt_tokens` is
/// the only tell. Numbers here are the ones measured against Ollama 0.32.4
/// running gemma4:latest at its 4096 default.
@Suite("Prompt budget — silent context truncation")
struct PromptBudgetTests {

    // MARK: - The observed failures

    @Test func theBodegaTurn_isFlagged() {
        // Measured: teemoon sent a grounded turn of roughly 4,500 tokens and
        // Ollama reported evaluating 392. The model then invented an unrelated
        // search query, having lost the question.
        let budget = PromptBudget(sentEstimate: 4_500, evaluated: 392)
        #expect(budget.looksTruncated)
    }

    @Test func theSecretWordProbe_isFlagged() {
        // Measured: ~6,200 tokens in, 2,051 evaluated, system prompt gone.
        #expect(PromptBudget(sentEstimate: 6_200, evaluated: 2_051).looksTruncated)
    }

    @Test func theSameTurnAfterRaisingTheWindow_isNotFlagged() {
        // Same request against OLLAMA_CONTEXT_LENGTH=32768: all 4,364 evaluated.
        #expect(!PromptBudget(sentEstimate: 4_500, evaluated: 4_364).looksTruncated)
    }

    // MARK: - Not crying wolf

    @Test func shortPromptsAreNeverJudged() {
        // Below the floor the estimate is dominated by the template overhead it
        // deliberately ignores, so the ratio means nothing.
        #expect(!PromptBudget(sentEstimate: 400, evaluated: 20).looksTruncated)
    }

    @Test func aTokenizerDisagreementIsNotTruncation() {
        // The estimate is chars/4 and real tokenizers vary either side of it.
        // A 25% miss must stay quiet.
        #expect(!PromptBudget(sentEstimate: 4_000, evaluated: 3_000).looksTruncated)
    }

    @Test func evaluatingMoreThanEstimatedIsFine() {
        // The estimate ignores tool schemas and the chat template, so the server
        // legitimately evaluates MORE than it. That is the normal case.
        #expect(!PromptBudget(sentEstimate: 2_000, evaluated: 2_600).looksTruncated)
    }

    @Test func atTheThresholdItStaysQuiet() {
        #expect(!PromptBudget(sentEstimate: 2_000, evaluated: 1_200).looksTruncated)
        #expect(PromptBudget(sentEstimate: 2_000, evaluated: 1_199).looksTruncated)
    }

    // MARK: - The estimate

    @Test func estimateCountsMessageContent() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": String(repeating: "a", count: 400)],
            ["role": "user", "content": String(repeating: "b", count: 400)],
        ]
        #expect(PromptBudget.estimateSentTokens(messages: messages) == 200)
    }

    @Test func estimateCountsToolCallArguments() {
        // A tool round's assistant message carries its payload in `tool_calls`,
        // not `content` — miss that and a grounded turn looks tiny.
        let messages: [[String: Any]] = [
            ["role": "assistant", "content": "",
             "tool_calls": [
                // "web_search" is 10 characters and counts too — the name is in
                // the rendered prompt just as much as the arguments are.
                ["function": ["name": "web_search",
                              "arguments": String(repeating: "x", count: 390)]]
             ]],
        ]
        #expect(PromptBudget.estimateSentTokens(messages: messages) == 100)
    }

    @Test func estimateIgnoresMessagesWithoutContent() {
        #expect(PromptBudget.estimateSentTokens(messages: [["role": "user"]]) == 0)
    }

    // MARK: - Reading it off the wire

    /// The shape Ollama sends with `stream_options.include_usage`, which is what
    /// teemoon always requests.
    @Test func parserReadsPromptTokensFromTheUsageChunk() {
        let parser = SSEStreamParser(hasTools: false)
        // Framed the way HTTPTransport feeds it: one line, then a blank line.
        let chunk = #"""
            data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":392,"completion_tokens":1110,"total_tokens":1502}}
            """# + "\n\n"
        _ = parser.consume(Data(chunk.utf8))
        #expect(parser.promptTokens == 392)
        #expect(parser.completionTokens == 1110)
    }

    @Test func parserLeavesPromptTokensNilWhenTheServerOmitsUsage() {
        let parser = SSEStreamParser(hasTools: false)
        let chunk = #"""
            data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"hi"}}]}
            """# + "\n\n"
        _ = parser.consume(Data(chunk.utf8))
        #expect(parser.promptTokens == nil)
    }
}
