//
//  ThinkHarderTests.swift
//  teemoonTests
//
//  "Think Harder" in the newest reply's long-press menu (the maintainer, 2026-10-19:
//  "A only", newest only, re-stamp): the same question again, same provider and
//  model, at high effort with room to think, in place of that reply.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@Suite("Think Harder")
struct ThinkHarderTests {

    @Test @MainActor func itReasksTheQuestionTheReplyAnswered() throws {
        let container = try ModelContainer(for: ChatThread.self, Message.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let thread = ChatThread()
        context.insert(thread)
        let texts: [(Role, String)] = [(.user, "q1"), (.assistant, "a1"), (.user, "q2"), (.assistant, "a2")]
        var made: [Message] = []
        for (i, (role, text)) in texts.enumerated() {
            let m = Message(role: role, content: text, thread: thread)
            m.timestamp = Date(timeIntervalSince1970: Double(100 + i))
            context.insert(m)
            made.append(m)
        }
        try context.save()
        #expect(ChatViewModel.question(answeredBy: made[1], in: thread)?.content == "q1")
        #expect(ChatViewModel.question(answeredBy: made[3], in: thread)?.content == "q2")
        #expect(ChatViewModel.question(answeredBy: made[0], in: thread) == nil)
    }

    @Test func itAsksForHighEffortAndRoomToThink() {
        let p = Provider(name: "p", endpoint: "https://api.fireworks.ai/inference/v1", model: "m", requiresAPIKey: true)
        let fields = ReasoningEffort.thinkHarder.bodyFields(for: p)
        #expect(fields?["reasoning_effort"] as? String == "high")
        // No cap: Fireworks' own default wrote 13k tokens (2026-10-22); 8192 gave Think Harder less room.
        #expect(fields?["max_tokens"] == nil)
        #expect(ReasoningEffort.fast.bodyFields(for: p)?["max_tokens"] == nil, "a normal turn keeps the provider's budget")
        let near = Provider(name: "n", endpoint: "https://cloud-api.near.ai/v1", model: "m", requiresAPIKey: true)
        #expect(ReasoningEffort.thinkHarder.bodyFields(for: near)?["max_tokens"] as? Int == 8192, "near.ai's default is unmeasured")
        #expect(ReasoningEffort.thinkHarderOutputTokens >= 8192)
    }

    @Test @MainActor func thinkHarderRestampsTheQuestionAndARetryDoesNot() {
        let asked = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 9_000)
        let q = Message(role: .user, content: "q")
        q.timestamp = asked
        ChatViewModel.restampIfReasked(q, effort: .chatDefault, now: now)
        #expect(q.timestamp == asked, "a retry keeps the time it was first sent")
        ChatViewModel.restampIfReasked(q, effort: .thinkHarder, now: now)
        #expect(q.timestamp == now, "Think Harder asks again now")
    }
}
