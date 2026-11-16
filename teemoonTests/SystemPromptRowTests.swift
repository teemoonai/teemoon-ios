//
//  SystemPromptRowTests.swift
//  teemoonTests
//
//  UI audit #10 (approved 2026-10-25): the system prompt is a row reading "default" or "custom" that opens its
//  own screen, instead of an editor filling Settings → chats.
//

import Testing
@testable import teemoon

@Suite("Settings — system prompt row")
struct SystemPromptRowTests {
    @Test func theRowSaysDefaultUntilThePromptIsEdited() {
        #expect(SystemPromptRow.value(for: AppSettings.defaultSystemPrompt) == "default")
        #expect(SystemPromptRow.value(for: AppSettings.defaultSystemPrompt + " be brief.") == "custom")
        #expect(SystemPromptRow.value(for: "") == "custom")
    }
}
