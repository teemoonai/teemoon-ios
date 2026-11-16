import Foundation
import Testing
@testable import teemoon

/// chat-search-titles (the maintainer, 2026-11-06): the index is fts5 over message text,
/// and an imported near.ai chat keeps a title that is usually in none of its
/// messages, so searching that title answered "no results". Titles now match
/// too, with Android's rule (f9fe44fb): case- and diacritic-insensitive
/// substring; title matches first in the list's order, then the index's hits in
/// rank order, each chat once. A row that matched both keeps the index snippet.
@Suite("Chat list title search")
struct ChatListTitleSearchTests {

    private struct Chat: Equatable {
        let id = UUID()
        let title: String?
    }

    private let open = ChatSearchIndex.highlightOpen
    private let close = ChatSearchIndex.highlightClose

    // The unfiltered list's order: newest first.
    private let recent = Chat(title: "trip to Café Montréal")
    private let groceries = Chat(title: "groceries")
    private let imported = Chat(title: "a ~10 MB JPEG data URL: imports")
    private let untitled = Chat(title: nil)
    private var list: [Chat] { [recent, groceries, imported, untitled] }

    private func rows(_ query: String,
                      hits: [(threadID: UUID, snippet: String?)]) -> [ChatListTitleSearch.Row<Chat>] {
        ChatListTitleSearch.rows(list, id: \.id, title: \.title, query: query, hits: hits)
    }

    @Test func anImportedChatIsFoundByItsTitleWhenNoMessageHasIt() {
        let shown = rows("JPEG data URL", hits: [])
        #expect(shown.map(\.chat) == [imported])
        // Title-only: no snippet, so the row draws its plain preview line.
        #expect(shown.first?.snippet == nil)
        #expect(shown.first.flatMap(\.markedTitle).map(ChatSearchHighlight.plainText) == imported.title)
    }

    @Test func titlesFoldCaseAndDiacritics() {
        #expect(rows("cafe", hits: []).map(\.chat) == [recent])
        #expect(rows("MONTREAL", hits: []).map(\.chat) == [recent])
        #expect(rows("Café", hits: []).map(\.chat) == [recent])
    }

    @Test func theMatchedRunOfTheTitleIsMarked() throws {
        let marked = try #require(ChatListTitleSearch.markedTitle(recent.title, query: "cafe"))
        #expect(ChatSearchHighlight.plainText(marked) == "trip to Café Montréal")
        #expect(ChatSearchHighlight.segments(marked).filter(\.isMatch).map(\.text) == ["Café"])
        #expect(ChatListTitleSearch.markedTitle(groceries.title, query: "cafe") == nil)
        #expect(ChatListTitleSearch.markedTitle(nil, query: "cafe") == nil)
    }

    @Test func titleHitsComeFirstInListOrderThenIndexRankWithoutRepeats() {
        let camera = Chat(title: "camera notes")
        let zebra = Chat(title: "zebra")
        let opera = Chat(title: "opera")
        let chats = [camera, untitled, zebra, groceries, opera]
        // The index ranks the untitled chat, then opera (also a title match),
        // then groceries.
        let shown = ChatListTitleSearch.rows(
            chats, id: \.id, title: \.title, query: "ra",
            hits: [(untitled.id, "x"), (opera.id, "y"), (groceries.id, "z")])
        // Title matches in list order, then the index's remaining hits in rank
        // order; opera is listed once.
        #expect(shown.map(\.chat) == [camera, zebra, opera, untitled, groceries])
    }

    @Test func aChatWithNoTitleIsMatchedOnlyByTheIndex() {
        #expect(rows("groceries", hits: [(untitled.id, "\(open)groceries\(close) list")]).map(\.chat)
                == [groceries, untitled])
        #expect(rows("nothing here", hits: []).isEmpty)
    }

    @Test func aRowMatchingTitleAndMessageKeepsBothHighlights() throws {
        let snippet = "…the \(open)JPEG\(close) came through…"
        let shown = rows("jpeg", hits: [(imported.id, snippet)])
        #expect(shown.count == 1)
        let row = try #require(shown.first)
        #expect(row.chat == imported)
        #expect(row.snippet == snippet)
        let marked = try #require(row.markedTitle)
        #expect(ChatSearchHighlight.segments(marked).filter(\.isMatch).map(\.text) == ["JPEG"])
    }

    @Test func anIndexOnlyRowHasNoTitleMark() {
        let shown = rows("kettle", hits: [(groceries.id, "the \(open)kettle\(close)")])
        #expect(shown.map(\.chat) == [groceries])
        #expect(shown.first?.markedTitle == nil)
        #expect(shown.first?.snippet == "the \(open)kettle\(close)")
    }

    @Test func anIndexHitWithNoChatIsDropped() {
        #expect(rows("zzz", hits: [(UUID(), "gone"), (groceries.id, nil)]).map(\.chat) == [groceries])
    }

    @Test func aBlankQueryMatchesNoTitle() {
        #expect(ChatListTitleSearch.markedTitle("anything", query: "  ") == nil)
    }
}
