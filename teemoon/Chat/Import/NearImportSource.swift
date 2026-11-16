//
//  NearImportSource.swift
//  teemoon
//
//  near.ai Private Chat exports (docs/IMPORT_NEAR.md §1–§4): the full export (an array of
//  conversations) and the per-chat "Export chat (.json)" file (one chat's items). Which
//  branch to keep is decided here, as near's own reader decides it. Expected results are
//  in conformance/import/near/cases.json; keep this in step with reference_import.py.
//
//  Never fetch an image_url: an inline data: URL is handed on as a placeholder's payload for the
//  writer's ImageIntake; anything else is a placeholder only.
//

import Foundation

struct NearImportSource: ChatImportSource {

    let name = "near"

    func detect(first: Any) -> ImportFileKind? {
        guard let object = first as? [String: Any] else { return nil }
        if object["data"] != nil { return .chatPerElement }
        if object["type"] != nil { return .singleChat }
        return nil
    }

    func chat(element: Data, depth: Int) -> ImportedChat? {
        guard let c = try? JSONSerialization.jsonObject(with: element) as? [String: Any],
              let id = Self.string(c["id"]), let data = c["data"] as? [Any]
        else { return nil }
        let meta = c["metadata"] as? [String: Any] ?? [:]
        return Self.chat(sourceId: id, title: Self.title(meta), createdAt: Self.int(c["created_at"]).map { $0 * 1000 },
                         data: data, legacy: Self.isLegacy(meta), mayBeIncomplete: false, skippedBefore: 0)
    }

    func chat(items: [(data: Data, depth: Int)], cutOff: Bool, fileBytes: Int) -> ImportedChat? {
        let depth = 1 + (items.map(\.depth).max() ?? 0)
        guard fileBytes <= ImportFileScanner.maxElementBytes, depth <= ImportFileScanner.maxDepth else { return nil }
        let data: [Any] = items.compactMap { try? JSONSerialization.jsonObject(with: $0.data, options: .fragmentsAllowed) }
        let readable = Self.readable(data)
        let ids = Set(readable.map(\.responseId))
        let root = readable.first { $0.previous.map { !ids.contains($0) } ?? true }?.responseId ?? readable.first?.responseId
        guard let root else {
            // Nothing readable: no chat, every element counted, then the chat itself.
            return ImportedChat(sourceId: "chat:", title: nil, createdAt: nil, messages: [],
                                itemsSkipped: data.count + (cutOff ? 1 : 0), mayBeIncomplete: false)
        }
        return Self.chat(sourceId: "chat:" + root, title: nil, createdAt: nil, data: data, legacy: false,
                         mayBeIncomplete: items.count + (cutOff ? 1 : 0) >= 100 || cutOff, skippedBefore: cutOff ? 1 : 0)
    }

    // MARK: Items

    private struct Item {
        let raw: [String: Any]
        let position: Int
        let id: String
        let responseId: String
        let createdAt: Int64
        let type: String?
        var previous: String? { NearImportSource.nonEmptyString(raw["previous_response_id"]) }
        var next: [String] { (raw["next_response_ids"] as? [Any] ?? []).compactMap(NearImportSource.string) }
        var role: Role? { (raw["role"] as? String).flatMap(Role.init(rawValue:)) }
    }

    /// Readable items in data order, duplicates after the first dropped (§3.1).
    private static func readable(_ data: [Any]) -> [Item] {
        var seen = Set<String>()
        var out: [Item] = []
        for (n, value) in data.enumerated() {
            guard let item = readable(value, position: n), seen.insert(item.id).inserted else { continue }
            out.append(item)
        }
        return out
    }

    private static func readable(_ value: Any, position: Int) -> Item? {
        guard let i = value as? [String: Any], let id = string(i["id"]), let resp = string(i["response_id"]),
              let created = int(i["created_at"]) else { return nil }
        let type = i["type"] as? String
        if type == "message" {
            guard i["content"] is [Any], let role = i["role"] as? String, ["user", "assistant", "system"].contains(role)
            else { return nil }
            if let status = i["status"] as? String, status == "failed" || status == "pending" { return nil }
        }
        return Item(raw: i, position: position, id: id, responseId: resp, createdAt: created, type: type)
    }

    // MARK: A chat

