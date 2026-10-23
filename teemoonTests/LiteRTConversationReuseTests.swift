//
//  LiteRTConversationReuseTests.swift
//  teemoonTests
//
//  The rule that lets an on-device turn keep last turn's conversation, ported
//  from Android's ConversationReuseTest. Device timing is a separate check.
//

import Foundation
import Testing
@testable import teemoon

@Suite("LiteRT conversation reuse")
struct LiteRTConversationReuseTests {
    typealias Turn = KeptConversationState.Turn
    static let persona = "The current date and time is Sunday, October 19, 2026.\n\nBe direct."
    static let history = [Turn(role: "user", text: "hi"), Turn(role: "assistant", text: "Hello.")]

    static func kept(after user: String = "how are you?\n\n[Sent at 4:11 AM]", answer: String = "Well.") -> KeptConversationState? {
        LiteRTConversationReuse.afterTurn(systemMessage: persona, toolNames: ["web_search"], history: history,
                                          userText: user, rawAnswer: answer, toolsRan: 0, completed: true)
    }

    /// The next seed spells the user turn with the same note: it is rebuilt from the stored timestamp.
    static let nextHistory = history + [Turn(role: "user", text: "how are you?\n\n[Sent at 4:11 AM]"),
                                        Turn(role: "assistant", text: "Well.")]

    @Test func theNextTurnReusesWhenItWouldSeedTheSame() {
        #expect(LiteRTConversationReuse.canReuse(Self.kept(), systemMessage: Self.persona, toolNames: ["web_search"],
                                                 history: Self.nextHistory))
    }

    @Test func everyMismatchRebuilds() {
        let k = Self.kept()
        #expect(!LiteRTConversationReuse.canReuse(k, systemMessage: Self.persona + "!", toolNames: ["web_search"], history: Self.nextHistory))
        #expect(!LiteRTConversationReuse.canReuse(k, systemMessage: Self.persona, toolNames: [], history: Self.nextHistory))
        #expect(!LiteRTConversationReuse.canReuse(k, systemMessage: Self.persona, toolNames: ["web_search"], history: Array(Self.nextHistory.dropFirst(2))), "trimmed")
        var edited = Self.nextHistory; edited[2] = Turn(role: "user", text: "how are you??")
        #expect(!LiteRTConversationReuse.canReuse(k, systemMessage: Self.persona, toolNames: ["web_search"], history: edited))
        #expect(!LiteRTConversationReuse.canReuse(nil, systemMessage: Self.persona, toolNames: ["web_search"], history: Self.nextHistory))
    }

    @Test func aRawAnswerThatIsNotWhatGetsStoredRebuilds() {
        let k = Self.kept(answer: "<think>hmm</think>Well.")
        #expect(!LiteRTConversationReuse.canReuse(k, systemMessage: Self.persona, toolNames: ["web_search"], history: Self.nextHistory))
    }

    @Test func notKeptAfterAToolOrAnUnfinishedTurn() {
        #expect(LiteRTConversationReuse.afterTurn(systemMessage: Self.persona, toolNames: ["web_search"], history: Self.history,
                                                  userText: "q", rawAnswer: "a", toolsRan: 1, completed: true) == nil)
        #expect(LiteRTConversationReuse.afterTurn(systemMessage: Self.persona, toolNames: ["web_search"], history: Self.history,
                                                  userText: "q", rawAnswer: "a", toolsRan: 0, completed: false) == nil)
        #expect(LiteRTConversationReuse.afterTurn(systemMessage: Self.persona, toolNames: [], history: Self.history,
                                                  userText: "q", rawAnswer: "", toolsRan: 0, completed: true) == nil)
    }

    /// Think Harder turns thinking on; its KV holds the thought, which no seed carries.
    @Test func aThinkingTurnIsNeverKept() {
        #expect(LiteRTConversationReuse.afterTurn(systemMessage: Self.persona, toolNames: ["web_search"], history: Self.history,
                                                  userText: "q", rawAnswer: "a", toolsRan: 0, completed: true,
                                                  thinking: true) == nil)
    }

    @Test func aConversationIsNotReusedAcrossThinkingModes() {
        #expect(!LiteRTConversationReuse.canReuse(Self.kept(), systemMessage: Self.persona, toolNames: ["web_search"],
                                                  history: Self.nextHistory, thinking: true))
        #expect(LiteRTConversationReuse.canReuse(Self.kept(), systemMessage: Self.persona, toolNames: ["web_search"],
                                                 history: Self.nextHistory, thinking: false))
    }

    /// The maintainer, 2026-10-22: Gemma's thinking is handled like cloud reasoning: never shown, never kept.
    /// Android's NPU bundle puts it inline; it is stripped from the reply.
    @Test func anInlineThoughtIsStrippedFromTheReply() {
        let sentinel = "SENTINEL-THOUGHT-7f3a"
        let raw = "<|channel>thought\nCount the r's. \(sentinel)<channel|>There are 3 r's."
        let (thinking, visible) = ThinkingContentParser.parse(LiteRTTransport.strippingInlineThought(raw))
        #expect(thinking == nil)
        #expect(visible == "There are 3 r's.")
        let cutOff = ThinkingContentParser.parse(LiteRTTransport.strippingInlineThought("<|channel>thought\nstill \(sentinel)"))
        #expect(cutOff.answer?.isEmpty ?? true, "a thought cut off by the cap leaves no reply")
        #expect(cutOff.thinking == nil, "and nothing for the reasoning-only fallback to promote")
        #expect(LiteRTTransport.strippingInlineThought("Hello.") == "Hello.")
    }

    /// While it streams, an inline thought never reaches a partial, however the chunks split it.
    @Test func anInlineThoughtNeverReachesAPartial() {
        let sentinel = "SENTINEL-THOUGHT-7f3a"
        let stream = "Sure. <|channel>thought\nCount: \(sentinel)<channel|>There are 3 r's."
        for size in 1...12 {
            var filter = InlineThoughtFilter()
            var shown = ""
            var i = stream.startIndex
            while i < stream.endIndex {
                let j = stream.index(i, offsetBy: size, limitedBy: stream.endIndex) ?? stream.endIndex
                shown += filter.append(String(stream[i..<j]))
                #expect(!shown.contains(sentinel) && !shown.contains("<|"), "chunk size \(size): \(shown)")
                i = j
            }
            shown += filter.finish()
            #expect(shown == "Sure. There are 3 r's.", "chunk size \(size)")
        }
        var cut = InlineThoughtFilter()
        #expect(cut.append("<|channel>thought\n\(sentinel)") == "")
        #expect(cut.finish() == "", "a thought the cap cut off shows nothing")
        var plain = InlineThoughtFilter()
        #expect(plain.append("a < b") + plain.finish() == "a < b")
    }

    @Test func aHistoryWithoutTheTurnsOwnTimeRebuilds() {
        let bare = Self.history + [Turn(role: "user", text: "how are you?"), Turn(role: "assistant", text: "Well.")]
        #expect(!LiteRTConversationReuse.canReuse(Self.kept(), systemMessage: Self.persona, toolNames: ["web_search"], history: bare))
    }
}
