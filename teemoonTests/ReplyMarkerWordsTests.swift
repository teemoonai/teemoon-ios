//
//  ReplyMarkerWordsTests.swift
//  teemoonTests
//
//  The approved words behind reply-machine.json's marker and mark ids, which row shows which, and that retry is
//  offered only on a didn't-finish marker on the newest reply.
//

import Foundation
import SwiftUI
import Testing
@testable import teemoon

@Suite("A reply's marker and mark words")
@MainActor struct ReplyMarkerWordsTests {

    @Test func theApprovedWords() {
        #expect(ReplyMarkerWords.line(.didntFinish) == "this reply didn't finish.")
        #expect(ReplyMarkerWords.line(.stopped) == "you stopped this reply.")
        #expect(ReplyMarkerWords.line(.cutShort) == "this reply was cut short.")
        #expect(ReplyMarkerWords.line(.decryptFailed) == "this reply couldn't be decrypted, so it isn't shown.")
        #expect(ReplyMarkerWords.line(.sentWhileChecking) == "sent while near.ai's hardware was still being checked")
        #expect(ReplyMarkerWords.line(.checkFailedAfterSend)
                == "near.ai's hardware failed its check after this was sent. treat this reply as not private.")
        #expect(ReplyMarkerWords.retry == "retry", "retry is the word, as Android has it — not an icon")
    }

    @Test func eachStoredStatusShowsItsMarker() {
        func reply(_ status: String?) -> Message {
            let m = Message(role: .assistant, content: "x")
            m.statusRaw = status
            return m
        }
        #expect(ReplyMarkerWords.marker(of: reply(nil)) == nil, "rows from before V3 read complete")
        #expect(ReplyMarkerWords.marker(of: reply("complete")) == nil)
        #expect(ReplyMarkerWords.marker(of: reply("interrupted")) == .didntFinish, "killed mid-turn, read back at launch")
        #expect(ReplyMarkerWords.marker(of: reply("failed")) == .didntFinish)
        #expect(ReplyMarkerWords.marker(of: reply("stopped")) == .stopped)
        #expect(ReplyMarkerWords.marker(of: reply("cutOff")) == .cutShort)
        #expect(ReplyMarkerWords.marker(of: reply("decryptFailed")) == .decryptFailed)
        let question = Message(role: .user, content: "q")
        question.statusRaw = "interrupted"
        #expect(ReplyMarkerWords.marker(of: question) == nil, "a question never wears a reply marker")
    }

    @Test func retryOnlyOnTheNewestDidntFinish() {
        let dead = Message(role: .assistant, content: "")
        dead.statusRaw = "interrupted"
        let stopped = Message(role: .assistant, content: "part")
        stopped.statusRaw = "stopped"
        #expect(ReplyMarkerWords.offersRetry(dead, isNewest: true))
        #expect(!ReplyMarkerWords.offersRetry(dead, isNewest: false))
        #expect(!ReplyMarkerWords.offersRetry(stopped, isNewest: true))
    }

    /// The failed-after-send mark wears the trust screens' hard-failure red (TrustScopeLineView .broken, the hero's
    /// .failed); the pending mark and every marker stay secondary.
    @Test func theFailedMarkIsHardFailureRed() {
        #expect(ReplyMarkerWords.color(of: .checkFailedAfterSend) == Color.red)
        #expect(ReplyMarkerWords.color(of: .sentWhileChecking) == Color.secondary)
    }

    /// A row with no text (couldn't decrypt, didn't finish) draws no answer block, so its marker sits at the normal
    /// gap under the question.
    @Test func anEmptyReplyDrawsNoAnswerBlock() {
        #expect(ReplyMarkerWords.answerToDraw(nil) == nil)
        #expect(ReplyMarkerWords.answerToDraw("") == nil)
        #expect(ReplyMarkerWords.answerToDraw("  \n ") == nil)
        #expect(ReplyMarkerWords.answerToDraw("Partial") == "Partial")
    }
}
