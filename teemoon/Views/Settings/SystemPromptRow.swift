//
//  SystemPromptRow.swift
//  teemoon
//

//  The system prompt as a Settings row and its own screen (UI audit #10). SystemPromptRowTests pins the value.
//

import SwiftUI

enum SystemPromptRow {
    static func value(for prompt: String) -> String {
        prompt == AppSettings.defaultSystemPrompt ? "default" : "custom"
    }
}

struct SystemPromptView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section(footer: Text("{{date}} is replaced with today's date. The current time is added to each message you send.")) {
                TextEditor(text: $settings.systemPrompt)
                    .textEditorStyle(.plain)
                    .frame(minHeight: 240)
            }
            Section {
                Button("reset to default") { settings.systemPrompt = AppSettings.defaultSystemPrompt }
                    .disabled(settings.systemPrompt == AppSettings.defaultSystemPrompt)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("system prompt")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    NavigationStack { SystemPromptView() }
        .environment(AppSettings())
}
