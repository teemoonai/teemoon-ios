//
//  ChatsSettingsView.swift
//  teemoon
//
//  Created by Jordan Singer on 10/6/24.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "settings")

struct ChatsSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) var modelContext
    @State var systemPrompt = ""
    @State var deleteAllChats = false
    /// The main screen's importer on iPhone (it opens the chats list after "show chats");
    /// absent in the Mac's Settings window, which imports here.
    @Environment(ChatImportModel.self) private var sharedImporter: ChatImportModel?
    @State private var localImporter = ChatImportModel()
    private var importer: ChatImportModel { sharedImporter ?? localImporter }
    @State private var showingImport = false
    /// False only once the import sheet's dismissal has finished: the delete offer waits for it.
    @State private var importSheetUp = false
    @Binding var currentThread: Thread?
    
    var body: some View {
        @Bindable var settings = settings
        Form {
            Section(header: Text("system prompt")) {
                NavigationLink {
                    SystemPromptView()
                } label: {
                    LabeledContent("system prompt", value: SystemPromptRow.value(for: settings.systemPrompt))
                }
            }

            if DeviceLayout.current == .phone {
                Section {
                    Toggle("haptics", isOn: $settings.shouldPlayHaptics)
                        .tint(.green)
                }
            }
            
            Section {
                Button {
                    importSheetUp = true
                    showingImport = true
                } label: {
                    Label(ChatImportText.pageTitle, systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("chats.import")
            } footer: {
                Text(ChatImportText.footerLead)
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
        // Its own full-height sheet over Settings; closing it any way but mid-import resets the flow.
        .sheet(isPresented: $showingImport, onDismiss: {
            importer.closeSettingsFlow()
            importSheetUp = false
        }) {
            NavigationStack { NearImportView(importer: importer) }
                .presentationBackground(PlatformColors.background)
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 560)
                #else
                .presentationDetents([.large])
                #endif
        }
        .chatImportDeleteOffer(importer, fromOutside: false, sheetUp: importSheetUp)
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
            Task { await LiteRTTransport.forgetKeptConversations() }
            StoreCompaction.requestAfterDelete()
        } catch {
            logger.error("Failed to delete chats: \(error)")
        }
    }
}

#Preview {
    ChatsSettingsView(currentThread: .constant(nil))
        .environment(AppSettings())
        .modelContainer(for: [Thread.self, Message.self, ImageAttachment.self], inMemory: true)
}
