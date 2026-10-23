//
//  PromptPrefixStabilityTests.swift
//  teemoonTests
//
//  Prompt caching needs the request prefix byte-identical from one turn to the
//  next. pm measured it 2026-10-19 with a ~3.8k-token prompt: Fireworks
//  deepseek-v4p1-flash cached 0 → 3718 tokens on a repeat, and 0 again when only
//  the minute in the system prompt changed; xAI grok-4.20 128 → 3968, and 128.
//  `{{datetime}}` resolved to the minute, so most chats never hit the cache.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Prompt prefix stability")
@MainActor struct PromptPrefixStabilityTests {

    static let morning = Date(timeIntervalSince1970: 1_792_400_000)   // a fixed instant
    static let laterThatDay = morning.addingTimeInterval(3 * 3600 + 17 * 60)

    static func message(_ role: Role, _ content: String, at date: Date) -> Message {
        let m = Message(role: role, content: content)
        m.timestamp = date
        return m
    }

    @Test func theSystemPromptIsTheSameAllDay() {
        let a = ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt, now: Self.morning)
        let b = ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt, now: Self.laterThatDay)
        #expect(a == b)
        #expect(!a.contains("{{datetime}}"))
        #expect(!a.contains(":"), "no clock time in the system prompt")
    }

    @Test func dateAndTheOlderDatetimeMeanTheSameDay() {
        let a = ChatGeneration.resolvePromptTemplates("Today is {{date}}.", now: Self.morning)
        let b = ChatGeneration.resolvePromptTemplates("Today is {{datetime}}.", now: Self.morning)
        #expect(a == b)
        #expect(!a.contains("{{"))
    }

    @Test func aPersonaWithADateGetsTimeNotes() {
        #expect(ChatGeneration.wantsTimeNotes(systemPrompt: "It is {{date}}.", omitSystemPrompt: false))
        #expect(ChatGeneration.wantsTimeNotes(systemPrompt: "It is {{datetime}}.", omitSystemPrompt: false))
        #expect(!ChatGeneration.wantsTimeNotes(systemPrompt: "no template here", omitSystemPrompt: false))
        #expect(!ChatGeneration.wantsTimeNotes(systemPrompt: "It is {{date}}.", omitSystemPrompt: true))
        #expect(ChatGeneration.timeNote(sentAt: Self.morning).hasPrefix("\n\n[Sent at "))
    }

    /// Every user turn carries the time it was sent, from the store: the same
    /// turn renders the same bytes on every later request.
    @Test @MainActor func eachUserTurnCarriesItsOwnTimeAndKeepsIt() {
        let u1 = Self.message(.user, "first question", at: Self.morning)
        let a1 = Self.message(.assistant, "first answer", at: Self.morning.addingTimeInterval(20))
        let u2 = Self.message(.user, "follow-up", at: Self.laterThatDay)
        let a2 = Self.message(.assistant, "second answer", at: Self.laterThatDay.addingTimeInterval(20))
        let u3 = Self.message(.user, "third", at: Self.laterThatDay.addingTimeInterval(600))
        let sys = ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt, now: Self.morning)
        let turn2 = ChatGeneration.buildWireMessages(from: [u1, a1, u2], systemPrompt: sys, maxMessages: nil, timeNotes: true)
        let turn3 = ChatGeneration.buildWireMessages(from: [u1, a1, u2, a2, u3], systemPrompt: sys, maxMessages: nil, timeNotes: true)
        #expect(turn2[1].content == "first question" + ChatGeneration.timeNote(sentAt: Self.morning))
        #expect(turn3.prefix(turn2.count).map(\.content) == turn2.map(\.content))
        #expect(turn3[3].content == "follow-up" + ChatGeneration.timeNote(sentAt: Self.laterThatDay))
        #expect(turn3[2].content == "first answer", "assistant turns carry no note")
    }

    /// The history the second turn sends starts with exactly the bytes the first turn sent.
    @Test @MainActor func historyIsAPrefixOfTheNextTurn() {
        let u1 = Message(role: .user, content: "first question")
        let a1 = Message(role: .assistant, content: "first answer")
        let u2 = Message(role: .user, content: "follow-up")
        let sys1 = ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt, now: Self.morning)
        let sys2 = ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt, now: Self.laterThatDay)
        let turn1 = ChatGeneration.buildWireMessages(from: [u1], systemPrompt: sys1, maxMessages: nil)
        let turn2 = ChatGeneration.buildWireMessages(from: [u1, a1, u2], systemPrompt: sys2, maxMessages: nil)
        let first: [String] = turn1.map { $0.content }
        let next: [String] = turn2.prefix(turn1.count).map { $0.content }
        #expect(first == next)
        #expect(turn2.map { $0.role } == ["system", "user", "assistant"])
    }
}
