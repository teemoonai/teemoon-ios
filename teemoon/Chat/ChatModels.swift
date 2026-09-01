//
//  ChatModels.swift
//  teemoon
//
//  SwiftData models for chat threads and messages.
//

import Foundation
import SwiftData

enum Role: String, Codable {
    case assistant
    case user
    case system
}

@Model
class Message {
    @Attribute(.unique) var id: UUID
    var role: Role
    var content: String
    var timestamp: Date
    var generatingTime: TimeInterval?
    var sourcesJSON: String? = nil
    /// Whether this message was sent/received with application-layer E2EE.
    var isE2EE: Bool = false

    @Relationship(inverse: \Thread.messages) var thread: Thread?

    @Transient private var _cachedSources: [GroundingSource]?
    @Transient private var _cachedSourcesJSON: String?

    var groundingSources: [GroundingSource] {
        if let cached = _cachedSources, _cachedSourcesJSON == sourcesJSON { return cached }
        guard let json = sourcesJSON,
              let data = json.data(using: .utf8),
              let sources = try? JSONDecoder().decode([GroundingSource].self, from: data)
        else { return [] }
        _cachedSources = sources
        _cachedSourcesJSON = sourcesJSON
        return sources
    }

    init(role: Role, content: String, thread: Thread? = nil, generatingTime: TimeInterval? = nil, sourcesJSON: String? = nil, isE2EE: Bool = false) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.thread = thread
        self.generatingTime = generatingTime
        self.sourcesJSON = sourcesJSON
        self.isE2EE = isE2EE
    }
}

@Model
final class Thread: Sendable {
    @Attribute(.unique) var id: UUID
    var title: String?
    var timestamp: Date

    @Relationship var messages: [Message] = []

    /// Monotonically increasing version counter bumped by `invalidateSortedMessages()`.
    @Transient private var _sortVersion: Int = 0
    @Transient private var _cachedSorted: [Message]?
    @Transient private var _cachedVersion: Int = -1

    var sortedMessages: [Message] {
        if _cachedVersion == _sortVersion, let cached = _cachedSorted { return cached }
        let sorted = messages.sorted { $0.timestamp < $1.timestamp }
        _cachedSorted = sorted
        _cachedVersion = _sortVersion
        return sorted
    }

    func invalidateSortedMessages() {
        _sortVersion += 1
        _cachedSorted = nil
    }

    init() {
        self.id = UUID()
        self.timestamp = Date()
    }
}