    private static func chat(sourceId: String, title: String?, createdAt: Int64?, data: [Any], legacy: Bool,
                             mayBeIncomplete: Bool, skippedBefore: Int) -> ImportedChat {
        let items = readable(data)
        var ordered = items
        if !legacy, let keep = path(items) {
            ordered = keep.sorted { ($0.createdAt, $0.position) < ($1.createdAt, $1.position) }
        }
        let messages: [ImportedMessage] = ordered.compactMap { item in
            guard item.type == "message", let role = item.role, role != .system else { return nil }
            return message(item, response: ordered.filter { $0.responseId == item.responseId })
        }
        return ImportedChat(sourceId: sourceId, title: title, createdAt: createdAt, messages: messages,
                            itemsSkipped: skippedBefore + data.count - items.count, mayBeIncomplete: mayBeIncomplete)
    }

    /// near's combineMessagesById + findLastResponseId (§3.3). nil when nothing can be a root (a loop).
    private static func path(_ items: [Item]) -> [Item]? {
        let responseIds = Set(items.map(\.responseId))
        var children: [String: [String]] = [:]
        var parent: [String: String] = [:]
        var present = Set<String>()
        var root: String?
        for item in items {
            present.insert(item.responseId)
            if root == nil, item.previous.map({ !responseIds.contains($0) }) ?? true { root = item.responseId }
            if let p = item.previous {
                parent[item.responseId] = p
                if !(children[p] ?? []).contains(item.responseId) { children[p, default: []].append(item.responseId) }
            }
            for x in item.next where !(children[item.responseId] ?? []).contains(x) {
                children[item.responseId, default: []].append(x)
            }
        }
        guard let root else { return nil }
        // Deepest response wins; first reached on a tie. Iterative, for long chains.
        var best = (depth: 0, id: root)
        var seen = Set<String>()
        var stack = [(root, 0)]
        while let (r, d) = stack.popLast() {
            guard present.contains(r), !seen.contains(r) else { continue }   // ids with no readable items are skipped
            seen.insert(r)
            if d > best.depth { best = (d, r) }
            for x in (children[r] ?? []).reversed() { stack.append((x, d + 1)) }
        }
        var onPath = Set<String>()
        var cur: String? = best.id
        while let c = cur, present.contains(c), !onPath.contains(c) {
            onPath.insert(c)
            cur = parent[c]
        }
        return items.filter { onPath.contains($0.responseId) }
    }

    private static func message(_ item: Item, response: [Item]) -> ImportedMessage {
        let content = item.raw["content"] as? [Any] ?? []
        var parts: [ImportedMessage.Part] = []
        for case let p as [String: Any] in content {
            let type = p["type"] as? String
            if type == "input_text" || type == "output_text" {
                if let text = p["text"] as? String, !text.isEmpty { parts.append(.text(text)) }
            } else {
                let name = nonEmptyString(p["name"]) ?? nonEmptyString(p["filename"])
                if type == "input_image" {
                    // image_url is a string in near's exports; tolerate {url:}. Only a data: URL is carried.
                    let url = nonEmptyString(p["image_url"]) ?? nonEmptyString((p["image_url"] as? [String: Any])?["url"])
                    parts.append(.placeholder(.init(kind: .image, name: name,
                                                    dataURL: url.flatMap { $0.hasPrefix("data:") ? $0 : nil })))
                } else {
                    parts.append(.placeholder(.init(kind: .file, name: name)))
                }
            }
        }
        var sources: [ImportedMessage.Source] = []
        if item.role == .assistant {
            for case let p as [String: Any] in content {
                for case let a as [String: Any] in p["annotations"] as? [Any] ?? [] {
                    guard a["type"] as? String == "url_citation", let url = nonEmptyString(a["url"]) else { continue }
                    sources.append(.init(url: url, title: nonEmptyString(a["title"])))
                }
            }
            for w in response where w.type == "web_search_call" {
                let action = w.raw["action"] as? [String: Any] ?? [:]
                for case let s as [String: Any] in action["sources"] as? [Any] ?? [] {
                    if let url = nonEmptyString(s["url"]) { sources.append(.init(url: url, title: nil)) }
                }
            }
        }
        return ImportedMessage(sourceId: item.id, role: item.role ?? .user, parts: parts,
                               createdAt: item.createdAt * 1000, sources: sources)
    }

    // MARK: Fields

    private static func title(_ meta: [String: Any]) -> String? {
        let t = (meta["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty || t == "New Conversation" ? nil : t
    }

    /// `imported_at` as a string or number that parses as finite; a boolean is not a marker.
    private static func isLegacy(_ meta: [String: Any]) -> Bool {
        guard let v = meta["imported_at"] else { return false }
        if let n = v as? NSNumber {
            return CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue.isFinite
        }
        if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d.isFinite }
        return false
    }

    fileprivate static func string(_ v: Any?) -> String? { v as? String }
    fileprivate static func nonEmptyString(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    /// An integer: not a boolean, not a float.
    static func int(_ v: Any?) -> Int64? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return nil }
        return n.int64Value
    }
}
