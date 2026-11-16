//
//  ChatListTitleSearch.swift
//  teemoon
//
//  The chats list's search matches titles as well as the index's message hits.
//  Same rule as Android's ChatListTitleSearch; change both or neither.
//

import Foundation

enum ChatListTitleSearch {

    struct Row<Chat> {
        let chat: Chat
        /// The whole title with the matched run delimited, when the title matched.
        let markedTitle: String?
        /// The message passage that matched, when the index (or fallback) found one.
        let snippet: String?
    }

    /// Case- and diacritic-insensitive substring only; do not add other folding.
    static func markedTitle(_ title: String?, query: String) -> String? {
        guard let title, !title.isEmpty else { return nil }
        return ChatSearchHighlight.excerpt(matching: query, in: [title], window: title.count)
    }

    /// Title matches first in `chats`' order, then `hits` in their order minus
    /// chats already listed. A hit whose chat is not in `chats` is dropped.
    static func rows<Chat>(_ chats: [Chat],
                           id: (Chat) -> UUID,
                           title: (Chat) -> String?,
                           query: String,
                           hits: [(threadID: UUID, snippet: String?)]) -> [Row<Chat>] {
        var snippets: [UUID: String?] = [:]
        for hit in hits where snippets[hit.threadID] == nil { snippets[hit.threadID] = hit.snippet }

        var listed = Set<UUID>()
        var result: [Row<Chat>] = []
        for chat in chats {
            guard let marked = markedTitle(title(chat), query: query) else { continue }
            listed.insert(id(chat))
            result.append(Row(chat: chat, markedTitle: marked, snippet: snippets[id(chat)] ?? nil))
        }
        let byID = Dictionary(chats.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        for hit in hits {
            guard let chat = byID[hit.threadID], listed.insert(hit.threadID).inserted else { continue }
            result.append(Row(chat: chat, markedTitle: nil, snippet: hit.snippet))
        }
        return result
    }
}
