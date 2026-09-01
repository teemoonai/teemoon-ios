//
//  FreshStartTests.swift
//  teemoonTests
//
//  The rule is drawn between turns, so the interesting cases are all boundary
//  cases — and a rule in the wrong place says something false about what the
//  provider saw.
//

import Testing
@testable import teemoon

@Suite("Fresh-start rule placement")
struct FreshStartTests {

    @Test func noRulesForAProviderThatSeesTheConversation() {
        let roles: [Role] = [.user, .assistant, .user, .assistant]
        #expect(FreshStart.indices(roles: roles, singleTurn: false).isEmpty)
    }

    @Test func theFirstQuestionIsNotAFreshStart() {
        // Nothing preceded it, so there is nothing the provider failed to see.
        #expect(FreshStart.indices(roles: [.user], singleTurn: true).isEmpty)
        #expect(FreshStart.indices(roles: [.user, .assistant], singleTurn: true).isEmpty)
    }

    @Test func everyFollowUpQuestionIsMarked() {
        let roles: [Role] = [.user, .assistant, .user, .assistant, .user]
        #expect(FreshStart.indices(roles: roles, singleTurn: true) == [2, 4])
    }

    @Test func answersAreNeverMarked() {
        // The break belongs to the question sent alone, not the reply.
        let roles: [Role] = [.user, .assistant, .user, .assistant]
        let marked = FreshStart.indices(roles: roles, singleTurn: true)
        for i in marked { #expect(roles[i] == .user) }
    }

    @Test func consecutiveQuestionsEachStartFresh() {
        // A send that failed, then a retry: two user turns in a row, and the
        // second is still a question the provider will answer blind.
        let roles: [Role] = [.user, .user, .user]
        #expect(FreshStart.indices(roles: roles, singleTurn: true) == [1, 2])
    }

    @Test func aLeadingSystemOrAssistantTurnDoesNotCountAsAQuestion() {
        let roles: [Role] = [.assistant, .user, .assistant, .user]
        // Index 1 is still the FIRST question, so only index 3 is marked.
        #expect(FreshStart.indices(roles: roles, singleTurn: true) == [3])
    }

    @Test func emptyTranscript() {
        #expect(FreshStart.indices(roles: [], singleTurn: true).isEmpty)
    }
}
