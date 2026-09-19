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

    /// NVIDIA lists models its chat endpoint no longer serves; the 404 body
    /// is problem-details with no `error` envelope. It is the model, not
    /// the URL — and the function/account ids stay out of the sentence.
    @Test func nvidiaUnservedModel404NamesTheModelNotTheURL() {
        let body = #"{"status":404,"title":"Not Found","detail":"Function 'b0fcd392-e905-4ab4-8eb9-aeae95c30b37': Not found for account 'iqVNM_S9wj9BaKVMYqRKW'"}"#
        let msg = apiErrorMessage(from: body, httpStatus: 404, provider: "nvidia")
        #expect(msg.contains("does not serve this model"))
        #expect(msg.contains("404"))
        #expect(!msg.contains("URL"))
        #expect(!msg.contains("b0fcd392"))
        #expect(!msg.contains("iqVNM"))
    }

    @Test func problemDetailsBodyShowsItsDetail() {
        let body = #"{"status":429,"title":"Too Many Requests","detail":"Rate limit exceeded for this model."}"#
        let msg = apiErrorMessage(from: body, httpStatus: 429, provider: "nvidia")
        #expect(msg == "nvidia (HTTP 429): Rate limit exceeded for this model.")
    }

    @Test func anErrorEnvelopeStillWinsOverProblemDetails() {
        let body = #"{"error":{"message":"bad request"},"detail":"ignored"}"#
        let msg = apiErrorMessage(from: body, httpStatus: 400, provider: "x")
        #expect(msg == "x (HTTP 400): bad request")
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

    private static let invalidToken = #"{"error":{"code":"SUBSCRIPTION_TOKEN_INVALID","detail":"The provided subscription token is invalid.","meta":{"component":"authentication"}}}"#

    /// The transcript read "Brave web search returned an error (HTTP 422)."
    /// for a key Brave had said, in the body, was invalid.
    @Test func groundingMessage_422InvalidTokenNamesTheKey() {
        let msg = LLMError.groundingMessage(httpStatus: 422, responseBody: Self.invalidToken)
        #expect(msg.contains("rejected the API key (HTTP 422)"))
        #expect(msg.contains("subscription token is invalid"))
        #expect(msg.contains("Settings → Search"))
    }

    @Test func groundingMessage_appendsBravesDetailWhenTheBodyHasOne() {
        let body = #"{"error":{"code":"PLAN","detail":"The option is not included in the plan."}}"#
        #expect(LLMError.groundingMessage(httpStatus: 400, responseBody: body)
                == "Brave web search returned an error (HTTP 400): The option is not included in the plan.")
        // No body, or not Brave's shape: the bare status, as before.
        #expect(LLMError.groundingMessage(httpStatus: 422) == "Brave web search returned an error (HTTP 422).")
        #expect(LLMError.groundingMessage(httpStatus: 500, responseBody: "<html>bad gateway</html>")
                == "Brave web search returned an error (HTTP 500).")
    }

    /// The tool loop stops on a refused key instead of retrying three rephrased
    /// searches against it. 401/402/403 always; 422 only with Brave's code.
    @Test func keyRejectionCoversBravesInvalidToken422() {
        func error(_ status: Int?, _ body: String?) -> LLMError {
            LLMError(source: .braveGrounding, userMessage: "x", httpStatus: status, url: nil,
                     requestHeaders: [:], requestBodyJSON: nil, messageHistory: nil,
                     responseBody: body, underlyingError: nil)
        }
        #expect(error(401, nil).isKeyRejection)
        #expect(error(402, nil).isKeyRejection)
        #expect(error(403, nil).isKeyRejection)
        #expect(error(422, Self.invalidToken).isKeyRejection)
        #expect(!error(422, #"{"error":{"code":"VALIDATION","detail":"q is required"}}"#).isKeyRejection)
        #expect(!error(422, nil).isKeyRejection)
        #expect(!error(500, Self.invalidToken).isKeyRejection)
        #expect(!error(nil, Self.invalidToken).isKeyRejection)
    }
}
