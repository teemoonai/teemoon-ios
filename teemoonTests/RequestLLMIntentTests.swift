import Foundation
import Testing
@testable import teemoon

// A failed Siri turn must say something. `ChatGeneration.generate` returns an
// empty string and parks the error on failure; `perform` used to hand that
// empty string straight to Siri (spoken as silence), and in continuous mode
// asked a blank follow-up question. `failureDialog` is the pure gate that turns
// a failure into spoken words.
@Suite("Siri intent failure dialog")
struct RequestLLMIntentTests {

    @Test func speaksTheProviderError() {
        #expect(RequestLLMIntent.failureDialog(errorMessage: "the server is down", output: "")
                == "Sorry — the server is down")
    }

    @Test func speaksSomethingWhenOutputIsEmptyWithNoError() {
        let dialog = RequestLLMIntent.failureDialog(errorMessage: nil, output: "")
        #expect(dialog != nil)
        #expect(!(dialog ?? "").isEmpty)
    }

    @Test func staysSilentOnASuccessfulReply() {
        #expect(RequestLLMIntent.failureDialog(errorMessage: nil, output: "here is your answer") == nil)
    }
}
