//
//  MessageView.swift
//  teemoon

import SwiftUI
import Textual

// MARK: - TimeInterval formatting

extension TimeInterval {
    var formatted: String {
        let totalSeconds = Int(self)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes > 0 {
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        } else {
            return "\(seconds)s"
        }
    }

    /// One-decimal-place format for debug panels: "0.82s", "4.1s", "66.5s"
    var debugFormatted: String {
        String(format: "%.1fs", self)
    }
}

// MARK: - NSCache value wrapper

final class CacheEntry<T> {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - MessageView

struct MessageView: View {
    @State private var collapsed = true
    let message: Message
    let isLLMRunning: Bool
    var onRetry: (() -> Void)? = nil

    // MARK: - Cached thinking-content parse (persisted messages only)
    //
    // ONCE PER MESSAGE, NOT ONCE PER APPEARANCE.
    //
    // These used to be `@State` filled from `onAppear`. That was free while the
    // transcript was a plain VStack, because a row appeared exactly once — but
    // the transcript is a LazyVStack now, so a row is torn down when it leaves
    // the viewport and rebuilt with fresh (empty) @State when it comes back.
    // Per-appearance parsing turns every scroll-back into a re-parse of the
    // whole message and is precisely the hitch a lazy stack is supposed to
    // remove. A process-wide cache keyed on the message id fixes that: a
    // persisted message's content never changes, so the id is a complete key.
    //
    // NSCache, like `_attrCache` below, so it evicts under memory pressure
    // rather than growing with the session.

    private struct ThinkParse {
        let thinking: String?
        let answer: String?
        /// True when the `<think>` block was never closed. Folded in here so
        /// the body doesn't rescan the whole message for `</think>` on every
        /// evaluation.
        let isThinking: Bool
        /// Whether each half needs Textual's block renderer. Same reason:
        /// `needsStructuredText` runs ten `contains` passes over the content,
        /// which is not something to repeat per body evaluation.
        let answerNeedsStructuredText: Bool
        let thinkingNeedsStructuredText: Bool
    }

    private static let _thinkCache: NSCache<NSString, CacheEntry<ThinkParse>> = {
        let cache = NSCache<NSString, CacheEntry<ThinkParse>>()
        cache.countLimit = 400
        return cache
    }()

    private var thinkParse: ThinkParse {
        let key = message.id.uuidString as NSString
        if let hit = Self._thinkCache.object(forKey: key) { return hit.value }
        let (t, a) = ThinkingContentParser.parse(message.content)
        let parsed = ThinkParse(
            thinking: t,
            answer: a,
            isThinking: !message.content.contains("</think>"),
            answerNeedsStructuredText: a.map(Self.needsStructuredText) ?? false,
            thinkingNeedsStructuredText: t.map(Self.needsStructuredText) ?? false)
        Self._thinkCache.setObject(CacheEntry(parsed), forKey: key)
        return parsed
    }

    // MARK: - Disclosure state that survives leaving the viewport
    //
    // `collapsed` is @State, and a LazyVStack destroys a row's state when it
    // scrolls out of view. Without this, expanding a reasoning block, scrolling
    // down and scrolling back would find it collapsed again — the row is a new
    // view struct with a fresh `true`. Held outside the view, keyed on message
    // id, so the disclosure is a property of the MESSAGE rather than of the
    // row that happens to be showing it.
    //
    // Grows only by explicit taps, so it is bounded by what a person can do
    // with a thumb; nothing here justifies an eviction policy.
    @MainActor
    final class DisclosureState {
        static let shared = DisclosureState()
        private var expanded: Set<UUID> = []
        func isExpanded(_ id: UUID) -> Bool { expanded.contains(id) }
        func setExpanded(_ id: UUID, _ value: Bool) {
            if value { expanded.insert(id) } else { expanded.remove(id) }
        }
    }

    // MARK: - Fast-path rendering
    //
    // StructuredText parses markdown on every view creation. For messages that only
    // use inline markdown (bold, italic, inline code, links), we parse once to an
    // AttributedString, cache it, and render with a plain Text view (<1ms on cache hit).
    // StructuredText is only used for messages that need block-level rendering
    // (code fences, tables, lists, etc.), avoiding the parse cost on re-renders.

