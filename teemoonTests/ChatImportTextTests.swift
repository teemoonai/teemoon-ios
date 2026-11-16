//
//  ChatImportTextTests.swift
//  teemoonTests
//
//  The import summary's lines and the list row's name for an imported chat.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Import — text")
struct ChatImportTextTests {

    @Test func theDoneStepSaysWhatCameInAndWhatDidnt() {
        let s = ImportSummary(chatsImported: 6, messagesImported: 25, chatsAlreadyHere: 1, itemsSkipped: 4,
                              mayBeIncomplete: false, imagesImported: 1)
        #expect(ChatImportText.finishedBody(s) == "teemoon imported 6 chats, 25 messages and 1 image.")
        #expect(ChatImportText.finishedNotes(s) == ["4 items couldn't be read and were skipped."])
        #expect(ChatImportText.finishedBody(ImportSummary(chatsImported: 1, messagesImported: 1)) == "teemoon imported 1 chat and 1 message.")
        let none = ImportSummary(chatsImported: 0, chatsAlreadyHere: 1, mayBeIncomplete: true)
        #expect(ChatImportText.finishedBody(none) == "there was nothing new to import.")
        #expect(ChatImportText.finishedNotes(none).first?.hasPrefix("part of this chat may be missing") == true)
        #expect(!ChatImportText.finishedNotes(s).contains { $0.contains("comes back") }, "pm 11-01: that line is dropped")
    }

    /// The file card says what the dry run found before anything is written, and only the notes that apply (placeholders).
    @Test func theFileCardSaysWhatWillComeInAndOnlyTheNotesThatApply() {
        let s = ImportSummary(chatsImported: 6, messagesImported: 25, chatsAlreadyHere: 1, itemsSkipped: 4,
                              mayBeIncomplete: false, imagesImported: 1)
        #expect(ChatImportText.cardCounts(s) == "6 chats, 25 messages and 1 image")
        #expect(ChatImportText.cardNote(s) == "1 chat already here stays as it is. 4 items can't be read and will be skipped.")
        #expect(ChatImportText.cardNote(ImportSummary(chatsImported: 2, messagesImported: 3, chatsAlreadyHere: 2))
                == "2 chats already here stay as they are.")
        #expect(ChatImportText.cardNote(ImportSummary(chatsImported: 2, messagesImported: 3)) == nil)
        // Nothing new (v7): its own screen; the card counts the file's chats only and carries no note.
        let nothing = ImportSummary(chatsAlreadyHere: 3)
        #expect(ChatImportText.isNothingNew(nothing))
        #expect(ChatImportText.title(for: .confirm(nothing)) == "nothing new to import")
        #expect(ChatImportText.cardCounts(nothing) == "3 chats")
        #expect(ChatImportText.cardCounts(ImportSummary(chatsAlreadyHere: 1)) == "1 chat")
        #expect(ChatImportText.cardNote(nothing) == nil)
        #expect(ChatImportText.cardNote(ImportSummary(chatsAlreadyHere: 3, itemsSkipped: 1)) == nil, "nothing to skip from")
        // An empty file (v8): the same result screen, its own words.
        #expect(ChatImportText.isNothingNew(ImportSummary()))
        #expect(ChatImportText.title(for: .confirm(ImportSummary())) == "nothing to import")
        #expect(ChatImportText.cardCounts(ImportSummary()) == nil, "no count line: \"0 chats\" would repeat the body")
    }

    @Test func theCardDatesAndSizesTheFile() {
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .current, year: 2026, month: 10, day: 15))!
        let facts = ChatImportModel.FileFacts(name: "x.json", modified: date, bytes: 24_000)
        #expect(ChatImportText.fileFacts(facts, locale: Locale(identifier: "en_US")) == "oct 15 · 24 KB")
        #expect(ChatImportText.fileFacts(.init(name: "x.json")) == nil)
    }

    @Test func theTitleFollowsTheStep() {
        #expect(ChatImportText.title(for: .idle) == "import from near.ai")
        #expect(ChatImportText.title(for: .confirm(ImportSummary(chatsImported: 1, messagesImported: 1))) == "import from near.ai")
        #expect(ChatImportText.title(for: .importing(read: 1, total: 2)) == "importing…")
        #expect(ChatImportText.title(for: .finished(ImportSummary())) == "import finished")
    }

    /// UI audit #8 (the maintainer approved the wording 2026-10-25): a failure is a system alert with a title that says
    /// what happened; only a finished import gets the summary sheet.
    @Test func aFailureIsAnAlertAndOnlyAFinishedImportIsASheet() {
        #expect(ChatImportText.alert(for: .failed(.wrongFile))
                == .init(title: "this file can't be imported", message: "it isn't a chat export teemoon can read."))
        #expect(ChatImportText.alert(for: .failed(.cantOpen)) == .init(title: "couldn't open this file", message: nil))
        #expect(ChatImportText.alert(for: .failed(.stopped))
                == .init(title: "the import stopped",
                         message: "chats already imported are kept; import the same file again to finish."))
        #expect(ChatImportText.alert(for: .finished(ImportSummary(chatsImported: 1, messagesImported: 1, chatsAlreadyHere: 0,
                                                                   itemsSkipped: 0, mayBeIncomplete: false))) == nil)
        #expect(ChatImportText.alert(for: .importing(read: 2, total: 5)) == nil)
    }

    /// v9 (the maintainer 11-01, D5/D6): the red button names the file, "not now" replaces "keep", and the body says it's final.
    @Test func theDeleteOfferSaysWhatWasApproved() {
        #expect(ChatImportText.deleteButton("export.json") == "delete “export.json”")
        #expect(ChatImportText.notNow == "not now")
        #expect(ChatImportText.deleteMessage("export.json")
                == "export.json holds your chats unencrypted. teemoon has its own copy now. this can't be undone.")
    }

    @Test func theFooterSaysWhatWasApproved() {
        #expect(ChatImportText.footerLead == "from near.ai private chat. it stays on this phone.")
    }

    @Test func theListNamesAChatByItsTitleThenItsFirstMessage() {
        #expect(ThreadListTitle.text(title: "Two days in Lisbon", firstMessage: "What should I see?") == "Two days in Lisbon")
        #expect(ThreadListTitle.text(title: nil, firstMessage: "What should I see?") == "What should I see?")
        #expect(ThreadListTitle.text(title: "  ", firstMessage: "What should I see?") == "What should I see?")
        #expect(ThreadListTitle.text(title: nil, firstMessage: nil) == "untitled")
    }
}
