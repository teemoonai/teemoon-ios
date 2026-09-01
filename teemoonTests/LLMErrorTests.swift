import Foundation
import Testing
@testable import teemoon

@Suite("LLMError")
struct LLMErrorTests {

    // MARK: - LocalizedError conformance

    /// Regression: LLMError without LocalizedError yields Foundation's generic
    /// "operation couldn't be completed" from `localizedDescription`, hiding
    /// the real message from users and from ProviderSmokeTests' unreachable-
    /// box skip matching.
    @Test func localizedDescriptionIsTheUserMessage() {
        let err = LLMError(
            source: .provider(name: "ollama"),
            userMessage: "Could not connect to ollama. The server may be offline.",
            httpStatus: nil, url: nil, requestHeaders: nil,
            requestBodyJSON: nil, messageHistory: nil, responseBody: nil,
            underlyingError: nil
        )
        #expect(err.localizedDescription == err.userMessage)
        #expect(!err.localizedDescription.contains("operation couldn"))
    }

    // MARK: - providerMessage

    @Test func providerMessage_401() {
        let msg = LLMError.providerMessage(httpStatus: 401, provider: "OpenAI")
        #expect(msg.contains("401"))
        #expect(msg.contains("OpenAI"))
        #expect(msg.contains("API key"))
    }

    @Test func providerMessage_402() {
        let msg = LLMError.providerMessage(httpStatus: 402, provider: "near.ai")
        #expect(msg.contains("402"))
        #expect(msg.contains("near.ai"))
        #expect(msg.lowercased().contains("credit"))
    }

    @Test func providerMessage_403() {
        let msg = LLMError.providerMessage(httpStatus: 403, provider: "near.ai")
        #expect(msg.contains("403"))
        #expect(msg.contains("permission"))
    }

    @Test func providerMessage_404() {
        let msg = LLMError.providerMessage(httpStatus: 404, provider: "Test")
        #expect(msg.contains("404"))
        #expect(msg.contains("not found"))
    }

    @Test func providerMessage_422() {
        let msg = LLMError.providerMessage(httpStatus: 422, provider: "Test")
        #expect(msg.contains("422"))
        #expect(msg.contains("model name"))
    }

    @Test func providerMessage_429() {
        let msg = LLMError.providerMessage(httpStatus: 429, provider: "Test")
        #expect(msg.contains("rate limit"))
    }

    @Test func providerMessage_500() {
        let msg = LLMError.providerMessage(httpStatus: 500, provider: "Test")
        #expect(msg.contains("server error"))
    }

    @Test func providerMessage_502() {
        let msg = LLMError.providerMessage(httpStatus: 502, provider: "Test")
        #expect(msg.contains("server error"))
    }

    @Test func providerMessage_unknownStatus() {
        let msg = LLMError.providerMessage(httpStatus: 418, provider: "Test")
        #expect(msg.contains("418"))
    }

    // MARK: - groundingMessage

    @Test func groundingMessage_401() {
        let msg = LLMError.groundingMessage(httpStatus: 401)
        #expect(msg.contains("Brave"))
        #expect(msg.contains("API key"))
    }

    @Test func groundingMessage_402() {
        let msg = LLMError.groundingMessage(httpStatus: 402)
        #expect(msg.contains("credits"))
    }

    @Test func groundingMessage_429() {
        let msg = LLMError.groundingMessage(httpStatus: 429)
        #expect(msg.contains("rate limit"))
    }
}