    static let _attrCache: NSCache<NSString, CacheEntry<AttributedString>> = {
        let cache = NSCache<NSString, CacheEntry<AttributedString>>()
        cache.countLimit = 200
        return cache
    }()
    private static let _parseOpts = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace)

    /// Escapes lone `~` characters (not part of `~~`) so they don't trigger
    /// false strikethrough rendering in Apple's markdown parser.
    private static func escapeLoneTildes(_ markdown: String) -> String {
        let chars = Array(markdown)
        var result = ""
        result.reserveCapacity(markdown.count)
        for i in chars.indices {
            if chars[i] == "~" {
                let prevIsTilde = i > 0 && chars[i - 1] == "~"
                let nextIsTilde = i + 1 < chars.count && chars[i + 1] == "~"
                if !prevIsTilde && !nextIsTilde {
                    result += "\\~"
                    continue
                }
            }
            result.append(chars[i])
        }
        return result
    }

    static func cachedAttr(_ markdown: String, key: String) -> AttributedString {
        let nsKey = key as NSString
        if let hit = _attrCache.object(forKey: nsKey) { return hit.value }
        let escaped = escapeLoneTildes(markdown)
        let result = (try? AttributedString(markdown: escaped, options: _parseOpts))
            ?? AttributedString(markdown)
        _attrCache.setObject(CacheEntry(result), forKey: nsKey)
        return result
    }

    /// Returns true for content requiring StructuredText's block-level rendering.
    static func needsStructuredText(_ markdown: String) -> Bool {
        // Code fences
        if markdown.contains("```") || markdown.contains("~~~") { return true }
        // Tables
        if markdown.contains("| ") && markdown.contains("|--") { return true }
        // Headings
        if markdown.hasPrefix("#") || markdown.contains("\n#") { return true }
        // Unordered lists
        if markdown.hasPrefix("- ") || markdown.contains("\n- ") { return true }
        if markdown.hasPrefix("* ") || markdown.contains("\n* ") { return true }
        if markdown.hasPrefix("+ ") || markdown.contains("\n+ ") { return true }
        // Ordered lists
        if markdown.hasPrefix("1. ") || markdown.contains("\n1. ") { return true }
        // Blockquotes
        if markdown.hasPrefix("> ") || markdown.contains("\n> ") { return true }
        return false
    }

    /// Fills empty markdown table cells with a non-breaking space so Textual
    /// doesn't collapse them and shift columns.
    static func fixEmptyTableCells(_ markdown: String) -> String {
        guard markdown.contains("|") else { return markdown }
        return markdown
            .replacingOccurrences(of: "| |", with: "| \u{00A0} |")
            .replacingOccurrences(of: "||", with: "| \u{00A0} |")
    }

    @ViewBuilder
    func renderedAssistantText(_ markdown: String, cacheKeySuffix: String, structured: Bool) -> some View {
        if structured {
            StructuredText.cached(markdown)
                .textual.textSelection(.enabled)
        } else {
            Text(MessageView.cachedAttr(markdown, key: message.id.uuidString + cacheKeySuffix))
                .textSelection(.enabled)
        }
    }

    static func processThinkingContent(_ content: String) -> (String?, String?) {
        let result = ThinkingContentParser.parse(content)
        return (result.thinking, result.answer)
    }

    var time: String {
        if let generatingTime = message.generatingTime {
            return "\(generatingTime.formatted)"
        }
        return "0s"
    }

    private func thinkingLabel(isThinking: Bool) -> some View {
        HStack {
            Button {
                toggleCollapsed()
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 12))
                    .fontWeight(.medium)
            }

            Text("\(isThinking ? "thinking..." : "thought for") \(time)")
                .italic()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private func toggleCollapsed() {
        collapsed.toggle()
        DisclosureState.shared.setExpanded(message.id, !collapsed)
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer() }

