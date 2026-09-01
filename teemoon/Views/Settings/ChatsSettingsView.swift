//
//  ChatsSettingsView.swift
//  teemoon
//
//  Created by Jordan Singer on 10/6/24.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "settings")

struct ChatsSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) var modelContext
    @State var systemPrompt = ""
    @State var deleteAllChats = false
    @Binding var currentThread: Thread?
    
    var body: some View {
        @Bindable var settings = settings
        Form {
            Section(header: Text("system prompt"), footer: Text("Use {{datetime}} to insert the current date and time.")) {
                TextEditor(text: $settings.systemPrompt)
                    .textEditorStyle(.plain)
            }

            if DeviceLayout.current == .phone {
                Section {
                    Toggle("haptics", isOn: $settings.shouldPlayHaptics)
                        .tint(.green)
                }
            }
            
            Section {
                Button {
                    deleteAllChats.toggle()
                } label: {
                    Label("delete all chats", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .alert("are you sure?", isPresented: $deleteAllChats) {
                    Button("cancel", role: .cancel) {
                        deleteAllChats = false
                    }
                    Button("delete", role: .destructive) {
                        deleteChats()
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("chats")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    
    func deleteChats() {
        do {
            currentThread = nil
            try ThreadDeletion.deleteAll(in: modelContext)
            // The index sweep still matters: an index left behind would keep
            // a searchable plaintext copy of everything just deleted.
            ChatSearchService.shared.didDeleteAllChats()
        } catch {
            logger.error("Failed to delete chats: \(error)")
        }
    }
}

#Preview {
    ChatsSettingsView(currentThread: .constant(nil))
        .environment(AppSettings())
        .modelContainer(for: [Thread.self, Message.self], inMemory: true)
}
