//
//  ThreadListTitle.swift
//  teemoon
//
//  A chat's name in the list: its title when it has one (only imported chats do), else
//  its first message, as Android names it (the maintainer, 2026-10-15; 1.1.0).
//

import Foundation

enum ThreadListTitle {
    static func text(title: String?, firstMessage: String?) -> String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return firstMessage ?? "untitled"
    }
}