            if message.role == .assistant {
                let parse = thinkParse
                let thinking = parse.thinking
                let afterThink = parse.answer
                VStack(alignment: .leading, spacing: 16) {

                    if let thinking {
                        VStack(alignment: .leading, spacing: 12) {
                            thinkingLabel(isThinking: parse.isThinking)
                            if !collapsed {
                                if !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    HStack(spacing: 12) {
                                        Capsule()
                                            .frame(width: 2)
                                            .padding(.vertical, 1)
                                            .foregroundStyle(.fill)
                                        renderedAssistantText(thinking, cacheKeySuffix: "t",
                                                              structured: parse.thinkingNeedsStructuredText)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.leading, 5)
                                }
                            }
                        }
                        .contentShape(.rect)
                        .onTapGesture {
                            toggleCollapsed()
                        }
                    }

                    let sources = message.groundingSources
                    if let afterThink {
                        let hasSources = thinking == nil && !sources.isEmpty
                        renderedAssistantText(afterThink, cacheKeySuffix: "c",
                                              structured: parse.answerNeedsStructuredText)
                            .padding(.bottom, hasSources ? 12 : 0)
                    }

                    if thinking == nil, !sources.isEmpty {
                        SourceStackChipView(sources: sources)
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button {
                        let textToCopy = afterThink ?? message.content
                        #if os(iOS) || os(visionOS)
                        UIPasteboard.general.string = textToCopy
                        #elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(textToCopy, forType: .string)
                        #endif
                    } label: {
                        Label("Copy", systemImage: "square.on.square")
                    }
                }
            } else {
                Text(message.content)
                #if os(iOS) || os(visionOS)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                #else
                    .padding(.horizontal, 16 * 2 / 3)
                    .padding(.vertical, 8)
                #endif
                    .background(Self.platformBackgroundColor)
                #if os(iOS) || os(visionOS)
                    .mask(RoundedRectangle(cornerRadius: 24))
                #elseif os(macOS)
                    .mask(RoundedRectangle(cornerRadius: 16))
                #endif
                    .overlay(alignment: .bottomTrailing) {
                        if onRetry != nil {
                            Button { onRetry?() } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16, height: 16)
                                    .background(Self.platformBackgroundColor, in: Circle())
                                    .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("retry")
                            .accessibilityIdentifier("chat.retry")
                            .padding(.trailing, 10)
                            .offset(y: 8)
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeIn(duration: 0.4), value: onRetry != nil)
                    .contextMenu {
                        Button {
                            #if os(iOS) || os(visionOS)
                            UIPasteboard.general.string = message.content
                            #elseif os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                            #endif
                        } label: {
                            Label("Copy", systemImage: "square.on.square")
                        }
                    }
                    .padding(.leading, 48)
            }
        }
        .onAppear {
            // Restore a disclosure the user opened before this row was recycled
            // out of the lazy stack — see DisclosureState.
            if DisclosureState.shared.isExpanded(message.id) {
                collapsed = false
            } else if isLLMRunning {
                // `isLLMRunning` is now scoped by the caller to the turn in
                // flight, so this expands the reasoning of the message being
                // worked on and nothing else. It used to be true for EVERY row
                // whenever the thread had a generation running, which opened
                // every historic reasoning block on a mid-generation thread
                // open — and, under a lazy stack, would have fired again on
                // each scroll-in.
                collapsed = false
            }
        }
    }

    static let platformBackgroundColor = PlatformColors.secondaryBackground
}

// MARK: - Previews

#Preview("User Message Bubble") {
    VStack(spacing: 0) {
        MessageView(message: Message(role: .user, content: "What's the weather like today?"), isLLMRunning: false)
            .padding()
        MessageView(message: Message(role: .user, content: "Tell me a short story about a robot learning to paint."), isLLMRunning: false)
            .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("MessageView tok/s") {
    let sources = try! JSONEncoder().encode([
        GroundingSource(url: "https://techcrunch.com", domain: "techcrunch.com", title: "TechCrunch"),
        GroundingSource(url: "https://forbes.com", domain: "forbes.com", title: "Forbes")
    ])
    let msg = Message(role: .assistant,
                      content: "Fireworks AI is a private inference platform backed by Sequoia Capital. It focuses on fast, low-latency LLM serving.",
                      generatingTime: 2.8,
                      sourcesJSON: String(data: sources, encoding: .utf8))
    ScrollView {
        MessageView(message: msg, isLLMRunning: false)
            .padding()
    }
}
