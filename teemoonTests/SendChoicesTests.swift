//
//  SendChoicesTests.swift
//  teemoonTests
//
//  The E2EE send confirmation and the mobile-data question are action sheets (pm, 2026-10-25: HIG puts choices
//  in an action sheet, not an alert). Same order on both platforms, the way out last; a hard break never offers send.
//  2026-10-30 (the maintainer, via pm): on iOS 26.5 the E2EE sheet is a popover from the title and iOS hid its role-.cancel
//  button, leaving an unlabelled tap outside as the only safe exit. It now ends in a plain "don't send" that keeps
//  the draft, "send unencrypted" is red, and the soft-degrade body is the maintainer's text, exact.
//

import Testing
@testable import teemoon

@Suite("Three-way questions")
struct SendChoicesTests {
    @Test func theE2EEQuestionKeepsItsOrderAndNeverOffersSendOnAHardBreak() {
        #expect(E2EESendChoice.choices(hardFailure: false, provenanceOnly: false).map(\.label)
                == ["retry verification", "send unencrypted", "don't send"])
        #expect(E2EESendChoice.choices(hardFailure: false, provenanceOnly: true).map(\.label)
                == ["retry verification", "send anyway (still encrypted)", "don't send"])
        #expect(E2EESendChoice.choices(hardFailure: true, provenanceOnly: true).map(\.label)
                == ["retry verification", "don't send"])
    }

    @Test func onlySendingUnsealedIsRed() {
        let all = E2EESendChoice.choices(hardFailure: false, provenanceOnly: false)
            + E2EESendChoice.choices(hardFailure: false, provenanceOnly: true)
        #expect(all.filter(\.isDestructive) == [.sendAnyway(stillEncrypted: false)])
    }

    @Test func theE2EEQuestionSaysNothingWasSent() {
        #expect(E2EESendChoice.message(hardFailure: false, provenanceOnly: false, cause: "couldn't reach the attestation server.")
                == "teemoon couldn't seal this message so only the model can read it. nothing has been sent.")
        #expect(E2EESendChoice.message(hardFailure: true, provenanceOnly: false, cause: "the hardware quote failed intel dcap verification.")
                .hasPrefix("the hardware quote failed intel dcap verification. sending is blocked"))
        #expect(E2EESendChoice.message(hardFailure: false, provenanceOnly: true, cause: nil)
                .hasPrefix("your message would still be sealed"))
    }

    /// S30 (the maintainer 2026-11-07, "The wording is good"): the two provenance questions, exact.
    @Test func theProvenanceQuestionsSayExactlyThis() {
        #expect(E2EESendChoice.provenancePendingTitle == "couldn't confirm near.ai's software yet")
        #expect(E2EESendChoice.provenancePendingMessage == "your message would still be sealed to the model's verified hardware key, but teemoon hasn't yet confirmed that the software running on it is the published code.")
        #expect(E2EESendChoice.provenanceUncheckedTitle == "couldn't confirm near.ai's software")
        #expect(E2EESendChoice.provenanceUncheckedMessage == "your message would still be sealed to the model's verified hardware key, but teemoon couldn't reach GitHub or Docker Hub to confirm that the software running on it is the published code.")
    }

    /// Which question the gate shows: provenance in flight at the timeout gets "send anyway" · "wait" like the hardware
    /// ask; a lookup that ended without an answer has nothing to wait for and reuses the provenance-only choices.
    @Test func eachPendingKindAsksItsOwnQuestion() {
        func ask(pending: ConfidentialSession.PendingKind? = nil, unchecked: Bool = false, soft: Bool = true,
                 hard: Bool = false) -> E2EEAsk {
            E2EEAsk.make(hardFailure: hard, pendingAsk: pending, provenanceUnchecked: unchecked, softButSealed: soft,
                         provenanceBlocked: false, cause: nil)
        }
        #expect(ask(pending: .provenance) == E2EEAsk(title: "couldn't confirm near.ai's software yet",
                                                     message: E2EESendChoice.provenancePendingMessage,
                                                     choices: E2EESendChoice.stillChecking))
        #expect(ask(pending: .provenance).choices.map(\.label) == ["send anyway", "wait"])
        #expect(ask(pending: .hardware).title == "still checking near.ai's hardware")
        #expect(ask(pending: .hardware).choices.map(\.label) == ["send anyway", "wait"])
        #expect(ask(unchecked: true) == E2EEAsk(title: "couldn't confirm near.ai's software",
                                                message: E2EESendChoice.provenanceUncheckedMessage,
                                                choices: E2EESendChoice.choices(hardFailure: false, provenanceOnly: true)))
        #expect(ask(unchecked: true).choices.map(\.label) == ["retry verification", "send anyway (still encrypted)", "don't send"])
        #expect(ask().title == "still checking near.ai's hardware", "a soft seal-holding state keeps its question")
        #expect(ask(pending: .provenance, hard: true).title == "verification failed — sending blocked")
    }

    /// Past near.ai's tier deadline nothing is still checking and nothing reloads the list (design review 2026-11-14):
    /// its own title and body, and like the T2b provenance ask nothing to wait for, so no "wait".
    @Test func aTimedOutAskDoesNotSayStillChecking() {
        func ask(pending: ConfidentialSession.PendingKind? = nil, passed: Bool) -> E2EEAsk {
            E2EEAsk.make(hardFailure: false, pendingAsk: pending, provenanceUnchecked: false, softButSealed: true,
                         provenanceBlocked: false, cause: nil, deadlinePassed: passed)
        }
        #expect(ask(passed: true).title == "couldn't confirm near.ai's hardware")
        #expect(ask(passed: true).message == "near.ai's model list didn't load, so teemoon couldn't confirm this model runs on its own hardware.")
        #expect(ask(passed: true).choices.map(\.label) == ["send anyway", "don't send"])
        let stillChecking = E2EEAsk(title: "still checking near.ai's hardware", message: E2EESendChoice.stillCheckingMessage,
                                    choices: E2EESendChoice.stillChecking)
        #expect(ask(passed: false) == stillChecking)
        #expect(ask(pending: .hardware, passed: false) == stillChecking)
        #expect(stillChecking.choices.map(\.label) == ["send anyway", "wait"])
    }

    @Test func theMobileDataQuestionKeepsItsOrder() {
        #expect(CellularDownloadChoice.allCases.map(\.label) == ["download now", "wait for wi-fi", "not now"])
    }
}
