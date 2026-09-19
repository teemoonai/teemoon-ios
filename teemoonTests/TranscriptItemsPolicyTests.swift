//
//  TranscriptItemsPolicyTests.swift
//  teemoonTests
//
//  The onboarding turn: a keyless question raises the web-search offer under
//  a long first reply, and developer mode adds the card. With the offer as
//  the transcript's last item the hand-off gave it the reply's height and
//  the card sat centred in a cell that tall — an empty band above it and
//  another below (nvidia nemotron, 2026-09-18). The newest offer is the
//  tail's; earlier ones stay under their message.
//

#if os(iOS)

import Foundation
import Testing
@testable import teemoon

@Suite("Transcript item lists")
struct TranscriptItemsPolicyTests {

    @Test func theNewestOfferOpensTheTailNotTheTranscript() {
        let user = UUID(), reply = UUID()
        let lists = TranscriptItemsPolicy.lists(
            messageIDs: [user, reply], freshStarts: [], searchConfigured: false, offered: { $0 == reply })
        #expect(lists.transcript == [.message(user), .message(reply)])
        #expect(lists.transcript.last == .message(reply),
                "the hand-off sizes the transcript's last item; it must be the reply")
        #expect(lists.tailOffer == .offer(reply))
    }

    @Test func anEarlierOfferStaysUnderItsMessage() {
        let a = UUID(), b = UUID(), c = UUID()
        let lists = TranscriptItemsPolicy.lists(
            messageIDs: [a, b, c], freshStarts: [], searchConfigured: false, offered: { $0 == b })
        #expect(lists.transcript == [.message(a), .message(b), .offer(b), .message(c)])
        #expect(lists.tailOffer == nil)
    }

    /// The key can arrive from settings or the web chip, not only from the
    /// card's paste row — the only path that clears the offer map. The row
    /// must go either way.
    @Test func aConfiguredSearchShowsNoOfferAnywhere() {
        let a = UUID(), b = UUID(), c = UUID()
        let lists = TranscriptItemsPolicy.lists(
            messageIDs: [a, b, c], freshStarts: [], searchConfigured: true,
            offered: { $0 == b || $0 == c })
        #expect(lists.transcript == [.message(a), .message(b), .message(c)])
        #expect(lists.tailOffer == nil)
    }

    @Test func noOfferNoTailRow() {
        let a = UUID(), b = UUID()
        let lists = TranscriptItemsPolicy.lists(
            messageIDs: [a, b], freshStarts: [1], searchConfigured: false, offered: { _ in false })
        #expect(lists.transcript == [.message(a), .freshStart(before: b), .message(b)])
        #expect(lists.tailOffer == nil)
    }
}

#endif
