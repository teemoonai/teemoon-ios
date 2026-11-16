//
//  ReplyParseCacheTests.swift
//  teemoonTests
//
//  Device 2026-11-07, GLM 5.3 Flash with web search: the reply row is saved empty at turn start and can be drawn
//  during the search round. Its parse ("no answer") was cached by message id alone, so the finished 1,671-char reply
//  drew only its sources chip — a blank transcript until the chat was reopened.
//

import Foundation
import Testing
@testable import teemoon

@Suite("A reply's parse follows its text")
@MainActor struct ReplyParseCacheTests {
    @Test func aReplyFirstDrawnEmptyShowsItsTextOnceItArrives() {
        let id = UUID()
        #expect(MessageView.thinkParse(id: id, content: "").answer.flatMap(ReplyMarkerWords.answerToDraw) == nil)
        let full = "- one\n- two\n\nA paragraph."
        #expect(MessageView.thinkParse(id: id, content: full).answer == full, "the empty first parse stuck")
    }

    @Test func thinkingThatClosesLaterIsReparsed() {
        let id = UUID()
        #expect(MessageView.thinkParse(id: id, content: "<think>still going").isThinking)
        let done = MessageView.thinkParse(id: id, content: "<think>done</think>the answer")
        #expect(!done.isThinking && done.answer == "the answer")
    }
}
