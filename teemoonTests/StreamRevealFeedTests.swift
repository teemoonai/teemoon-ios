//
//  StreamRevealFeedTests.swift
//  teemoonTests
//
//  "Whole if quick" applies to the answer only: thinking shows as it arrives (pm, 2026-10-25, item 7), and the
//  stall rule counts arrivals, not what is drawn.
//

import Testing
@testable import teemoon

@Suite("Streaming reveal — what the view draws")
struct StreamRevealFeedTests {

    @Test func thinkingShowsAsItArrives() {
        var feed = StreamRevealFeed()
        #expect(feed.frame(source: "<think>weighing it", at: 0).text == "<think>weighing it")
        #expect(feed.frame(source: "<think>weighing it up", at: 50).text == "<think>weighing it up")
    }

    @Test func theAnswerAfterThinkingIsHeldThenRevealed() {
        var feed = StreamRevealFeed()
        _ = feed.frame(source: "<think>t</think>", at: 0)
        #expect(feed.frame(source: "<think>t</think>alpha beta gamma delta", at: 100).text == "<think>t</think>")
        #expect(feed.frame(source: "<think>t</think>alpha beta gamma delta", at: 700).text == "<think>t</think>alpha")
    }

    @Test func aQuickAnswerParagraphFadesFromItsStartInTheDrawnText() {
        var feed = StreamRevealFeed()
        _ = feed.frame(source: "Hi", at: 0)
        let shown = feed.frame(source: "Hi there.\n\n", at: 100)
        #expect(shown.text == "Hi there.\n\n")
        #expect(shown.fadeFrom == 0)
    }

    /// The turn's origin is set when the request is built, which can be after the view starts drawing: it is read
    /// at the answer's first character, not before.
    @Test func anOnDeviceAnswerIsNotHeldAndItsOriginIsReadAtTheFirstCharacter() {
        var feed = StreamRevealFeed()
        #expect(feed.frame(source: "", origin: .cloud, at: 0).text == "")
        #expect(feed.frame(source: "one two three", origin: .onDevice, at: 10).text == "one")
        var cloud = StreamRevealFeed()
        #expect(cloud.frame(source: "one two three", origin: .cloud, at: 10).text == "")
    }

    @Test func arrivalsCountChangesNotFrames() {
        var feed = StreamRevealFeed()
        _ = feed.frame(source: "a", at: 0)
        _ = feed.frame(source: "a", at: 16)
        _ = feed.frame(source: "ab", at: 33)
        #expect(feed.arrivals == 2)
    }
}
